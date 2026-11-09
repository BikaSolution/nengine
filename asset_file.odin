package nengine

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import rl "vendor:raylib"

// Sprite files, and the table scenes look things up in.
//
// A .sprite file is a palette plus rows of characters, so a 16x16 sprite is
// a readable 16x16 block of text you can edit in any editor:
//
//     sprite hat
//     size 12 10
//     frames 1
//     pal . 0,0,0,0
//     pal # 28,26,32,255
//     frame 0
//     ..#######...
//     ..#######...
//
// nart writes these, both its editor and its `nart sprite` commands.

// Everything loaded from disk, by name. Scenes reference things by name
// ("lamp"), and this is what turns that into pixels and sound. A file's name
// without its extension is the name it goes in under, so `lamp.sprite`,
// `parlour.png` and `cat_purr.wav` become "lamp", "parlour" and "cat_purr".
Assets :: struct {
	sprites: map[string]Sprite,
	images:  map[string]rl.Texture2D, // backgrounds
	sounds:  map[string]rl.Sound,      // played whole: short ones at load, others on demand
	loops:   map[string]^Loop,         // streamed, made on demand (assets_loop)
	audio:   map[string]Audio_File,    // every sound's file, by name: what both are made from
	chars:   map[string]Character_Art, // whole characters: every pose, by name
	cuts:    map[string]Cutscene,      // cutscenes, by file name. See play_cutscene
	depths:  map[string]Depth_Map,     // .depth: a backdrop's or a sprite's depth map. See priority.odin
	solids:  map[string]Solid_Map,     // .solid: a backdrop's solid map
}

// The file a sound of a name plays from: of its .qoa, .ogg and .wav, the
// newest, and of two the same age the first in AUDIO_EXTENSIONS. A bake
// leaves one (audio.odin); two means one was written since, by an editor's
// export, and that is the one somebody wants to hear.
Audio_File :: struct {
	path:  string,
	rank:  int, // its place in AUDIO_EXTENSIONS
	mtime: i64, // unix nanoseconds
}

assets_destroy :: proc(a: ^Assets) {
	for name, s in a.sprites {
		rl.UnloadTexture(s.texture)
		delete(s.holds)
		delete(name)
	}
	for name, t in a.images {
		rl.UnloadTexture(t)
		delete(name)
	}
	for name, s in a.sounds {
		rl.UnloadSound(s)
		delete(name)
	}
	for name, l in a.loops {
		unload_loop(l)
		free(l)
		delete(name)
	}
	for name, f in a.audio {
		delete(name)
		delete(f.path)
	}
	for name, &c in a.chars {
		character_art_destroy(&c)
		delete(name)
	}
	for name, &c in a.cuts {
		cutscene_destroy(&c)
		delete(name)
	}
	for name, &m in a.depths {
		depth_map_destroy(&m)
		delete(name)
	}
	for name, &m in a.solids {
		solid_map_destroy(&m)
		delete(name)
	}
	delete(a.depths)
	delete(a.solids)
	delete(a.sprites)
	delete(a.images)
	delete(a.sounds)
	delete(a.loops)
	delete(a.audio)
	delete(a.chars)
	delete(a.cuts)
	a^ = {}
}

assets_sprite :: proc(a: ^Assets, name: string) -> Sprite {
	return a.sprites[name] if name in a.sprites else Sprite{}
}

// A sound to play whole (play_sound, a footstep, a tick). A short file was
// loaded with its folder; a long one only now, the first time it is asked
// for as a sound rather than streamed — which nothing in a game should need.
assets_sound :: proc(a: ^Assets, name: string) -> rl.Sound {
	if s, has := a.sounds[name]; has do return s
	f, has := a.audio[name]
	if !has do return {}
	s := rl.LoadSound(strings.clone_to_cstring(f.path, context.temp_allocator))
	if a.sounds == nil do a.sounds = make(map[string]rl.Sound)
	a.sounds[strings.clone(name)] = s // even a failure: it is not tried again
	return s
}

// The file a sound of this name plays from (Audio_File), if it has one.
assets_audio_path :: proc(a: ^Assets, name: string) -> (string, bool) {
	f, has := a.audio[name]
	return f.path, has
}

// The looping version of a sound, streamed from its file. Made the first
// time it's asked for: a scene's ambience and an object's hum are loops, and
// several scenes can share one; so is music (play_music, Menu.music).
//
// Only baked files. Songs and sounds are *sources* — text the tools edit — and
// the game never renders them, because rendering audio at startup is a cost
// the player pays for nothing. `just bake` turns them into .qoa and .wav.
assets_loop :: proc(a: ^Assets, name: string) -> ^Loop {
	if l, has := a.loops[name]; has do return l

	f, has := a.audio[name]
	if !has do return nil
	l := new(Loop)
	l^ = load_loop(strings.clone_to_cstring(f.path, context.temp_allocator))

	if a.loops == nil do a.loops = make(map[string]^Loop)
	a.loops[strings.clone(name)] = l
	return l
}

// Loads every asset file in a folder and the folders inside it: .sprite,
// .png, .qoa, .ogg, .wav, .char and .cut. Not .song or .sound — those are
// sources the tools edit, and the game only ever plays what `just bake` makes
// of them. Sprites are drawn `sprite_scale` times their size, which is how
// small hand-drawn art fills a big canvas; they are kept at their own
// (sprite.odin). Returns how many files it took in.
//
// A sound file is only noted, by name (Audio_File); then the short .wav
// files, the effects, are loaded whole as Sounds (LONG_SOUND_SECS or less),
// and everything else waits to be streamed (assets_loop): a .qoa is what a
// bake makes of a sound that is long or loops.
//
// Folders are only for keeping things findable — a file goes in under its own
// name wherever it sits, so `sprites/lamp.sprite` is just "lamp".
assets_load_folder :: proc(a: ^Assets, dir: string, sprite_scale: f32 = 1) -> (loaded: int) {
	loaded = assets_scan_folder(a, dir, sprite_scale)
	for name, f in a.audio {
		if name in a.sounds || !strings.has_suffix(f.path, ".wav") do continue
		if secs, known := audio_file_seconds(f.path); known && secs <= LONG_SOUND_SECS do assets_sound(a, name)
	}
	return
}

@(private = "file")
assets_scan_folder :: proc(a: ^Assets, dir: string, sprite_scale: f32) -> (loaded: int) {
	files, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil do return 0
	for f in files {
		path := fmt.tprintf("%v/%v", dir, f.name)
		if f.type == .Directory {
			loaded += assets_scan_folder(a, path, sprite_scale)
			continue
		}
		if rank := audio_extension(f.name); rank >= 0 {
			assets_note_audio(a, asset_name(f.name), path, rank, time.to_unix_nanoseconds(f.modification_time))
			loaded += 1
			continue
		}
		switch {
		case strings.has_suffix(f.name, ".sprite"):
			if assets_load_sprite(a, path, sprite_scale) do loaded += 1
		case strings.has_suffix(f.name, ".png"):
			if a.images == nil do a.images = make(map[string]rl.Texture2D)
			tex := rl.LoadTexture(strings.clone_to_cstring(path, context.temp_allocator))
			if tex.id == 0 do continue
			a.images[strings.clone(asset_name(f.name))] = tex
			loaded += 1
		case strings.has_suffix(f.name, ".char"):
			if assets_load_character(a, path, sprite_scale) do loaded += 1
		case strings.has_suffix(f.name, ".cut"):
			if assets_load_cutscene(a, path) do loaded += 1
		case strings.has_suffix(f.name, ".depth"), strings.has_suffix(f.name, ".solid"):
			if assets_load_map(a, path, f.name) do loaded += 1
		}
	}
	return
}

// A sound's file, noted under its name unless the name has a better one
// already (Audio_File). A better one replaces the old, and a Sound already
// made from the old goes with it. (Loops are made after the folders load, by
// the scenes, and are left alone: rooms hold them.)
assets_note_audio :: proc(a: ^Assets, name, path: string, rank: int, mtime: i64) {
	if a.audio == nil do a.audio = make(map[string]Audio_File)
	if old, has := &a.audio[name]; has {
		if mtime < old.mtime || (mtime == old.mtime && rank >= old.rank) do return
		delete(old.path)
		old^ = {strings.clone(path), rank, mtime}
		if s, had := a.sounds[name]; had {
			key, _ := delete_key(&a.sounds, name)
			rl.UnloadSound(s)
			delete(key)
		}
		return
	}
	a.audio[strings.clone(name)] = {strings.clone(path), rank, mtime}
}

// A .cut into the table under its file name, which is also the name it then
// goes by (the `cut` line's own is the editor's). A second file of the same
// name replaces the first.
assets_load_cutscene :: proc(a: ^Assets, path: string) -> bool {
	c, ok := load_cutscene(path)
	if !ok do return false
	slash := strings.last_index_byte(path, '/')
	name := asset_name(path[slash + 1:])
	delete(c.name)
	c.name = strings.clone(name)
	if a.cuts == nil do a.cuts = make(map[string]Cutscene)
	if old, has := &a.cuts[name]; has {
		cutscene_destroy(old)
		old^ = c
	} else {
		a.cuts[strings.clone(name)] = c
	}
	return true
}

// "cat_purr.wav" -> "cat_purr"
rl_color :: proc(r, g, b, a: u8) -> rl.Color {
	return {r, g, b, a}
}

asset_name :: proc(file_name: string) -> string {
	if dot := strings.last_index_byte(file_name, '.'); dot > 0 do return file_name[:dot]
	return file_name
}

// --- Sprite files ---

Sprite_Data :: struct {
	name:    string,
	w, h:    i32,
	frames:  i32,
	mode:    Palette_Mode, // which colours this picture is allowed. See palette.odin
	ramps:   [dynamic]Ramp, // materials: the tones a surface goes through. Authoring
	                        // data — the game never reads it. See palette.odin
	palette: [dynamic]Palette_Entry,
	pixels:  [dynamic]u8, // index into palette, frames * h rows of w
	// How many ticks each frame shows for, at the speed it is played at. Empty,
	// or shorter than `frames`, means one tick for every frame not listed.
	// See anim.odin.
	holds:   [dynamic]i32,
}

Palette_Entry :: struct {
	ch:    u8,
	color: rl.Color,
}

sprite_data_destroy :: proc(d: ^Sprite_Data) {
	ramps_destroy(&d.ramps)
	delete(d.palette)
	delete(d.pixels)
	delete(d.holds)
	delete(d.name)
}

// How many ticks frame `f` shows for. A frame nobody has set shows for one.
sprite_data_hold :: proc(d: ^Sprite_Data, f: i32) -> i32 {
	if f < 0 || int(f) >= len(d.holds) do return 1
	return max(d.holds[f], 1)
}

// Sets how many ticks frame `f` shows for. Below one is one.
sprite_data_set_hold :: proc(d: ^Sprite_Data, f, hold: i32) {
	if f < 0 || f >= d.frames do return
	for i32(len(d.holds)) <= f do append(&d.holds, 1)
	d.holds[f] = max(hold, 1)
}

// The holds as a list the length of the frames, or nil when every frame shows
// for one tick, which is what nearly every part is.
sprite_data_holds :: proc(d: ^Sprite_Data, allocator := context.allocator) -> []i32 {
	uneven := false
	for f in 0 ..< d.frames do if sprite_data_hold(d, f) != 1 do uneven = true
	if !uneven do return nil
	out := make([]i32, d.frames, allocator)
	for f in 0 ..< d.frames do out[f] = sprite_data_hold(d, f)
	return out
}

sprite_data_new :: proc(name: string, w, h, frames: i32) -> Sprite_Data {
	d := Sprite_Data {
		name   = strings.clone(name),
		w      = w,
		h      = h,
		frames = frames,
	}
	append(&d.palette, Palette_Entry{'.', {0, 0, 0, 0}}) // 0 is always transparent
	resize(&d.pixels, int(w * h * frames))
	return d
}

// Sets which colours a picture is allowed, and for bEGA seeds the palette with
// all sixteen of them.
//
// bEGA is seeded because sixteen is few enough to write out, and the payoff is
// that a picture which starts in bEGA has the same colour in the same slot as
// every other one: transparent, then the sixteen in colour-number order. Copy
// a patch of pixels from one bEGA picture into another and the colours survive
// the journey, because an index means the same thing at both ends.
//
// fEGA and VGA are not seeded. Sixty-four `pal` lines in every file, most of
// them for colours nobody used, is what the editors used to do with their
// thirty-two, and it was never worth it: a palette should be what the picture
// is made of.
sprite_data_set_mode :: proc(d: ^Sprite_Data, mode: Palette_Mode) {
	d.mode = mode
	if mode != .BEGA do return
	for c in BEGA {
		if _, have := sprite_data_slot_of(d, c); have do continue
		append(&d.palette, Palette_Entry{palette_char(len(d.palette) - 1), c})
	}
}

// Which slot holds this colour, if any does.
sprite_data_slot_of :: proc(d: ^Sprite_Data, c: rl.Color) -> (u8, bool) {
	for p, i in d.palette {
		if p.color == c do return u8(i), true
	}
	return 0, false
}

// Every colour in the palette the mode does not permit, as slot numbers.
//
// This reports rather than refuses, and the difference matters. A file is the
// truth: if it says a pixel is some off-grid brown then that is what the game
// will draw, and a loader that threw the picture away instead would lose work
// over a rule about authoring. The tools show this and offer to snap; nothing
// here decides for anybody.
sprite_data_offenders :: proc(d: ^Sprite_Data, into: ^[dynamic]u8) {
	clear(into)
	for p, i in d.palette {
		if i == 0 do continue // slot 0 is transparent by construction
		if !palette_mode_allows(d.mode, p.color) do append(into, u8(i))
	}
}

// Moves every colour onto the nearest one the mode permits.
//
// Two slots can land on the same colour — an off-grid picture usually has
// several tones that all snap to the same bEGA one — so the pixels are remapped
// onto the surviving slots and the duplicates go. Returns how many colours the
// picture came out with.
sprite_data_snap_to_mode :: proc(d: ^Sprite_Data) -> int {
	remap := make([]u8, len(d.palette), context.temp_allocator)
	fresh := make([dynamic]Palette_Entry, context.temp_allocator)
	append(&fresh, Palette_Entry{'.', {0, 0, 0, 0}})

	for p, i in d.palette {
		if i == 0 do continue
		want := palette_mode_snap(d.mode, p.color)
		found := false
		for have, hi in fresh {
			if have.color == want {
				remap[i], found = u8(hi), true
				break
			}
		}
		if !found {
			append(&fresh, Palette_Entry{palette_char(len(fresh) - 1), want})
			remap[i] = u8(len(fresh) - 1)
		}
	}
	for &cell in d.pixels do cell = remap[int(cell)] if int(cell) < len(remap) else 0

	clear(&d.palette)
	append(&d.palette, ..fresh[:])
	return len(d.palette) - 1
}

sprite_data_at :: proc(d: ^Sprite_Data, frame, x, y: i32) -> ^u8 {
	if x < 0 || y < 0 || x >= d.w || y >= d.h || frame < 0 || frame >= d.frames do return nil
	return &d.pixels[int(frame * d.w * d.h + y * d.w + x)]
}

// Changes the size of the grid, keeping whatever still fits in the corner.
// Growing pads with transparent; shrinking crops.
sprite_data_resize :: proc(d: ^Sprite_Data, want_w, want_h: i32) {
	w, h := clamp(want_w, 1, 4096), clamp(want_h, 1, 4096)
	if w == d.w && h == d.h do return

	fresh := make([dynamic]u8)
	resize(&fresh, int(w * h * d.frames))
	for f in 0 ..< d.frames {
		for y in 0 ..< min(h, d.h) {
			for x in 0 ..< min(w, d.w) {
				fresh[int(f * w * h + y * w + x)] = sprite_data_at(d, f, x, y)^
			}
		}
	}
	delete(d.pixels)
	d.pixels = fresh
	d.w, d.h = w, h
}

load_sprite_data :: proc(path: string) -> (d: Sprite_Data, ok: bool) {
	text := read_data_file(path) or_return
	return parse_sprite_data(text)
}

// The same, from text already in hand. The editors' undo keeps documents as
// text, so that what you undo to is exactly what would have been saved.
parse_sprite_data :: proc(text: string) -> (d: Sprite_Data, ok: bool) {
	d.frames = 1
	frame: i32 = -1
	row: i32 = 0

	// Lines are read by hand rather than with data_lines, because a row of
	// pixels is not a line of keywords: "#" is a perfectly good palette
	// character, and a row of solid colour would otherwise read as a comment
	// and vanish. So comments and blank lines only count in the header,
	// before the first `frame`; after that every line is pixels.
	rest := text
	for raw_line in strings.split_lines_iterator(&rest) {
		raw := strings.trim_right_space(raw_line)

		// Inside a frame, every line is pixels — except the one that starts
		// the next frame, which no row can be mistaken for, since a space is
		// never a palette character.
		if frame >= 0 && !strings.has_prefix(raw, "frame ") {
			for i := 0; i < len(raw) && i32(i) < d.w; i += 1 {
				idx: u8 = 0
				for p, pi in d.palette {
					if p.ch == raw[i] {
						idx = u8(pi)
						break
					}
				}
				if cell := sprite_data_at(&d, frame, i32(i), row); cell != nil do cell^ = idx
			}
			row += 1
			continue
		}

		raw = strings.trim_space(raw)
		if raw == "" || strings.has_prefix(raw, "#") do continue
		l := parse_line(raw)
		switch l.key {
		case "sprite":
			if len(l.words) > 0 do d.name = strings.clone(l.words[0])
		case "size":
			if len(l.words) >= 2 {
				w, _ := strconv.parse_int(l.words[0])
				h, _ := strconv.parse_int(l.words[1])
				d.w, d.h = i32(w), i32(h)
			}
		case "frames":
			if len(l.words) > 0 {
				n, _ := strconv.parse_int(l.words[0])
				d.frames = i32(max(n, 1))
			}
		case "mode":
			// A file that doesn't say is VGA, which is what every file written
			// before there were modes is: unconstrained, and still correct.
			if len(l.words) > 0 do d.mode, _ = palette_mode_from_name(l.words[0])
		case "ramp":
			if r, got := parse_ramp(l.words); got do append(&d.ramps, r)
		case "pal":
			if len(l.words) >= 2 {
				append(&d.palette, Palette_Entry{l.words[0][0], palette_colour(l.words)})
			}
		case "frame":
			if len(d.pixels) == 0 do resize(&d.pixels, int(d.w * d.h * d.frames))
			n := 0
			if len(l.words) > 0 do n, _ = strconv.parse_int(l.words[0])
			frame = i32(n)
			row = 0
			// `frame 2 hold=3`: this frame shows for three ticks, as in a .char.
			if hold := field_int(l, "hold", 1); hold != 1 do sprite_data_set_hold(&d, frame, i32(hold))
		}
	}
	if len(d.palette) == 0 do append(&d.palette, Palette_Entry{'.', {0, 0, 0, 0}})
	return d, d.w > 0 && d.h > 0
}

save_sprite_data :: proc(d: ^Sprite_Data, path: string) -> bool {
	return write_data_file(path, sprite_data_text(d))
}

sprite_data_text :: proc(d: ^Sprite_Data, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "# nengine sprite\nsprite %v\nsize %v %v\nframes %v\n", d.name, d.w, d.h, d.frames)
	fmt.sbprintf(&b, "mode %v\n", palette_mode_name(d.mode))
	write_ramps(&b, d.ramps[:])
	for p in d.palette {
		fmt.sbprintf(&b, "pal %c %v,%v,%v,%v\n", rune(p.ch), p.color.r, p.color.g, p.color.b, p.color.a)
	}
	for f in 0 ..< d.frames {
		if hold := sprite_data_hold(d, i32(f)); hold != 1 {
			fmt.sbprintf(&b, "frame %v hold=%v\n", f, hold)
		} else {
			fmt.sbprintf(&b, "frame %v\n", f)
		}
		for y in 0 ..< d.h {
			for x in 0 ..< d.w {
				idx := sprite_data_at(d, f, x, y)^
				ch := d.palette[int(idx)].ch if int(idx) < len(d.palette) else '.'
				strings.write_byte(&b, ch)
			}
			strings.write_byte(&b, '\n')
		}
	}
	return strings.to_string(b)
}

// Turns the pixel data into a sprite sheet on the GPU, frames left to right,
// one texel per painted pixel. `scale` is how big it is drawn, not how big it
// is kept: the small hand-drawn art fills a large canvas as it is drawn
// (sprite.odin), so a 320x200 backdrop at 3.2 is 320x200 texels and draws
// 1024x640. It needn't be a whole number.
sprite_data_to_sprite :: proc(d: ^Sprite_Data, scale: f32 = 1) -> Sprite {
	s := max(scale, 0.01)
	img := rl.GenImageColor(d.w * d.frames, d.h, rl.BLANK)
	defer rl.UnloadImage(img)
	sprite_data_paint(d, img)
	// Frame holds go with it, so a room's object can sway on its own rhythm:
	// a gust, a long stillness, a smaller one.
	holds := sprite_data_holds(d)
	tex := rl.LoadTextureFromImage(img)
	rl.SetTextureFilter(tex, .POINT) // nearest: blown up as drawn, never blurred
	return {
		texture = tex,
		frame_w = sprite_up(d.w, s),
		frame_h = sprite_up(d.h, s),
		frames  = d.frames,
		holds   = holds,
		w       = d.w,
		h       = d.h,
		scale   = s,
	}
}

// The frames, left to right, into an image of exactly that size: each pixel
// its palette colour, as it is (no blending), and transparent where it is 0.
@(private)
sprite_data_paint :: proc(d: ^Sprite_Data, img: rl.Image) {
	out := ([^]rl.Color)(img.data)
	for f in 0 ..< d.frames {
		for y in 0 ..< d.h {
			for x in 0 ..< d.w {
				idx := int(sprite_data_at(d, f, x, y)^)
				if idx == 0 || idx >= len(d.palette) do continue
				out[y * img.width + f * d.w + x] = d.palette[idx].color
			}
		}
	}
}

// The same frames as a picture blown up by `scale` on the CPU, for writing a
// .png at the size the game draws it. Each block is measured from where the
// last one ended, so the blocks tile exactly with no seams or overlaps: art
// pixel x covers columns sprite_up(x) up to sprite_up(x+1), which is also
// where drawing a Sprite puts it. The caller unloads the image.
sprite_data_to_image :: proc(d: ^Sprite_Data, scale: f32 = 1) -> rl.Image {
	s := max(scale, 0.01)
	frame_w, frame_h := sprite_up(d.w, s), sprite_up(d.h, s)
	img := rl.GenImageColor(frame_w * d.frames, frame_h, rl.BLANK)
	for f in 0 ..< d.frames {
		for y in 0 ..< d.h {
			y0, y1 := sprite_up(y, s), sprite_up(y + 1, s)
			for x in 0 ..< d.w {
				idx := int(sprite_data_at(d, f, x, y)^)
				if idx == 0 || idx >= len(d.palette) do continue
				x0, x1 := sprite_up(x, s), sprite_up(x + 1, s)
				rl.ImageDrawRectangle(&img, f * frame_w + x0, y0, x1 - x0, y1 - y0, d.palette[idx].color)
			}
		}
	}
	return img
}

// Load a .sprite straight onto the GPU and into the table under its name.
assets_load_sprite :: proc(a: ^Assets, path: string, scale: f32 = 1) -> bool {
	d, ok := load_sprite_data(path)
	if !ok do return false
	defer sprite_data_destroy(&d)
	if a.sprites == nil do a.sprites = make(map[string]Sprite)
	a.sprites[strings.clone(d.name)] = sprite_data_to_sprite(&d, scale)
	return true
}

// The other direction: a drawn image becomes pixel data you can save as a
// .sprite. This is how art drawn in code becomes a file you can then edit in
// the tools — after which the file is the truth and the code goes away.
sprite_data_from_image :: proc(name: string, img: rl.Image, frame_w, frames: i32) -> (d: Sprite_Data, ok: bool) {
	colors := rl.LoadImageColors(img)
	defer rl.UnloadImageColors(colors)
	if colors == nil do return {}, false

	d = sprite_data_new(name, frame_w, img.height, frames)
	for f in 0 ..< frames {
		for y in 0 ..< img.height {
			for x in 0 ..< frame_w {
				sx := f * frame_w + x
				if sx >= img.width do continue
				c := colors[int(y * img.width + sx)]
				if c.a == 0 do continue
				cell := sprite_data_at(&d, f, x, y)
				if cell == nil do continue
				cell^ = palette_index(&d, c) or_else 0
			}
		}
	}
	return d, true
}

// The palette slot for this colour, adding it if it's new. Fails only if the
// sprite has more colours than there are characters to name them with.
@(private)
palette_index :: proc(d: ^Sprite_Data, c: rl.Color) -> (u8, bool) {
	for p, i in d.palette {
		if p.color == c do return u8(i), true
	}
	slot := len(d.palette) - 1 // slot 0 is transparent, and isn't named
	ch := palette_char(slot)
	if ch == '?' do return 0, false
	append(&d.palette, Palette_Entry{ch, c})
	return u8(len(d.palette) - 1), true
}

// The colour on a `pal` line. Written as `pal <ch> <r,g,b,a>`, but a hand-
// written file may put something between the two — ada.char has `pal o #
// 86,42,30,255`, where the `#` reads as a separator. So the colour is found
// rather than counted to: it is the word with the commas in it.
//
// Getting this wrong is silent and total. A colour that fails to parse is
// {0,0,0,0}, which is transparent, so every character in the game turns
// invisible while the art itself is perfectly intact.
palette_colour :: proc(words: []string) -> rl.Color {
	for w in words[1:] {
		parts := strings.split(w, ",", context.temp_allocator)
		if len(parts) < 4 do continue
		r, r_ok := strconv.parse_int(parts[0])
		g, g_ok := strconv.parse_int(parts[1])
		b, b_ok := strconv.parse_int(parts[2])
		a, a_ok := strconv.parse_int(parts[3])
		if !r_ok || !g_ok || !b_ok || !a_ok do continue
		return {u8(r), u8(g), u8(b), u8(a)}
	}
	return {}
}
