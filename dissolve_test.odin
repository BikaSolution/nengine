package nengine

import "core:os"
import "core:testing"
import rl "vendor:raylib"

@(test)
dissolve_order_is_every_pixel_once :: proc(t: ^testing.T) {
	// A title layer's size (640x240), a backdrop's (320x200), and odd ones.
	for size in ([][2]int{{640, 240}, {320, 200}, {7, 5}, {1, 1}, {0, 0}}) {
		n := size.x * size.y
		order := dissolve_order(size.x, size.y)
		defer delete(order)
		testing.expect_value(t, len(order), n)
		seen := make([]bool, n)
		defer delete(seen)
		for p in order {
			testing.expectf(t, p >= 0 && int(p) < n, "pixel %v out of 0..<%v", p, n)
			testing.expectf(t, !seen[p], "pixel %v turns twice", p)
			seen[p] = true
		}
		for s, i in seen do testing.expectf(t, s, "pixel %v never turns", i)
	}
}

@(test)
dissolve_order_is_fixed_and_shuffled :: proc(t: ^testing.T) {
	a := dissolve_order(320, 200)
	b := dissolve_order(320, 200)
	c := dissolve_order(320, 200, DISSOLVE_SEED + 1)
	defer delete(a)
	defer delete(b)
	defer delete(c)
	// The same seed, the same order, every run: a shot half way is always the same shot.
	same, differ, in_place := true, 0, 0
	for i in 0 ..< len(a) {
		if a[i] != b[i] do same = false
		if a[i] != c[i] do differ += 1
		if int(a[i]) == i do in_place += 1
	}
	testing.expect(t, same, "the order changed between two runs")
	testing.expectf(t, differ > 60000, "another seed should be another order (%v differ)", differ)
	// Shuffled, not swept: almost nothing is left where it started.
	testing.expectf(t, in_place < 100, "%v pixels never moved in the shuffle", in_place)
	// And spread: the first hundredth to turn is all over the picture, not
	// one corner: something in every band of four rows.
	bands: [50]bool
	for p in a[:640] do bands[p / 320 / 4] = true
	for b, i in bands do testing.expectf(t, b, "rows %v to %v have nothing in the first hundredth", i * 4, i * 4 + 3)
	// Ordered: at a quarter, a half, three quarters, exactly the pixels of a
	// 4x4 ordered dither have turned, so the picture is an even dither of the
	// two paintings and not static.
	for q in ([]int{4, 8, 12}) {
		turned := make([]bool, len(a))
		defer delete(turned)
		for p in a[:len(a) * q / 16] do turned[p] = true
		for p, i in turned {
			x, y := i % 320, i / 320
			testing.expectf(t, p == (int(BAYER4[y % 4][x % 4]) < q), "%v/16: pixel %v,%v", q, x, y)
		}
	}
	// Half way is a checkerboard.
	half := make([]bool, len(a))
	defer delete(half)
	for p in a[:len(a) / 2] do half[p] = true
	for y in 0 ..< 4 do for x in 0 ..< 4 do testing.expect_value(t, half[y * 320 + x], (x + y) % 2 == 0)
}

@(test)
dissolve_counts_from_none_to_all :: proc(t: ^testing.T) {
	n := 640 * 240
	testing.expect_value(t, dissolve_count(0, n), 0)
	testing.expect_value(t, dissolve_count(-1, n), 0)
	testing.expect_value(t, dissolve_count(1, n), n)
	testing.expect_value(t, dissolve_count(2, n), n)
	testing.expect_value(t, dissolve_count(0.5, n), n / 2)
	last := 0
	for i in 0 ..= 1000 {
		c := dissolve_count(f32(i) / 1000, n)
		testing.expectf(t, c >= last, "fewer turned at %v than before", f32(i) / 1000)
		last = c
	}
	testing.expect_value(t, last, n)
}

@(test)
dusk_scales_with_its_length :: proc(t: ^testing.T) {
	// Ten seconds, the default.
	testing.expect_value(t, dusk_progress(0, 10), 0)
	testing.expect_value(t, dusk_progress(5, 10), 0.5)
	testing.expect_value(t, dusk_progress(10, 10), 1)
	testing.expect_value(t, dusk_progress(60, 10), 1) // and it stays night
	// Thirty: the same dusk, three times as slow.
	testing.expect_value(t, dusk_progress(15, 30), 0.5)
	testing.expect_value(t, dusk_progress(30, 30), 1)
	for s in 0 ..= 30 {
		// Thirty seconds at 3s is ten at s, all the way and after.
		testing.expectf(t, abs(dusk_progress(f32(s) * 3, 30) - dusk_progress(f32(s), 10)) < 1e-5, "30 s at %v should be 10 s at %v", s * 3, s)
	}
	// Ten seconds in, a thirty-second dusk is a third done; the pixels too.
	n := 640 * 240
	testing.expect_value(t, dissolve_count(dusk_progress(10, 30), n), n / 3)
	testing.expect_value(t, dissolve_count(dusk_progress(10, 10), n), n)
	// No length, no dusk: the first painting stays.
	testing.expect_value(t, dusk_progress(100, 0), 0)
	testing.expect_value(t, dusk_progress(100, -1), 0)
}

@(test)
dissolve_steps_turn_each_pixel_once_and_back :: proc(t: ^testing.T) {
	n := 320 * 4
	from := make([]rl.Color, n)
	to := make([]rl.Color, n)
	shown := make([]rl.Color, n)
	defer delete(from)
	defer delete(to)
	defer delete(shown)
	for i in 0 ..< n {
		from[i] = {170, 85, 0, 255} // sunset brown
		to[i] = {0, 0, 170, 255}    // night blue
	}
	copy(shown, from)
	order := dissolve_order(320, 4)
	defer delete(order)

	count_night :: proc(shown: []rl.Color) -> (c: int) {
		for p in shown do if p.b == 170 do c += 1
		return
	}
	done := 0
	// In uneven steps, as frames come: the shown picture always has exactly
	// as many night pixels as have turned.
	for p in ([]f32{0.01, 0.013, 0.2, 0.2, 0.55, 0.9, 0.999, 1}) {
		done = dissolve_step(shown, from, to, order, done, dissolve_count(p, n))
		testing.expect_value(t, count_night(shown), done)
	}
	testing.expect_value(t, done, n)
	for p in shown do testing.expect_value(t, p, rl.Color{0, 0, 170, 255})
	// The dusk begun again: back to the first painting, every pixel.
	done = dissolve_step(shown, from, to, order, done, 0)
	testing.expect_value(t, done, 0)
	testing.expect_value(t, count_night(shown), 0)
}

@(test)
dusk_seconds_from_the_environment :: proc(t: ^testing.T) {
	m := Menu{dusk_seconds = 10}
	was := os.get_env(TITLE_DUSK_ENV, context.temp_allocator)
	defer if was != "" do os.set_env(TITLE_DUSK_ENV, was)
	else do os.unset_env(TITLE_DUSK_ENV)
	os.set_env(TITLE_DUSK_ENV, "30")
	testing.expect_value(t, menu_dusk_seconds(&m), 30)
	os.set_env(TITLE_DUSK_ENV, "soon")
	testing.expect_value(t, menu_dusk_seconds(&m), 10) // not a number: the game's own
	os.unset_env(TITLE_DUSK_ENV)
	testing.expect_value(t, menu_dusk_seconds(&m), 10)
	// Held by the harness: exactly that, however much time passes.
	m.dusk_held, m.dusk_hold = true, 0.25
	m.time = 999
	testing.expect_value(t, menu_dusk(&m), 0.25)
	m.dusk_held = false
	m.dusk_on, m.dusk_from, m.dusk_secs = true, 990, 10
	testing.expect_value(t, menu_dusk(&m), 0.9)
	m.dusk_on = false // the title come up again: from the start
	testing.expect_value(t, menu_dusk(&m), 0)
}

@(test)
about_wraps_its_paragraphs :: proc(t: ^testing.T) {
	// Measured in characters, ten to a line.
	measure :: proc(text: string) -> f32 {return f32(len(text))}
	a := About{lines = {"one two three four five", "", "six"}}
	lines := about_lines(a, 10, measure)
	testing.expect_value(t, len(lines), 5)
	testing.expect_value(t, lines[0], "one two")
	testing.expect_value(t, lines[1], "three four")
	testing.expect_value(t, lines[2], "five")
	testing.expect_value(t, lines[3], "")
	testing.expect_value(t, lines[4], "six")
}

@(test)
title_bang_holds_the_dusk :: proc(t: ^testing.T) {
	defer title_harness = {}
	title_bang("at=0.5 about")
	testing.expect(t, title_harness.on && title_harness.held && title_harness.about)
	testing.expect_value(t, title_harness.at, 0.5)
	f := front_new({}, Menu{dusk_seconds = 10}, Launch{skip = true}, nil)
	testing.expect_value(t, f.phase, Front_Phase.Menu)
	testing.expect_value(t, menu_dusk(&f.menu), 0.5)
	testing.expect(t, about_open(&f.menu))
	testing.expect_value(t, title_bang("at=2"), TITLE_BANG_USAGE)
	// The Load screen, and a row of it.
	title_bang("load 7")
	testing.expect(t, title_harness.on && title_harness.load && !title_harness.held)
	testing.expect_value(t, title_harness.load_row, 7)
	title_bang("load")
	testing.expect(t, title_harness.load)
	testing.expect_value(t, title_harness.load_row, 0)
	testing.expect_value(t, title_bang("load x"), TITLE_BANG_USAGE)
}

@(test)
title_report_says_night_or_dusk :: proc(t: ^testing.T) {
	night := Sprite{texture = {id = 1}}
	items := []cstring{"Start", "Load Game", "Quit"}
	// Night from the start: the night paintings as the layers, no dusk.
	m := Menu{layers = {{sprite = night}, {sprite = night}}, items = items, lights = {.Night, .Night}}
	testing.expect_value(t, title_report(&m), "title: 2 of 2 layers painted, no dusk, the Night theme; choices Start, Load Game, Quit")
	// A dusk with no night paintings is no dusk.
	m.dusk_seconds = 10
	testing.expect_value(t, title_report(&m), "title: 2 of 2 layers painted, no dusk, the Night theme; choices Start, Load Game, Quit")
}
