package nengine

import "core:testing"

@(private = "file", thread_local)
fired: int

@(test)
a_timer_fires_once_unless_called_off :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	fired = 0
	after(&w, "drug", 25, proc(w: ^World) {fired += 1})
	left, running := timer_left(&w, "drug")
	testing.expect(t, running)
	testing.expect_value(t, left, f32(25))

	w.time = 24
	run_timers(&w)
	testing.expect_value(t, fired, 0)
	w.time = 25
	run_timers(&w)
	testing.expect_value(t, fired, 1)
	run_timers(&w)
	testing.expect_value(t, fired, 1) // once

	after(&w, "drug", 5, proc(w: ^World) {fired += 1})
	cancel_timer(&w, "drug")
	w.time = 100
	run_timers(&w)
	testing.expect_value(t, fired, 1) // she got away
	_, running = timer_left(&w, "drug")
	testing.expect(t, !running)
}

// A deadline waits while there is something on the screen to read; a plain
// timer (somebody else's fuse) does not.
@(test)
a_deadline_waits_while_she_reads :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	deadline(&w, "drug", 25, nil)
	after(&w, "engine", 25, nil)
	lines := [?]Talk_Line{{text = "There. Up the slope."}}
	begin_conversation(&w, &w.node_talk, lines[:])
	testing.expect(t, talking(&w))
	w.time += 10
	hold_deadlines(&w, 10)
	left, _ := timer_left(&w, "drug")
	testing.expect_value(t, left, f32(25)) // her seconds waited
	left, _ = timer_left(&w, "engine")
	testing.expect_value(t, left, f32(15)) // the world's did not
	for talking(&w) do advance_conversation(&w)
	w.time += 5
	hold_deadlines(&w, 5)
	left, _ = timer_left(&w, "drug")
	testing.expect_value(t, left, f32(20))
}
