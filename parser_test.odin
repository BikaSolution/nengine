package nengine

import "core:testing"

// A small vocabulary, just for these tests. Real games bring their own.
@(private = "file")
vocab := [?]Word {
	{.Verb, "look", "l, examine, look at"},
	{.Verb, "search", "look in, look inside"},
	{.Verb, "take", "get, pick up, grab"},
	{.Verb, "give", "offer"},
	{.Verb, "turn on", "switch on, light"},
	{.Noun, "lamp", "light, lantern"},
	{.Noun, "cat", "kitty"},
	{.Noun, "plate", ""},
	{.Noun, "crate", "box"},
	{.Noun, "north", "n"},
	{.Prep, "to", ""},
	{.Prep, "in", "into"},
	{.Ignore, "the", ""},
	{.Ignore, "a", ""},
}

@(private = "file")
expect_command :: proc(t: ^testing.T, line: string, want: Command, loc := #caller_location) {
	cmd, err, _ := parse(line, vocab[:])
	testing.expect_value(t, err, Parse_Error.None, loc)
	testing.expect_value(t, cmd, want, loc)
}

@(test)
verb_and_noun :: proc(t: ^testing.T) {
	expect_command(t, "take lamp", {verb = "take", noun = "lamp"})
}

@(test)
synonyms :: proc(t: ^testing.T) {
	expect_command(t, "grab kitty", {verb = "take", noun = "cat"})
	expect_command(t, "l", {verb = "look"})
}

@(test)
longest_phrase_wins :: proc(t: ^testing.T) {
	expect_command(t, "pick up the lamp", {verb = "take", noun = "lamp"})
	expect_command(t, "look at box", {verb = "look", noun = "crate"})
	expect_command(t, "look in box", {verb = "search", noun = "crate"})
}

@(test)
case_and_punctuation_are_ignored :: proc(t: ^testing.T) {
	expect_command(t, "  LOOK at the Cat!!  ", {verb = "look", noun = "cat"})
}

@(test)
second_noun_after_a_preposition :: proc(t: ^testing.T) {
	expect_command(t, "give the plate to the cat", {verb = "give", noun = "plate", prep = "to", noun2 = "cat"})
}

// A sentence with three nouns keeps the third, and the preposition before it
// in prep2: "accuse the cook of the murder with the knife". The first
// preposition is not overwritten by the second.
@(test)
third_noun_after_a_second_preposition :: proc(t: ^testing.T) {
	expect_command(t, "give the plate to the cat in the crate",
		{verb = "give", noun = "plate", prep = "to", noun2 = "cat", prep2 = "in", noun3 = "crate"})
	expect_command(t, "give plate cat in crate",
		{verb = "give", noun = "plate", noun2 = "cat", prep2 = "in", noun3 = "crate"})
}

@(test)
a_word_that_is_both_verb_and_noun :: proc(t: ^testing.T) {
	expect_command(t, "light lamp", {verb = "turn on", noun = "lamp"})
	expect_command(t, "look at the light", {verb = "look", noun = "lamp"})
}

@(test)
no_verb_is_not_an_error :: proc(t: ^testing.T) {
	// The game decides what "north" on its own means.
	expect_command(t, "n", {noun = "north"})
}

@(test)
unknown_words_are_reported :: proc(t: ^testing.T) {
	_, err, bad := parse("take the frobnicator", vocab[:])
	testing.expect_value(t, err, Parse_Error.Unknown_Word)
	testing.expect_value(t, bad, "frobnicator")
}

@(test)
empty_lines :: proc(t: ^testing.T) {
	_, err, _ := parse("   ", vocab[:])
	testing.expect_value(t, err, Parse_Error.Empty)
	_, err, _ = parse("?!", vocab[:])
	testing.expect_value(t, err, Parse_Error.Empty)
}

// --- run_command: the scene gets first go, then the world ---

@(private = "file") scene_saw: Command
@(private = "file") world_saw: Command

@(test)
the_scene_handles_commands_before_the_world :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	w.vocab = vocab[:]
	w.on_command = proc(w: ^World, cmd: Command) { world_saw = cmd }
	append(&w.scenes, Scene {
		on_command = proc(w: ^World, cmd: Command) -> bool {
			scene_saw = cmd
			return cmd.noun == "cat" // the scene only cares about the cat
		},
	})

	scene_saw, world_saw = {}, {}
	run_command(&w, "look at cat")
	testing.expect_value(t, scene_saw.noun, "cat")
	testing.expect_value(t, world_saw.noun, "") // handled, never got here

	scene_saw, world_saw = {}, {}
	run_command(&w, "look at lamp")
	testing.expect_value(t, world_saw.noun, "lamp")
}

@(test)
unknown_word_message :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	w.vocab = vocab[:]
	append(&w.scenes, Scene{})

	run_command(&w, "xyzzy")
	testing.expect_value(t, message(&w), "I don't know the word \"xyzzy\".")
}

@(test)
an_apostrophe_joins_a_word :: proc(t: ^testing.T) {
	vocab := []Word {
		{.Verb, "dunno", "i dont know, dont know"},
		{.Noun, "index", "fairbank's index"},
		{.Verb, "look", ""},
	}
	cmd, err, _ := parse("I don't know", vocab)
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, cmd.verb, "dunno")
	cmd, err, _ = parse("i don’t know", vocab) // the curly one
	testing.expect_value(t, cmd.verb, "dunno")
	cmd, err, _ = parse("look fairbank's index", vocab)
	testing.expect_value(t, cmd.noun, "index")
}
