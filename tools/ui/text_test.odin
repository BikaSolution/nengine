package ui

import "core:testing"

// Editing a field's buffer, without a window: the caret, the selection, words
// and the characters that cannot go in.

@(private = "file")
field_with :: proc(s: string) -> Text_Input {
	t: Text_Input
	text_input_focus(&t, "f", s)
	return t
}

@(test)
focus_selects_everything_so_typing_replaces_it :: proc(t: ^testing.T) {
	f := field_with("lamp")
	defer text_input_destroy(&f)
	testing.expect_value(t, text_selected(&f), "lamp")
	text_insert(&f, "chest")
	testing.expect_value(t, text_input_value(&f), "chest")
	testing.expect_value(t, f.caret, 5)
	testing.expect(t, !text_has_selection(&f))
}

@(test)
typing_goes_in_at_the_caret :: proc(t: ^testing.T) {
	f := field_with("a lamp")
	defer text_input_destroy(&f)
	text_move(&f, 2, false)
	text_insert(&f, "brass ")
	testing.expect_value(t, text_input_value(&f), "a brass lamp")
	text_backspace(&f)
	text_backspace(&f, word = true)
	testing.expect_value(t, text_input_value(&f), "a lamp")
	text_move(&f, 0, false)
	text_delete_forward(&f, word = true)
	testing.expect_value(t, text_input_value(&f), " lamp")
}

@(test)
a_selection_is_replaced_and_deleted_whole :: proc(t: ^testing.T) {
	f := field_with("the brass lamp")
	defer text_input_destroy(&f)
	text_move(&f, 4, false)
	text_move(&f, 9, true) // shift-drag over "brass"
	testing.expect_value(t, text_selected(&f), "brass")
	text_insert(&f, "tin")
	testing.expect_value(t, text_input_value(&f), "the tin lamp")
	text_move(&f, 0, false)
	text_move(&f, 4, true)
	text_backspace(&f)
	testing.expect_value(t, text_input_value(&f), "tin lamp")
}

@(test)
a_paste_stays_on_one_line :: proc(t: ^testing.T) {
	f := field_with("")
	defer text_input_destroy(&f)
	text_insert(&f, "one\r\ntwo\nthree\tfour")
	testing.expect_value(t, text_input_value(&f), "one two three four")
}

@(test)
the_caret_steps_over_a_whole_character :: proc(t: ^testing.T) {
	// An em dash typed into a file by hand is three bytes; the caret never
	// lands inside it and Backspace takes it all.
	f := field_with("a—b")
	defer text_input_destroy(&f)
	testing.expect_value(t, len(f.buf), 5)
	text_move(&f, 4, false) // before "b"
	text_backspace(&f)
	testing.expect_value(t, text_input_value(&f), "ab")
	testing.expect_value(t, prev_char(transmute([]u8)string("a—b"), 4), 1)
	testing.expect_value(t, next_char(transmute([]u8)string("a—b"), 1), 4)
}

@(test)
words_are_runs_between_spaces :: proc(t: ^testing.T) {
	b := transmute([]u8)string("on chest  look")
	testing.expect_value(t, prev_word(b, len(b)), 10)
	testing.expect_value(t, prev_word(b, 10), 3)
	testing.expect_value(t, next_word(b, 0), 2)
	testing.expect_value(t, next_word(b, 8), 14)
}

@(test)
rows_break_at_spaces_and_the_caret_finds_its_row :: proc(t: ^testing.T) {
	rows := []Text_Row{{0, 3}, {4, 7}}
	testing.expect_value(t, row_of(rows, 0), 0)
	testing.expect_value(t, row_of(rows, 3), 0) // the end of a row, before its space
	testing.expect_value(t, row_of(rows, 4), 1)
	testing.expect_value(t, row_of(rows, 7), 1)
}
