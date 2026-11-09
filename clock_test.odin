package nengine

import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
clocked :: proc() -> World {
	return World{clock_start = 19 * 60 + 30, clock_step = 4}
}

@(private = "file")
tidy :: proc(w: ^World) {
	clear_notebook(w)
	clear_accusations(w)
	clear_flags(w)
	clear_awards(w)
	delete(w.notebook)
	delete(w.accusations)
	delete(w.scenes)
}

// The hook counts how often the hour changed, so tests can see it being told.
@(private = "file", thread_local)
heard: int

@(private = "file")
count_hours :: proc(w: ^World) {
	heard += 1
	set_flag(w, "late", clock_minute(w) >= 23 * 60)
}

@(test)
the_clock_starts_where_the_game_says_and_moves_by_the_tick :: proc(t: ^testing.T) {
	w := clocked()
	defer tidy(&w)
	testing.expect_value(t, clock_minute(&w), 19 * 60 + 30)
	tick(&w)
	testing.expect_value(t, clock_minute(&w), 19 * 60 + 34)
	tick(&w, 10)
	testing.expect_value(t, clock_minute(&w), 19 * 60 + 74)
}

// The story does not run backwards. A restore is set_clock, not a negative
// tick, and a tick of nothing is nothing.
@(test)
a_tick_cannot_take_time_back :: proc(t: ^testing.T) {
	w := clocked()
	defer tidy(&w)
	tick(&w, 5)
	tick(&w, -3)
	tick(&w, 0)
	testing.expect_value(t, w.clock_ticks, 5)
}

// A prologue holds the clock: while the condition holds, a tick is free, and
// when it stops holding the clock goes on from where it was.
@(test)
a_held_clock_spends_nothing_until_it_is_let_go :: proc(t: ^testing.T) {
	w := clocked()
	defer tidy(&w)
	w.clock_held = "prologue"
	set_flag(&w, "prologue", true)
	tick(&w, 3)
	clock_at_least(&w, 23 * 60)
	testing.expect_value(t, clock_minute(&w), 19 * 60 + 30)
	set_flag(&w, "prologue", false)
	tick(&w)
	testing.expect_value(t, clock_minute(&w), 19 * 60 + 34)
}

// Ten past midnight is 1450, not 10. The face wraps; the minute never does.
@(test)
the_clock_counts_on_past_midnight_and_only_the_face_wraps :: proc(t: ^testing.T) {
	w := clocked()
	defer tidy(&w)
	tick(&w, 101) // 19:30 + 404 minutes
	testing.expect_value(t, clock_minute(&w), 26 * 60 + 14)
	testing.expect_value(t, clock_face(clock_minute(&w)), "02:14")
	testing.expect_value(t, clock_face(0), "00:00")
	testing.expect_value(t, clock_face(23 * 60 + 52), "23:52")
	testing.expect_value(t, clock_face(24 * 60 + 10), "00:10")
	// A clock that starts before midnight and is asked about earlier.
	testing.expect_value(t, clock_face(-10), "23:50")
}

@(test)
the_game_hears_about_every_hour_that_passes :: proc(t: ^testing.T) {
	w := clocked()
	defer tidy(&w)
	w.on_clock = count_hours
	heard = 0

	tick(&w)
	tick(&w, 3)
	testing.expect_value(t, heard, 2)
	testing.expect(t, !flag(&w, "late"))

	set_clock(&w, 60) // 23:30
	testing.expect_value(t, heard, 3)
	testing.expect(t, flag(&w, "late"), "on_clock's flags follow the hour")

	tick(&w, 0) // spending nothing is not an hour passing
	testing.expect_value(t, heard, 3)
}

// Finding something writes it, stamps it with the hour, and spends a tick —
// once. The notebook is idempotent, so the clock is too.
@(test)
discovering_a_thing_twice_costs_what_it_did_once :: proc(t: ^testing.T) {
	w := clocked()
	defer tidy(&w)
	testing.expect(t, discover(&w, {id = "shoe", tab = "things", text = "One shoe."}))
	testing.expect(t, !discover(&w, {id = "shoe", tab = "things", text = "One shoe."}))
	testing.expect_value(t, w.clock_ticks, 1)

	e, _ := notebook_entry(&w, "shoe")
	m, timed := e.minute.?
	testing.expect(t, timed)
	// Stamped with the hour it was found, before the tick it cost.
	testing.expect_value(t, m, 19 * 60 + 30)
}

// A witness's "about eleven" is about eleven whenever it is heard.
@(test)
a_discovery_that_knows_its_own_hour_keeps_it :: proc(t: ^testing.T) {
	w := clocked()
	defer tidy(&w)
	tick(&w, 60)
	discover(&w, {id = "voice", tab = "times", text = "A woman's voice.", minute = 23 * 60 + 15})
	e, _ := notebook_entry(&w, "voice")
	m, _ := e.minute.?
	testing.expect_value(t, m, 23 * 60 + 15)
}

// A game about a clock cannot come back from a restore with the night still to
// spend. The engine saves the count; on_clock puts the world back to the hour.
@(test)
the_story_clock_survives_a_save :: proc(t: ^testing.T) {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" do base = "/tmp"
	dir := strings.concatenate({base, "/nengine-clock"}, context.temp_allocator)
	os.remove_all(dir)
	defer os.remove_all(dir)

	w := clocked()
	w.save_name = dir
	w.on_clock = count_hours
	append(&w.scenes, Scene{name = "fire_pit"})
	defer tidy(&w)

	tick(&w, 60)
	testing.expect(t, flag(&w, "late"))
	testing.expect(t, save_game(&w, 1))

	tick(&w, 20)
	set_flag(&w, "late", false) // as if the world had moved on and forgotten
	testing.expect(t, load_game(&w, 1))
	testing.expect_value(t, w.clock_ticks, 60)
	testing.expect(t, flag(&w, "late"), "the world is put back to the hour it was saved at")
}

@(test)
a_tick_is_worth_the_pace_it_starts_in :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	@(static) paces := [?]Clock_Pace{{from = 19 * 60 + 30, step = 4}}
	w.clock_start, w.clock_step, w.clock_paces = 16 * 60, 15, paces[:]

	tick(&w, 13) // quarter hours: 19:15
	testing.expect_value(t, clock_face(clock_minute(&w)), "19:15")
	tick(&w)     // the last quarter: 19:30
	tick(&w)     // and from dinner, fours
	testing.expect_value(t, clock_face(clock_minute(&w)), "19:34")
}

@(test)
windows_and_catching_up :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	w.clock_start, w.clock_step = 16 * 60, 15

	testing.expect(t, clock_between(&w, 16 * 60, 16 * 60 + 35))
	testing.expect(t, !clock_between(&w, 16 * 60 + 20, 16 * 60 + 35))

	// A talk from twenty past to twenty-five to: walk in at four, and it is
	// over at twenty-five to — the next quarter at or after it.
	testing.expect_value(t, clock_at_least(&w, 16 * 60 + 35), 3)
	testing.expect_value(t, clock_face(clock_minute(&w)), "16:45")
	testing.expect_value(t, clock_at_least(&w, 16 * 60), 0) // already past: free
}

@(test)
overheard_once_in_its_window :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	w.clock_start, w.clock_step = 17 * 60, 15
	append(&w.scenes, Scene{})
	man := Speaker{name = "A man"}
	lines := []Talk_Line{{who = &man, text = "Four."}}
	wall := Overheard{name = "heard_it", from = 17 * 60 + 25, until = 17 * 60 + 40, cost = 1, lines = lines}
	c: Conversation

	testing.expect_value(t, overhear(&w, wall, &c), Overhear_Outcome.Too_Early)
	tick(&w, 2) // 17:30
	testing.expect_value(t, overhear(&w, wall, &c), Overhear_Outcome.Heard)
	testing.expect(t, talking(&w))
	testing.expect_value(t, w.clock_ticks, 3) // listening cost one
	testing.expect(t, flag(&w, "heard_it"))
	end_conversation(&w)
	testing.expect_value(t, overhear(&w, wall, &c), Overhear_Outcome.Already)

	clear_flags(&w)
	tick(&w, 1) // 17:45
	testing.expect_value(t, overhear(&w, wall, &c), Overhear_Outcome.Too_Late)
}
