package pixel

import ne "../../"
import "core:strings"
import "core:testing"
import rl "vendor:raylib"

// The point of an ordered matrix is that it spreads the pixels it turns on as
// evenly as it can at every ratio. If a matrix has a value twice, some ratio
// puts two pixels next to each other that should have been apart, and the tone
// shows as texture.
@(test)
every_bayer_matrix_uses_each_of_its_values_once :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, m: []f32) {
		seen := make([]bool, len(m), context.temp_allocator)
		for v in m {
			i := int(v)
			testing.expect(t, i >= 0 && i < len(m))
			testing.expect(t, !seen[i]) // twice is a bug you would see and not explain
			seen[i] = true
		}
	}
	check(t, BAYER2[:])
	check(t, BAYER4[:])
	check(t, BAYER8[:])
}

@(test)
a_threshold_is_always_inside_the_unit_range :: proc(t: ^testing.T) {
	for p in Pattern {
		for y in i32(-9) ..= 9 {
			for x in i32(-9) ..= 9 {
				v := dither_threshold(p, x, y)
				testing.expect(t, v >= 0 && v < 1)
			}
		}
	}
}

// Negative coordinates happen — art gets resized and pasted about — and Odin's
// % gives -1 for -1 % 8, which would index off the front of the matrix.
@(test)
the_pattern_tiles_across_the_origin :: proc(t: ^testing.T) {
	for p in Pattern {
		if p == .Noise || p == .Mixed do continue // hashed, so not periodic
		for y in i32(-16) ..= 16 {
			for x in i32(-16) ..= 16 {
				testing.expect_value(t, dither_threshold(p, x, y), dither_threshold(p, x + 8, y + 8))
			}
		}
	}
}

// A stroke has to depend on where the pixel is, not on where the stroke began,
// or shading a wall in two passes leaves a seam down the middle of it.
@(test)
the_same_pixel_always_dithers_the_same_way :: proc(t: ^testing.T) {
	for p in Pattern {
		for y in i32(0) ..< 16 {
			for x in i32(0) ..< 16 {
				a := dither_pick(rl.BLACK, rl.WHITE, 0.5, p, x, y)
				b := dither_pick(rl.BLACK, rl.WHITE, 0.5, p, x, y)
				testing.expect_value(t, a, b)
			}
		}
	}
}

// Over one tile of an ordered matrix the ratio is not approximate, it is exact:
// thresholds land on a regular grid, so a ratio that is a multiple of 1/64
// turns on exactly that many of the sixty-four.
@(test)
an_ordered_ratio_is_exact_over_one_tile :: proc(t: ^testing.T) {
	count :: proc(p: Pattern, ratio: f32, n: i32) -> int {
		hits := 0
		for y in i32(0) ..< n {
			for x in i32(0) ..< n {
				if dither_pick(rl.BLACK, rl.WHITE, ratio, p, x, y) == rl.WHITE do hits += 1
			}
		}
		return hits
	}
	testing.expect_value(t, count(.Bayer8, 0.5, 8), 32)
	testing.expect_value(t, count(.Bayer8, 0.25, 8), 16)
	testing.expect_value(t, count(.Bayer8, 0.75, 8), 48)
	testing.expect_value(t, count(.Bayer4, 0.5, 4), 8)
	testing.expect_value(t, count(.Bayer2, 0.5, 2), 2)
}

// A light level has to mean what the status line says it means. Mixed is held to
// the same standard as the ordered patterns on purpose: it is the default, it is
// what lighting is painted with, and the obvious implementation of it — the mean
// of ordered and noise — fails this test by four hundred per cent at low light.
@(test)
a_hashed_ratio_is_close_over_a_large_area :: proc(t: ^testing.T) {
	for p in ([]Pattern{.Noise, .Mixed}) {
		for want in ([]f32{0.25, 0.5, 0.75}) {
			hits := 0
			for y in i32(0) ..< 128 {
				for x in i32(0) ..< 128 {
					if dither_pick(rl.BLACK, rl.WHITE, want, p, x, y) == rl.WHITE do hits += 1
				}
			}
			got := f32(hits) / (128 * 128)
			tol := f32(0.005) if p == .Mixed else f32(0.01)
			testing.expect(t, got > want - tol && got < want + tol)
		}
	}
}

// The ends have to be clean. A ratio of 0 that leaves one stray pixel of the
// other colour is a speck you will chase around a picture for an hour.
@(test)
the_ends_of_the_range_are_flat_colour :: proc(t: ^testing.T) {
	for p in Pattern {
		for y in i32(0) ..< 16 {
			for x in i32(0) ..< 16 {
				testing.expect_value(t, dither_pick(rl.BLACK, rl.WHITE, 0, p, x, y), rl.BLACK)
				testing.expect_value(t, dither_pick(rl.BLACK, rl.WHITE, 1, p, x, y), rl.WHITE)
				// And out of range is clamped, not wrapped.
				testing.expect_value(t, dither_pick(rl.BLACK, rl.WHITE, -1, p, x, y), rl.BLACK)
				testing.expect_value(t, dither_pick(rl.BLACK, rl.WHITE, 2, p, x, y), rl.WHITE)
			}
		}
	}
}

// --- Ramps and light ---

@(test)
a_light_level_walks_up_the_ramp :: proc(t: ^testing.T) {
	steps := []rl.Color{ne.BEGA[0], ne.BEGA[8], ne.BEGA[7], ne.BEGA[15]} // black, greys, white

	lo, hi, ratio := ne.ramp_at(steps, 0)
	testing.expect_value(t, lo, ne.BEGA[0])
	testing.expect_value(t, ratio, f32(0)) // nothing to dither at the bottom

	// A third of the way up a four-step ramp is exactly the second step.
	lo, hi, ratio = ne.ramp_at(steps, 1.0 / 3.0)
	testing.expect_value(t, lo, ne.BEGA[8])
	testing.expect(t, ratio < 0.01)

	// Halfway between two steps is a half-and-half dither of those two.
	lo, hi, ratio = ne.ramp_at(steps, 0.5)
	testing.expect_value(t, lo, ne.BEGA[8])
	testing.expect_value(t, hi, ne.BEGA[7])
	testing.expect(t, ratio > 0.49 && ratio < 0.51)
}

// The rule that cost an afternoon: above 1.0 every tone lands on the top step,
// so form within reach of a bright light does not go dim, it goes missing. The
// clamp lives in the engine so that no tool can forget it.
@(test)
light_is_clamped_at_one_and_the_top_step_is_flat :: proc(t: ^testing.T) {
	steps := []rl.Color{ne.BEGA[0], ne.BEGA[8], ne.BEGA[15]}
	for light in ([]f32{1.0, 1.42, 9}) {
		lo, hi, ratio := ne.ramp_at(steps, light)
		testing.expect_value(t, lo, ne.BEGA[15])
		testing.expect_value(t, hi, ne.BEGA[15])
		testing.expect_value(t, ratio, f32(0))
	}
	// And below zero is the bottom, not a wrap to the top.
	lo, _, _ := ne.ramp_at(steps, -3)
	testing.expect_value(t, lo, ne.BEGA[0])
}

@(test)
a_ramp_of_one_tone_or_none_does_not_fall_over :: proc(t: ^testing.T) {
	one := []rl.Color{ne.BEGA[6]}
	lo, hi, ratio := ne.ramp_at(one, 0.5)
	testing.expect_value(t, lo, ne.BEGA[6])
	testing.expect_value(t, hi, ne.BEGA[6])
	testing.expect_value(t, ratio, f32(0))

	lo, _, _ = ne.ramp_at(nil, 0.5)
	testing.expect_value(t, lo, rl.Color{})
}

// --- The brush ---

@(test)
the_brush_reads_its_tones_from_a_pair_or_from_a_material :: proc(t: ^testing.T) {
	ramps := ne.ramps_clone([]ne.Ramp{})
	defer ne.ramps_destroy(&ramps)
	canvas := ne.Ramp{name = strings.clone("canvas")}
	append(&canvas.steps, ne.BEGA[0], ne.BEGA[8], ne.BEGA[15])
	append(&ramps, canvas)

	pair := Dither{on = true, source = .Pair, other = ne.BEGA[15], ratio = 0.5}
	lo, hi, ratio := dither_tones(&pair, ne.BEGA[0], ramps[:])
	testing.expect_value(t, lo, ne.BEGA[0])
	testing.expect_value(t, hi, ne.BEGA[15])
	testing.expect_value(t, ratio, f32(0.5))

	mat := Dither{on = true, source = .Ramp, ramp = "canvas", light = 1}
	lo, hi, ratio = dither_tones(&mat, ne.BEGA[6], ramps[:])
	testing.expect_value(t, lo, ne.BEGA[15]) // full light is the top of the ramp
	testing.expect_value(t, ratio, f32(0))

	// A material that is not there paints flat rather than painting nothing:
	// losing a ramp should not mean losing the ability to draw.
	gone := Dither{on = true, source = .Ramp, ramp = "gravel", light = 0.5}
	lo, hi, ratio = dither_tones(&gone, ne.BEGA[6], ramps[:])
	testing.expect_value(t, lo, ne.BEGA[6])
	testing.expect_value(t, hi, ne.BEGA[6])
	testing.expect_value(t, ratio, f32(0))
}

// What the brush looks like from across the room has to be the linear-light
// average, not the average of the sRGB numbers — half black and half white is
// about 188, and a panel that says 128 sends somebody chasing a grey that is
// not in the picture.
@(test)
the_brush_reports_what_it_will_look_like_from_across_the_room :: proc(t: ^testing.T) {
	d := Dither{on = true, source = .Pair, other = ne.BEGA[15], ratio = 0.5}
	seen := dither_perceived(&d, ne.BEGA[0], nil)
	testing.expect(t, seen.r > 180 && seen.r < 195)

	// Two bEGA colours, dithered, reaching a tone the sixteen do not contain.
	d.other = ne.BEGA[12] // bright red
	seen = dither_perceived(&d, ne.BEGA[4], nil) // over red
	for c in ne.BEGA do testing.expect(t, c != seen)
}

@(test)
a_pattern_has_a_name_for_the_status_line :: proc(t: ^testing.T) {
	for p in Pattern do testing.expect(t, pattern_name(p) != "")
	testing.expect_value(t, pattern_name(.Mixed), "mixed")
	// Mixed is the zero value, so a brush nobody configured is the one that
	// does not band over a soft gradient.
	fresh: Dither
	testing.expect_value(t, fresh.pattern, Pattern.Mixed)
}

// --- The brush ---

// The shapes asked for, spelled out. A round brush of 2 is the four
// neighbours and no corners; getting this wrong gives a three-by-three block,
// which is a different tool.
@(test)
a_round_brush_grows_through_the_shapes_it_should :: proc(t: ^testing.T) {
	draw :: proc(b: Brush) -> string {
		buf: [(BRUSH_MAX * 2 + 1) * (BRUSH_MAX * 2 + 1)][2]i32
		offs := brush_offsets(b, &buf)
		r := i32(clamp(b.size, 1, BRUSH_MAX) - 1)
		out := strings.builder_make(context.temp_allocator)
		for y in -r ..= r {
			for x in -r ..= r {
				on := false
				want := [2]i32{x, y}
				for o in offs do if o == want do on = true
				strings.write_byte(&out, 'o' if on else ' ')
			}
			if y < r do strings.write_byte(&out, '\n')
		}
		return strings.to_string(out)
	}

	testing.expect_value(t, draw({size = 1}), "o")
	testing.expect_value(t, draw({size = 2}), " o \nooo\n o ")
	testing.expect_value(t, draw({size = 3}), "  o  \n ooo \nooooo\n ooo \n  o  ")
	// Square is the whole block, every time.
	testing.expect_value(t, draw({size = 2, square = true}), "ooo\nooo\nooo")
	testing.expect_value(t, draw({size = 3, square = true}), "ooooo\nooooo\nooooo\nooooo\nooooo")
}

@(test)
a_brush_covers_the_number_of_pixels_its_shape_implies :: proc(t: ^testing.T) {
	buf: [(BRUSH_MAX * 2 + 1) * (BRUSH_MAX * 2 + 1)][2]i32
	testing.expect_value(t, len(brush_offsets({size = 1}, &buf)), 1)
	testing.expect_value(t, len(brush_offsets({size = 2}, &buf)), 5)  // the plus
	testing.expect_value(t, len(brush_offsets({size = 3}, &buf)), 13)
	testing.expect_value(t, len(brush_offsets({size = 3, square = true}, &buf)), 25)

	// Out of range is clamped rather than overrunning the buffer, and a size
	// nobody set is still one pixel rather than none.
	testing.expect_value(t, len(brush_offsets({size = 0}, &buf)), 1)
	testing.expect_value(t, len(brush_offsets({size = -4}, &buf)), 1)
	// Clamped to BRUSH_MAX, whose radius is one less — so 31 across, not 33.
	// The buffer is sized for 33 and the slack is deliberate.
	big := brush_offsets({size = 9999, square = true}, &buf)
	testing.expect_value(t, len(big), (BRUSH_MAX * 2 - 1) * (BRUSH_MAX * 2 - 1))
}

// Every brush is centred on the pixel under the cursor, or a stroke would
// drift away from where you are pointing as it got bigger.
@(test)
a_brush_is_centred_on_the_pixel_under_the_cursor :: proc(t: ^testing.T) {
	buf: [(BRUSH_MAX * 2 + 1) * (BRUSH_MAX * 2 + 1)][2]i32
	for size in 1 ..= 8 {
		for square in ([]bool{false, true}) {
			offs := brush_offsets({size = size, square = square}, &buf)
			sum := [2]i32{}
			origin := false
			for o in offs {
				sum += o
				if o == {0, 0} do origin = true
			}
			testing.expect(t, origin)                 // it covers what you point at
			testing.expect_value(t, sum, [2]i32{0, 0}) // and is symmetric about it
		}
	}
}

// The swatch size is the one setting that is about the person rather than the
// picture, so it has to go both ways and stop at both ends.
@(test)
the_swatch_size_grows_and_shrinks_and_stops_at_the_ends :: proc(t: ^testing.T) {
	c: Canvas
	c.swatch = SWATCH_DEFAULT

	canvas_swatch_by(&c, 4)
	testing.expect_value(t, c.swatch, SWATCH_DEFAULT + 4)
	canvas_swatch_by(&c, -4)
	testing.expect_value(t, c.swatch, SWATCH_DEFAULT)

	// Down to the floor and no further, and back up again afterwards — a
	// setting that could only grow would be a setting you get one go at.
	for _ in 0 ..< 40 do canvas_swatch_by(&c, -4)
	testing.expect_value(t, c.swatch, SWATCH_MIN)
	canvas_swatch_by(&c, 4)
	testing.expect_value(t, c.swatch, SWATCH_MIN + 4)

	for _ in 0 ..< 40 do canvas_swatch_by(&c, 4)
	testing.expect_value(t, c.swatch, SWATCH_MAX)
	canvas_swatch_by(&c, -4)
	testing.expect_value(t, c.swatch, SWATCH_MAX - 4)
}
