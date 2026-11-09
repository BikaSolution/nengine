package nengine

import "core:fmt"
import "core:strconv"
import "core:strings"

// The detective's notebook: what the player has written down, and nothing else.
//
// This is the back of it — what an entry is, where it is kept, how it is asked
// for and how it survives a save. Drawing the thing, turning its pages and
// deciding which tab is showing is the game's job, because a notebook is a
// prop and every game will want its own. What is shared is the filing.
//
//     TABS := [?]ne.Notebook_Tab {
//         {name = "people", title = "People"},
//         {name = "things", title = "Things"},
//         {name = "times",  title = "Times"},
//         {name = "questions", title = "Questions", no_proof = true},
//     }
//     w.notebook_tabs = TABS[:]
//
//     ne.note(&w, {id = "glasses", tab = "things",
//                  text = "One full, lipstick. One empty, flies in it."})
//     ne.note(&w, {id = "tod", tab = "times", minute = 24 * 60 + 10,
//                  source = "Dr Sherwood",
//                  text = "Between eleven and one, both, within minutes."})
//
//     for e in ne.notebook_entries(&w, "times", .Time) { ... draw it ... }
//
// **The rule this file exists to keep:** the notebook never knows more than the
// player does. There is no "important", no highlight, no hint and no solver.
// It takes what it is given, keeps it in the order it arrived, and will sort it
// by the clock if asked — and sorting a list the player already had is the
// whole of the trick. A notebook that pointed at the answer would be a
// different game, and a worse one.

// A tab, declared by the game. The engine keeps the declared order, so the
// frontend can page left and right without holding its own list.
Notebook_Tab :: struct {
	name:     string, // what an entry files itself under: "times"
	title:    string, // what the frontend puts at the top of the page: "Times"
	// What she wonders is not what she can show: an entry under a tab like
	// this ("questions") is refused as proof at the accusation (Not_Proof).
	no_proof: bool,
}

Entry :: struct {
	id:     string,      // stable, and the reason writing it twice writes it once
	tab:    string,      // which tab it files under
	text:   string,      // what it says, in the protagonist's own words
	source: string,      // who said it, or where it came from. May be empty
	minute: Maybe(int),  // the time the fact is ABOUT — see below — or nothing
	seq:    int,         // the order it was written down in. Set by `note`
	shown:  [dynamic]Shown, // who a thing was shown to, and what they said. See `shown`
	closed: bool,        // answered, and kept: drawn struck through. See close_note
}

// One line under a thing's entry: shown to somebody, and what came of it.
Shown :: struct {
	who:  string,
	text: string,
}

// `minute` is a Maybe rather than a plain int because most entries have no
// clock time at all, and an int's nothing is zero, which is a perfectly good
// time. A notebook that filed "I never asked when" under midnight would put it
// at the top of the one page where order is the evidence.
//
// **And `minute` is a time on the game's own clock, not a time of day.**
//
// A case that runs from four in the afternoon until dawn crosses midnight, and
// if minutes wrapped at 1440 then ten past midnight would sort before ten to
// twelve and the night would come apart in the one tab that has to hold it
// together. So the engine never interprets this number: it only ever compares
// two of them. Count from whenever the game likes and let it run past 1440;
// turning it back into "00:10" for the page is the frontend's business.

// Two entries that cannot both be right.
//
// The game declares these, because knowing that "I never go out after dark"
// disagrees with finding her outside the fence is knowing the case. What the
// engine does is notice when the player is holding both — and then say only
// that, with a mark against each. It never says which one is the lie, because
// it does not know and neither, yet, does the player.
Contradiction :: struct {
	a, b:  string, // two entry ids
	needs: string, // a flag condition before it may be noticed; "" is always
}

// How to order a page.
Entry_Sort :: enum {
	Found, // the order they were written down, which is how it was lived
	Time,  // by the clock. Entries with no time fall to the end, in found order
}

// --- Writing in it ---

// Writes an entry, if that id has not been written already. True the first
// time only, so a game can say something the first time and stay quiet after:
//
//     if ne.note(w, {id = "the_shoe", tab = "things", text = "One shoe..."}) {
//         ne.say(w, "You write it down.")
//     }
//
// Idempotent for the same reason awards are: a player who looks at the shoe
// four times has found one shoe, and a notebook with it in four times is a
// notebook nobody can read.
note :: proc(w: ^World, e: Entry) -> bool {
	if e.id == "" || noted(w, e.id) do return false
	fresh := Entry {
		id     = strings.clone(e.id),
		tab    = strings.clone(e.tab),
		text   = strings.clone(sanitise(e.text)),
		source = strings.clone(sanitise(e.source)),
		minute = e.minute,
		seq    = w.notebook_seq,
	}
	w.notebook_seq += 1
	append(&w.notebook, fresh)
	if w.note_sound != "" do play_sound(w, w.note_sound, 0.6)
	// A clue is progress (World.notes_tick): the first one a command finds
	// spends a tick.
	if w.notes_tick && !w.ticked do tick(w)
	return true
}

noted :: proc(w: ^World, id: string) -> bool {
	for e in w.notebook do if e.id == id do return true
	return false
}

// The entry itself, for a frontend that wants to draw one, and for anything
// that needs to check a player really is holding what they say they are.
notebook_entry :: proc(w: ^World, id: string) -> (Entry, bool) {
	for e in w.notebook do if e.id == id do return e, true
	return {}, false
}

// Rubs one out. For a fact that turns out to be wrong, and for tests, which
// have to be able to start again.
unnote :: proc(w: ^World, id: string) {
	for e, i in w.notebook {
		if e.id != id do continue
		entry_destroy(&w.notebook[i])
		ordered_remove(&w.notebook, i)
		return
	}
}

clear_notebook :: proc(w: ^World) {
	for &e in w.notebook do entry_destroy(&e)
	clear(&w.notebook)
	w.notebook_seq = 0
}

@(private)
entry_destroy :: proc(e: ^Entry) {
	delete(e.id)
	delete(e.tab)
	delete(e.text)
	delete(e.source)
	for s in e.shown {
		delete(s.who)
		delete(s.text)
	}
	delete(e.shown)
}

// Keeps a show under the thing's entry: who it was shown to, and what they
// said ("" for nothing). Once per person: showing the shoe to Moore twice
// is one line, and the first answer is the one kept. False if there is no
// entry by that id, or the person is already under it. Costs no tick: the
// show already did.
shown :: proc(w: ^World, entry_id, who, text: string) -> bool {
	for &e in w.notebook {
		if e.id != entry_id do continue
		for s in e.shown do if s.who == who do return false
		append(&e.shown, Shown{who = strings.clone(sanitise(who)), text = strings.clone(sanitise(text))})
		return true
	}
	return false
}

// A save line is `key value` to the end of the line, so a tab or a newline in
// the middle of a sentence would quietly eat everything after it. Written
// dialogue has neither on purpose; this makes sure of it anyway, because the
// day it does not is the day somebody loses a save and cannot say why.
@(private)
sanitise :: proc(s: string, allocator := context.temp_allocator) -> string {
	if strings.index_byte(s, '\t') < 0 && strings.index_byte(s, '\n') < 0 do return s
	out := strings.builder_make(allocator)
	for i in 0 ..< len(s) {
		strings.write_byte(&out, ' ' if s[i] == '\t' || s[i] == '\n' else s[i])
	}
	return strings.to_string(out)
}

// Strikes an entry through: a question that has been answered, a lead that
// went nowhere. It stays in the book, because what she once wondered is part
// of how she got here; the frontend draws it struck, and `open_only` leaves
// it out. False if there is no such entry.
close_note :: proc(w: ^World, id: string) -> bool {
	for &e in w.notebook {
		if e.id != id do continue
		e.closed = true
		return true
	}
	return false
}

note_closed :: proc(w: ^World, id: string) -> bool {
	for e in w.notebook do if e.id == id do return e.closed
	return false
}

// --- Reading it ---

// One page. `tab` empty means the whole book.
//
// The result is a fresh list in the temp allocator by default: the frontend is
// drawing a page this frame and has no business holding a pointer into the
// notebook while the game carries on writing in it.
notebook_entries :: proc(
	w: ^World,
	tab: string = "",
	sort: Entry_Sort = .Found,
	allocator := context.temp_allocator,
	open_only := false,
) -> []Entry {
	out := make([dynamic]Entry, allocator)
	for e in w.notebook {
		if open_only && e.closed do continue
		if tab == "" || e.tab == tab do append(&out, e)
	}
	if sort == .Time do sort_by_time(out[:])
	return out[:]
}

// Insertion sort: a page is a few dozen entries and this keeps equal times in
// the order they were found, which matters — two facts about the same minute
// should read in the order the player got them.
@(private)
sort_by_time :: proc(list: []Entry) {
	for i in 1 ..< len(list) {
		v := list[i]
		j := i - 1
		for j >= 0 && later(list[j], v) {
			list[j + 1] = list[j]
			j -= 1
		}
		list[j + 1] = v
	}
}

@(private)
later :: proc(a, b: Entry) -> bool {
	am, a_timed := a.minute.?
	bm, b_timed := b.minute.?
	// An entry with no time has not got a place on a clock, so it waits at the
	// back rather than pretending to be at midnight.
	if !a_timed && b_timed do return true
	if a_timed && !b_timed do return false
	if a_timed && b_timed && am != bm do return am > bm
	return a.seq > b.seq
}

notebook_count :: proc(w: ^World, tab: string = "") -> (n: int) {
	for e in w.notebook do if tab == "" || e.tab == tab do n += 1
	return
}

notebook_tab :: proc(w: ^World, name: string) -> (Notebook_Tab, bool) {
	for t in w.notebook_tabs do if t.name == name do return t, true
	return {}, false
}

// --- Dog-ears ---

// Every contradiction the player is currently holding both halves of.
//
// "Currently" matters: a contradiction can be declared with a `needs`, and one
// in this game is, because the notebook catching the killer's single lie in
// Act I would end the story on the boat. The player is taught early that
// dog-ears are reliable, and the one the book stays quiet about is the case.
notebook_dogears :: proc(w: ^World, allocator := context.temp_allocator) -> []Contradiction {
	out := make([dynamic]Contradiction, allocator)
	for c in w.contradictions {
		if !noted(w, c.a) || !noted(w, c.b) do continue
		if !condition_met(w, c.needs) do continue
		append(&out, c)
	}
	return out[:]
}

// Whether this entry is one half of something that does not add up — which is
// all the mark on the page says, and all it should say.
notebook_dogeared :: proc(w: ^World, id: string) -> bool {
	for c in w.contradictions {
		if c.a != id && c.b != id do continue
		if !noted(w, c.a) || !noted(w, c.b) do continue
		if condition_met(w, c.needs) do return true
	}
	return false
}

// --- The accusation ---
//
// The end of a mystery is a name and a reason to believe it. The game declares
// the questions, because how many bodies there are is the case; the engine
// keeps the answers and will say whether the evidence attached to one is
// something the player actually has.
//
//     QUESTIONS := [?]string{"Who killed Henry Fairbank?", "And Beatrice?"}
//     for q in QUESTIONS do ne.ask(&w, q)
//     ne.accuse(&w, 0, "beatrice", "glasses")
//
// Whether the name is the *right* name is not the engine's business. Being
// right and being able to show it are different things, and only the second
// one is a rule.

Accusation :: struct {
	question: string,
	name:     string, // the answer given, or empty
	support:  string, // an entry id offered as proof, or empty
}

ask :: proc(w: ^World, question: string) {
	append(&w.accusations, Accusation{question = strings.clone(question)})
}

// Why an answer was or was not taken.
Accuse_Result :: enum {
	Taken,
	No_Question, // there is no question by that number
	Not_Noted,   // the proof offered is not in the notebook
	Not_Proof,   // it is, but under a tab of things wondered, not things shown
}

// Records an answer. False if there is no such question, or if the evidence
// attached is not in the notebook — a player may name anyone, but may only
// point at something they wrote down, and not at a question she asked
// herself. accuse_why says which.
accuse :: proc(w: ^World, question: int, name, support: string) -> bool {
	return accuse_why(w, question, name, support) == .Taken
}

accuse_why :: proc(w: ^World, question: int, name, support: string) -> Accuse_Result {
	if question < 0 || question >= len(w.accusations) do return .No_Question
	if support != "" {
		e, ok := notebook_entry(w, support)
		if !ok do return .Not_Noted
		if tab, has := notebook_tab(w, e.tab); has && tab.no_proof do return .Not_Proof
	}
	a := &w.accusations[question]
	// Clone before freeing: the name given may be the one already there —
	// attaching evidence to an answer is answering it again with the same name.
	new_name, new_support := strings.clone(name), strings.clone(support)
	delete(a.name)
	delete(a.support)
	a.name, a.support = new_name, new_support
	return .Taken
}

accusation_supported :: proc(w: ^World, question: int) -> bool {
	if question < 0 || question >= len(w.accusations) do return false
	a := w.accusations[question]
	return a.name != "" && a.support != "" && noted(w, a.support)
}

clear_accusations :: proc(w: ^World) {
	for &a in w.accusations {
		delete(a.question)
		delete(a.name)
		delete(a.support)
	}
	clear(&w.accusations)
}

// --- Saving ---
//
// One line per entry, because a notebook is the one part of a save somebody
// might open and read. Fields are tab-separated and the text comes last, so it
// can have anything in it that a sentence can have.

@(private)
notebook_save :: proc(w: ^World, s: ^Save) {
	if len(w.notebook) == 0 do return
	save_put_int(s, "notes", len(w.notebook))
	for e, i in w.notebook {
		save_put(
			s,
			fmt.tprintf("note.%v", i),
			fmt.tprintf("%v\t%v\t%v\t%v\t%v", e.id, e.tab, minute_text(e.minute), e.source, e.text),
		)
		for sh, k in e.shown do save_put(s, fmt.tprintf("note.%v.shown.%v", i, k), fmt.tprintf("%v\t%v", sh.who, sh.text))
		if e.closed do save_put_int(s, fmt.tprintf("note.%v.closed", i), 1)
	}
	for a, i in w.accusations {
		if a.name == "" do continue
		save_put(s, fmt.tprintf("accuse.%v", i), fmt.tprintf("%v\t%v", a.name, a.support))
	}
}

// An entry with no time writes an empty field, which parses back as no time.
@(private)
minute_text :: proc(m: Maybe(int), allocator := context.temp_allocator) -> string {
	v, timed := m.?
	return fmt.aprintf("%v", v, allocator = allocator) if timed else ""
}

@(private)
notebook_load :: proc(w: ^World, s: ^Save) {
	clear_notebook(w)
	pen := w.note_sound // the whole book back at once is not writing
	w.note_sound = ""
	defer w.note_sound = pen
	n := save_int(s, "notes")
	for i in 0 ..< n {
		line := save_text(s, fmt.tprintf("note.%v", i))
		if line == "" do continue
		parts := strings.split(line, "\t", context.temp_allocator)
		if len(parts) < 5 do continue
		fresh := Entry{id = parts[0], tab = parts[1], source = parts[3], text = parts[4]}
		if v, ok := strconv.parse_int(parts[2]); ok do fresh.minute = v
		note(w, fresh)
		if save_int(s, fmt.tprintf("note.%v.closed", i)) == 1 do close_note(w, fresh.id)
		for k := 0; ; k += 1 {
			shown_line := save_text(s, fmt.tprintf("note.%v.shown.%v", i, k))
			if shown_line == "" do break
			sp := strings.split(shown_line, "\t", context.temp_allocator)
			shown(w, fresh.id, sp[0], sp[1] if len(sp) > 1 else "")
		}
	}
	for &a, i in w.accusations {
		line := save_text(s, fmt.tprintf("accuse.%v", i))
		delete(a.name)
		delete(a.support)
		a.name, a.support = "", ""
		if line == "" do continue
		parts := strings.split(line, "\t", context.temp_allocator)
		a.name = strings.clone(parts[0])
		if len(parts) > 1 do a.support = strings.clone(parts[1])
	}
}
