package nengine

import "core:strings"
import "core:testing"

@(private = "file")
tidy :: proc(w: ^World) {
	clear_notebook(w)
	clear_accusations(w)
	clear_flags(w)
	delete(w.notebook)
	delete(w.accusations)
	w^ = {}
}

// Writing the same thing twice writes it once. A player who looks at the shoe
// four times has found one shoe.
@(test)
an_entry_is_written_once_however_often_it_is_found :: proc(t: ^testing.T) {
	w: World
	defer tidy(&w)

	testing.expect(t, note(&w, {id = "shoe", tab = "things", text = "One shoe."}))
	testing.expect(t, !note(&w, {id = "shoe", tab = "things", text = "One shoe."}))
	// Even said differently the second time — the id is what it is.
	testing.expect(t, !note(&w, {id = "shoe", tab = "things", text = "A shoe, on its side."}))
	testing.expect_value(t, notebook_count(&w), 1)

	e, got := notebook_entry(&w, "shoe")
	testing.expect(t, got)
	testing.expect_value(t, e.text, "One shoe.") // the first telling, not the last
}

@(test)
an_entry_with_no_id_is_not_an_entry :: proc(t: ^testing.T) {
	w: World
	defer tidy(&w)
	testing.expect(t, !note(&w, {tab = "things", text = "Something."}))
	testing.expect_value(t, notebook_count(&w), 0)
}

@(test)
a_page_holds_its_own_tab_and_the_book_holds_everything :: proc(t: ^testing.T) {
	w: World
	defer tidy(&w)
	note(&w, {id = "a", tab = "things", text = "A"})
	note(&w, {id = "b", tab = "times", text = "B"})
	note(&w, {id = "c", tab = "things", text = "C"})

	testing.expect_value(t, len(notebook_entries(&w, "things")), 2)
	testing.expect_value(t, len(notebook_entries(&w, "times")), 1)
	testing.expect_value(t, len(notebook_entries(&w, "nothing")), 0)
	testing.expect_value(t, len(notebook_entries(&w)), 3) // no tab is the whole book
}

@(test)
found_order_is_the_order_it_was_lived_in :: proc(t: ^testing.T) {
	w: World
	defer tidy(&w)
	note(&w, {id = "first", tab = "t", minute = 900})
	note(&w, {id = "second", tab = "t", minute = 100})
	note(&w, {id = "third", tab = "t", minute = 500})

	page := notebook_entries(&w, "t", .Found)
	testing.expect_value(t, page[0].id, "first")
	testing.expect_value(t, page[1].id, "second")
	testing.expect_value(t, page[2].id, "third")
}

// The set piece: a list the player already had, read in a different order.
@(test)
sorting_by_time_is_the_same_facts_in_clock_order :: proc(t: ^testing.T) {
	w: World
	defer tidy(&w)
	note(&w, {id = "late", tab = "t", minute = 1400})
	note(&w, {id = "early", tab = "t", minute = 100})
	note(&w, {id = "middle", tab = "t", minute = 700})

	page := notebook_entries(&w, "t", .Time)
	testing.expect_value(t, page[0].id, "early")
	testing.expect_value(t, page[1].id, "middle")
	testing.expect_value(t, page[2].id, "late")
	// Sorting a view must not disturb the book itself.
	testing.expect_value(t, notebook_entries(&w, "t", .Found)[0].id, "late")
}

// A case that runs from teatime to dawn crosses midnight. If minutes wrapped
// at 1440, ten past midnight would sort before ten to twelve and the night
// would come apart in the one tab that has to hold it together — so the engine
// never interprets the number, it only compares.
@(test)
a_night_that_crosses_midnight_stays_in_order :: proc(t: ^testing.T) {
	w: World
	defer tidy(&w)
	note(&w, {id = "dinner", tab = "t", minute = 19 * 60 + 30})  // 19:30
	note(&w, {id = "generator", tab = "t", minute = 22 * 60 + 30}) // 22:30
	note(&w, {id = "found", tab = "t", minute = 23 * 60 + 52})     // 23:52
	note(&w, {id = "doctor", tab = "t", minute = 24 * 60 + 10})    // 00:10, the next day
	note(&w, {id = "dawn", tab = "t", minute = 30 * 60 + 30})      // 06:30

	page := notebook_entries(&w, "t", .Time)
	want := [?]string{"dinner", "generator", "found", "doctor", "dawn"}
	for id, i in want do testing.expect_value(t, page[i].id, id)
}

// Two facts about the same minute read in the order the player got them.
@(test)
entries_at_the_same_minute_keep_the_order_they_were_found :: proc(t: ^testing.T) {
	w: World
	defer tidy(&w)
	note(&w, {id = "one", tab = "t", minute = 600})
	note(&w, {id = "two", tab = "t", minute = 600})
	note(&w, {id = "three", tab = "t", minute = 600})

	page := notebook_entries(&w, "t", .Time)
	testing.expect_value(t, page[0].id, "one")
	testing.expect_value(t, page[1].id, "two")
	testing.expect_value(t, page[2].id, "three")
}

@(test)
an_entry_with_no_time_waits_at_the_back :: proc(t: ^testing.T) {
	w: World
	defer tidy(&w)
	note(&w, {id = "untimed", tab = "t"})
	note(&w, {id = "timed", tab = "t", minute = 500})
	note(&w, {id = "untimed2", tab = "t"})

	page := notebook_entries(&w, "t", .Time)
	testing.expect_value(t, page[0].id, "timed")
	// And no-time does not pretend to be midnight, which would put it first.
	testing.expect_value(t, page[1].id, "untimed")
	testing.expect_value(t, page[2].id, "untimed2")
}

@(test)
an_entry_can_be_rubbed_out :: proc(t: ^testing.T) {
	w: World
	defer tidy(&w)
	note(&w, {id = "a", tab = "t"})
	note(&w, {id = "b", tab = "t"})
	unnote(&w, "a")
	testing.expect(t, !noted(&w, "a"))
	testing.expect(t, noted(&w, "b"))
	testing.expect_value(t, notebook_count(&w), 1)
	unnote(&w, "nothing_like_this") // and rubbing out what is not there is fine
	testing.expect_value(t, notebook_count(&w), 1)
}

// --- Dog-ears ---

@(test)
a_dogear_needs_both_halves_before_it_is_anything :: proc(t: ^testing.T) {
	w: World
	defer tidy(&w)
	CONTRA := [?]Contradiction{{a = "said_indoors", b = "found_outdoors"}}
	w.contradictions = CONTRA[:]

	note(&w, {id = "said_indoors", tab = "people", text = "I never go out after dark."})
	testing.expect_value(t, len(notebook_dogears(&w)), 0) // one half is just a fact
	testing.expect(t, !notebook_dogeared(&w, "said_indoors"))

	note(&w, {id = "found_outdoors", tab = "things", text = "Outside the fence."})
	testing.expect_value(t, len(notebook_dogears(&w)), 1)
	// The mark goes on both, and says only that they disagree.
	testing.expect(t, notebook_dogeared(&w, "said_indoors"))
	testing.expect(t, notebook_dogeared(&w, "found_outdoors"))
}

// The one the book stays quiet about is the case: a contradiction can be held
// back until the story is ready for it, and until then the player is holding
// both halves and the notebook says nothing.
@(test)
a_dogear_can_be_held_back_until_the_story_is_ready :: proc(t: ^testing.T) {
	w: World
	defer tidy(&w)
	CONTRA := [?]Contradiction{{a = "never_been", b = "signed_the_book", needs = "act5"}}
	w.contradictions = CONTRA[:]

	note(&w, {id = "never_been", tab = "people", text = "No, never."})
	note(&w, {id = "signed_the_book", tab = "things", text = "M. Whitfield, 1948."})
	testing.expect_value(t, len(notebook_dogears(&w)), 0)
	testing.expect(t, !notebook_dogeared(&w, "never_been"))

	set_flag(&w, "act5", true)
	testing.expect_value(t, len(notebook_dogears(&w)), 1)
	testing.expect(t, notebook_dogeared(&w, "never_been"))
}

// --- The accusation ---

@(test)
an_answer_must_point_at_something_the_player_actually_has :: proc(t: ^testing.T) {
	w: World
	defer tidy(&w)
	ask(&w, "Who killed Henry Fairbank?")
	note(&w, {id = "glasses", tab = "things", text = "One full, one flyblown."})

	// A name on its own is allowed. Being right is not the same as showing it.
	testing.expect(t, accuse(&w, 0, "beatrice", ""))
	testing.expect(t, !accusation_supported(&w, 0))

	// Evidence that is not in the book is not evidence.
	testing.expect(t, !accuse(&w, 0, "beatrice", "a_thing_never_found"))
	testing.expect(t, accuse(&w, 0, "beatrice", "glasses"))
	testing.expect(t, accusation_supported(&w, 0))

	// And a question nobody asked has no answer.
	testing.expect(t, !accuse(&w, 7, "anyone", "glasses"))
	testing.expect(t, !accusation_supported(&w, 7))
}

// --- Saving ---

@(test)
a_notebook_survives_saving_and_loading :: proc(t: ^testing.T) {
	w: World
	defer tidy(&w)
	ask(&w, "Who?")
	note(&w, {id = "tod", tab = "times", minute = 24 * 60 + 10, source = "Dr Sherwood",
	          text = "Between eleven and one, both of them."})
	note(&w, {id = "shoe", tab = "things", text = "One shoe, ten yards past the post."})
	accuse(&w, 0, "edmund", "shoe")

	s: Save
	defer save_destroy(&s)
	notebook_save(&w, &s)

	// Into a fresh world, the way a restore does it.
	back: World
	defer tidy(&back)
	ask(&back, "Who?")
	notebook_load(&back, &s)

	testing.expect_value(t, notebook_count(&back), 2)
	e, got := notebook_entry(&back, "tod")
	testing.expect(t, got)
	testing.expect_value(t, e.tab, "times")
	m, timed := e.minute.?
	testing.expect(t, timed)
	testing.expect_value(t, m, 24 * 60 + 10)
	testing.expect_value(t, e.source, "Dr Sherwood")
	testing.expect_value(t, e.text, "Between eleven and one, both of them.")
	// Order survives, which is the half of a notebook that is not the words.
	testing.expect_value(t, notebook_entries(&back)[0].id, "tod")
	testing.expect_value(t, notebook_entries(&back)[1].id, "shoe")

	testing.expect_value(t, back.accusations[0].name, "edmund")
	testing.expect(t, accusation_supported(&back, 0))
}

@(test)
an_entry_with_no_time_comes_back_with_no_time :: proc(t: ^testing.T) {
	w: World
	defer tidy(&w)
	note(&w, {id = "plain", tab = "things", text = "No clock on this one."})

	s: Save
	defer save_destroy(&s)
	notebook_save(&w, &s)

	back: World
	defer tidy(&back)
	notebook_load(&back, &s)
	e, got := notebook_entry(&back, "plain")
	testing.expect(t, got)
	_, timed := e.minute.?
	testing.expect(t, !timed)
	// And still sorts to the back rather than to midnight.
	note(&back, {id = "timed", tab = "things", minute = 0})
	testing.expect_value(t, notebook_entries(&back, "things", .Time)[0].id, "timed")
}

// A save line is `key value` to the end of the line, so a tab in a sentence
// would eat everything after it.
@(test)
a_tab_in_a_sentence_cannot_eat_the_rest_of_the_save :: proc(t: ^testing.T) {
	w: World
	defer tidy(&w)
	note(&w, {id = "nasty", tab = "things", source = "a\tb",
	          text = "One full,\tlipstick.\nOne empty."})

	s: Save
	defer save_destroy(&s)
	notebook_save(&w, &s)

	back: World
	defer tidy(&back)
	notebook_load(&back, &s)
	e, got := notebook_entry(&back, "nasty")
	testing.expect(t, got)
	testing.expect_value(t, e.text, "One full, lipstick. One empty.")
	testing.expect_value(t, e.source, "a b")
}

@(test)
loading_replaces_a_notebook_rather_than_adding_to_one :: proc(t: ^testing.T) {
	w: World
	defer tidy(&w)
	note(&w, {id = "kept", tab = "t"})

	s: Save
	defer save_destroy(&s)
	notebook_save(&w, &s)

	back: World
	defer tidy(&back)
	note(&back, {id = "from_the_other_game", tab = "t"})
	notebook_load(&back, &s)
	testing.expect_value(t, notebook_count(&back), 1)
	testing.expect(t, !noted(&back, "from_the_other_game"))
}

@(test)
the_declared_tabs_can_be_looked_up_for_a_page_heading :: proc(t: ^testing.T) {
	w: World
	defer tidy(&w)
	TABS := [?]Notebook_Tab{{name = "people", title = "People"}, {name = "things", title = "Things"}}
	w.notebook_tabs = TABS[:]

	tab, got := notebook_tab(&w, "things")
	testing.expect(t, got)
	testing.expect_value(t, tab.title, "Things")
	_, missing := notebook_tab(&w, "nothing")
	testing.expect(t, !missing)
}

@(test)
answering_again_with_the_same_name_keeps_it :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	ask(&w, "Who?")
	note(&w, {id = "clue", tab = "things", text = "A clue."})
	testing.expect(t, accuse(&w, 0, "Margaret", ""))
	// Attaching evidence: the same name again, which is the one already held.
	testing.expect(t, accuse(&w, 0, w.accusations[0].name, "clue"))
	testing.expect_value(t, w.accusations[0].name, "Margaret")
	testing.expect(t, accusation_supported(&w, 0))
}

@(test)
shown_is_idempotent_per_pair :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	note(&w, {id = "shoe", tab = "things", text = "One shoe, on the path."})
	testing.expect(t, shown(&w, "shoe", "Moore", "Otter had that."))
	testing.expect(t, !shown(&w, "shoe", "Moore", "Something else."), "once per person")
	testing.expect(t, shown(&w, "shoe", "Sherwood", ""))
	testing.expect(t, !shown(&w, "nothing", "Moore", "x"), "no entry, nothing kept")
	e, _ := notebook_entry(&w, "shoe")
	testing.expect_value(t, len(e.shown), 2)
	testing.expect_value(t, e.shown[0].text, "Otter had that.")
	testing.expect_value(t, e.shown[1].who, "Sherwood")

	// And it survives a save.
	s: Save
	defer save_destroy(&s)
	notebook_save(&w, &s)
	w2: World
	defer destroy_world(&w2)
	notebook_load(&w2, &s)
	back, _ := notebook_entry(&w2, "shoe")
	testing.expect_value(t, len(back.shown), 2)
	testing.expect_value(t, back.shown[0].who, "Moore")
}

@(test)
a_no_proof_tab_refuses_at_the_accusation :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	tabs := [?]Notebook_Tab{{name = "things", title = "Things"}, {name = "questions", title = "Questions", no_proof = true}}
	w.notebook_tabs = tabs[:]
	ask(&w, "Who killed Henry Fairbank?")
	note(&w, {id = "glasses", tab = "things", text = "One full, one flyblown."})
	note(&w, {id = "why_two", tab = "questions", text = "Why two glasses?"})

	testing.expect_value(t, accuse_why(&w, 0, "beatrice", "why_two"), Accuse_Result.Not_Proof)
	testing.expect_value(t, w.accusations[0].name, "") // refused, so nothing written
	testing.expect_value(t, accuse_why(&w, 0, "beatrice", "nothing"), Accuse_Result.Not_Noted)
	testing.expect_value(t, accuse_why(&w, 3, "beatrice", "glasses"), Accuse_Result.No_Question)
	testing.expect_value(t, accuse_why(&w, 0, "beatrice", "glasses"), Accuse_Result.Taken)
	testing.expect(t, accusation_supported(&w, 0))
}

@(test)
a_closed_entry_stays_and_is_struck :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	note(&w, {id = "why_two", tab = "questions", text = "Why two glasses?"})
	note(&w, {id = "who_paid", tab = "questions", text = "Who paid the ranger?"})
	testing.expect(t, close_note(&w, "why_two"))
	testing.expect(t, !close_note(&w, "nothing"))
	testing.expect(t, note_closed(&w, "why_two"))
	testing.expect_value(t, len(notebook_entries(&w, "questions")), 2) // still in the book
	open := notebook_entries(&w, "questions", open_only = true)
	testing.expect_value(t, len(open), 1)
	testing.expect_value(t, open[0].id, "who_paid")

	// A save keeps the strike.
	s: Save
	defer save_destroy(&s)
	notebook_save(&w, &s)
	w2: World
	defer destroy_world(&w2)
	notebook_load(&w2, &s)
	testing.expect(t, note_closed(&w2, "why_two"))
	testing.expect(t, !note_closed(&w2, "who_paid"))
}

@(test)
four_questions_answer_in_any_order :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	for q in ([?]string{"Fairbank?", "Beatrice?", "Hawkes?", "Moore?"}) do ask(&w, q)
	for id in ([?]string{"glasses", "letter", "film", "stub_book"}) do note(&w, {id = id, tab = "things", text = id})
	testing.expect(t, accuse(&w, 3, "margaret", "stub_book"))
	testing.expect(t, accuse(&w, 0, "beatrice", "glasses"))
	testing.expect(t, accuse(&w, 2, "moore", "film"))
	testing.expect(t, accuse(&w, 1, "margaret", "letter"))
	for i in 0 ..< 4 do testing.expect(t, accusation_supported(&w, i))
	testing.expect_value(t, w.accusations[2].name, "moore")
	page := bang(&w, "page", nil)
	testing.expect(t, strings.contains(page, "4 question(s)"))
	testing.expect(t, strings.contains(page, "3. Hawkes? moore, film"))
}

@(test)
a_question_answered_twice_keeps_the_last :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	ask(&w, "Fairbank?")
	note(&w, {id = "glasses", tab = "things", text = "glasses"})
	note(&w, {id = "boiler", tab = "things", text = "boiler"})
	accuse(&w, 0, "edmund", "glasses")
	accuse(&w, 0, "beatrice", "boiler")
	testing.expect_value(t, w.accusations[0].name, "beatrice")
	testing.expect_value(t, w.accusations[0].support, "boiler")
}
