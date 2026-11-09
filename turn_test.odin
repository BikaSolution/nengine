package nengine

import "core:testing"

// A camp with one thing that happens: at 16:40 a man comes out of his tent.
@(private = "file")
camp :: proc() -> World {
	w: World
	w.clock_start, w.clock_step = 16 * 60, 1
	w.clock_turns, w.clock_turn_max = true, 30
	sc := Scene{name = "row"}
	append(&sc.objects, Object{name = "man", sprite_name = "man", only = "out"})
	append(&w.scenes, sc)
	w.on_clock = proc(w: ^World) {set_flag(w, "out", clock_minute(w) >= 16 * 60 + 40)}
	return w
}

@(test)
a_turn_runs_to_the_next_change :: proc(t: ^testing.T) {
	w := camp()
	defer destroy_world(&w)
	tick(&w) // nothing until twenty to five... but no more than half an hour
	testing.expect_value(t, clock_minute(&w), 16 * 60 + 30)
	tick(&w) // and then he comes out, and the turn stops there
	testing.expect_value(t, clock_minute(&w), 16 * 60 + 40)
	clock_at_least(&w, 17 * 60) // a jump is minutes, not turns
	testing.expect_value(t, clock_minute(&w), 17 * 60)
}

@(test)
a_clue_is_a_turn_once_a_command :: proc(t: ^testing.T) {
	w := camp()
	defer destroy_world(&w)
	w.notes_tick = true
	w.ticked = false
	note(&w, {id = "a", tab = "things", text = "One."})
	at := clock_minute(&w)
	testing.expect(t, at > 16 * 60) // the first clue spent a turn
	note(&w, {id = "b", tab = "things", text = "Two, from the same look."})
	testing.expect_value(t, clock_minute(&w), at) // the second did not
	w.ticked = false // the next command
	note(&w, {id = "c", tab = "things", text = "Three."})
	testing.expect(t, clock_minute(&w) > at)
}
