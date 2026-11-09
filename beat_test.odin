package nengine

import "core:testing"

@(private = "file", thread_local)
played: int

@(private = "file")
dinner :: proc() -> World {
	w: World
	w.clock_start, w.clock_step = 20 * 60, 4
	append(&w.scenes, Scene{name = "fire"}, Scene{name = "kitchen"})
	w.player.pos = {100, 100}
	played = 0
	return w
}

@(private = "file")
man := Speaker{name = "A man"}
@(private = "file")
LINES := [?]Talk_Line{{who = &man, text = "Nine o'clock. The pool."}}

@(private = "file")
BEATS := [?]Beat {
	{name = "heard", room = "fire", from = 20 * 60 + 20, until = 20 * 60 + 28,
	 area = {300, 300, 100, 100}, cost = 1, lines = LINES[:], on_play = proc(w: ^World) {played += 1}},
	{name = "saw", room = "fire", from = 20 * 60 + 20, until = 20 * 60 + 28, only = "!heard"},
	{name = "gong", from = 20 * 60 + 4, until = 21 * 60}, // anywhere
}

@(test)
a_beat_plays_once_where_and_when_it_happens :: proc(t: ^testing.T) {
	w := dinner()
	defer destroy_world(&w)
	w.beats = BEATS[:]

	testing.expect(t, !play_beats(&w)) // 20:00: nothing yet
	tick(&w)                           // 20:04
	testing.expect(t, play_beats(&w))  // the gong, in any room
	testing.expect(t, flag(&w, "gong"))
	testing.expect(t, !play_beats(&w)) // once

	tick(&w, 5) // 20:24
	w.player.pos = {350, 350}          // at the next chair
	testing.expect(t, play_beats(&w))
	testing.expect(t, flag(&w, "heard"))
	testing.expect_value(t, played, 1)
	testing.expect(t, talking(&w))
	testing.expect_value(t, w.clock_ticks, 7) // it cost one
	testing.expect(t, !play_beats(&w))        // not over a conversation
	end_conversation(&w)
	testing.expect(t, !play_beats(&w))        // and "saw" is ruled out by hearing
	clear_flags(&w)
}

@(test)
not_there_and_it_happens_without_you :: proc(t: ^testing.T) {
	w := dinner()
	defer destroy_world(&w)
	w.beats = BEATS[:]
	w.current = 1 // the kitchen
	tick(&w, 6)   // 20:24
	testing.expect(t, play_beats(&w)) // only the gong
	testing.expect(t, !play_beats(&w))
	tick(&w, 2)   // 20:32: the window has shut
	w.current = 0
	testing.expect(t, !play_beats(&w))
	testing.expect(t, !flag(&w, "heard") && !flag(&w, "saw"))
	clear_flags(&w)
}

@(test)
a_glance_whose_condition_is_false_is_skipped :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	looks := []Glance{{look = "a", secs = 1}, {look = "b", secs = 1, only = "open"}, {look = "c", secs = 1}}
	hosts := []Host{{name = "cat", anywhere = true, attention = looks}}
	w.hosts = hosts
	append(&w.scenes, Scene{name = "room"})
	ride(&w, "cat")
	settle_ride(&w)
	testing.expect_value(t, ride_glance(&w).look, "a")
	update_ride(&w, 1)
	testing.expect_value(t, ride_glance(&w).look, "c") // b skipped
	set_flag(&w, "open")
	update_ride(&w, 1)
	update_ride(&w, 1)
	testing.expect_value(t, ride_glance(&w).look, "b")
	clear_flags(&w)
}
