package nengine

import "core:strings"

// A text parser in the Sierra tradition. The player types a sentence, the
// parser turns it into a Command, and the game decides what happens.
//
// The engine knows no words. The game hands over a vocabulary: every word it
// understands, what kind of word it is, and its synonyms. A synonym can be
// several words long ("pick up", "look at"), and the longest match wins, so
// "look in crate" can mean something different from "look at crate".
//
//   "pick up the lamp"          -> {verb = "take", noun = "lamp"}
//   "give the plate to the cat" -> {verb = "give", noun = "plate", prep = "to", noun2 = "cat"}
//   "inspect boots with monocle"-> {verb = "look", noun = "boots", prep = "with", noun2 = "monocle"}
//   "give plate to cat with fork" -> {..., noun2 = "cat", prep2 = "with", noun3 = "fork"}
//   "north"                     -> {noun = "north"}   (no verb; the game decides)
//
// The engine ships a standard vocabulary — see vocab.odin — and a game adds
// its own words to it. The engine still knows nothing about what any of them
// mean; it only knows how to take a sentence apart.

Word_Kind :: enum {
	Verb,        // look, take, open
	Verb_Dative, // give, show, tell: see below
	Noun,        // door, lamp, north
	Adjective,   // brass, rusty: which lamp
	Prep,        // with, on, to, in: joins a second noun
	Pronoun,     // it, them: whatever was talked about last
	Ignore,      // the, a, please: dropped
}

// A dative verb takes its recipient first when there is no preposition:
// "give cat the plate" means what "give the plate to the cat" means. It is a
// kind rather than a flag on the struct so that a vocabulary stays three
// readable columns — `{.Verb, "look", "examine, x"}` — instead of every game
// having to write a `false` on every line.
Word :: struct {
	kind:     Word_Kind,
	name:     string, // what the game sees in the Command
	synonyms: string, // comma separated: "l, examine, look at"
}

// What the player meant, in the game's own words. Any part can be empty.
Command :: struct {
	verb:  string,
	adj:   string, // "brass", when they said which one
	noun:  string,
	prep:  string,
	adj2:  string,
	noun2: string,
	// A third noun, after a second preposition: "accuse the cook of the
	// murder with the knife" keeps the knife here, and "with" in prep2.
	prep2: string,
	noun3: string,
}

Parse_Error :: enum {
	None,
	Empty,
	Unknown_Word,   // `bad` holds the word
	No_Antecedent,  // "it", but nothing has been mentioned yet
}

// `last` is the noun the player last talked about, which is what "it" means.
// Games keep it between commands; passing "" makes "it" an error rather than
// a silent nothing.
parse :: proc(line: string, vocab: []Word, last := "") -> (cmd: Command, err: Parse_Error, bad: string) {
	words := split_words(line)
	if len(words) == 0 do return {}, .Empty, ""

	for i := 0; i < len(words); {
		// When a word could be two kinds of thing, guess from what's still
		// missing. "light lamp": light is the verb. "look at light": the noun.
		prefer := Word_Kind.Prep
		if cmd.verb == "" {
			prefer = .Verb
		} else if cmd.noun == "" {
			prefer = .Noun
		}

		word, used, ok := match(words[i:], vocab, prefer)
		if !ok do return {}, .Unknown_Word, words[i]
		i += used

		switch word.kind {
		case .Ignore:
		case .Verb, .Verb_Dative:
			if cmd.verb == "" do cmd.verb = word.name
		case .Prep:
			// A preposition after the second noun introduces a third.
			if cmd.noun2 != "" {
				cmd.prep2 = word.name
			} else {
				cmd.prep = word.name
			}
		case .Adjective:
			// Adjectives describe whichever noun has not been said yet.
			if cmd.noun == "" {
				cmd.adj = word.name
			} else {
				cmd.adj2 = word.name
			}
		case .Pronoun:
			if last == "" do return {}, .No_Antecedent, word.name
			put_noun(&cmd, last)
		case .Noun:
			put_noun(&cmd, word.name)
		}
	}

	// "give cat plate" — a recipient, then the thing. Said with a preposition
	// it would have been "give plate to cat", so make it that, and the game
	// only ever has to handle one shape.
	if cmd.prep == "" && cmd.noun != "" && cmd.noun2 != "" && is_dative(cmd.verb, vocab) {
		cmd.noun, cmd.noun2 = cmd.noun2, cmd.noun
		cmd.adj, cmd.adj2 = cmd.adj2, cmd.adj
		cmd.prep = "to"
	}
	return cmd, .None, ""
}

@(private = "file")
put_noun :: proc(cmd: ^Command, name: string) {
	if cmd.noun == "" {
		cmd.noun = name
	} else if cmd.noun2 == "" {
		cmd.noun2 = name
	} else if cmd.noun3 == "" {
		cmd.noun3 = name
	}
}

@(private = "file")
is_dative :: proc(verb: string, vocab: []Word) -> bool {
	if verb == "" do return false
	for v in vocab do if v.name == verb do return v.kind == .Verb_Dative
	return false
}

// Lower case, punctuation dropped, split on spaces.
@(private)
split_words :: proc(line: string) -> []string {
	// An apostrophe joins rather than splits: "don't" is "dont", the way
	// players type it either way, and "fairbank's" is "calloways". A curly
	// one (’) is the same apostrophe from a word processor.
	text, _ := strings.replace_all(line, "’", "'", context.temp_allocator)
	clean := make([dynamic]u8, 0, len(text), context.temp_allocator)
	for i in 0 ..< len(text) {
		c := text[i]
		switch c {
		case 'A' ..= 'Z':
			append(&clean, c + ('a' - 'A'))
		case 'a' ..= 'z', '0' ..= '9':
			append(&clean, c)
		case '\'':
		case:
			append(&clean, ' ')
		}
	}
	words := strings.fields(string(clean[:]), context.temp_allocator)
	return words
}

@(private = "file")
MAX_PHRASE :: 8

// Finds the vocabulary entry for the longest phrase (up to MAX_PHRASE words)
// at the start of `words`.
@(private)
match :: proc(words: []string, vocab: []Word, prefer: Word_Kind) -> (found: Word, used: int, ok: bool) {
	// Longest first, up to a whole sentence's worth: "i would have handed it
	// in" is one word to the game that wrote it.
	for n := min(MAX_PHRASE, len(words)); n >= 1; n -= 1 {
		phrase := strings.join(words[:n], " ", context.temp_allocator)
		for v in vocab {
			if !is_called(v, phrase) do continue
			if wanted(v.kind, prefer) do return v, n, true
			if !ok do found, used, ok = v, n, true
		}
		if ok do return
	}
	return
}

// Both kinds of verb answer to a preference for a verb.
@(private = "file")
wanted :: proc(kind, prefer: Word_Kind) -> bool {
	if kind == prefer do return true
	return prefer == .Verb && kind == .Verb_Dative
}

@(private)
is_called :: proc(w: Word, phrase: string) -> bool {
	if w.name == phrase do return true
	rest := w.synonyms
	for s in strings.split_iterator(&rest, ",") {
		// A synonym written with an apostrophe matches the way split_words
		// leaves one: "fairbank's index" is "calloways index".
		said := strings.trim_space(s)
		if strings.index_byte(said, '\'') >= 0 do said, _ = strings.remove_all(said, "'", context.temp_allocator)
		if said == phrase do return true
	}
	return false
}
