package nengine

import "core:testing"

@(private = "file")
boss := Speaker{name = "Mrs P", portrait = {texture = {id = 1}, frame_w = 10, frame_h = 10, frames = 1}}
@(private = "file")
two_shot := Sprite{texture = {id = 1}, frame_w = 1024, frame_h = 640, frames = 3}

@(private = "file")
CLOSE := [?]Talk_Line {
	{who = &boss, text = "A word."},
	{who = &boss, text = "Don't break it.", shot = &two_shot, frame = 2},
}

@(private = "file")
ended, skipped: int

@(test)
a_close_up_is_up_only_while_its_line_is :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	c: Conversation
	begin_conversation(&w, &c, CLOSE[:])

	_, _, up := conversation_shot(&w)
	testing.expect(t, !up) // the room, with her portrait by the box
	testing.expect(t, w.message_who == &boss)

	advance_conversation(&w)
	shot, frame, ok := conversation_shot(&w)
	testing.expect(t, ok)
	testing.expect(t, shot == &two_shot)
	testing.expect_value(t, frame, 2)
	// Her face is the picture, so the box names her instead.
	testing.expect(t, w.message_who == nil)
	testing.expect_value(t, message(&w), "Mrs P: Don't break it.")

	advance_conversation(&w)
	_, _, up = conversation_shot(&w)
	testing.expect(t, !up) // over: the room again
}

@(test)
skipping_runs_on_skip_and_not_on_end :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	c: Conversation
	ended, skipped = 0, 0
	on_end := proc(w: ^World) {ended += 1}
	on_skip := proc(w: ^World) {skipped += 1}

	begin_conversation(&w, &c, CLOSE[:], on_end, on_skip)
	skip_conversation(&w)
	testing.expect(t, !talking(&w))
	testing.expect_value(t, skipped, 1)
	testing.expect_value(t, ended, 0)

	// Read to the end, it ends.
	begin_conversation(&w, &c, CLOSE[:], on_end, on_skip)
	advance_conversation(&w)
	advance_conversation(&w)
	testing.expect_value(t, ended, 1)

	// Without an on_skip, skipping is ending, as it always was.
	begin_conversation(&w, &c, CLOSE[:], on_end)
	skip_conversation(&w)
	testing.expect_value(t, ended, 2)
}

@(private = "file")
CARD := [?]Talk_Line {
	{who = &boss, text = "A word."},
	{text = "Mora, four days later.", card = true},
}

@(test)
a_card_is_its_words_alone_and_fades_in :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	c: Conversation
	begin_conversation(&w, &c, CARD[:])

	_, _, up := conversation_card(&w)
	testing.expect(t, !up) // a line in the box

	advance_conversation(&w)
	text, alpha, ok := conversation_card(&w)
	testing.expect(t, ok)
	testing.expect_value(t, text, "Mora, four days later.")
	testing.expect_value(t, alpha, f32(0))
	// Not in the box: the box would say it twice, over the card.
	testing.expect_value(t, message(&w), "")
	testing.expect(t, w.message_who == nil)

	w.time += CARD_FADE
	_, alpha, _ = conversation_card(&w)
	testing.expect_value(t, alpha, f32(1))
	// It waits for the reader like any line.
	testing.expect(t, talking(&w))
	advance_conversation(&w)
	testing.expect(t, !talking(&w))
}
