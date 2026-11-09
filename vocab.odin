package nengine

import "core:strings"

// The words every adventure game needs.
//
// The parser knows no words; this is where the ones nobody should have to
// type out again live. LOOK, TAKE, OPEN, the compass, "the", "with" — the
// vocabulary of the genre rather than of any one game. A game adds its own
// nouns and whatever verbs its puzzles need, and can override anything here
// by giving the same word a meaning of its own.
//
//     vocab := ne.vocab_join(GAME_WORDS[:])
//     defer delete(vocab)
//     w.vocab = vocab
//
// The engine still decides nothing. Knowing that "take" is a verb is not the
// same as knowing what taking does, and nothing in here says what any of
// these mean — only how a sentence comes apart.
//
// Two notes on the order of this table, because it is load-bearing:
//
//   * A game's words go FIRST, so a game that redefines a word wins.
//   * Directions come before prepositions, so a bare "in" is a way to go and
//     "look in the crate" is a preposition. The parser prefers whichever kind
//     the sentence still wants; this settles it when it wants neither.

STANDARD_VOCAB := [?]Word {
	// --- Looking ---
	{.Verb, "look", "l, examine, x, inspect, look at, study, describe, view, check"},
	{.Verb, "search", "look in, look inside, search in, rummage, rummage in, look through"},
	{.Verb, "look under", "look beneath, check under, look underneath"},
	{.Verb, "look behind", "check behind"},
	{.Verb, "read", "peruse"},

	// --- Hands ---
	{.Verb, "take", "get, pick up, grab, collect, remove, steal"},
	{.Verb, "drop", "put down, discard, leave, let go of"},
	{.Verb, "put", "place, insert, put in, put into, put on top of"},
	{.Verb, "open", "unseal"},
	{.Verb, "close", "shut"},
	{.Verb, "lock", ""},
	{.Verb, "unlock", ""},
	{.Verb, "push", "press, shove, depress"},
	{.Verb, "pull", "tug, yank, drag"},
	{.Verb, "turn", "rotate, twist, wind"},
	{.Verb, "turn on", "switch on, light, activate, start"},
	{.Verb, "turn off", "switch off, extinguish, put out, deactivate, stop"},
	{.Verb, "move", "shift, slide"},
	{.Verb, "use", "apply, operate, work"},
	{.Verb, "touch", "feel, pat, pet, stroke, poke, prod"},
	{.Verb, "clean", "wipe, polish, rub, dust"},
	{.Verb, "fill", ""},
	{.Verb, "empty", "pour out, tip out, pour"},
	{.Verb, "tie", "attach, fasten, fix, connect"},
	{.Verb, "untie", "detach, unfasten, disconnect, undo"},
	{.Verb, "cut", "slice, saw"},
	{.Verb, "dig", "dig in"},
	{.Verb, "knock", "knock on, knock at, rap on"},
	{.Verb, "throw", "toss, chuck, hurl"},
	{.Verb, "hit", "attack, strike, kick, punch, break, smash, bash"},

	// --- Wearing and eating ---
	{.Verb, "wear", "put on, don"},
	{.Verb, "take off", "doff"},
	{.Verb, "eat", "consume, bite, chew"},
	{.Verb, "drink", "sip, swallow"},
	{.Verb, "smell", "sniff, whiff"},
	{.Verb, "listen", "listen to, hear"},
	{.Verb, "peep", "peek, spy, peep at, peek at, peep through, peek through, spy on"},
	{.Verb, "taste", "lick"},

	// --- People ---
	{.Verb, "talk to", "talk, speak to, speak, greet, hello, hi"},
	{.Verb, "ask", "ask about, enquire, enquire about, query"},
	{.Verb, "answer", "reply, respond"},
	{.Verb, "yes", "yeah, aye"},
	{.Verb, "no", "nope, nay"},
	{.Verb_Dative, "give", "hand, offer, pay, feed"},
	{.Verb_Dative, "show", "display, present"},
	{.Verb_Dative, "tell", "tell about, say to"},

	// --- Going places ---
	{.Verb, "go", "walk, walk to, run, run to, head, travel, go to, move to"},
	{.Verb, "enter", "go in, go into, get in, get into, board"},
	{.Verb, "exit", "leave, go out, get out, disembark"},
	{.Verb, "climb", "climb up, scale, climb on, climb over"},
	{.Verb, "jump", "leap, hop"},
	{.Verb, "swim", ""},
	{.Verb, "sit", "sit on, sit down, sit in"},
	{.Verb, "stand", "stand up, get up, rise"},
	{.Verb, "sleep", "rest, lie down, nap"},
	{.Verb, "wake", "wake up, rouse"},
	{.Verb, "hide", "hide in, hide behind"},
	{.Verb, "wait", "z"},

	// --- Talking to the game rather than to the world ---
	{.Verb, "inventory", "i, inv, carrying, possessions"},
	{.Verb, "score", "points, how am i doing"},
	{.Verb, "time", "clock, how long"},
	{.Verb, "help", "commands, verbs"},
	{.Verb, "save", "save game"},
	{.Verb, "restore", "load, load game"},
	{.Verb, "restart", "start over"},
	{.Verb, "quit", "q, exit game"},
	{.Verb, "look at me", "examine me, examine self, look at self"},

	// --- The notebook. The engine keeps it; the game draws it. notebook.odin ---
	//
	// `sort by` is a verb rather than a verb and a preposition, because "by"
	// is already a way of saying "near" — so "sort by time" would otherwise
	// come apart as sort/near/time, which is a sentence about standing next to
	// a clock.
	//
	// The names of the tabs are a game's own and belong in its vocabulary. Mind
	// that "time" is a verb here already: a tab called `times` parses, a tab
	// called `time` is asking to be told how long you have been playing.
	{.Verb, "notebook", "journal, diary, casebook, notes, my notebook"},
	// No hyphens in a synonym: the tokeniser splits on them, so "re-sort"
	// arrives as "re" and is a word nobody knows. And no "resort" either —
	// in a game about a travel agency that is a place, not an instruction.
	{.Verb, "sort", "order, arrange, sort by, order by"},
	{.Verb, "accuse", "blame, charge"},

	// --- The compass. Nouns, so "north" and "go north" both work. ---
	{.Noun, "north", "n"},
	{.Noun, "south", "s"},
	{.Noun, "east", "e"},
	{.Noun, "west", "w"},
	{.Noun, "northeast", "ne"},
	{.Noun, "northwest", "nw"},
	{.Noun, "southeast", "se"},
	{.Noun, "southwest", "sw"},
	{.Noun, "up", "u, upstairs, upward"},
	{.Noun, "down", "d, downstairs, downward"},
	{.Noun, "in", "inward"},
	{.Noun, "out", "outward"},
	{.Noun, "me", "self, myself"},

	// Numbers, so "save 3" and "restore 2" can be typed at the prompt.
	{.Noun, "1", "one, first"},
	{.Noun, "2", "two, second"},
	{.Noun, "3", "three, third"},
	{.Noun, "4", "four, fourth"},
	{.Noun, "5", "five, fifth"},
	{.Noun, "6", "six, sixth"},
	{.Noun, "7", "seven, seventh"},
	{.Noun, "8", "eight, eighth"},

	// --- Joining two things ---
	{.Prep, "to", "toward, towards, onto"},
	{.Prep, "at", ""},
	{.Prep, "on", "on top of, upon"},
	{.Prep, "in", "into, inside, within"},
	{.Prep, "with", "using"},
	{.Prep, "under", "underneath, beneath, below"},
	{.Prep, "behind", ""},
	{.Prep, "over", "above, across"},
	{.Prep, "from", "out of, off, off of"},
	{.Prep, "through", ""},
	{.Prep, "about", "concerning, regarding"},
	{.Prep, "for", ""},
	{.Prep, "between", ""},
	{.Prep, "against", ""},
	{.Prep, "near", "beside, next to, by"},

	// --- Whatever we were just talking about ---
	{.Pronoun, "it", "that, this, him, her, them"},
	{.Pronoun, "them", "those, these"},

	// --- Noise ---
	{.Ignore, "the", ""},
	{.Ignore, "a", "an"},
	{.Ignore, "my", "your, his, her, their, its"},
	{.Ignore, "some", "any"},
	{.Ignore, "please", "kindly"},
	{.Ignore, "of", ""},
	{.Ignore, "and", "then"},
}

// A game's words, then the engine's. The result is owned by the caller.
//
// Game words come first because the first match wins: a game that wants
// "light" to be a noun rather than a verb says so, and its answer is the one
// found. Nothing is removed — an engine word a game disagrees with is
// shadowed, not deleted, so a synonym the game didn't think of still works.
vocab_join :: proc(game: []Word, allocator := context.allocator) -> []Word {
	out := make([]Word, len(game) + len(STANDARD_VOCAB), allocator)
	copy(out[:], game)
	copy(out[len(game):], STANDARD_VOCAB[:])
	return out
}

// Every verb the player could type, in the order they are listed, for a HELP
// screen. Only the canonical names — a list including every synonym is a wall
// of words nobody reads.
verb_list :: proc(vocab: []Word, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for v in vocab {
		if v.kind != .Verb && v.kind != .Verb_Dative do continue
		seen := false
		for had in out do if had == v.name do seen = true
		if !seen do append(&out, v.name)
	}
	return out[:]
}

// Is `word` something this vocabulary knows at all? For a game checking its
// own nouns against the engine's list before shipping a puzzle nobody can
// type the answer to.
vocab_knows :: proc(vocab: []Word, phrase: string) -> bool {
	want := strings.to_lower(strings.trim_space(phrase), context.temp_allocator)
	for v in vocab do if is_called(v, want) do return true
	return false
}
