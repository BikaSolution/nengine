package nengine

import "core:testing"

// The standard vocabulary, driven the way a player would drive it. These are
// the sentences the genre expects to work; if one of them stops working, a
// game built on this engine has a puzzle nobody can type the answer to.

@(private = "file")
game := [?]Word {
	{.Noun, "lamp", "lantern"},
	{.Noun, "boots", "boot"},
	{.Noun, "monocle", "eyeglass"},
	{.Noun, "cat", "kitty"},
	{.Noun, "plate", ""},
	{.Noun, "crate", "box"},
	{.Noun, "door", ""},
	{.Noun, "key", ""},
	{.Adjective, "brass", ""},
	{.Adjective, "muddy", ""},
}

@(private = "file")
with_standard :: proc(t: ^testing.T) -> []Word {
	return vocab_join(game[:], context.temp_allocator)
}

@(private = "file")
expect :: proc(t: ^testing.T, line: string, want: Command, last := "", loc := #caller_location) {
	cmd, err, bad := parse(line, with_standard(t), last)
	testing.expectf(t, err == .None, "%q: %v %q", line, err, bad, loc = loc)
	testing.expect_value(t, cmd, want, loc)
}

@(test)
the_verbs_the_genre_expects :: proc(t: ^testing.T) {
	expect(t, "take the lamp", {verb = "take", noun = "lamp"})
	expect(t, "get lantern", {verb = "take", noun = "lamp"})
	expect(t, "pick up the lamp", {verb = "take", noun = "lamp"})
	expect(t, "open door", {verb = "open", noun = "door"})
	expect(t, "shut the door", {verb = "close", noun = "door"})
	expect(t, "x boots", {verb = "look", noun = "boots"})
	expect(t, "i", {verb = "inventory"})
	expect(t, "wait", {verb = "wait"})
}

@(test)
a_verb_and_two_things_joined_by_a_preposition :: proc(t: ^testing.T) {
	// The two sentences the whole exercise was about.
	expect(t, "give the plate to the cat", {verb = "give", noun = "plate", prep = "to", noun2 = "cat"})
	expect(t, "inspect boots with monocle", {verb = "look", noun = "boots", prep = "with", noun2 = "monocle"})

	expect(t, "unlock the door with the key", {verb = "unlock", noun = "door", prep = "with", noun2 = "key"})
	expect(t, "put the lamp in the crate", {verb = "put", noun = "lamp", prep = "in", noun2 = "crate"})
	expect(t, "look under the crate", {verb = "look under", noun = "crate"})
}

@(test)
a_recipient_said_first_still_means_the_same_thing :: proc(t: ^testing.T) {
	// "give cat plate" is the same sentence as "give plate to cat". Read
	// literally it would have the player handing the cat to the plate.
	expect(t, "give the cat the plate", {verb = "give", noun = "plate", prep = "to", noun2 = "cat"})
	expect(t, "show the cat the lamp", {verb = "show", noun = "lamp", prep = "to", noun2 = "cat"})

	// Only for verbs that take a recipient. "put lamp crate" is not "put
	// crate to lamp"; it is a sentence the game has to make sense of itself.
	expect(t, "put lamp crate", {verb = "put", noun = "lamp", noun2 = "crate"})
}

@(test)
adjectives_say_which_one :: proc(t: ^testing.T) {
	expect(t, "look at the brass lamp", {verb = "look", adj = "brass", noun = "lamp"})
	// One on each side of the preposition.
	expect(t, "clean the muddy boots with the brass monocle",
		{verb = "clean", adj = "muddy", noun = "boots", prep = "with", adj2 = "brass", noun2 = "monocle"})
}

@(test)
it_means_whatever_was_last_talked_about :: proc(t: ^testing.T) {
	expect(t, "open it", {verb = "open", noun = "crate"}, last = "crate")
	expect(t, "look at it", {verb = "look", noun = "crate"}, last = "crate")
	// A person is last talked about as often as a thing is.
	expect(t, "ask him about the lamp", {verb = "ask", noun = "percy", prep = "about", noun2 = "lamp"}, last = "percy")

	// With nothing to point at, say so rather than doing something random.
	_, err, bad := parse("take it", with_standard(t))
	testing.expect_value(t, err, Parse_Error.No_Antecedent)
	testing.expect_value(t, bad, "it")
}

@(test)
the_compass_works_bare_or_with_a_verb :: proc(t: ^testing.T) {
	expect(t, "north", {noun = "north"})
	expect(t, "n", {noun = "north"})
	expect(t, "go north", {verb = "go", noun = "north"})
	expect(t, "walk to the door", {verb = "go", noun = "door"})
}

@(test)
in_is_a_direction_alone_and_a_preposition_in_a_sentence :: proc(t: ^testing.T) {
	// The one genuine ambiguity in the standard list, settled by position.
	expect(t, "in", {noun = "in"})
	expect(t, "look in the crate", {verb = "search", noun = "crate"})
	expect(t, "put the key in the lamp", {verb = "put", noun = "key", prep = "in", noun2 = "lamp"})
}

@(test)
a_game_can_overrule_a_word_the_engine_ships :: proc(t: ^testing.T) {
	// "light" is a synonym of "turn on" as standard. A game about a lamp
	// wants it to be the lamp, and says so.
	mine := [?]Word{{.Noun, "light", "lamp"}}
	vocab := vocab_join(mine[:], context.temp_allocator)

	cmd, err, _ := parse("take the light", vocab)
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, cmd, Command{verb = "take", noun = "light"})

	// And the engine's own meaning is shadowed, not deleted: "switch on" is
	// still there, so nothing the game didn't think about stops working.
	cmd2, err2, _ := parse("switch on the light", vocab)
	testing.expect_value(t, err2, Parse_Error.None)
	testing.expect_value(t, cmd2, Command{verb = "turn on", noun = "light"})
}

@(test)
an_unknown_word_says_which_one :: proc(t: ^testing.T) {
	_, err, bad := parse("take the flibbertigibbet", with_standard(t))
	testing.expect_value(t, err, Parse_Error.Unknown_Word)
	testing.expect_value(t, bad, "flibbertigibbet")
}

@(test)
the_verb_list_is_for_a_help_screen :: proc(t: ^testing.T) {
	verbs := verb_list(with_standard(t))
	testing.expect(t, len(verbs) > 40, "the engine ships a genre's worth of verbs")

	// Canonical names only, and each one once.
	for v, i in verbs {
		for w, j in verbs do if i != j do testing.expectf(t, v != w, "%q listed twice", v)
	}
	found := false
	for v in verbs do if v == "take" do found = true
	testing.expect(t, found, "take is in the list")
	for v in verbs do testing.expectf(t, v != "grab", "%q is a synonym, not a verb to list", v)
}

@(test)
vocab_knows_what_it_knows :: proc(t: ^testing.T) {
	vocab := with_standard(t)
	testing.expect(t, vocab_knows(vocab, "take"))
	testing.expect(t, vocab_knows(vocab, "pick up")) // a synonym counts
	testing.expect(t, vocab_knows(vocab, "  LAMP  ")) // trimmed and lowered
	testing.expect(t, !vocab_knows(vocab, "flibbertigibbet"))
}

// --- The notebook verbs ---

@(test)
the_notebook_opens_by_any_of_the_names_people_call_it :: proc(t: ^testing.T) {
	v := vocab_join(nil)
	defer delete(v)
	for said in ([]string{"notebook", "journal", "diary", "casebook", "notes", "my notebook"}) {
		cmd, err, bad := parse(said, v)
		testing.expectf(t, err == .None, "%q: %v %q", said, err, bad)
		testing.expect_value(t, cmd.verb, "notebook")
	}
}

// "by" is already a way of saying "near", so `sort by time` would come apart
// as sort/near/time — a sentence about standing next to a clock. `sort by`
// being a verb of its own is what stops that.
@(test)
sort_by_does_not_come_apart_on_the_preposition :: proc(t: ^testing.T) {
	GAME := [?]Word{{.Noun, "times", "time tab"}}
	v := vocab_join(GAME[:])
	defer delete(v)

	for said in ([]string{"sort times", "sort by times", "order by times", "order times", "arrange times"}) {
		cmd, err, bad := parse(said, v)
		testing.expectf(t, err == .None, "%q: %v %q", said, err, bad)
		testing.expect_value(t, cmd.verb, "sort")
		testing.expectf(t, cmd.noun == "times", "%q gave noun %q", said, cmd.noun)
		// And nothing was left stuck in the preposition.
		testing.expectf(t, cmd.prep == "", "%q gave prep %q", said, cmd.prep)
	}
}

@(test)
accuse_takes_a_name_and_what_backs_it_up :: proc(t: ^testing.T) {
	GAME := [?]Word{{.Noun, "margaret", "whitfield"}, {.Noun, "february", ""}}
	v := vocab_join(GAME[:])
	defer delete(v)

	cmd, err, bad := parse("accuse margaret with february", v)
	testing.expectf(t, err == .None, "%v %q", err, bad)
	testing.expect_value(t, cmd.verb, "accuse")
	testing.expect_value(t, cmd.noun, "margaret")
	testing.expect_value(t, cmd.prep, "with")
	testing.expect_value(t, cmd.noun2, "february")
}

// A game's own words go first, so a game with a physical book in it can take
// the word back — which this one does, because Fairbank's field book is a
// thing you can pick up and the player will type "book" meaning that.
@(test)
a_game_can_take_the_word_notebook_back_for_a_thing :: proc(t: ^testing.T) {
	GAME := [?]Word{{.Noun, "field book", "book, notebook, fieldbook"}}
	v := vocab_join(GAME[:])
	defer delete(v)

	cmd, err, _ := parse("look at notebook", v)
	testing.expect(t, err == .None)
	testing.expect_value(t, cmd.verb, "look")
	testing.expect_value(t, cmd.noun, "field book")
}

// A game's phrase can be longer than three words, and the longest one wins.
@(test)
a_long_phrase_is_one_word :: proc(t: ^testing.T) {
	words := [?]Word {
		{.Verb, "snap", "take a picture of"},
		{.Verb, "handin", "i would have handed it in"},
		{.Noun, "photograph", ""},
	}
	vocab := vocab_join(words[:], context.temp_allocator)
	cmd, err, _ := parse("take a picture of the photograph", vocab)
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, cmd, Command{verb = "snap", noun = "photograph"})
	cmd, err, _ = parse("I would have handed it in", vocab)
	testing.expect_value(t, cmd.verb, "handin")
}
