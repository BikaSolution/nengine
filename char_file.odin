package nengine

import "core:fmt"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

// Character files: everything one person looks like, in one file.
//
// A character needs more than a sprite. They stand facing four ways, walk in
// four directions, talk, and have a face for close-ups — so a .char file is
// a list of named parts, each its own little grid of frames, all sharing one
// palette so the character stays one character.
//
//     character potato
//     size 16 28
//     pal . 0,0,0,0
//     pal # 28,26,32,255
//     part front frames=1
//     frame 0
//     ..####..
//     part walk_right frames=4 fps=8
//     frame 0
//     ...
//
// The character editor in nart writes these. Games ask for a part by
// name: assets_char_part(&assets, "potato", "walk_left").

// The parts the engine picks by itself. `Actor.character` chooses one of
// these from the direction walked, so every character is expected to have
// them and the editor lists them first.
//
// **A character may have as many more as it likes.** Anything not on this
// list is an extra pose: sitting, kneeling, at a tripod, dead. Nothing picks
// those automatically — a routine asks for one by name with
// `step moore play chair 4`, a cutscene cue does the same, and game code
// sets `Actor.pose`. That is the whole difference between the ten and the
// rest, and it is the reason the ten are a list rather than an enum.
CHAR_PARTS := [?]string {
	"front", "back", "left", "right",
	"walk_front", "walk_back", "walk_left", "walk_right",
	"talk", "face",
}

// What each one is for, for the editor to show.
CHAR_PART_HELP := [?]string {
	"standing, towards you", "standing, away", "standing, facing left", "standing, facing right",
	"walking towards you", "walking away", "walking left", "walking right",
	"talking, head to toe", "the face, close up, talking",
}

// Is this one of the ten the engine chooses on its own? Extras are renamed
// and removed freely; these are not, because something is looking for them.
char_part_standard :: proc(name: string) -> bool {
	for p in CHAR_PARTS do if p == name do return true
	return false
}

// What a standard part is for, or "" for an extra.
char_part_help :: proc(name: string) -> string {
	for p, i in CHAR_PARTS do if p == name do return CHAR_PART_HELP[i]
	return ""
}

// What a pose may be called. A part name is the second word of a `part` line
// and is typed into routines and cutscene cues, so a space would split it in
// two and an `=` would look like a field. Lower case, digits and underscores,
// starting with a letter — the same shape as everything else the tools take.
char_part_name_ok :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > 24 do return false
	if name == "part" || name == "frame" do return false // would shadow the format's own words
	for i in 0 ..< len(name) {
		ch := name[i]
		switch {
		case ch >= 'a' && ch <= 'z': // always fine
		case ch >= '0' && ch <= '9', ch == '_':
			if i == 0 do return false // a name starts with a letter
		case:
			return false
		}
	}
	return true
}

Character :: struct {
	name:  string,
	w, h:  i32, // the size a new part starts at
	mode:  Palette_Mode, // which colours this character is allowed. See palette.odin
	ramps: [dynamic]Ramp, // materials shared by every pose. See palette.odin
	parts: [dynamic]Character_Part,
}

// One pose. `data` is the same pixel grid a .sprite holds, so the drawing
// and the editing are the same code.
Character_Part :: struct {
	name: string,
	fps:  f32,
	data: Sprite_Data,
}

character_new :: proc(name: string, w: i32 = 16, h: i32 = 28) -> Character {
	return {name = strings.clone(name), w = w, h = h}
}

character_destroy :: proc(c: ^Character) {
	for &p in c.parts {
		delete(p.name)
		sprite_data_destroy(&p.data)
	}
	delete(c.parts)
	ramps_destroy(&c.ramps)
	delete(c.name)
	c^ = {}
}

character_part :: proc(c: ^Character, name: string) -> ^Character_Part {
	for &p in c.parts {
		if p.name == name do return &p
	}
	return nil
}

// The colours the character is drawn in. Every part shares them, so a new
// pose can start with the tray the rest of the character already uses rather
// than an empty one.
character_palette :: proc(c: ^Character) -> []Palette_Entry {
	for &p in c.parts do if len(p.data.palette) > 1 do return p.data.palette[:]
	return nil
}

// Adds a part, or hands back the one already there.
character_add_part :: proc(c: ^Character, name: string, frames: i32 = 1, fps: f32 = 0) -> ^Character_Part {
	if p := character_part(c, name); p != nil do return p
	data := sprite_data_new(name, c.w, c.h, frames)
	// Take the character's colours, and the constraint they were chosen under.
	// Done before the append, because that can move the parts and the palette
	// we are copying lives inside one of them.
	if pal := character_palette(c); len(pal) > 1 {
		clear(&data.palette)
		append(&data.palette, ..pal)
		data.mode = c.mode
	} else {
		sprite_data_set_mode(&data, c.mode)
	}
	append(&c.parts, Character_Part{name = strings.clone(name), fps = fps, data = data})
	return &c.parts[len(c.parts) - 1]
}

// A new pose that starts as a copy of an existing one — which is how most
// extras are actually drawn: sitting is standing with the legs redone, and
// nobody wants to redraw a head to find that out. Returns nil if `from` is
// not there, or `to` is already taken or not a name a part may have.
character_copy_part :: proc(c: ^Character, from, to: string) -> ^Character_Part {
	if !char_part_name_ok(to) || character_part(c, to) != nil do return nil
	src := character_part(c, from)
	if src == nil do return nil

	// Built and filled before the append, for the same reason as above.
	data := sprite_data_new(to, src.data.w, src.data.h, src.data.frames)
	clear(&data.palette)
	append(&data.palette, ..src.data.palette[:])
	copy(data.pixels[:], src.data.pixels[:])
	append(&data.holds, ..src.data.holds[:])
	fps := src.fps

	append(&c.parts, Character_Part{name = strings.clone(to), fps = fps, data = data})
	return &c.parts[len(c.parts) - 1]
}

// Renames a pose. Refuses a name that is taken or malformed, and refuses to
// rename one of the standard ten, because the engine looks those up by name
// and a character with no `walk_left` stops walking left.
character_rename_part :: proc(c: ^Character, old, new: string) -> bool {
	if char_part_standard(old) do return false
	if !char_part_name_ok(new) || character_part(c, new) != nil do return false
	p := character_part(c, old)
	if p == nil do return false
	delete(p.name)
	p.name = strings.clone(new)
	// The pixel grid carries the name too, so an exported sheet is labelled.
	delete(p.data.name)
	p.data.name = strings.clone(new)
	return true
}

// Removes a pose, extras only. The standard ten stay whether they are drawn
// or not: a blank pose is a thing still to do, and a missing one is a bug
// somewhere else at four in the morning.
character_remove_part :: proc(c: ^Character, name: string) -> bool {
	if char_part_standard(name) do return false
	for &p, i in c.parts {
		if p.name == name {
			delete(p.name)
			sprite_data_destroy(&p.data)
			ordered_remove(&c.parts, i)
			return true
		}
	}
	return false
}

// The extras, in file order. What a routine or a cutscene can ask for by
// name beyond the ten.
character_extras :: proc(c: ^Character, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for &p in c.parts do if !char_part_standard(p.name) do append(&out, p.name)
	return out[:]
}

// --- File ---

load_character :: proc(path: string) -> (c: Character, ok: bool) {
	text := read_data_file(path) or_return
	return parse_character(text)
}

parse_character :: proc(text: string) -> (c: Character, ok: bool) {
	c.w, c.h = 16, 28
	palette := make([dynamic]Palette_Entry, context.temp_allocator)
	append(&palette, Palette_Entry{'.', {0, 0, 0, 0}})

	part: ^Character_Part
	frame, row: i32 = -1, 0

	rest := text
	for raw_line in strings.split_lines_iterator(&rest) {
		raw := strings.trim_right_space(raw_line)
		starts_block := strings.has_prefix(raw, "part ") || strings.has_prefix(raw, "frame ")

		// Inside a frame every line is pixels, because a row of solid colour
		// can look like anything — a comment, a keyword. Only "part " and
		// "frame " break out, and no row can be either: a palette character
		// is never a space.
		if frame >= 0 && !starts_block {
			if part != nil {
				for i := 0; i < len(raw) && i32(i) < part.data.w; i += 1 {
					idx: u8 = 0
					for p, pi in part.data.palette {
						if p.ch == raw[i] {
							idx = u8(pi)
							break
						}
					}
					if cell := sprite_data_at(&part.data, frame, i32(i), row); cell != nil do cell^ = idx
				}
			}
			row += 1
			continue
		}

		raw = strings.trim_space(raw)
		if raw == "" || strings.has_prefix(raw, "#") do continue
		l := parse_line(raw)
		switch l.key {
		case "character":
			if len(l.words) > 0 do c.name = strings.clone(l.words[0])

		case "size":
			if len(l.words) >= 2 {
				w, _ := strconv.parse_int(l.words[0])
				h, _ := strconv.parse_int(l.words[1])
				c.w, c.h = i32(w), i32(h)
			}

		case "mode":
			// A file that doesn't say is VGA, which is what every character
			// written before there were modes is.
			if len(l.words) > 0 do c.mode, _ = palette_mode_from_name(l.words[0])

		case "ramp":
			if r, got := parse_ramp(l.words); got do append(&c.ramps, r)

		case "pal":
			if len(l.words) >= 2 {
				append(&palette, Palette_Entry{l.words[0][0], palette_colour(l.words)})
			}

		case "part":
			if len(l.words) == 0 do continue
			w, h := c.w, c.h
			if size := field_vec2(l, "size"); size != {} do w, h = i32(size.x), i32(size.y)
			frames := i32(max(field_int(l, "frames", 1), 1))
			append(&c.parts, Character_Part {
				name = strings.clone(l.words[0]),
				fps  = field_f32(l, "fps"),
				data = sprite_data_new(l.words[0], w, h, frames),
			})
			part = &c.parts[len(c.parts) - 1]
			// Every part shares the character's palette.
			clear(&part.data.palette)
			append(&part.data.palette, ..palette[:])
			frame, row = -1, 0

		case "frame":
			if part == nil do continue
			n := 0
			if len(l.words) > 0 do n, _ = strconv.parse_int(l.words[0])
			frame = i32(n)
			row = 0
			// `frame 2 hold=3`: this frame shows for three ticks. See anim.odin.
			if hold := field_int(l, "hold", 1); hold != 1 do sprite_data_set_hold(&part.data, frame, i32(hold))
		}
	}
	// Every part is painted under the character's mode and with the character's
	// materials, because they share one palette and a pose cannot be allowed
	// colours its neighbours are not.
	for &p in c.parts {
		p.data.mode = c.mode
		ramps_destroy(&p.data.ramps)
		p.data.ramps = ramps_clone(c.ramps[:])
	}
	return c, c.name != "" || len(c.parts) > 0
}

save_character :: proc(c: ^Character, path: string) -> bool {
	return write_data_file(path, character_text(c))
}

character_text :: proc(c: ^Character, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "# nengine character\ncharacter %v\nsize %v %v\n", c.name, c.w, c.h)
	fmt.sbprintf(&b, "mode %v\n", palette_mode_name(c.mode))
	write_ramps(&b, c.ramps[:])

	// One palette for the whole character: everything any part uses, with
	// each part's own indices mapped onto it.
	palette := make([dynamic]Palette_Entry, context.temp_allocator)
	append(&palette, Palette_Entry{'.', {0, 0, 0, 0}})
	remap := make([][]u8, len(c.parts), context.temp_allocator)
	for &p, pi in c.parts {
		remap[pi] = make([]u8, max(len(p.data.palette), 1), context.temp_allocator)
		for entry, i in p.data.palette {
			if i == 0 do continue // transparent
			found := false
			for have, hi in palette {
				if have.color == entry.color {
					remap[pi][i] = u8(hi)
					found = true
					break
				}
			}
			if !found {
				append(&palette, entry)
				remap[pi][i] = u8(len(palette) - 1)
			}
		}
	}
	// Two parts can disagree about which character means which colour, so
	// the shared palette names them again, in its own order.
	for &entry, i in palette {
		if i > 0 do entry.ch = palette_char(i - 1)
	}
	for p in palette[1:] {
		fmt.sbprintf(&b, "pal %c %v,%v,%v,%v\n", rune(p.ch), p.color.r, p.color.g, p.color.b, p.color.a)
	}

	for &p, pi in c.parts {
		fmt.sbprintf(&b, "part %v", p.name)
		if p.data.w != c.w || p.data.h != c.h do fmt.sbprintf(&b, " size=%v,%v", p.data.w, p.data.h)
		fmt.sbprintf(&b, " frames=%v", p.data.frames)
		if p.fps != 0 do fmt.sbprintf(&b, " fps=%v", p.fps)
		strings.write_byte(&b, '\n')
		for f in 0 ..< p.data.frames {
			fmt.sbprintf(&b, "frame %v", f)
			if hold := sprite_data_hold(&p.data, f); hold != 1 do fmt.sbprintf(&b, " hold=%v", hold)
			strings.write_byte(&b, '\n')
			for y in 0 ..< p.data.h {
				for x in 0 ..< p.data.w {
					idx := int(sprite_data_at(&p.data, f, x, y)^)
					shared := remap[pi][idx] if idx < len(remap[pi]) else 0
					strings.write_byte(&b, palette[int(shared)].ch if int(shared) < len(palette) else '.')
				}
				strings.write_byte(&b, '\n')
			}
		}
	}
	return strings.to_string(b)
}

// --- Ready to draw ---

// A character loaded onto the GPU: each part a sprite sheet, with the speed
// it animates at.
Character_Art :: struct {
	name:  string,
	parts: map[string]Part_Art,
}

Part_Art :: struct {
	sprite: Sprite,
	fps:    f32,
	holds:  []i32, // ticks per frame; nil when every frame shows for one. See anim.odin
}

character_art_destroy :: proc(a: ^Character_Art) {
	for name, p in a.parts {
		rl.UnloadTexture(p.sprite.texture)
		delete(p.holds)
		delete(name)
	}
	delete(a.parts)
	delete(a.name)
	a^ = {}
}

// One pose, ready to draw. Missing parts come back empty rather than
// crashing, so a half-drawn character still runs.
assets_char_part :: proc(a: ^Assets, character, part: string) -> Part_Art {
	c, has := &a.chars[character]
	if !has do return {}
	return c.parts[part] if part in c.parts else Part_Art{}
}

assets_load_character :: proc(a: ^Assets, path: string, scale: f32 = 1) -> bool {
	c, ok := load_character(path)
	if !ok do return false
	defer character_destroy(&c)

	art := Character_Art{name = strings.clone(c.name)}
	art.parts = make(map[string]Part_Art)
	for &p in c.parts {
		art.parts[strings.clone(p.name)] = {
			sprite = sprite_data_to_sprite(&p.data, scale),
			fps    = p.fps,
			holds  = sprite_data_holds(&p.data),
		}
	}
	if a.chars == nil do a.chars = make(map[string]Character_Art)
	a.chars[strings.clone(c.name)] = art
	return true
}
