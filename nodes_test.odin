package nengine

import "core:strings"
import "core:testing"

@(private = "file")
SCRIPT :: `# Act II

Some commentary the writers left, which is not a node.

## 16:00 — the gate

### A2.GT.SPEECH · Moore states the impossibility
> when: act2 16:00  needs: —  gives: F1  once  [the case hangs on this]
MOORE: Before anyone unpacks. Two *gates*. One **key**.
(He shows it. He does not hand it over.)
ADA: (writing) Two gates, one key.
BRAND: Not on my aeroplane.
[sets: heard_the_fence, one_key]
[A note for the builder, not shown.]

| a table | that is not lines |
| --- | --- |

### A2N.TEL.CHOICE · The telephone
> when: 22:45  needs: —  gives: —  tick
ADA: (cranking) Nothing.
>> Tell Mr Moore
    MOORE: Dead?
    [sets: told_moore_telephone. Elena's trust now needs all three.]
>> Say nothing
    ADA: Not mine to report.

---

More commentary.
`

@(test)
nodes_read_lines_speakers_and_headers :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	moore := Speaker{name = "Moore"}
	ada := Speaker{name = "Ada"}
	speakers := [?]^Speaker{&moore, &ada}
	w.speakers = speakers[:]
	testing.expect_value(t, parse_nodes(&w, SCRIPT), 2)

	n, ok := node(&w, "A2.GT.SPEECH")
	testing.expect(t, ok)
	testing.expect_value(t, n.title, "Moore states the impossibility")
	testing.expect_value(t, n.when_, "act2 16:00")
	testing.expect_value(t, n.gives, "F1")
	testing.expect_value(t, n.needs, "")
	testing.expect(t, n.once)
	testing.expect_value(t, len(n.lines), 4)
	testing.expect(t, n.lines[0].who == &moore)
	testing.expect_value(t, n.lines[0].text, "Before anyone unpacks. Two gates. One key.")
	testing.expect(t, n.lines[1].who == nil) // a stage direction
	testing.expect_value(t, n.lines[2].text, "(writing) Two gates, one key.")
	testing.expect_value(t, n.lines[3].text, "Brand: Not on my aeroplane.") // nobody declared him
	testing.expect_value(t, len(n.sets), 2)
	testing.expect_value(t, n.sets[1], "one_key")

	c, _ := node(&w, "A2N.TEL.CHOICE")
	testing.expect(t, c.tick)
	testing.expect_value(t, len(c.lines), 1)
	testing.expect_value(t, len(c.choices), 2)
	testing.expect_value(t, c.choices[0].label, "Tell Mr Moore")
	testing.expect_value(t, c.choices[0].sets[0], "told_moore_telephone")
	testing.expect_value(t, c.choices[1].lines[0].text, "Not mine to report.")
}

@(test)
playing_a_node_sets_its_flags_at_the_end :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	append(&w.scenes, Scene{})
	parse_nodes(&w, SCRIPT)
	testing.expect(t, play_node(&w, "A2.GT.SPEECH"))
	testing.expect(t, talking(&w))
	testing.expect(t, node_said(&w, "A2.GT.SPEECH"))
	testing.expect(t, !flag(&w, "one_key"), "not until it has been read")
	for talking(&w) do advance_conversation(&w)
	testing.expect(t, flag(&w, "one_key"))
	testing.expect(t, flag(&w, "heard_the_fence"))
	testing.expect(t, !play_node(&w, "NO.SUCH.NODE"))

	testing.expect(t, node_choose(&w, "A2N.TEL.CHOICE", 0))
	for talking(&w) do advance_conversation(&w)
	testing.expect(t, flag(&w, "told_moore_telephone"))
}

@(private = "file")
TELLINGS :: `### ASK.ELENA.HERSELF · Herself
> when: any  once
[closed] ELENA: I am the office.
[open] ELENA: Elena Vale. Nine years.

### EV.B1.OTHERS
> gives: —
— PICKETT: *May.* · LUCY: *When Norm's leave came through.*
— PERCY: I don't book, escort. I'm booked.

### SOT.PATH · The night
— **Early (to 00:30):** PERCY: Ask me in the morning.
— **Middle:** PERCY: The old girl. With her handbag.
— Act II: someone walking the fence line, all night.

### INTRO.CLOSE · Somebody has to go
[close-up, talk] HARGREAVE: Mr Pyke is in the Infirmary.
`

@(test)
nodes_keep_their_tellings :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	append(&w.scenes, Scene{})
	elena := Speaker{name = "Elena"}
	percy := Speaker{name = "Percy"}
	pickett := Speaker{name = "Pickett"}
	hargreave := Speaker{name = "Mrs Hargreave"}
	speakers := [?]^Speaker{&elena, &percy, &pickett, &hargreave}
	w.speakers = speakers[:]
	testing.expect_value(t, parse_nodes(&w, TELLINGS), 4)

	play_node(&w, "ASK.ELENA.HERSELF", tag = "open")
	testing.expect_value(t, len(w.talk.lines), 1)
	testing.expect_value(t, w.talk.lines[0].text, "Elena Vale. Nine years.")
	for talking(&w) do advance_conversation(&w)

	others := node_lines_of(&w, "EV.B1.OTHERS", "pickett")
	testing.expect_value(t, len(others), 1)
	testing.expect_value(t, others[0].text, "May.")
	n, _ := node(&w, "EV.B1.OTHERS")
	testing.expect_value(t, len(n.lines), 3) // two on one line, split at the dot

	tags := node_tags(&w, "SOT.PATH")
	testing.expect_value(t, len(tags), 3)
	testing.expect_value(t, tags[0], "early")
	testing.expect_value(t, tags[2], "act ii")
	play_node(&w, "SOT.PATH", tag = "middle")
	testing.expect_value(t, w.talk.lines[0].text, "The old girl. With her handbag.")
	for talking(&w) do advance_conversation(&w)

	intro, _ := node(&w, "INTRO.CLOSE")
	testing.expect_value(t, intro.tags[0], "") // a close-up is framing, not a telling
	testing.expect(t, intro.lines[0].who == &hargreave)
}

// Lines after the branches, not indented under any, are said whichever
// branch is taken ("either way"): node_choose plays them after its own.
@(private = "file")
EITHER_WAY :: `### A5.MM.TEST · Either way
MARGARET: Have you told anyone?
>> Tell her
    ADA: Everything.
>> Say nothing
    ADA: I'm tired.
MARGARET: Sleep for an hour.
ADA: There's my hut.
`

@(test)
lines_after_the_branches_follow_either_branch :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	append(&w.scenes, Scene{})
	mm := Speaker{name = "Margaret"}
	ada := Speaker{name = "Ada"}
	speakers := [?]^Speaker{&mm, &ada}
	w.speakers = speakers[:]
	testing.expect_value(t, parse_nodes(&w, EITHER_WAY), 1)
	n, _ := node(&w, "A5.MM.TEST")
	testing.expect_value(t, len(n.lines), 1)
	testing.expect_value(t, len(n.after), 2)
	testing.expect_value(t, n.after[0].text, "Sleep for an hour.")
	testing.expect(t, node_choose(&w, "A5.MM.TEST", 1))
	said := make([dynamic]string, context.temp_allocator)
	for talking(&w) {
		append(&said, w.node_talk.lines[w.node_talk.at].text)
		advance_conversation(&w)
	}
	testing.expect_value(t, len(said), 3)
	testing.expect_value(t, said[0], "I'm tired.")
	testing.expect_value(t, said[2], "There's my hut.")
}

// A list of barks: each tagged by when, said one at a time, round and round,
// as timed messages; a line that does not fit now is passed over.
@(private = "file")
BARKS :: `### BARK.FIRE · The fire
> lights: day, night
- day: OTTO: (dragging a chair) Twelve chairs.
- night: LUCY: Has anybody seen Mr Hawkes?
- night: ADA: (the ash) Nobody.
- night: WALTER: Somebody said keep it in.
- night, dinner (on a loop, three deep, and a note longer than a label): EDMUND: "— the bill —" · PERCY: "— the second barrel —"
- night, before 02:30, Moore away from the post: ADA: Scales.
`

@(private = "file")
bark_at_night :: proc(w: ^World, tag: string, line: Talk_Line) -> bool {
	return tag == "night" && (line.who == nil || line.who.name != "Walter")
}

@(test)
barks_go_round_the_lines_that_fit :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	append(&w.scenes, Scene{})
	otto := Speaker{name = "Otto"}
	lucy := Speaker{name = "Lucy"}
	ada := Speaker{name = "Ada"}
	walter := Speaker{name = "Walter"}
	edmund := Speaker{name = "Edmund"}
	percy := Speaker{name = "Percy"}
	speakers := [?]^Speaker{&otto, &lucy, &ada, &walter, &edmund, &percy}
	w.speakers = speakers[:]
	testing.expect_value(t, parse_nodes(&w, BARKS), 1)

	testing.expect(t, bark(&w, "BARK.FIRE", bark_at_night))
	testing.expect_value(t, message(&w), "Has anybody seen Mr Hawkes?")
	testing.expect(t, w.message_who == &lucy)
	testing.expect(t, !talking(&w)) // a timed message, not a conversation
	testing.expect(t, bark(&w, "BARK.FIRE", bark_at_night))
	testing.expect_value(t, message(&w), "(the ash) Nobody.")
	testing.expect(t, bark(&w, "BARK.FIRE", bark_at_night)) // Walter is passed over; round again
	testing.expect_value(t, message(&w), "Has anybody seen Mr Hawkes?")
	l, ok := next_bark(&w, "BARK.FIRE") // with no test, every line in turn
	testing.expect(t, ok)
	testing.expect(t, l.who == &ada)
	testing.expect(t, !bark(&w, "BARK.FIRE", proc(w: ^World, tag: string, line: Talk_Line) -> bool {return false}))
	testing.expect(t, !bark(&w, "BARK.NONE", bark_at_night))
	testing.expect_value(t, w.clock_ticks, 0) // and it costs nothing
	// A label with a note in brackets, and a long one: still labels.
	n, _ := node(&w, "BARK.FIRE")
	testing.expect_value(t, len(n.lines), 7)
	testing.expect_value(t, n.tags[4], "night, dinner")
	testing.expect_value(t, n.tags[5], "night, dinner")
	testing.expect_value(t, n.lines[5].text, "\"— the second barrel —\"")
	testing.expect_value(t, n.tags[6], "night, before 02:30, moore away from the post")
}

// A bold name with a long condition after it is still the bullet's label
// (A5.MM.COMPANY's three).
@(private = "file")
LONG_LABELS :: `### A5.MM.STAY · Asking somebody to stay
— **Elena**, if earned: ADA: Would you sit with me.
— **Lucy**, if Ada went out to Billy at one and Lucy has been with her since: LUCY: I'm not going back to that net.
`

@(test)
a_long_condition_after_a_bold_name_keeps_the_label :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	append(&w.scenes, Scene{})
	ada := Speaker{name = "Ada"}
	lucy := Speaker{name = "Lucy"}
	speakers := [?]^Speaker{&ada, &lucy}
	w.speakers = speakers[:]
	testing.expect_value(t, parse_nodes(&w, LONG_LABELS), 1)
	n, _ := node(&w, "A5.MM.STAY")
	testing.expect_value(t, len(n.lines), 2)
	testing.expect(t, strings.has_prefix(n.tags[0], "elena"))
	testing.expect(t, strings.has_prefix(n.tags[1], "lucy"))
	testing.expect(t, n.lines[1].who == &lucy)
}

// A node a cutscene said: node_done leaves the world as play_node would have,
// without a word said.
@(private = "file")
DONE_NODE :: `### A2.CUT.TEST · Said by a cut
> when: 16:00  needs: —  gives: —  once
MOORE: Signed for.
[sets: cut_seen]
`

@(test)
node_done_does_what_playing_does_but_say_it :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	append(&w.scenes, Scene{})
	moore := Speaker{name = "Moore"}
	speakers := [?]^Speaker{&moore}
	w.speakers = speakers[:]
	testing.expect_value(t, parse_nodes(&w, DONE_NODE), 1)
	testing.expect(t, node_done(&w, "A2.CUT.TEST"))
	testing.expect(t, node_said(&w, "A2.CUT.TEST"))
	testing.expect(t, flag(&w, "cut_seen"))
	testing.expect(t, !talking(&w))
	testing.expect(t, !node_done(&w, "NO.SUCH.NODE"))
}
