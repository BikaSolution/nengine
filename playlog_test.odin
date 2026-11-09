package nengine

import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
LOG_TALK :: `ask moore fence
moore: That's the fence, miss.
(He does not put the rifle down.)

ask moore *
moore: (a look) No.
`

@(private = "file")
LOG_WORDS := [?]Word{
	{.Noun, "door", ""},
	{.Noun, "moore", ""},
	{.Noun, "fence", ""},
	{.Noun, "weather", ""},
}

// The rows of a log, each split into its seven fields.
@(private = "file")
log_rows :: proc(t: ^testing.T, path: string) -> (header: string, rows: [][]string) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil)
	lines := strings.split_lines(strings.trim_right(string(data), "\n"), context.temp_allocator)
	out := make([dynamic][]string, context.temp_allocator)
	for line, i in lines {
		if i == 0 {
			header = line
			continue
		}
		fields := strings.split(line, "\t", context.temp_allocator)
		testing.expect_value(t, len(fields), 7)
		append(&out, fields)
	}
	return header, out[:]
}

@(test)
the_play_log_writes_a_row_for_every_command :: proc(t: ^testing.T) {
	talk := test_tmp("nengine-playlog-test.talk")
	path := test_tmp("nengine-playlog-test.tsv")
	testing.expect(t, os.write_entire_file(talk, transmute([]u8)string(LOG_TALK)) == nil)
	defer os.remove(talk)
	defer os.remove(path)

	w := World{clock_start = 16 * 60, clock_step = 5}
	defer destroy_world(&w)
	@(static) floor := [4][2]f32{{0, 0}, {400, 0}, {400, 300}, {0, 300}}
	door := Object{name = "door", description = "A door.", pos = {300, 60}}
	append(&door.on, Interaction{verb = "open", text = "It opens onto the yard."})
	defer delete(door.on)
	deck := Scene{name = "deck", walk_area = floor[:]}
	append(&deck.objects, door)
	append(&deck.objects, Object{name = "moore", pos = {100, 100}})
	append(&w.scenes, deck)
	w.vocab = vocab_join(LOG_WORDS[:], context.temp_allocator)
	w.player = {pos = {200, 150}, speed = 120}
	moore := Speaker{name = "Moore"}
	speakers := [?]^Speaker{&moore}
	w.speakers = speakers[:]
	_, ok := load_talk(&w, talk)
	testing.expect(t, ok)
	w.on_status = proc(w: ^World) -> string {return "act2; carrying shoe"}
	// The game: ASK by the talk files, and a fallback it marks itself.
	w.on_command = proc(w: ^World, cmd: Command) {
		switch cmd.verb {
		case "ask":
			if !answer(w, cmd.noun, cmd.noun2) do say(w, "Nothing about that.")
		case:
			log_gap(w, "no-verb")
			say(w, "I'm a booking clerk, not a magician.")
		}
	}

	testing.expect(t, log_open(&w, path))
	run_script(&w, "open door; frobnicate; ask moore about fence; ask moore about weather; push door; look at door; !tick 2")
	log_close(&w)

	header, rows := log_rows(t, path)
	testing.expect_value(t, header, "time\troom\tstatus\tinput\troute\tgap\tresponse")
	testing.expect_value(t, len(rows), 7)
	if len(rows) < 7 do return

	// An object's own verb, on purpose.
	r := rows[0]
	testing.expect_value(t, r[0], "16:00")
	testing.expect_value(t, r[1], "deck (200,150)") // the room, and where she stood
	testing.expect_value(t, r[2], "act2; carrying shoe")
	testing.expect_value(t, r[3], "open door")
	testing.expect_value(t, r[4], "object:door.open")
	testing.expect_value(t, r[5], "")
	testing.expect_value(t, r[6], "It opens onto the yard.")

	// A word nobody knows: the engine's gap.
	r = rows[1]
	testing.expect_value(t, r[4], "parse:unknown frobnicate")
	testing.expect_value(t, r[5], "unknown-word")
	testing.expect_value(t, r[6], "I don't know the word \"frobnicate\".")

	// A conversation: every line, by its speaker, and the stage direction.
	r = rows[2]
	testing.expect_value(t, r[4], "game")
	testing.expect_value(t, r[5], "")
	testing.expect_value(t, r[6], "Moore: That's the fence, miss. / (He does not put the rifle down.)")

	// Answered by the person's catch-all: a shrug, which is a gap.
	r = rows[3]
	testing.expect_value(t, r[5], "talk-shrug")
	testing.expect_value(t, r[6], "Moore: (a look) No.")

	// The game's own fallback, marked by the game.
	r = rows[4]
	testing.expect_value(t, r[3], "push door")
	testing.expect_value(t, r[4], "game")
	testing.expect_value(t, r[5], "no-verb")
	testing.expect_value(t, r[6], "I'm a booking clerk, not a magician.")

	// LOOK with nothing written for it: the description.
	r = rows[5]
	testing.expect_value(t, r[4], "object:door.look")
	testing.expect_value(t, r[6], "A door.")

	// A harness line has a row of its own, and the clock moved.
	r = rows[6]
	testing.expect_value(t, r[3], "!tick 2")
	testing.expect_value(t, r[4], "harness")
	testing.expect_value(t, r[0], "16:00") // as it was typed
}

@(test)
the_play_log_gives_the_story_its_own_rows :: proc(t: ^testing.T) {
	path := test_tmp("nengine-playlog-story-test.tsv")
	defer os.remove(path)

	w: World
	defer destroy_world(&w)
	append(&w.scenes, Scene{name = "banda"})
	w.vocab = vocab_join(nil, context.temp_allocator)
	testing.expect(t, log_open(&w, path))

	// A timer that says something, with nobody typing: (timer), story.
	after(&w, "bark", 2, proc(w: ^World) {say(w, "A hyena, somewhere past the wire.")})
	w.time = 3
	run_timers(&w)
	log_settle(&w)
	// A line said twice running is one; a command that says nothing is silent.
	w.on_command = proc(w: ^World, cmd: Command) {}
	run_command(&w, "wait")
	log_end(&w)
	log_close(&w)

	_, rows := log_rows(t, path)
	testing.expect_value(t, len(rows), 2)
	if len(rows) < 2 do return
	testing.expect_value(t, rows[0][0], "+0:03") // no story clock: the play clock
	testing.expect_value(t, rows[0][1], "banda (0,0)")
	testing.expect_value(t, rows[0][3], "(timer)")
	testing.expect_value(t, rows[0][4], "story")
	testing.expect_value(t, rows[0][6], "A hyena, somewhere past the wire.")
	testing.expect_value(t, rows[1][3], "wait")
	testing.expect_value(t, rows[1][5], "silent")
}

@(test)
log_is_a_launch_flag :: proc(t: ^testing.T) {
	l := launch_flags({"--skip", "--log", "play.log"})
	testing.expect_value(t, l.log, "play.log")
	testing.expect(t, l.skip)
}
