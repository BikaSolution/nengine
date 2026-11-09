package nengine

import "core:testing"

// The format has to survive a trip through the editor, which saves what it
// loaded. Anything that doesn't round-trip is a line of somebody's cutscene
// quietly going missing.

@(test)
a_cutscene_survives_being_written_and_read :: proc(t: ^testing.T) {
	text := `# a scene
cut arrival scene=veranda
cast ada  char=ada  at=240,470 facing=right
cast heir char=heir at=700,470 facing=left

0.0  ada   walk_to 420,470
1.6  heir  face left
2.0  heir  say You're the agency girl.
3.4  ada   think He knows my name.
5.0  camera shake 0.40
5.5  narrate The lamps had not been lit.
5.8  sound gate
7.0  end
`
	c, ok := parse_cutscene(text)
	testing.expect(t, ok)
	defer cutscene_destroy(&c)

	testing.expect_value(t, c.name, "arrival")
	testing.expect_value(t, c.scene, "veranda")
	testing.expect_value(t, len(c.people), 2)
	testing.expect_value(t, c.people[1].name, "heir")
	testing.expect_value(t, c.people[1].facing, Facing.Left)
	testing.expect_value(t, c.people[0].at.x, f32(240))

	testing.expect_value(t, len(c.cues), 8)
	testing.expect_value(t, c.cues[0].action, Cue_Action.Walk_To)
	testing.expect_value(t, c.cues[0].to.x, f32(420))
	// Free text runs to the end of the line, apostrophes and all.
	testing.expect_value(t, c.cues[2].text, "You're the agency girl.")
	testing.expect_value(t, c.cues[4].action, Cue_Action.Shake)
	testing.expect_value(t, c.cues[5].text, "The lamps had not been lit.")
	testing.expect_value(t, c.cues[6].action, Cue_Action.Sound)
	testing.expect_value(t, c.cues[6].text, "gate")
	testing.expect_value(t, c.cues[7].action, Cue_Action.End)
	testing.expect_value(t, cutscene_length(&c), f32(7))

	// Written out and read back, it is the same cutscene.
	again, good := parse_cutscene(cutscene_text(&c))
	testing.expect(t, good)
	defer cutscene_destroy(&again)
	testing.expect_value(t, again.name, c.name)
	testing.expect_value(t, again.scene, c.scene)
	testing.expect_value(t, len(again.people), len(c.people))
	testing.expect_value(t, len(again.cues), len(c.cues))
	for q, i in again.cues {
		testing.expect_value(t, q.at, c.cues[i].at)
		testing.expect_value(t, q.action, c.cues[i].action)
		testing.expect_value(t, q.who, c.cues[i].who)
		testing.expect_value(t, q.text, c.cues[i].text)
	}
}

@(test)
cues_are_kept_in_time_order :: proc(t: ^testing.T) {
	// Written out of order, on purpose: the editor drags cues about and the
	// player walks the list forwards, so the list has to be sorted.
	c, ok := parse_cutscene(`cut x
5.0 end
1.0 narrate second
0.5 narrate first
`)
	testing.expect(t, ok)
	defer cutscene_destroy(&c)
	testing.expect_value(t, len(c.cues), 3)
	testing.expect_value(t, c.cues[0].text, "first")
	testing.expect_value(t, c.cues[1].text, "second")
	testing.expect_value(t, c.cues[2].action, Cue_Action.End)
}

@(test)
a_line_that_is_not_a_cue_is_skipped_not_guessed_at :: proc(t: ^testing.T) {
	// A typo should cost you that line, not the file.
	c, ok := parse_cutscene(`cut x
0.5 ada waltz_to 10,10
1.0 narrate this one is fine
what even is this
`)
	testing.expect(t, ok)
	defer cutscene_destroy(&c)
	testing.expect_value(t, len(c.cues), 1)
	testing.expect_value(t, c.cues[0].text, "this one is fine")
}

@(test)
length_without_an_end_leaves_room_to_finish :: proc(t: ^testing.T) {
	c, ok := parse_cutscene("cut x\n3.0 narrate a line\n")
	testing.expect(t, ok)
	defer cutscene_destroy(&c)
	// No `end`, so the last cue plus a breath rather than cutting off on it.
	testing.expect_value(t, cutscene_length(&c), f32(5))
}

// Each line on its own: what an editor that keeps a file's own lines writes
// for the one line it changed. Every kind of cue, and a cast member with and
// without its place and facing, reads back as itself.
@(test)
one_line_at_a_time_reads_back_as_itself :: proc(t: ^testing.T) {
	text := `cut x
cast ada
cast moore char=moore at=-50,445 facing=right
0.00 ada walk_to 480,470
2.20 moore face left
2.40 moore play rifle_idle 42.00
2.50 moore play wave once
2.60 moore play wave 3x
3.00 moore say You're late.
3.10 ada think He knows.
4.00 narrate The lamps were out.
5.00 line A2.GT.FENCE 3-5 tag=percy
5.10 line A2.GT.FENCE 2
6.00 camera shake 0.40
6.50 sound chest_lid
8.00 end
`
	c, ok := parse_cutscene(text)
	testing.expect(t, ok)
	defer cutscene_destroy(&c)
	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, "cut x")
	for m in c.people do append(&lines, cast_text(m))
	for q in c.cues do append(&lines, cue_text(q))
	want := []string{
		"cut x", "cast ada", "cast moore char=moore at=-50,445 facing=right",
		"0.00 ada walk_to 480,470", "2.20 moore face left", "2.40 moore play rifle_idle 42.00",
		"2.50 moore play wave once", "2.60 moore play wave 3x", "3.00 moore say You're late.",
		"3.10 ada think He knows.", "4.00 narrate The lamps were out.",
		"5.00 line A2.GT.FENCE 3-5 tag=percy", "5.10 line A2.GT.FENCE 2",
		"6.00 camera shake 0.40", "6.50 sound chest_lid", "8.00 end",
	}
	testing.expect_value(t, len(lines), len(want))
	for w, i in want do if i < len(lines) do testing.expect_value(t, lines[i], w)
	testing.expect_value(t, cue_body_text(c.cues[0]), "ada walk_to 480,470")
	testing.expect(t, c.people[0].keep_place && c.people[0].keep_facing)
}
