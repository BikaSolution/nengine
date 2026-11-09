package nengine

import "core:fmt"
import "core:strings"

// What people say when they are asked: ASK MOORE ABOUT THE KEY, SHOW THE SHOE
// TO MOORE. The lines are content, and content lives in files — a `.talk`
// file, one per game or one per person, which a writer can edit without
// touching a line of Odin:
//
//     # nengine talk
//     ask margaret herself
//     margaret: Sixty-six, widowed, one son, and an income that was arranged by men who are all dead.
//
//     ask margaret husband when=told_margaret_husband
//     margaret: He arranged things. That was his gift.
//
//     ask moore kink,fence,gap when=saw_kink tick action=moore_on_the_kink
//     ada: Forty yards behind the fuel store were re-hung uphill after the rains.
//     moore: (very long pause) Aye.
//     (He does not put the rifle down.)
//
// A topic is a header — `ask` (or `show`, which is the same) <who> <about,
// about...> — with an optional `when=` condition, `tick` if answering it
// yields and so costs time, and `action=` for what the game does about it
// (an award, a note, a door opening). The lines under it are `name: text`
// for somebody talking, and `(...)` for a stage direction. The name is looked
// up among `World.speakers`, so a portrait comes with it.
//
// **The last topic that matches wins**, so a file reads top to bottom as a
// person getting more forthcoming: the plain answer first, the one that
// needs a flag after it. Every topic sets `told_<who>_<about>` when it is
// said, and `retold_<who>_<about>` the second time, which is how "again" is
// written — `when=told_margaret_husband`. A
// tick is spent the first time a topic is told, never again.
//
// `answer(w, who, about)` says whichever topic fits, and is false if none
// does — then the game says something in its own voice. `about = "*"` in a
// file is anything else asked of that person.
Topic :: struct {
	who:    string,
	about:  []string,
	only:   string,
	tick:   bool,
	action: string,
	lines:  []Talk_Line,
	seen:   string, // a flag of its own: told once, ticked once
	show:   bool,   // a `show` header: a thing held out, not a question. See show_thing
}

// Reads a talk file into the world. The speakers must be set first: a line's
// name is resolved to a portrait here. False, and a reason, if it could not.
load_talk :: proc(w: ^World, path: string) -> (problem: string, ok: bool) {
	text, read := read_data_file(path)
	if !read do return fmt.tprintf("could not read %v", path), false
	// The text is the temp allocator's (read_data_file); every string kept
	// from it is cloned below.

	cur: ^Topic
	lines: [dynamic]Talk_Line
	finish :: proc(cur: ^Topic, lines: ^[dynamic]Talk_Line) {
		if cur == nil do return
		cur.lines = lines[:]
		lines^ = {}
	}
	for raw in data_lines(text) {
		l := parse_line(raw)
		if l.key == "ask" || l.key == "show" {
			finish(cur, &lines)
			if len(l.words) < 2 do return fmt.tprintf("%v: %q wants a person and a topic", path, raw), false
			t := Topic {
				who    = strings.clone(l.words[0]),
				only   = clone_field(l, "when"),
				action = clone_field(l, "action"),
				seen   = fmt.aprintf("topic_%v_%v", len(w.topics), l.words[0]),
				show   = l.key == "show",
			}
			for word in l.words[1:] {
				if word == "tick" {
					t.tick = true
					continue
				}
				abouts := make([dynamic]string)
				rest := word
				for a in strings.split_iterator(&rest, ",") do append(&abouts, strings.clone(a))
				t.about = abouts[:]
			}
			append(&w.topics, t)
			cur = &w.topics[len(w.topics) - 1]
			continue
		}
		if cur == nil do return fmt.tprintf("%v: a line before any topic: %q", path, raw), false
		append(&lines, talk_line(w, raw))
	}
	finish(cur, &lines)
	return "", true
}

@(private = "file")
clone_field :: proc(l: Line, name: string) -> string {
	if v, has := field(l, name); has do return strings.clone(v)
	return ""
}

// `moore: Aye.` or `(He does not answer.)`
@(private = "file")
talk_line :: proc(w: ^World, raw: string) -> Talk_Line {
	if strings.has_prefix(raw, "(") do return {who = nil, text = strings.clone(raw)}
	colon := strings.index_byte(raw, ':')
	if colon > 0 {
		name := strings.trim_space(raw[:colon])
		text := strings.trim_space(raw[colon + 1:])
		for s in w.speakers do if strings.equal_fold(s.name, name) do return {who = s, text = strings.clone(text)}
		// Nobody by that name: keep the name on the line, so it still reads.
		return {who = nil, text = fmt.aprintf("%v: %v", name, text)}
	}
	return {who = nil, text = strings.clone(raw)}
}

// The topic that answers this, if any. `shows_only` is for show_thing: only
// the `show` headers; `asks_only` is for answer: never them.
topic_for :: proc(w: ^World, who, about: string, shows_only := false, asks_only := false) -> ^Topic {
	named, anything: ^Topic
	for &t in w.topics {
		if t.who != who || !condition_met(w, t.only) do continue
		if shows_only && !t.show do continue
		if asks_only && t.show do continue
		for a in t.about {
			if a == about do named = &t                     // the last one that fits
			if a == "*" && anything == nil do anything = &t // the first catch-all
		}
	}
	return named if named != nil else anything
}

// Says the topic that answers ASK <who> ABOUT <about>. False if nobody has a
// line for it. A `show` topic is a thing held out, not a question: asking
// about the shoe is not showing it, so `answer` never says one (show_thing
// does, with the shoe in her hand).
answer :: proc(w: ^World, who, about: string) -> bool {
	t := topic_for(w, who, about, asks_only = true)
	if t == nil do return false
	// Answered by the person's `*` (or asked for it): nothing written for
	// this word. A gap, for the play log (playlog.odin).
	named := false
	for a in t.about do if a == about && a != "*" do named = true
	if !named do log_gap(w, "talk-shrug")
	tell_topic(w, t, who, about)
	return true
}

@(private = "file")
tell_topic :: proc(w: ^World, t: ^Topic, who, about: string, free := false) {
	first := !flag(w, t.seen)
	set_flag(w, t.seen, true)
	// told_<who>_<about> the first time it comes up, retold_ the second: which
	// is how a file writes "again", and "a third time, quietly".
	told := fmt.tprintf("told_%v_%v", who, about)
	if flag(w, told) do set_flag(w, fmt.tprintf("retold_%v_%v", who, about), true)
	set_flag(w, told, true)
	if first && t.tick && !free do tick(w)
	if t.action != "" && w.on_topic != nil do w.on_topic(w, t.action)
	if len(t.lines) > 0 do begin_conversation(w, &w.topic_talk, t.lines)
}

// --- Showing a thing to somebody ---
//
// SHOW THE SHOE TO MOORE. In a talk file it is a `show` header:
//
//     show moore shoe tick action=moore_on_the_shoe
//     moore: (he does not take it) Otter had that. Two hours, I said.
//
//     show moore *
//     moore: (a look at it, and back at you) No.
//
// A thing must be in her hands (the flag `carrying_shoe`), or an object here
// marked `show=true` (a photograph on a wall), to be shown at all. The `*`
// topic is the person's shrug, and a shrug never costs a tick, whatever the
// file says. Somebody not in the room is Not_Here, and somebody dead (a
// Speaker with `gone` set) is Gone, so both are lines of the game's and
// never a parser error.
Answer_Kind :: enum {
	Answered,    // a line written for this thing
	Shrug,       // the person's `*`: they had nothing to say about it
	None,        // no `show` topic for them at all
	Not_Here,    // they are not in the room
	Gone,        // they are dead
	Not_Carried, // she is not holding it, and it is not a showable thing here
}

// The speaker a talk file's lower-case name means: "moore" for "Moore",
// "hargreave" for "Mrs Hargreave".
speaker_named :: proc(w: ^World, who: string) -> ^Speaker {
	for s in w.speakers {
		if strings.equal_fold(s.name, who) do return s
		if sp := strings.last_index_byte(s.name, ' '); sp >= 0 && strings.equal_fold(s.name[sp + 1:], who) do return s
	}
	return nil
}

show_thing :: proc(w: ^World, who, thing: string) -> Answer_Kind {
	if s := speaker_named(w, who); s != nil && s.gone do return .Gone
	scene := current_scene(w)
	if object_here(scene, who) == nil do return .Not_Here
	held := flag(w, fmt.tprintf("carrying_%v", thing))
	if !held {
		o := object_here(scene, thing)
		if o == nil || !o.show do return .Not_Carried
	}
	t := topic_for(w, who, thing, shows_only = true)
	if t == nil do return .None
	shrug := true
	for a in t.about do if a == thing do shrug = false
	if shrug do log_gap(w, "show-shrug")
	tell_topic(w, t, who, thing, free = shrug)
	return .Shrug if shrug else .Answered
}

// Asks the player something, and the next thing they type is the answer — see
// World.on_answer. For a choice the parser has no other way to make: "I won't
// write the money down", or everything goes in the book.
expect_answer :: proc(w: ^World, question: string) {
	w.pending = question
}

@(private)
topics_destroy :: proc(w: ^World) {
	for t in w.topics {
		delete(t.who)
		delete(t.only)
		delete(t.action)
		delete(t.seen)
		for a in t.about do delete(a)
		delete(t.about)
		for l in t.lines do delete(l.text)
		delete(t.lines)
	}
	delete(w.topics)
	w.topics = nil
}
