package nengine

import "core:testing"

// The text box wraps to a pixel width, which needs a font, which needs a
// window — so the wrapping itself is tested through wrap_text, which counts
// characters instead and is the same walk over the same words.

@(test)
a_line_break_the_caller_asked_for_is_kept :: proc(t: ^testing.T) {
	lines := wrap_text("Two glasses.\nOne full, lipstick.\nOne empty, flies in it.", 40)
	testing.expect_value(t, len(lines), 3)
	testing.expect_value(t, lines[0], "Two glasses.")
	testing.expect_value(t, lines[2], "One empty, flies in it.")
}

@(test)
a_long_line_still_wraps_inside_its_own_break :: proc(t: ^testing.T) {
	lines := wrap_text("PEOPLE\nMarchmont, M. Question eleven: no, never.", 20)
	testing.expect_value(t, lines[0], "PEOPLE")
	testing.expect(t, len(lines) >= 3, "the long entry should have wrapped")
	for l in lines do testing.expect(t, len(l) <= 20, "a line came out wider than asked for")
}

@(test)
a_blank_line_survives :: proc(t: ^testing.T) {
	lines := wrap_text("TIMES\n\n21:40 - R. R-R at the fire.", 40)
	testing.expect_value(t, len(lines), 3)
	testing.expect_value(t, lines[1], "")
}

@(test)
typographic_punctuation_becomes_what_the_font_has :: proc(t: ^testing.T) {
	testing.expect_value(t, plain_text("Faces. Give me — (beat) No."), "Faces. Give me -- (beat) No.")
	testing.expect_value(t, plain_text("“It’s now…”"), `"It's now..."`)
	testing.expect_value(t, plain_text("plain"), "plain")
}

@(test)
a_beat_in_a_box_is_a_line_break_not_words :: proc(t: ^testing.T) {
	// A one-box line as a scene writes it: the beat is the writers', and the
	// box breaks the line there instead of printing it.
	lines := wrap_text("Fence. And more fence behind it. (beat) Nothing to see.", 60)
	testing.expect_value(t, len(lines), 2)
	testing.expect_value(t, lines[0], "Fence. And more fence behind it.")
	testing.expect_value(t, lines[1], "Nothing to see.")
	testing.expect_value(t, beats_as_breaks("(beat) Since the rains. (a beat) Clean. (beat)"), "Since the rains.\nClean.")
	testing.expect_value(t, beats_as_breaks("No beat (to the fire, a beat late) here."), "No beat (to the fire, a beat late) here.")
	testing.expect_value(t, beats_in("One. (beat) Two. (beat) Three."), 2)
}

@(test)
a_beat_holds_a_one_box_line_a_moment_longer :: proc(t: ^testing.T) {
	w: World
	say(&w, "Padlocked. One key, on his belt.")
	plain := w.message_until
	say(&w, "Padlocked. (beat) One key, on his belt.")
	// The words are kept as written; only the box breaks and waits.
	testing.expect_value(t, message(&w), "Padlocked. (beat) One key, on his belt.")
	testing.expect(t, w.message_until - plain >= BEAT_SECS - 0.01, "a beat should hold the box longer")
}
