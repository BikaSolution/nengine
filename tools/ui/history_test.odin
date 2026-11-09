package ui

import "core:testing"

@(test)
undo_walks_back_and_redo_walks_forward :: proc(t: ^testing.T) {
	h: History
	defer history_destroy(&h)

	// Three edits: "a" becomes "b" becomes "c". Mark before each change.
	history_mark(&h, "a")
	history_mark(&h, "b")

	step, ok := history_undo(&h, "c")
	testing.expect(t, ok)
	testing.expect_value(t, step, "b")
	history_done(step)

	step, ok = history_undo(&h, "b")
	testing.expect(t, ok)
	testing.expect_value(t, step, "a")
	history_done(step)

	_, ok = history_undo(&h, "a")
	testing.expect(t, !ok, "nothing further back")

	step, ok = history_redo(&h, "a")
	testing.expect(t, ok)
	testing.expect_value(t, step, "b")
	history_done(step)
}

@(test)
a_new_edit_throws_away_the_redos :: proc(t: ^testing.T) {
	h: History
	defer history_destroy(&h)

	history_mark(&h, "a")
	step, _ := history_undo(&h, "b")
	history_done(step)
	testing.expect_value(t, len(h.redo), 1)

	// Editing after undoing abandons the branch you undid, as it must.
	history_mark(&h, "a")
	testing.expect_value(t, len(h.redo), 0)
}

@(test)
the_history_does_not_grow_forever :: proc(t: ^testing.T) {
	h: History
	defer history_destroy(&h)
	for _ in 0 ..< STEPS * 2 do history_mark(&h, "x")
	testing.expect_value(t, len(h.undo), STEPS)
}
