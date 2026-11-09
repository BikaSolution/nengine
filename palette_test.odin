package nengine

import "core:strings"
import "core:testing"
import rl "vendor:raylib"

// A palette colour that fails to parse is {0,0,0,0} — transparent — so the
// art loads perfectly and draws as nothing. That is exactly what happened to
// every character in the project, for as long as nobody looked at the game.

@(test)
a_palette_line_is_read_whatever_sits_between_the_name_and_the_colour :: proc(t: ^testing.T) {
	plain := [?]string{"o", "86,42,30,255"}
	testing.expect_value(t, palette_colour(plain[:]), rl.Color{86, 42, 30, 255})

	// ada.char's shape: a `#` between the two.
	spaced := [?]string{"o", "#", "86,42,30,255"}
	testing.expect_value(t, palette_colour(spaced[:]), rl.Color{86, 42, 30, 255})

	// Nothing colour-shaped at all: transparent, and that is the right answer.
	none := [?]string{"o", "#"}
	testing.expect_value(t, palette_colour(none[:]), rl.Color{})
}

@(test)
a_character_loads_with_the_colours_its_file_names :: proc(t: ^testing.T) {
	c, ok := parse_character(`character x
size 2 1
pal # # 24,20,18,255
pal o 86,42,30,255
part front
frame 0
#o
`)
	testing.expect(t, ok)
	defer character_destroy(&c)
	testing.expect_value(t, len(c.parts), 1)

	pal := c.parts[0].data.palette
	testing.expect_value(t, len(pal), 3) // transparent, then the two named
	testing.expect_value(t, pal[1].color, rl.Color{24, 20, 18, 255})
	testing.expect_value(t, pal[2].color, rl.Color{86, 42, 30, 255})

	// And the pixels point at them: "#o" is one of each.
	testing.expect_value(t, sprite_data_at(&c.parts[0].data, 0, 0, 0)^, u8(1))
	testing.expect_value(t, sprite_data_at(&c.parts[0].data, 0, 1, 0)^, u8(2))
}

@(test)
a_sprite_loads_with_the_colours_its_file_names :: proc(t: ^testing.T) {
	// A sprite file names its own transparent entry; a character file doesn't.
	d, ok := parse_sprite_data(`sprite x
size 2 1
pal . 0,0,0,0
pal # # 24,20,18,255
frame 0
#.
`)
	testing.expect(t, ok)
	defer sprite_data_destroy(&d)
	testing.expect_value(t, len(d.palette), 2)
	testing.expect_value(t, d.palette[1].color, rl.Color{24, 20, 18, 255})
}

// --- Palette modes ---

// The sixteen written out by hand and the sixteen the DAC makes have to be the
// same sixteen. If this fails, one of the two is a typo and the game is drawn
// in the wrong colours.
@(test)
the_bega_table_agrees_with_the_ega_decoder :: proc(t: ^testing.T) {
	for want, i in BEGA {
		testing.expect_value(t, ega_colour(BEGA_INDICES[i]), want)
	}
}

// The four famous awkward ones: brown is not dark yellow, and the bright
// colours are a second bit rather than a different hue.
@(test)
ega_brown_and_the_greys_land_where_the_hardware_puts_them :: proc(t: ^testing.T) {
	testing.expect_value(t, ega_colour(20), rl.Color{0xAA, 0x55, 0x00, 255}) // brown
	testing.expect_value(t, ega_colour(6), rl.Color{0xAA, 0xAA, 0x00, 255})  // the olive it is NOT
	testing.expect_value(t, ega_colour(7), rl.Color{0xAA, 0xAA, 0xAA, 255})  // light grey
	testing.expect_value(t, ega_colour(56), rl.Color{0x55, 0x55, 0x55, 255}) // dark grey
	testing.expect_value(t, ega_colour(63), rl.Color{0xFF, 0xFF, 0xFF, 255}) // white
}

@(test)
every_ega_channel_is_one_of_four_levels :: proc(t: ^testing.T) {
	all := fega_palette()
	for c in all {
		for v in ([3]u8{c.r, c.g, c.b}) {
			testing.expect(t, v == 0x00 || v == 0x55 || v == 0xAA || v == 0xFF)
		}
	}
	// Sixty-four distinct colours, not sixty-four entries with repeats.
	seen: map[rl.Color]bool
	defer delete(seen)
	for c in all do seen[c] = true
	testing.expect_value(t, len(seen), 64)
}

@(test)
a_mode_allows_its_own_gamut_and_refuses_the_others :: proc(t: ^testing.T) {
	brown := rl.Color{0xAA, 0x55, 0x00, 255}
	olive := rl.Color{0xAA, 0xAA, 0x00, 255} // fEGA, but not one of the sixteen
	ada := rl.Color{86, 42, 30, 255}         // off the grid entirely

	testing.expect(t, palette_mode_allows(.BEGA, brown))
	testing.expect(t, !palette_mode_allows(.BEGA, olive))
	testing.expect(t, !palette_mode_allows(.BEGA, ada))

	testing.expect(t, palette_mode_allows(.FEGA, brown))
	testing.expect(t, palette_mode_allows(.FEGA, olive))
	testing.expect(t, !palette_mode_allows(.FEGA, ada))

	testing.expect(t, palette_mode_allows(.VGA, brown))
	testing.expect(t, !palette_mode_allows(.VGA, ada)) // 86 is not on the six-bit grid

	// Transparent is the format, not a colour choice, so every mode takes it.
	for m in Palette_Mode do testing.expect(t, palette_mode_allows(m, rl.Color{0, 0, 0, 0}))
	// Half-dissolved is an accident in all three.
	for m in Palette_Mode do testing.expect(t, !palette_mode_allows(m, rl.Color{0xAA, 0x55, 0, 128}))
}

// Snapping has to be idempotent, or a file drifts a little every time it is
// saved and nobody can say when it stopped matching.
@(test)
snapping_a_colour_twice_is_the_same_as_snapping_it_once :: proc(t: ^testing.T) {
	for m in Palette_Mode {
		for c in ([]rl.Color{{86, 42, 30, 255}, {200, 180, 40, 255}, {1, 2, 3, 255}, {255, 255, 255, 255}}) {
			once := palette_mode_snap(m, c)
			testing.expect_value(t, palette_mode_snap(m, once), once)
			testing.expect(t, palette_mode_allows(m, once))
		}
	}
}

@(test)
snapping_finds_the_near_colour_not_merely_a_legal_one :: proc(t: ^testing.T) {
	// Nearly bright red, and nearly EGA brown.
	testing.expect_value(t, palette_mode_snap(.BEGA, rl.Color{250, 90, 88, 255}), BEGA[12])
	testing.expect_value(t, palette_mode_snap(.BEGA, rl.Color{170, 90, 10, 255}), BEGA[6])
	// Black and white are their own nearest in every mode.
	testing.expect_value(t, palette_mode_snap(.BEGA, rl.Color{0, 0, 0, 255}), BEGA[0])
	testing.expect_value(t, palette_mode_snap(.BEGA, rl.Color{255, 255, 255, 255}), BEGA[15])
}

@(test)
a_mode_name_survives_the_round_trip :: proc(t: ^testing.T) {
	for m in Palette_Mode {
		back, ok := palette_mode_from_name(palette_mode_name(m))
		testing.expect(t, ok)
		testing.expect_value(t, back, m)
	}
	// The spellings people actually type.
	for s in ([]string{"bEGA", "BEGA", "ega16"}) {
		m, ok := palette_mode_from_name(s)
		testing.expect(t, ok)
		testing.expect_value(t, m, Palette_Mode.BEGA)
	}
	// And an unknown word is not silently something.
	_, ok := palette_mode_from_name("cga")
	testing.expect(t, !ok)
}

@(test)
the_swatches_a_mode_offers_are_all_legal_in_it :: proc(t: ^testing.T) {
	buf: [64]rl.Color
	testing.expect_value(t, len(palette_swatches(.BEGA, &buf)), 16)
	testing.expect_value(t, len(palette_swatches(.FEGA, &buf)), 64)
	for m in Palette_Mode {
		for c in palette_swatches(m, &buf) do testing.expect(t, palette_mode_allows(m, c))
	}
}

// A dither read from across the room is an average in linear light, not in
// sRGB numbers. Half black and half white is about 188, not 128 — and a mixer
// panel that says 128 sends somebody chasing a grey that is not there.
@(test)
a_blend_is_averaged_in_linear_light :: proc(t: ^testing.T) {
	mid := palette_blend(BEGA[0], BEGA[15], 0.5)
	testing.expect(t, mid.r > 180 && mid.r < 195)
	// The ends are exact.
	testing.expect_value(t, palette_blend(BEGA[0], BEGA[15], 0), BEGA[0])
	testing.expect_value(t, palette_blend(BEGA[0], BEGA[15], 1), BEGA[15])
	// And it is clamped, not wrapped.
	testing.expect_value(t, palette_blend(BEGA[0], BEGA[15], 4), BEGA[15])
}

// Past the end of the naming characters a slot is '?', and never a second
// slot's name. Two slots sharing a character is a corrupted picture.
@(test)
palette_names_run_out_loudly_rather_than_wrapping :: proc(t: ^testing.T) {
	testing.expect_value(t, palette_char(0), u8('#'))
	testing.expect_value(t, palette_char(PALETTE_MAX - 1), u8('^'))
	testing.expect_value(t, palette_char(PALETTE_MAX), u8('?'))
	testing.expect_value(t, palette_char(PALETTE_MAX + 1), u8('?'))
	testing.expect_value(t, palette_char(-1), u8('?'))

	// No character is used twice, or the names are not names.
	chars := PALETTE_CHARS
	seen: map[u8]bool
	defer delete(seen)
	for i in 0 ..< len(chars) do seen[chars[i]] = true
	testing.expect_value(t, len(seen), PALETTE_MAX)
}

// --- The mode line ---

@(test)
a_file_that_says_nothing_about_its_mode_is_vga :: proc(t: ^testing.T) {
	d, ok := parse_sprite_data("sprite x\nsize 1 1\npal . 0,0,0,0\nframe 0\n.\n")
	testing.expect(t, ok)
	defer sprite_data_destroy(&d)
	testing.expect_value(t, d.mode, Palette_Mode.VGA)

	c, cok := parse_character("character x\nsize 1 1\npart front\nframe 0\n.\n")
	testing.expect(t, cok)
	defer character_destroy(&c)
	testing.expect_value(t, c.mode, Palette_Mode.VGA)
}

@(test)
a_sprites_mode_survives_saving_and_loading :: proc(t: ^testing.T) {
	for m in Palette_Mode {
		d := sprite_data_new("x", 2, 1, 1)
		defer sprite_data_destroy(&d)
		sprite_data_set_mode(&d, m)

		back, ok := parse_sprite_data(sprite_data_text(&d, context.temp_allocator))
		testing.expect(t, ok)
		defer sprite_data_destroy(&back)
		testing.expect_value(t, back.mode, m)
	}
}

@(test)
a_characters_mode_survives_and_reaches_every_pose :: proc(t: ^testing.T) {
	c := character_new("x", 2, 1)
	defer character_destroy(&c)
	c.mode = .BEGA
	append(&c.parts, Character_Part{name = strings.clone("front"), data = sprite_data_new("front", 2, 1, 1)})

	back, ok := parse_character(character_text(&c, context.temp_allocator))
	testing.expect(t, ok)
	defer character_destroy(&back)
	testing.expect_value(t, back.mode, Palette_Mode.BEGA)
	testing.expect_value(t, len(back.parts), 1)
	// A pose cannot be allowed colours its neighbours are not.
	testing.expect_value(t, back.parts[0].data.mode, Palette_Mode.BEGA)
}

// A bEGA picture gets the same colour in the same slot every time, so an index
// copied from one means the same in another.
@(test)
bega_seeds_the_same_sixteen_slots_every_time :: proc(t: ^testing.T) {
	d := sprite_data_new("x", 1, 1, 1)
	defer sprite_data_destroy(&d)
	sprite_data_set_mode(&d, .BEGA)

	testing.expect_value(t, len(d.palette), 17) // transparent, then sixteen
	testing.expect_value(t, d.palette[0].color, rl.Color{0, 0, 0, 0})
	for want, i in BEGA do testing.expect_value(t, d.palette[i + 1].color, want)

	// Setting it twice does not seed it twice.
	sprite_data_set_mode(&d, .BEGA)
	testing.expect_value(t, len(d.palette), 17)

	// fEGA and VGA start empty and gain colours as they are painted.
	e := sprite_data_new("y", 1, 1, 1)
	defer sprite_data_destroy(&e)
	sprite_data_set_mode(&e, .FEGA)
	testing.expect_value(t, len(e.palette), 1)
}

@(test)
offending_colours_are_reported_rather_than_refused :: proc(t: ^testing.T) {
	// A picture written before there were modes: off-grid colours throughout.
	d, ok := parse_sprite_data(
		"sprite x\nmode bega\nsize 2 1\npal . 0,0,0,0\npal # 86,42,30,255\npal o 170,85,0,255\nframe 0\n#o\n",
	)
	testing.expect(t, ok)
	defer sprite_data_destroy(&d)

	// It loaded. That is the point: the file is the truth, even when it breaks
	// a rule about authoring.
	testing.expect_value(t, d.mode, Palette_Mode.BEGA)
	testing.expect_value(t, d.palette[1].color, rl.Color{86, 42, 30, 255})

	bad: [dynamic]u8
	defer delete(bad)
	sprite_data_offenders(&d, &bad)
	testing.expect_value(t, len(bad), 1) // slot 1 only: 170,85,0 IS bEGA brown
	testing.expect_value(t, bad[0], u8(1))
}

// Several tones snapping onto one colour is the normal case, not the odd one,
// and the pixels have to follow their colours onto the slots that survive.
@(test)
snapping_collapses_duplicates_and_takes_the_pixels_with_it :: proc(t: ^testing.T) {
	d, ok := parse_sprite_data(
		"sprite x\nmode bega\nsize 3 1\npal . 0,0,0,0\npal # 250,250,250,255\npal o 245,245,245,255\npal + 2,2,2,255\nframe 0\n#o+\n",
	)
	testing.expect(t, ok)
	defer sprite_data_destroy(&d)

	testing.expect_value(t, sprite_data_snap_to_mode(&d), 2) // two whites became one

	white, black := sprite_data_at(&d, 0, 0, 0)^, sprite_data_at(&d, 0, 2, 0)^
	testing.expect_value(t, sprite_data_at(&d, 0, 1, 0)^, white) // both whites, one slot
	testing.expect(t, white != black)
	testing.expect_value(t, d.palette[int(white)].color, BEGA[15])
	testing.expect_value(t, d.palette[int(black)].color, BEGA[0])

	bad: [dynamic]u8
	defer delete(bad)
	sprite_data_offenders(&d, &bad)
	testing.expect_value(t, len(bad), 0)
}
