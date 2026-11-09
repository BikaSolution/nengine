package nengine

import "core:strings"
import "core:testing"

// The hint is the first entry that can be done now. What matters is that it
// is never something already done and never something not yet possible:
// the hour, the flags, the branch.

@(private = "file")
AWARDS := [?]Award {
	{"field_book", "Fairbank's field book", 10, 0, 0, ""},
	{"boiler_log", "The boiler was lit at 23:40", 20, 23 * 60, 25 * 60, ""},
	{"the_flap", "Tied from the outside", 20, 0, 0, "pickett_dead"},
	{"the_lie", "No, never", 0, 0, 0, ""},
}

@(private = "file")
HINTS := [?]Hint {
	{award = "boiler_log", place = "kitchen", nudge = "a", clearer = "b", answer = "c", does = "read log"},
	{award = "field_book", needs = "has_lamp", place = "tent", nudge = "a", clearer = "b", answer = "c", does = "look at book; read it"},
	{award = "the_flap", nudge = "a", clearer = "b", answer = "c", does = "look at flap"},
	{award = "field_book", from = 20 * 60, until = 21 * 60, nudge = "a", clearer = "b", answer = "c", does = "x"},
	{nudge = "sleep on it", clearer = "b", answer = "c", does = "sleep"}, // idle
}

@(private = "file")
hinted_world :: proc(minute: int) -> World {
	return World{awards = AWARDS[:], hints = HINTS[:], clock_start = minute, clock_step = 1}
}

@(private = "file")
tidy :: proc(w: ^World) {
	clear_awards(w)
	clear_flags(w)
}

@(test)
the_hint_is_the_first_entry_that_can_be_done :: proc(t: ^testing.T) {
	w := hinted_world(23 * 60 + 30)
	defer tidy(&w)
	testing.expect_value(t, first_hint(&w), 0) // the boiler, in its hour
	award(&w, "boiler_log")
	// Done: never pointed at again. The field book wants a lamp first.
	testing.expect_value(t, first_hint(&w), 4) // nothing scores: the idle entry
	set_flag(&w, "has_lamp", true)
	testing.expect_value(t, first_hint(&w), 1)
}

@(test)
a_hint_keeps_to_its_hour :: proc(t: ^testing.T) {
	w := hinted_world(22 * 60)
	defer tidy(&w)
	// Before the boiler's window: not yet.
	testing.expect(t, !hint_possible(&w, HINTS[0]), "the award's own window: not before it opens")
	// The entry's own window wins over the award's (0 to 0 here).
	testing.expect(t, !hint_possible(&w, HINTS[3]), "after its own window has shut")
	w.clock_start = 20 * 60 + 30
	testing.expect(t, hint_possible(&w, HINTS[3]), "inside its own window")
	w.clock_start = 25 * 60
	testing.expect(t, !hint_possible(&w, HINTS[0]), "at its until: gone")
	// A held clock has no hours: the window is not asked.
	w.clock_held = "boat"
	set_flag(&w, "boat", true)
	testing.expect(t, hint_possible(&w, HINTS[0]), "a held clock ignores the window")
}

@(test)
the_other_branch_is_nobodys_hint :: proc(t: ^testing.T) {
	w := hinted_world(12 * 60)
	defer tidy(&w)
	testing.expect(t, !hint_possible(&w, HINTS[2]), "the award's only does not hold")
	set_flag(&w, "pickett_dead", true)
	testing.expect(t, hint_possible(&w, HINTS[2]), "now it does")
}

@(test)
the_answer_says_what_to_type :: proc(t: ^testing.T) {
	testing.expect_value(t, hint_text(HINTS[1], 1), "a")
	testing.expect_value(t, hint_text(HINTS[1], 2), "b")
	testing.expect_value(t, hint_text(HINTS[1], 3), "c\nType: LOOK AT BOOK, then READ IT.")
}

@(test)
asking_changes_nothing :: proc(t: ^testing.T) {
	w := hinted_world(23 * 60 + 30)
	defer tidy(&w)
	before := flags_text(&w)
	_ = first_hint(&w)
	_, _ = points_open(&w)
	testing.expect_value(t, flags_text(&w), before)
	testing.expect_value(t, clock_minute(&w), 23 * 60 + 30)
	testing.expect_value(t, score(&w), 0)
}

@(test)
what_is_still_out_there :: proc(t: ^testing.T) {
	w := hinted_world(23 * 60 + 30)
	defer tidy(&w)
	// The field book and the boiler; not the other branch's flap, and not the
	// award worth nothing.
	pts, n := points_open(&w)
	testing.expect_value(t, pts, 30)
	testing.expect_value(t, n, 2)
	w.clock_start = 25 * 60 // the boiler's hour gone
	pts, n = points_open(&w)
	testing.expect_value(t, pts, 10)
	testing.expect_value(t, n, 1)
}

@(test)
coverage_names_what_has_no_hint :: proc(t: ^testing.T) {
	w := hinted_world(12 * 60)
	defer tidy(&w)
	report := hint_coverage(&w)
	testing.expect(t, strings.contains(report, "3 awards with points, 3 with a hint"), report)
	testing.expect(t, strings.has_suffix(report, "coverage ok"), report)
	lone := [?]Hint{{award = "nobody", nudge = "a", clearer = "b", answer = "c"}}
	w.hints = lone[:]
	report = hint_coverage(&w)
	testing.expect(t, strings.contains(report, "no hint: field_book boiler_log the_flap"), report)
	testing.expect(t, strings.contains(report, "names no award: nobody"), report)
	testing.expect(t, strings.contains(report, "nothing to type"), report)
}

@(test)
what_will_not_wait_comes_first :: proc(t: ^testing.T) {
	// The field book is first in the table and will be there all night; the
	// boiler goes at one. The boiler is the hint.
	table := [?]Hint {
		{award = "field_book", nudge = "a", clearer = "b", answer = "c", does = "x"},
		{award = "boiler_log", nudge = "a", clearer = "b", answer = "c", does = "y"},
	}
	w := hinted_world(23 * 60 + 30)
	defer tidy(&w)
	w.hints = table[:]
	testing.expect_value(t, first_hint(&w), 1)
	w.clock_start = 25 * 60 // the boiler's hour gone
	testing.expect_value(t, first_hint(&w), 0)
}
