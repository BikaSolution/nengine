package main

import ne "../../"
import ui "../ui"
import rl "vendor:raylib"
import "../pixel"
import "core:fmt"
import "core:strconv"
import "core:strings"

// `nart mode` and `nart ramp`: the two things about a picture's colours that
// are decisions rather than brush strokes.
//
// Neither is a key in the editors, on purpose. Changing the mode re-gamuts a
// whole picture and a ramp is a decision about what a surface is made of;
// both want to be typed, read back, and thought about, rather than reachable
// by leaning on the keyboard while drawing.
//
// Both work on a .sprite and a .char, because a character is a palette with
// poses attached and the question is the same either way.

mode_cmd :: proc(args: []string) -> bool {
	if len(args) < 1 do return ui.fail("mode: need a file")
	path := args[0]

	if strings.has_suffix(path, ".char") {
		c, ok := ne.load_character(path)
		if !ok do return ui.fail("mode: could not read %v", path)
		defer ne.character_destroy(&c)

		if len(args) < 2 {
			fmt.printfln("%v  %v", path, ne.palette_mode_name(c.mode))
			for &p in c.parts do report_offenders(p.name, &p.data)
			return true
		}
		want, known := ne.palette_mode_from_name(args[1])
		if !known do return ui.fail("mode: %v is not bega, fega or vga", args[1])

		was := c.mode
		c.mode = want
		total := 0
		for &p in c.parts {
			p.data.mode = want
			total = ne.sprite_data_snap_to_mode(&p.data)
		}
		if !ne.save_character(&c, path) do return ui.fail("mode: could not write %v", path)
		fmt.printfln(
			"%v: %v -> %v, %v colours across %v poses",
			path,
			ne.palette_mode_name(was),
			ne.palette_mode_name(want),
			total,
			len(c.parts),
		)
		return true
	}

	d, ok := ne.load_sprite_data(path)
	if !ok do return ui.fail("mode: could not read %v", path)
	defer ne.sprite_data_destroy(&d)

	if len(args) < 2 {
		fmt.printfln("%v  %v  %v colours", path, ne.palette_mode_name(d.mode), len(d.palette) - 1)
		report_offenders(d.name, &d)
		return true
	}
	want, known := ne.palette_mode_from_name(args[1])
	if !known do return ui.fail("mode: %v is not bega, fega or vga", args[1])

	was, before := d.mode, len(d.palette) - 1
	d.mode = want
	after := ne.sprite_data_snap_to_mode(&d)
	if !ne.save_sprite_data(&d, path) do return ui.fail("mode: could not write %v", path)
	fmt.printfln(
		"%v: %v -> %v, %v colours -> %v",
		path,
		ne.palette_mode_name(was),
		ne.palette_mode_name(want),
		before,
		after,
	)
	return true
}

// What in this picture the mode does not allow. Named, not counted, because
// "three colours are wrong" is not something anybody can act on.
@(private = "file")
report_offenders :: proc(what: string, d: ^ne.Sprite_Data) {
	bad: [dynamic]u8
	defer delete(bad)
	ne.sprite_data_offenders(d, &bad)
	if len(bad) == 0 do return
	fmt.printfln("  %v: %v colour(s) the mode does not allow", what, len(bad))
	for slot in bad {
		c := d.palette[int(slot)].color
		fmt.printfln(
			"    %c  %02X%02X%02X  ->  %v",
			rune(d.palette[int(slot)].ch),
			c.r,
			c.g,
			c.b,
			ne.colour_to_hex(ne.palette_mode_snap(d.mode, c)),
		)
	}
}

ramp_cmd :: proc(args: []string) -> bool {
	if len(args) < 1 do return ui.fail("ramp: need a file")
	path := args[0]
	is_char := strings.has_suffix(path, ".char")

	c: ne.Character
	d: ne.Sprite_Data
	ok: bool
	if is_char {
		c, ok = ne.load_character(path)
	} else {
		d, ok = ne.load_sprite_data(path)
	}
	if !ok do return ui.fail("ramp: could not read %v", path)
	defer if is_char {ne.character_destroy(&c)} else {ne.sprite_data_destroy(&d)}

	ramps := &c.ramps if is_char else &d.ramps
	mode := c.mode if is_char else d.mode

	// No arguments: what materials this picture has, and what each looks like
	// at half light, which is the number a person is actually after.
	if len(args) < 2 {
		if len(ramps) == 0 {
			fmt.printfln("%v: no materials", path)
			fmt.printfln("  add one:  nart ramp %v canvas 000000 555555 AAAAAA FFFFFF", path)
			return true
		}
		for r in ramps {
			fmt.printf("%v  ", r.name)
			for step in r.steps do fmt.printf("%v ", ne.colour_to_hex(step))
			fmt.printfln(" (half light reads as %v)", ne.colour_to_hex(ne.ramp_blend(r.steps[:], 0.5)))
		}
		return true
	}

	if args[1] == "remove" {
		if len(args) < 3 do return ui.fail("ramp remove: need a name")
		for r, i in ramps {
			if r.name != args[2] do continue
			entry := ramps[i]
			ne.ramp_destroy(&entry)
			ordered_remove(ramps, i)
			if !save_either(path, is_char, &c, &d) do return ui.fail("ramp: could not write %v", path)
			fmt.printfln("%v: removed %v", path, args[2])
			return true
		}
		return ui.fail("ramp remove: %v has no material called %v", path, args[2])
	}

	name := args[1]
	if len(args) < 3 do return ui.fail("ramp: need the tones, darkest first, as hex")

	fresh := ne.Ramp{name = strings.clone(name)}
	for word in args[2:] {
		col, good := ne.colour_from_hex(word)
		if !good {
			ne.ramp_destroy(&fresh)
			return ui.fail("ramp: %v is not a six-digit hex colour", word)
		}
		// A ramp is somewhere to pick colours from, so every tone in it has to
		// be a colour this picture is allowed. Snapping here rather than
		// refusing means you can paste an artist's hex values straight in.
		snapped := ne.palette_mode_snap(mode, col)
		if snapped != col {
			fmt.printfln("  %v is not in %v, using %v", word, ne.palette_mode_name(mode), ne.colour_to_hex(snapped))
		}
		append(&fresh.steps, snapped)
	}

	for r, i in ramps {
		if r.name != name do continue
		entry := ramps[i]
		ne.ramp_destroy(&entry)
		ordered_remove(ramps, i)
		break
	}
	append(ramps, fresh)

	if !save_either(path, is_char, &c, &d) do return ui.fail("ramp: could not write %v", path)
	fmt.printfln("%v: %v, %v tones", path, name, len(fresh.steps))
	return true
}

@(private = "file")
save_either :: proc(path: string, is_char: bool, c: ^ne.Character, d: ^ne.Sprite_Data) -> bool {
	return ne.save_character(c, path) if is_char else ne.save_sprite_data(d, path)
}

// `nart dither`: the brush, on the command line.
//
// Takes every pixel of one colour and makes it a dither of that colour and
// another. This is the brush the editors paint with — the same threshold, the
// same patterns — applied to a whole picture at once, which is what you want
// when a flat area was painted before you knew what it should be, or when a
// picture has just been snapped into a smaller gamut and the colour it landed
// on is too loud.
//
// Being a command rather than a gesture also means it can be read back, put in
// a note, and done again the same way in six months.
//
//   nart dither <file> <from> <with> <ratio> [pattern]
//   nart dither logo.sprite FFFF55 AA00AA 0.625 bayer8
dither_cmd :: proc(args: []string) -> bool {
	if len(args) < 4 do return ui.fail("dither: need a file, a colour, a colour to mix in, and a ratio")
	path := args[0]

	from, from_ok := ne.colour_from_hex(args[1])
	if !from_ok do return ui.fail("dither: %v is not a six-digit hex colour", args[1])
	with, with_ok := ne.colour_from_hex(args[2])
	if !with_ok do return ui.fail("dither: %v is not a six-digit hex colour", args[2])

	ratio, ratio_ok := strconv.parse_f32(args[3])
	if !ratio_ok || ratio < 0 || ratio > 1 do return ui.fail("dither: the ratio is a number from 0 to 1")

	pattern := pixel.Pattern.Mixed
	if len(args) > 4 {
		got := false
		for p in pixel.Pattern {
			if pixel.pattern_name(p) == args[4] {
				pattern, got = p, true
			}
		}
		if !got do return ui.fail("dither: %v is not mixed, bayer2, bayer4, bayer8 or noise", args[4])
	}

	is_char := strings.has_suffix(path, ".char")
	c: ne.Character
	d: ne.Sprite_Data
	ok: bool
	if is_char {
		c, ok = ne.load_character(path)
	} else {
		d, ok = ne.load_sprite_data(path)
	}
	if !ok do return ui.fail("dither: could not read %v", path)
	defer if is_char {ne.character_destroy(&c)} else {ne.sprite_data_destroy(&d)}

	mode := c.mode if is_char else d.mode
	if !ne.palette_mode_allows(mode, with) {
		snapped := ne.palette_mode_snap(mode, with)
		fmt.printfln("  %v is not in %v, using %v", args[2], ne.palette_mode_name(mode), ne.colour_to_hex(snapped))
		with = snapped
	}

	painted := 0
	if is_char {
		for &p in c.parts do painted += dither_over(&p.data, from, with, ratio, pattern)
	} else {
		painted = dither_over(&d, from, with, ratio, pattern)
	}
	if painted == 0 do return ui.fail("dither: no pixel in %v is %v", path, args[1])

	if !save_either(path, is_char, &c, &d) do return ui.fail("dither: could not write %v", path)
	fmt.printfln(
		"%v: %v pixels of %v dithered %v%% with %v, %v — reads as %v",
		path,
		painted,
		args[1],
		int(ratio * 100 + 0.5),
		ne.colour_to_hex(with),
		pixel.pattern_name(pattern),
		ne.colour_to_hex(ne.palette_blend(from, with, ratio)),
	)
	return true
}

// Every pixel of `from` becomes one of the two, by where it sits. Returns how
// many were touched.
@(private = "file")
dither_over :: proc(
	d: ^ne.Sprite_Data,
	from, with: rl.Color,
	ratio: f32,
	pattern: pixel.Pattern,
) -> (painted: int) {
	was, have := ne.sprite_data_slot_of(d, from)
	if !have do return 0
	keep, room := pixel.canvas_slot_for(d, with)
	if !room do return 0

	for f in 0 ..< d.frames {
		for y in 0 ..< d.h {
			for x in 0 ..< d.w {
				cell := ne.sprite_data_at(d, f, x, y)
				if cell == nil || cell^ != was do continue
				// Keyed on where the pixel is, not which frame it is in, so
				// every frame of an animation dithers the same way and a
				// texture does not crawl when it plays.
				if pixel.dither_pick(from, with, ratio, pattern, x, y) == with do cell^ = keep
				painted += 1
			}
		}
	}
	return
}
