package nengine

import "core:strings"
import "core:testing"
import rl "vendor:raylib"

// Somebody going past outside (passer.odin): the dice, the wait, the window,
// the glass it is drawn through, and that it is seen and changes nothing.

// A hut with two windows (the second only at night, by its own `when=`), its
// frame object, a yard outside with none, and a figure 28x54 at 3.2.
@(private = "file")
Fixture :: struct {
	w:      World,
	assets: Assets,
}

@(private = "file")
fixture :: proc(f: ^Fixture) {
	f.assets.chars = make(map[string]Character_Art)
	art := Character_Art{name = "figure"}
	art.parts = make(map[string]Part_Art)
	art.parts["walk_right"] = {sprite = {frame_w = 90, frame_h = 173, frames = 4}}
	art.parts["walk_left"] = {sprite = {frame_w = 90, frame_h = 173, frames = 4}}
	f.assets.chars["figure"] = art
	f.w.assets = &f.assets

	hut := Scene{name = "hut", indoors = true}
	append(&hut.objects, Object{name = "chair", pos = {500, 500}})
	append(&hut.objects, Object{name = "win_back", pos = {512, 400}, depth = .Back, base = 200})
	append(&hut.windows, Window{name = "back", glass = {445, 176, 138, 122}})
	append(&hut.windows, Window{name = "side", glass = {854, 262, 32, 218}, feet = 480, only = "shutter_cut"})
	hut.windows[0].frame = "win_back"
	yard := Scene{name = "yard"}
	append(&yard.windows, Window{name = "nothing", glass = {0, 0, 10, 10}}) // outdoors: never
	shed := Scene{name = "shed", indoors = true} // indoors, no window: never
	append(&f.w.scenes, hut, yard, shed)
	f.w.current = 1
	refresh_world(&f.w)
	set_passer(&f.w, {character = "figure", chance = 0.10, max_delay = 20, only = "night", seed = 7})
	set_flag(&f.w, "night", true)
}

@(private = "file")
tidy :: proc(f: ^Fixture) {
	for _, &art in f.assets.chars do delete(art.parts)
	delete(f.assets.chars)
	destroy_world(&f.w)
}

// One in ten, near enough, over a great many rooms come into; never at a
// chance of 0 and every time at 1.
@(test)
the_dice_come_up_at_the_chance_given :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer tidy(&f)
	w := &f.w
	hits := 0
	for _ in 0 ..< 10000 {
		go_to(w, 0, {500, 560})
		if w.passer.phase == .Waiting do hits += 1
	}
	testing.expectf(t, hits > 900 && hits < 1100, "%v rooms of 10000 had somebody at a chance of 0.1", hits)

	w.passer.chance = 0
	for _ in 0 ..< 1000 {
		go_to(w, 0, {500, 560})
		testing.expect_value(t, w.passer.phase, Passer_Phase.Idle)
	}
	w.passer.chance = 1
	for _ in 0 ..< 1000 {
		go_to(w, 0, {500, 560})
		testing.expect_value(t, w.passer.phase, Passer_Phase.Waiting)
	}
}

// Outdoors, indoors with no window open, or while the game's condition is
// false: no roll at all, whatever the chance.
@(test)
nobody_comes_outdoors_by_day_or_where_there_is_no_window :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer tidy(&f)
	w := &f.w
	w.passer.chance = 1
	go_to(w, 1, {10, 10}) // the yard: outdoors
	testing.expect_value(t, w.passer.phase, Passer_Phase.Idle)
	go_to(w, 2, {10, 10}) // the shed: no window
	testing.expect_value(t, w.passer.phase, Passer_Phase.Idle)
	set_flag(w, "night", false)
	go_to(w, 0, {500, 560}) // the hut by day
	testing.expect_value(t, w.passer.phase, Passer_Phase.Idle)
	set_flag(w, "night", true)
	go_to(w, 0, {500, 560})
	testing.expect_value(t, w.passer.phase, Passer_Phase.Waiting)
	// And with no figure, nobody.
	w.passer.character = ""
	go_to(w, 0, {500, 560})
	testing.expect_value(t, w.passer.phase, Passer_Phase.Idle)
}

// The wait is between none and max_delay seconds of World.time, and spread
// across it.
@(test)
the_wait_is_up_to_max_delay :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer tidy(&f)
	w := &f.w
	w.passer.chance = 1
	w.time = 100
	lo, hi := f32(1e9), f32(-1)
	for _ in 0 ..< 5000 {
		go_to(w, 0, {500, 560})
		d := w.passer.starts_at - w.time
		testing.expect(t, d >= 0 && d <= 20)
		lo, hi = min(lo, d), max(hi, d)
	}
	testing.expectf(t, lo < 0.5 && hi > 19.5, "waits ran %v..%v of 0..20", lo, hi)

	// It sets off when its time comes, not before.
	go_to(w, 0, {500, 560})
	at := w.passer.starts_at
	w.time = at - 0.01
	update_passer(w, 1.0 / 60)
	testing.expect_value(t, w.passer.phase, Passer_Phase.Waiting)
	w.time = at
	update_passer(w, 1.0 / 60)
	testing.expect_value(t, w.passer.phase, Passer_Phase.Walking)
}

// Only an open window is crossed; each open one comes up; both ways come up.
@(test)
it_picks_an_open_window_and_a_way :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer tidy(&f)
	w := &f.w
	go_to(w, 0, {500, 560})
	seen: [2]int
	ways: [2]int
	for _ in 0 ..< 400 {
		testing.expect(t, passer_start(w))
		seen[w.passer.window] += 1
		ways[int(w.passer.rightward)] += 1
	}
	testing.expect_value(t, seen[1], 0) // the side window's when= is false
	testing.expect_value(t, seen[0], 400)
	testing.expect(t, ways[0] > 120 && ways[1] > 120)

	set_flag(w, "shutter_cut", true)
	seen = {}
	for _ in 0 ..< 400 {
		passer_start(w)
		seen[w.passer.window] += 1
	}
	testing.expect(t, seen[0] > 120 && seen[1] > 120)

	// Asked for one, it is that one, that way.
	testing.expect(t, passer_start(w, 1, false))
	testing.expect_value(t, w.passer.window, 1)
	testing.expect_value(t, w.passer.rightward, false)
}

// Seeded, the same dice throw the same rooms.
@(test)
the_same_seed_throws_the_same :: proc(t: ^testing.T) {
	a, b: Fixture
	fixture(&a)
	defer tidy(&a)
	fixture(&b)
	defer tidy(&b)
	passer_seed(&a.w, 99)
	passer_seed(&b.w, 99)
	for _ in 0 ..< 200 {
		go_to(&a.w, 0, {500, 560})
		go_to(&b.w, 0, {500, 560})
		testing.expect_value(t, a.w.passer.phase, b.w.passer.phase)
		testing.expect_value(t, a.w.passer.starts_at, b.w.passer.starts_at)
	}
}

// From wholly out of sight past one edge of the glass to wholly out of sight
// past the other; standing on the window's feet line, or by default the foot
// of the glass and half a figure, so the figure shows from the waist up.
@(test)
the_walk_runs_from_beyond_one_edge_to_beyond_the_other :: proc(t: ^testing.T) {
	glass := rl.Rectangle{445, 176, 138, 122}
	figure := [2]f32{90, 173}
	testing.expect_value(t, window_feet(Window{glass = glass}, 173), f32(176 + 122) + 86.5)
	testing.expect_value(t, window_feet(Window{glass = glass, feet = 380}, 173), f32(380))
	testing.expect_value(t, passer_feet(glass, figure, 380, 0, true), [2]f32{400, 380})
	testing.expect_value(t, passer_feet(glass, figure, 380, 1, true), [2]f32{628, 380})
	testing.expect_value(t, passer_feet(glass, figure, 380, 0, false), [2]f32{628, 380})
	testing.expect_value(t, passer_feet(glass, figure, 380, 1, false), [2]f32{400, 380})

	// It is done when it is across, at its speed.
	f: Fixture
	fixture(&f)
	defer tidy(&f)
	w := &f.w
	go_to(w, 0, {500, 560})
	passer_start(w, 0, true)
	secs := passer_span(glass, 90) / PASSER_SPEED
	half := secs * 0.5
	for half > 0 {
		step := min(half, 1.0 / 60)
		update_passer(w, step)
		half -= step
	}
	testing.expect_value(t, w.passer.phase, Passer_Phase.Walking)
	testing.expect(t, abs(passer_progress(w) - 0.5) < 0.001)
	for _ in 0 ..< int(secs * 0.51 * 60) + 2 do update_passer(w, 1.0 / 60)
	testing.expect_value(t, w.passer.phase, Passer_Phase.Idle)

	// A stalled frame (the first after loading) moves it a fifteenth of a
	// second, not the seconds the stall took: the walk is still seen.
	passer_start(w, 0, true)
	update_passer(w, 5)
	testing.expect_value(t, w.passer.phase, Passer_Phase.Walking)
	testing.expect(t, abs(passer_progress(w) - PASSER_MAX_STEP * PASSER_SPEED / passer_span(glass, 90)) < 0.001)
}

// The scissor is the glass, in whole pixels, inside the canvas.
@(test)
it_is_clipped_to_the_glass :: proc(t: ^testing.T) {
	x, y, cw, ch := passer_clip({445, 176, 138, 122}, {1024, 640})
	testing.expect_value(t, [4]i32{x, y, cw, ch}, [4]i32{445, 176, 138, 122})
	x, y, cw, ch = passer_clip({-10.4, 173, 292.4, 221}, {1024, 640}) // off the left edge
	testing.expect_value(t, [4]i32{x, y, cw, ch}, [4]i32{0, 173, 282, 221})
	x, y, cw, ch = passer_clip({990, 600, 100, 100}, {1024, 640}) // off the corner
	testing.expect_value(t, [4]i32{x, y, cw, ch}, [4]i32{990, 600, 34, 40})
	_, _, cw, ch = passer_clip({2000, 10, 50, 50}, {1024, 640}) // off the canvas: nothing
	testing.expect(t, cw == 0 || ch == 0)
}

// Drawn just under the window's frame, whatever else is at depth=back; with
// no frame named (or it is not here), after everything at depth=back.
@(test)
it_is_drawn_just_under_the_frame :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer tidy(&f)
	sc := &f.w.scenes[0]
	k := passer_key(sc, &sc.windows[0])
	testing.expect_value(t, k, Passer_Key{.Back, 600, 1})
	k = passer_key(sc, &sc.windows[1])
	testing.expect_value(t, k.depth, Depth.Back)
	testing.expect_value(t, k.y, max(f32))
	sc.objects[1].hidden = true
	testing.expect_value(t, passer_key(sc, &sc.windows[0]).y, max(f32))
}

// Leaving the room ends it: through a door, waiting or half across, and by
// any other way the room changes.
@(test)
leaving_the_room_ends_it :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer tidy(&f)
	w := &f.w
	w.passer.chance = 1
	go_to(w, 0, {500, 560})
	testing.expect_value(t, w.passer.phase, Passer_Phase.Waiting)
	go_to(w, 1, {10, 10})
	testing.expect_value(t, w.passer.phase, Passer_Phase.Idle)

	go_to(w, 0, {500, 560})
	passer_start(w)
	w.current = 2 // a room changed by hand
	update_passer(w, 1.0 / 60)
	testing.expect_value(t, w.passer.phase, Passer_Phase.Idle)
	shown, _ := passer_shown(w, &w.scenes[0])
	testing.expect(t, !shown)
}

// Seen and nothing more: no tick, no flag, no note, no award, from the roll
// to the far edge.
@(test)
it_spends_no_time_and_changes_nothing :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer tidy(&f)
	w := &f.w
	w.clock_start, w.clock_step = 20 * 60, 4
	w.passer.chance = 1
	go_to(w, 0, {500, 560})
	flags_before := strings.clone(flags_text(w), context.temp_allocator)
	ticks := w.clock_ticks
	for _ in 0 ..< 60 * 40 {
		w.time += 1.0 / 60
		update_passer(w, 1.0 / 60)
	}
	testing.expect_value(t, w.passer.phase, Passer_Phase.Idle) // it came and went
	testing.expect_value(t, w.clock_ticks, ticks)
	testing.expect_value(t, flags_text(w), flags_before)
	testing.expect_value(t, len(w.notebook), 0)
	testing.expect_value(t, len(w.earned), 0)
}

// A scene file says it, and says it back.
@(test)
a_window_line_reads_and_writes_back :: proc(t: ^testing.T) {
	text := "scene hut\nindoors\nwindow back glass=445,176,138,122 feet=380 frame=win_back when=night\nwindow side glass=854,262,32,218\n"
	s, ok := parse_scene(text, nil)
	testing.expect(t, ok)
	defer {
		free_scene_strings(&s)
		delete(s.windows)
		delete(s.said)
		delete(s.objects)
		delete(s.exits)
		delete(s.triggers)
		delete(s.walk_area)
		delete(s.scenery)
	}
	testing.expect_value(t, len(s.windows), 2)
	testing.expect_value(t, s.windows[0].glass, rl.Rectangle{445, 176, 138, 122})
	testing.expect_value(t, s.windows[0].feet, f32(380))
	testing.expect_value(t, s.windows[0].frame, "win_back")
	testing.expect_value(t, s.windows[0].only, "night")
	testing.expect_value(t, s.windows[1].feet, f32(0))
	out := scene_text(&s)
	testing.expect(t, strings.contains(out, "window back glass=445,176,138,122 feet=380 frame=win_back when=night\n"))
	testing.expect(t, strings.contains(out, "window side glass=854,262,32,218\n"))
}
