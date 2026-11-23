package nengine

import "core:strings"
import "core:testing"

// A row with a net in it, and one thing that happens: at 16:40 a man comes
// out of his tent. Turns, a minute underneath, half an hour at most.
@(private = "file")
reach_camp :: proc(windows: []Peep_Window) -> World {
	w: World
	w.clock_start, w.clock_step = 16 * 60, 1
	w.clock_turns, w.clock_turn_max = true, 30
	sc := Scene{name = "row"}
	append(&sc.objects, Object{name = "man", sprite_name = "man", only = "out"})
	append(&sc.objects, Object{name = "net", peep = {is = true, kind = .Net}})
	append(&w.scenes, sc)
	w.on_clock = proc(w: ^World) {set_flag(w, "out", clock_minute(w) >= 16 * 60 + 40)}
	w.peep_windows = windows
	return w
}

@(test)
a_window_nothing_marks_is_stepped_over :: proc(t: ^testing.T) {
	windows := [?]Peep_Window {
		{name = "at_the_change", peep = "net", from = 16 * 60 + 40, until = 16 * 60 + 45}, // he comes out at 16:40: a turn stops in it
		{name = "between", peep = "net", from = 16 * 60 + 50, until = 16 * 60 + 55},      // nothing at 16:50: 16:40 -> 17:10
		{name = "a_branch", peep = "net", from = 16 * 60 + 50, until = 16 * 60 + 55, only = "never"}, // shut: not owed
		{name = "any_time", peep = "net"},                                               // a flag's window, not the clock's
	}
	w := reach_camp(windows[:])
	defer destroy_world(&w)
	reach_land(&w, clock_minute(&w), clock_minute(&w), nil)
	for clock_minute(&w) < 17 * 60 do reach_step(&w, "")
	testing.expect_value(t, w.reach[0].reached, 16 * 60 + 40)
	testing.expect(t, w.reach[1].over)
	testing.expect_value(t, w.reach[1].over_from, 16 * 60 + 40)
	testing.expect_value(t, w.reach[1].over_to, 17 * 60 + 10)
	testing.expect(t, !w.reach[2].over)
	report, over := reach_report(&w)
	testing.expect_value(t, over, 1)
	testing.expect(t, strings.contains(report, "between at net, 16:50-16:55: STEPPED OVER, 16:40 -> 17:10"))
	testing.expect(t, strings.contains(report, "at_the_change at net, 16:40-16:45: reached at 16:40"))
	testing.expect(t, !strings.contains(report, "any_time"))
}

// The same window, `!at` into it: a jump stands on any minute, so the
// harness's `!at` would play it and say nothing. The record is for turns.
@(test)
a_jump_lands_where_a_turn_would_not :: proc(t: ^testing.T) {
	windows := [?]Peep_Window{{name = "between", peep = "net", from = 16 * 60 + 50, until = 16 * 60 + 55}}
	w := reach_camp(windows[:])
	defer destroy_world(&w)
	clock_at_least(&w, 16 * 60 + 50)
	testing.expect(t, peep_window_open(&w, &w.peep_windows[0])) // !at hides it
	reach_land(&w, clock_minute(&w), clock_minute(&w), nil)
	testing.expect_value(t, w.reach[0].reached, 16 * 60 + 50) // and the record says where it stood
}

// A beat that plays a window inside a step, and a jump after it past the
// window's hours: the step lands after them, but the window played, so it is
// reached at the minute it played, not stepped over.
@(test)
a_window_a_beat_plays_is_reached :: proc(t: ^testing.T) {
	@(static) said := [?]Talk_Line{{text = "Still out."}}
	windows := [?]Peep_Window{{name = "between", peep = "net", from = 16 * 60 + 50, until = 16 * 60 + 55, lines = said[:],
	                           on_play = proc(w: ^World, _: int) {clock_at_least(w, 17 * 60)}}}
	w := reach_camp(windows[:])
	defer destroy_world(&w)
	beats := [?]Beat{{name = "plays_it", from = 16 * 60 + 40, until = 17 * 60, on_play = proc(w: ^World) {
		clock_at_least(w, 16 * 60 + 50)
		peep(w, object_here(current_scene(w), "net"))
	}}}
	w.beats = beats[:]
	reach_land(&w, clock_minute(&w), clock_minute(&w), nil)
	for clock_minute(&w) < 17 * 60 do reach_step(&w, "")
	testing.expect(t, flag(&w, "heard_between"))
	testing.expect_value(t, w.reach[0].reached, 16 * 60 + 50)
	testing.expect(t, !w.reach[0].over)
	report, over := reach_report(&w)
	testing.expect_value(t, over, 0)
	testing.expect(t, strings.contains(report, "between at net, 16:50-16:55: reached at 16:50"))
}

// A route that ends (the game over: `stop=`) lands nowhere after it, so a
// window past the end is not reached by a game that is over.
@(test)
a_route_stops_where_its_condition_holds :: proc(t: ^testing.T) {
	windows := [?]Peep_Window{{name = "at_the_change", peep = "net", from = 16 * 60 + 40, until = 16 * 60 + 45}}
	w := reach_camp(windows[:])
	defer destroy_world(&w)
	said := reach_bang(&w, "17:00 stop=out")
	testing.expect(t, strings.contains(said, "(stopped: out)"))
	testing.expect_value(t, clock_minute(&w), 16 * 60 + 40) // the step that brought him out, and no more
	testing.expect_value(t, w.reach[0].reached, -1)         // the landing where it holds is not one
	testing.expect(t, !w.reach[0].over)
}

// Away from the aperture, a window is not judged: a route waiting somewhere
// else may stop on other minutes than one waiting at it.
@(test)
a_window_is_judged_at_its_aperture :: proc(t: ^testing.T) {
	windows := [?]Peep_Window{{name = "between", peep = "net", from = 16 * 60 + 50, until = 16 * 60 + 55}}
	w := reach_camp(windows[:])
	defer destroy_world(&w)
	append(&w.scenes, Scene{name = "yard"})
	w.current = 1
	for clock_minute(&w) < 17 * 60 do reach_step(&w, "")
	testing.expect(t, !w.reach[0].over)
	testing.expect_value(t, w.reach[0].at_it, 0)
	report, over := reach_report(&w)
	testing.expect_value(t, over, 0)
	testing.expect(t, strings.contains(report, "she was not at its aperture on this route"))
}
