package nengine

import "core:fmt"
import "core:os"
import "core:testing"

@(private = "file")
TALK :: `# a talk file
ask margaret herself
margaret: Sixty-six, and a widow.

ask margaret husband
margaret: Hugh.
ask margaret husband when=told_margaret_husband
margaret: He arranged things.

ask moore kink,fence when=saw_kink tick action=moore_kink
ada: The fence bends.
moore: (very long pause) Aye.
(He does not put the rifle down.)

ask moore *
moore: That's the fence, miss.
`

@(private = "file", thread_local)
acted: string

@(test)
topics_answer_in_order_and_tick_once :: proc(t: ^testing.T) {
	path := test_tmp("nengine-talk-test.talk")
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string(TALK)) == nil)
	defer os.remove(path)

	w: World
	defer destroy_world(&w)
	append(&w.scenes, Scene{})
	margaret := Speaker{name = "Margaret"}
	moore := Speaker{name = "Moore"}
	speakers := [?]^Speaker{&margaret, &moore}
	w.speakers = speakers[:]
	w.on_topic = proc(w: ^World, action: string) {acted = action}
	acted = ""

	_, ok := load_talk(&w, path)
	testing.expect(t, ok)
	testing.expect_value(t, len(w.topics), 5)

	testing.expect(t, answer(&w, "margaret", "husband"))
	testing.expect_value(t, w.talk.lines[0].text, "Hugh.")
	testing.expect(t, w.talk.lines[0].who == &margaret)
	end_conversation(&w)
	testing.expect(t, answer(&w, "margaret", "husband")) // again
	testing.expect_value(t, w.talk.lines[0].text, "He arranged things.")
	end_conversation(&w)

	// Locked until the kink is seen; the catch-all answers until then.
	testing.expect(t, answer(&w, "moore", "kink"))
	testing.expect_value(t, w.talk.lines[0].text, "That's the fence, miss.")
	end_conversation(&w)
	set_flag(&w, "saw_kink")
	testing.expect(t, answer(&w, "moore", "fence"))
	testing.expect_value(t, len(w.talk.lines), 3)
	testing.expect(t, w.talk.lines[2].who == nil)
	testing.expect_value(t, acted, "moore_kink")
	testing.expect_value(t, w.clock_ticks, 1)
	end_conversation(&w)
	answer(&w, "moore", "fence")
	testing.expect_value(t, w.clock_ticks, 1) // once
	end_conversation(&w)

	testing.expect(t, !answer(&w, "margaret", "the weather"))
	clear_flags(&w)
}

@(private = "file", thread_local)
answered: string

@(test)
the_next_command_answers_a_question :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	w.vocab = vocab_join({}, context.temp_allocator)
	append(&w.scenes, Scene{})
	w.on_answer = proc(w: ^World, q: string, cmd: Command) -> bool {
		answered = cmd.verb
		return q == "trade"
	}
	w.on_command = proc(w: ^World, cmd: Command) {answered = "fell through"}

	expect_answer(&w, "trade")
	run_command(&w, "look")
	testing.expect_value(t, answered, "look")
	run_command(&w, "look") // the question has gone
	testing.expect_value(t, answered, "fell through")
}

// --- Showing things ---

@(private = "file")
SHOWS :: `# shows
show moore shoe tick
moore: Otter had that. Two hours, I said.

show moore photograph tick
moore: Before my time.

show moore * tick
moore: (a look at it, and back at you) No.

show fairbank shoe
fairbank: I'd want to check that.
`

@(private = "file")
shows_world :: proc(t: ^testing.T, name: string) -> World {
	path := test_tmp(fmt.tprintf("nengine-show-test-%v.talk", name))
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string(SHOWS)) == nil)
	defer os.remove(path)
	w: World
	sc := Scene{name = "gate"}
	append(&sc.objects, Object{name = "moore"})
	append(&sc.objects, Object{name = "photograph", show = true})
	append(&sc.objects, Object{name = "padlock"})
	append(&w.scenes, sc)
	speakers := make([]^Speaker, 2)
	speakers[0] = new_clone(Speaker{name = "Moore"})
	speakers[1] = new_clone(Speaker{name = "Mr Fairbank"})
	w.speakers = speakers
	_, ok := load_talk(&w, path)
	testing.expect(t, ok)
	return w
}

// destroy_world frees the scenes' objects (clear_world): deleting them here
// as well was a second free of the same block.
@(private = "file")
shows_done :: proc(w: ^World) {
	speakers := w.speakers
	destroy_world(w)
	for s in speakers do free(s)
	delete(speakers)
}

@(test)
a_thing_must_be_carried_to_be_shown :: proc(t: ^testing.T) {
	w := shows_world(t, "a_thing_must_be_carried_to_be_shown")
	defer shows_done(&w)
	testing.expect_value(t, show_thing(&w, "moore", "shoe"), Answer_Kind.Not_Carried)
	set_flag(&w, "carrying_shoe")
	testing.expect_value(t, show_thing(&w, "moore", "shoe"), Answer_Kind.Answered)
	testing.expect_value(t, w.talk.lines[0].text, "Otter had that. Two hours, I said.")
	testing.expect(t, flag(&w, "told_moore_shoe"))
	end_conversation(&w)
	show_thing(&w, "moore", "shoe")
	testing.expect(t, flag(&w, "retold_moore_shoe")) // the second show
}

@(test)
an_object_here_marked_show_can_be_shown :: proc(t: ^testing.T) {
	w := shows_world(t, "an_object_here_marked_show_can_be_shown")
	defer shows_done(&w)
	testing.expect_value(t, show_thing(&w, "moore", "photograph"), Answer_Kind.Answered) // on the wall, not in her hands
	end_conversation(&w)
	testing.expect_value(t, show_thing(&w, "moore", "padlock"), Answer_Kind.Not_Carried) // here, but not a thing to hold out
}

@(test)
the_shrug_costs_nothing :: proc(t: ^testing.T) {
	w := shows_world(t, "the_shrug_costs_nothing")
	defer shows_done(&w)
	w.clock_step = 1
	set_flag(&w, "carrying_matchbook")
	before := w.clock_ticks
	testing.expect_value(t, show_thing(&w, "moore", "matchbook"), Answer_Kind.Shrug)
	testing.expect_value(t, w.clock_ticks, before) // the file says tick; a shrug never does
	end_conversation(&w)
	set_flag(&w, "carrying_shoe")
	show_thing(&w, "moore", "shoe")
	testing.expect_value(t, w.clock_ticks, before + 1) // and a real answer does
}

@(test)
absent_is_not_here_and_dead_is_gone :: proc(t: ^testing.T) {
	w := shows_world(t, "absent_is_not_here_and_dead_is_gone")
	defer shows_done(&w)
	set_flag(&w, "carrying_shoe")
	testing.expect_value(t, show_thing(&w, "fairbank", "shoe"), Answer_Kind.Not_Here) // in another room
	w.speakers[1].gone = true
	testing.expect_value(t, show_thing(&w, "fairbank", "shoe"), Answer_Kind.Gone) // and now dead, wherever he is
	testing.expect_value(t, show_thing(&w, "elena", "shoe"), Answer_Kind.Not_Here)
}

@(test)
asking_is_not_showing :: proc(t: ^testing.T) {
	w := shows_world(t, "asking_is_not_showing")
	defer shows_done(&w)
	// ASK MOORE ABOUT THE SHOE, with no shoe: a show topic is not an answer.
	testing.expect(t, !answer(&w, "moore", "shoe"))
	set_flag(&w, "carrying_shoe")
	testing.expect(t, !answer(&w, "moore", "shoe")) // and not with it either: SHOW is how
	testing.expect_value(t, show_thing(&w, "moore", "shoe"), Answer_Kind.Answered)
}
