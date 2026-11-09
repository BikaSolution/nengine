package assetcache

import ne "../../"
import "core:fmt"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

// The art a tool is showing, and only that. Shared by the room editor
// (nscene) and the cutscene editor (nart/cutscene).
//
// The room editor used to open a scene by loading the game's whole assets
// folder — every sprite, every character, every backdrop in every light, a
// thousand textures — so that it could draw the dozen a room names and offer
// the rest on a shelf down the side. Opening the office took six hundred
// megabytes, and the browser did the same again for every room it previewed.
// The cutscene editor did the same to draw a room and ten people in it.
//
// Now there are two pieces. The **index** is the asset folder's names and
// where each file is, read once from the folder listing and the first line of
// each file, with no pixels in it. The **cache** loads a picture the first
// time something draws it, and lets it go when nothing has drawn it since the
// last time the room changed — an object given another sprite, the light
// switched, the editor closed.
//
// NSCENE_TRACE=1 (or NART_TRACE=1) says on stderr what it loads and lets go.

// Every piece of art in an assets folder, by the name a scene calls it: a
// sprite's `sprite` line, a character's `character` line, a picture's file
// name. That is the engine's naming (asset_file.odin), worked out without
// reading the pixels.
Asset_Index :: struct {
	root:    string, // owned; "" before it is built
	sprites: map[string]string, // name -> path, both owned
	images:  map[string]string, // .png backdrops
	chars:   map[string]string,
}

index_destroy :: proc(ix: ^Asset_Index) {
	for k, v in ix.sprites {
		delete(k)
		delete(v)
	}
	for k, v in ix.images {
		delete(k)
		delete(v)
	}
	for k, v in ix.chars {
		delete(k)
		delete(v)
	}
	delete(ix.sprites)
	delete(ix.images)
	delete(ix.chars)
	delete(ix.root)
	ix^ = {}
}

// Builds the index for `root`, unless it is already that one's.
index_build :: proc(ix: ^Asset_Index, root: string) {
	if ix.root == root && ix.root != "" do return
	index_destroy(ix)
	ix.root = strings.clone(root)
	index_walk(ix, root, 0)
	trace("index %v: %v sprites, %v pictures, %v characters", root, len(ix.sprites), len(ix.images), len(ix.chars))
}

@(private = "file")
index_walk :: proc(ix: ^Asset_Index, dir: string, depth: int) {
	if depth > 8 do return
	files, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil do return
	for f in files {
		path := fmt.tprintf("%v/%v", dir, f.name)
		if f.type == .Directory {
			index_walk(ix, path, depth + 1)
			continue
		}
		switch {
		case strings.has_suffix(f.name, ".sprite"):
			put(&ix.sprites, header_name(path, "sprite", ne.asset_name(f.name)), path)
		case strings.has_suffix(f.name, ".char"):
			put(&ix.chars, header_name(path, "character", ne.asset_name(f.name)), path)
		case strings.has_suffix(f.name, ".png"):
			put(&ix.images, ne.asset_name(f.name), path)
		}
	}
	put :: proc(m: ^map[string]string, name, path: string) {
		if old, has := m[name]; has {
			delete(old)
			m[name] = strings.clone(path)
			return
		}
		m[strings.clone(name)] = strings.clone(path)
	}
}

// The name a file gives itself on its first line that is not a comment —
// `sprite lamp` — or its file name if it does not say. Only the head of the
// file is read: the name is near the top and the pixels are not wanted.
@(private = "file")
header_name :: proc(path, key, fallback: string) -> string {
	f, err := os.open(path)
	if err != nil do return fallback
	defer os.close(f)
	buf: [4096]u8
	n, _ := os.read(f, buf[:])
	rest := string(buf[:n])
	for line in strings.split_lines_iterator(&rest) {
		t := strings.trim_space(line)
		if t == "" || t[0] == '#' do continue
		if strings.has_prefix(t, key) && len(t) > len(key) && t[len(key)] == ' ' {
			name := strings.trim_space(t[len(key):])
			if sp := strings.index_byte(name, ' '); sp > 0 do name = name[:sp]
			if name != "" do return strings.clone(name, context.temp_allocator)
		}
		break
	}
	return fallback
}

// The name the game looks a file up by — its own name for itself, which the
// index has — or "" if it is not in these assets. `pool` is ix.sprites,
// ix.chars or ix.images.
index_name_of :: proc(pool: map[string]string, path: string) -> string {
	for n, p in pool do if p == path do return n
	return ""
}

// The asset that stands for `name` in `light`: its own painting if there is
// one, or the one it borrows (light.odin: sunrise from sunset, either from
// day). "" when nothing is painted for that light at all — a lamp by day.
lit_name :: proc(ix: ^Asset_Index, name: string, light: ne.Light, images := false) -> (key: string, painted: bool) {
	l := light
	for {
		k := strings.concatenate({name, ne.LIGHT_SUFFIX[l]}, context.temp_allocator)
		if (images && k in ix.images) || k in ix.sprites do return k, l == light
		if l == .Day do return "", false
		l = ne.light_fallback(l)
	}
}

// Which lights `name` was painted in.
painted_lights :: proc(ix: ^Asset_Index, name: string, images := false) -> (out: bit_set[ne.Light]) {
	for l in ne.Light {
		k := strings.concatenate({name, ne.LIGHT_SUFFIX[l]}, context.temp_allocator)
		if (images && k in ix.images) || k in ix.sprites do out += {l}
	}
	return
}

trace :: proc(format: string, args: ..any) {
	if os.get_env("NSCENE_TRACE", context.temp_allocator) == "" && os.get_env("NART_TRACE", context.temp_allocator) == "" do return
	fmt.eprintfln(format, ..args)
}

// --- The cache ---

Art :: struct {
	index:   Asset_Index,
	scale:   f32, // how much the art is blown up: 3.2 puts 320-wide art on a 1024 room
	sprites: map[string]Art_Sprite, // by asset name ("admin.night")
	chars:   map[string]Art_Char,   // by character name
	frame:   int, // the editor's frame count: what was drawn this frame is wanted
	loaded:  int, // how many are on the GPU now, for the trace and the tests
}

Art_Sprite :: struct {
	sprite: ne.Sprite, // texture 0 when the file is missing or unreadable
	seen:   int,
}

Art_Char :: struct {
	data:  ne.Character, // the poses as pixels: small, and wanted for the list of poses
	ok:    bool,
	parts: map[string]Art_Sprite, // the poses drawn, uploaded as they are wanted
	seen:  int,
}

art_destroy :: proc(a: ^Art) {
	for k, &s in a.sprites {
		unload_sprite(&s.sprite)
		delete(k)
	}
	for k, &c in a.chars {
		char_unload(&c)
		delete(k)
	}
	delete(a.sprites)
	delete(a.chars)
	if a.loaded > 0 do trace("art: %v still loaded at close", a.loaded)
	index_destroy(&a.index)
	a^ = {}
}

@(private = "file")
unload_sprite :: proc(s: ^ne.Sprite) {
	if s.texture.id != 0 do rl.UnloadTexture(s.texture)
	delete(s.holds)
	s^ = {}
}

@(private = "file")
char_unload :: proc(c: ^Art_Char) {
	for k, &p in c.parts {
		unload_sprite(&p.sprite)
		delete(k)
	}
	delete(c.parts)
	if c.ok do ne.character_destroy(&c.data)
	c^ = {}
}

// A picture by its asset name, loaded the first time it is asked for.
art_sprite :: proc(a: ^Art, name: string, images := false) -> ne.Sprite {
	if name == "" do return {}
	if s, has := &a.sprites[name]; has {
		s.seen = a.frame
		return s.sprite
	}
	entry := Art_Sprite{seen = a.frame}
	if path, ok := a.index.images[name]; ok && images {
		tex := rl.LoadTexture(strings.clone_to_cstring(path, context.temp_allocator))
		if tex.id != 0 {
			rl.SetTextureFilter(tex, .POINT)
			entry.sprite = ne.texture_sprite(tex)
		}
		trace("load picture %v", name)
	} else if file, found := a.index.sprites[name]; found {
		if d, read := ne.load_sprite_data(file); read {
			entry.sprite = ne.sprite_data_to_sprite(&d, a.scale)
			ne.sprite_data_destroy(&d)
		}
		trace("load sprite %v", name)
	}
	if entry.sprite.texture.id != 0 do a.loaded += 1
	a.sprites[strings.clone(name)] = entry
	return entry.sprite
}

// `name` as painted for `light`, or what it borrows; and whether that is its
// own painting.
art_lit :: proc(a: ^Art, name: string, light: ne.Light, images := false) -> (ne.Sprite, bool) {
	key, painted := lit_name(&a.index, name, light, images)
	if key == "" do return {}, false
	return art_sprite(a, key, images), painted
}

@(private = "file")
art_char :: proc(a: ^Art, name: string) -> ^Art_Char {
	if c, has := &a.chars[name]; has {
		c.seen = a.frame
		return c
	}
	entry := Art_Char{seen = a.frame}
	if path, found := a.index.chars[name]; found {
		entry.data, entry.ok = ne.load_character(path)
		trace("load character %v", name)
	}
	a.chars[strings.clone(name)] = entry
	return &a.chars[name]
}

// One pose of a character, uploaded the first time it is drawn.
art_char_part :: proc(a: ^Art, name, part: string) -> ne.Sprite {
	if name == "" do return {}
	c := art_char(a, name)
	if !c.ok do return {}
	if p, has := &c.parts[part]; has {
		p.seen = a.frame
		return p.sprite
	}
	entry := Art_Sprite{seen = a.frame}
	if cp := ne.character_part(&c.data, part); cp != nil {
		entry.sprite = ne.sprite_data_to_sprite(&cp.data, a.scale)
		if entry.sprite.texture.id != 0 do a.loaded += 1
	}
	c.parts[strings.clone(part)] = entry
	return entry.sprite
}

// The poses a character has, for choosing one. Empty if it will not load.
art_char_poses :: proc(a: ^Art, name: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	if name == "" do return out[:]
	c := art_char(a, name)
	if !c.ok do return out[:]
	for &p in c.data.parts do append(&out, p.name)
	return out[:]
}

// A character's poses as data — their names, sizes and speeds — or nil if it
// will not load. Counts as drawn this frame.
art_char_data :: proc(a: ^Art, name: string) -> ^ne.Character {
	if name == "" do return nil
	c := art_char(a, name)
	return &c.data if c.ok else nil
}

// Lets go of everything that was not drawn this frame. Called on the frame
// after something changed what the room shows.
art_sweep :: proc(a: ^Art) {
	gone := make([dynamic]string, context.temp_allocator)
	for k, &s in a.sprites do if s.seen < a.frame {
		if s.sprite.texture.id != 0 {
			a.loaded -= 1
			trace("unload sprite %v", k)
		}
		unload_sprite(&s.sprite)
		append(&gone, k)
	}
	for k in gone {
		delete_key(&a.sprites, k)
		delete(k)
	}
	clear(&gone)
	for k, &c in a.chars {
		if c.seen < a.frame {
			for _, p in c.parts do if p.sprite.texture.id != 0 do a.loaded -= 1
			trace("unload character %v", k)
			char_unload(&c)
			append(&gone, k)
			continue
		}
		// A pose nobody stands in any more.
		parts := make([dynamic]string, context.temp_allocator)
		for pk, p in c.parts do if p.seen < a.frame do append(&parts, pk)
		for pk in parts {
			p := c.parts[pk]
			if p.sprite.texture.id != 0 do a.loaded -= 1
			unload_sprite(&p.sprite)
			delete_key(&c.parts, pk)
			delete(pk)
		}
	}
	for k in gone {
		delete_key(&a.chars, k)
		delete(k)
	}
}
