package cutscene

import ne "../../../"
import ui "../../ui"
import "core:fmt"
import "core:strings"

// Changing the cut: undo, adding, removing, and what a typed value does.
// Undo is the same trick as everywhere else in the tools: a step is the text
// the file would be saved as, so undo can only ever land on something the
// format can express.

mark :: proc(e: ^Editor) {
	ui.history_mark(&e.history, doc_text(&e.doc))
}

// After any change: the file needs saving, the panel stops drawing what it
// had, and art nothing shows any more is let go on the next frame.
changed :: proc(e: ^Editor) {
	e.dirty = true
	e.gen += 1
	e.sweep_at = e.frame + 1
	clamp_selection(e)
}

clamp_selection :: proc(e: ^Editor) {
	switch e.sel.kind {
	case .Cut:
	case .Cast: if e.sel.i < 0 || e.sel.i >= len(e.doc.people) do e.sel = {}
	case .Cue:  if e.sel.i < 0 || e.sel.i >= len(e.doc.cues) do e.sel = {}
	}
	if e.who >= len(e.doc.people) do e.who = len(e.doc.people) - 1
}

step_back :: proc(e: ^Editor, status: ^ui.Status, forward: bool) {
	now := doc_text(&e.doc)
	step: string
	ok: bool
	if forward {
		step, ok = ui.history_redo(&e.history, now)
	} else {
		step, ok = ui.history_undo(&e.history, now)
	}
	if !ok {
		ui.say(status, "nothing to redo" if forward else "nothing to undo")
		return
	}
	defer ui.history_done(step)
	doc_set_text_all(&e.doc, step)
	e.drag = .None
	changed(e)
	ui.say(status, "redone" if forward else "undone")
}

// Who a new cue is for: the person selected, or whoever the selected cue is
// aimed at; "" for the nobody row.
@(private = "file")
current_who :: proc(e: ^Editor) -> string {
	switch e.sel.kind {
	case .Cast: return e.doc.people[e.sel.i].m.name
	case .Cue:  return e.doc.cues[e.sel.i].q.who
	case .Cut:
	}
	if e.who >= 0 && e.who < len(e.doc.people) do return e.doc.people[e.who].m.name
	return ""
}

// A new cue at the playhead, for whoever is selected: a line of dialogue for
// a person, narration for nobody. What kind it is is a click in the panel.
add_cue :: proc(e: ^Editor, status: ^ui.Status) {
	who := strings.clone(current_who(e), context.temp_allocator)
	q := ne.Cue{at = f32(int(e.t * 10 + 0.5)) / 10, who = who, action = .Say, text = "..."}
	if who == "" do q.action = .Narrate
	// Somewhere to walk to, if it is turned into a walk: where they are.
	if m := doc_member(&e.doc, who); m >= 0 do q.to = snap(person_at(e, m, e.t))
	mark(e)
	i := doc_add_cue(&e.doc, q)
	changed(e)
	e.sel = {.Cue, i}
	ui.say(status, "cue at %.1fs: say what it is in the panel", q.at)
}

remove_selected :: proc(e: ^Editor, status: ^ui.Status) {
	switch e.sel.kind {
	case .Cut:
		ui.say(status, "select a cue or somebody to remove")
	case .Cue:
		mark(e)
		doc_remove_cue(&e.doc, e.sel.i)
		e.sel = {}
		changed(e)
		ui.say(status, "removed the cue")
	case .Cast:
		name := strings.clone(e.doc.people[e.sel.i].m.name, context.temp_allocator)
		mark(e)
		n := doc_remove_cast(&e.doc, e.sel.i)
		e.sel = {}
		changed(e)
		ui.say(status, "removed %v and %v cue%v (^Z puts them back)", name, n, "" if n == 1 else "s")
	}
}

// --- Somebody new ---

start_adding :: proc(e: ^Editor) {
	if e.adding {
		stop_adding(e)
		return
	}
	e.adding = true
	e.sel = {}
	ui.reset_string(&e.add_name, free_name(e, "person"))
	ui.text_input_focus(&e.text, "add.name", e.add_name)
}

stop_adding :: proc(e: ^Editor) {
	e.adding = false
	if e.text.focus == "add.name" do ui.text_input_blur(&e.text)
}

// The name has been typed: they go in where they stand and facing their own
// way, and the character they wear is asked for at once (cancel it for
// somebody the room has, or the player).
named :: proc(e: ^Editor, typed: string, status: ^ui.Status) {
	name := clean_name(typed)
	if name == "" {
		ui.say(status, "a name, one word: what the cues call them")
		ui.text_input_focus(&e.text, "add.name", e.add_name)
		return
	}
	if doc_member(&e.doc, name) >= 0 {
		ui.say(status, "%v is in the cast already", name)
		ui.text_input_focus(&e.text, "add.name", name)
		return
	}
	mark(e)
	i := doc_add_cast(&e.doc, name)
	changed(e)
	stop_adding(e)
	e.sel = {.Cast, i}
	e.who = i
	ui.say(status, "added %v: choose what they wear, or cancel for whoever the room has", name)
	ask_char(e, i)
}

// A name nobody in the cast has: person, person2...
@(private = "file")
free_name :: proc(e: ^Editor, want: string) -> string {
	if doc_member(&e.doc, want) < 0 do return want
	for n in 2 ..< 100 {
		try := fmt.tprintf("%v%v", want, n)
		if doc_member(&e.doc, try) < 0 do return try
	}
	return want
}

// Names are one word: what the cues call them.
clean_name :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in strings.trim_space(s) {
		switch {
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9', c == '_': strings.write_rune(&b, c)
		case c >= 'A' && c <= 'Z':                                strings.write_rune(&b, c + 32)
		case c == ' ' || c == '-':                                strings.write_byte(&b, '_')
		}
	}
	return strings.to_string(b)
}

// Whole pixels: the file holds whole numbers, and a dragged position that
// didn't round would rewrite the file with noise every time it was opened.
snap :: proc(p: [2]f32) -> [2]f32 {
	return {f32(int(p.x + (0.5 if p.x >= 0 else -0.5))), f32(int(p.y + (0.5 if p.y >= 0 else -0.5)))}
}

// Used by the browser when you name a new one.
write_blank :: proc(path, name: string) -> bool {
	c := ne.cutscene_new(name)
	defer ne.cutscene_destroy(&c)
	append(&c.cues, ne.Cue{at = 4, who = strings.clone(""), action = .End, text = strings.clone("")})
	return ne.save_cutscene(&c, path)
}

// --- What a typed value does ---

// What a field is for: where its value goes when it is committed. Kept for
// the field being typed into (Editor.focus), so a click somewhere else can
// commit it first thing on the next frame, before what it clicked has moved
// the lines about.
Target_Kind :: enum {
	None,
	Add_Name,  // somebody being added
	Cut_Name,  // the `cut` line's name
	Cast_Name, // cast member `i`, and every cue aimed at them
	Cast_At,   // where cast member `i` starts, as X,Y
	Cue_Time,  // cue `i`'s time
	Cue_Text,  // what cue `i` says (say, think, narrate)
	Cue_To,    // where walk_to cue `i` goes, as X,Y
	Cue_Lines, // line cue `i`'s lines: 3, or 3-5
	Cue_Node,  // line cue `i`'s node
	Cue_Part,  // play cue `i`'s part, typed
	Cue_Times, // play cue `i`: how many times
	Cue_Secs,  // play cue `i`: for how long; a shake: how long
}

Target :: struct {
	kind: Target_Kind,
	i:    int,
}

commit :: proc(e: ^Editor, t: Target, value: string, status: ^ui.Status) {
	if t.kind == .None do return
	if t.kind == .Add_Name {
		named(e, value, status)
		return
	}
	v := strings.trim_space(value)
	before := strings.clone(doc_text(&e.doc), context.temp_allocator)
	mark(e)
	d := &e.doc
	cue := t.i >= 0 && t.i < len(d.cues)
	q: ne.Cue
	if cue do q = d.cues[t.i].q
	switch t.kind {
	case .None, .Add_Name:
	case .Cut_Name:
		if n := clean_name(v); n != "" do doc_set_head(d, n, d.scene)
	case .Cast_Name:
		if n := clean_name(v); n != "" {
			if doc_member(d, n) >= 0 && n != d.people[t.i].m.name do ui.say(status, "%v is in the cast already", n)
			else do doc_rename_cast(d, t.i, n)
		}
	case .Cast_At:
		if p, ok := ne.parse_vec2(v); ok do doc_set_cast_field(d, t.i, "at", fmt.tprintf("%v,%v", int(p.x), int(p.y)))
	case .Cue_Time:
		if !cue do break
		if secs, ok := parse_secs(v); ok {
			i := doc_set_cue_time(d, t.i, secs)
			if e.sel.kind == .Cue do e.sel.i = i
		}
	case .Cue_Text:
		if !cue do break
		q.text = v if v != "" else "..."
		doc_set_cue(d, t.i, q)
	case .Cue_To:
		if !cue do break
		if p, ok := ne.parse_vec2(v); ok {
			q.to = snap(p)
			doc_set_cue(d, t.i, q)
		}
	case .Cue_Lines:
		if !cue do break
		if span, ok := ne.parse_line_range(v); ok {
			q.lines = span
			doc_set_cue(d, t.i, q)
		} else {
			ui.say(status, "lines are a number, or two with a dash: 3, 3-5")
		}
	case .Cue_Node:
		if !cue do break
		if w := one_word(v); w != "" {
			q.text = w
			doc_set_cue(d, t.i, q)
		}
	case .Cue_Part:
		if !cue do break
		if w := one_word(v); w != "" {
			q.text = w
			doc_set_cue(d, t.i, q)
		}
	case .Cue_Times:
		if !cue do break
		n := ui.to_int(v, q.times)
		if n >= 1 {
			q.times = n
			doc_set_cue(d, t.i, q)
		}
	case .Cue_Secs:
		if !cue do break
		if secs, ok := parse_secs(v); ok {
			q.amount = secs
			if q.action == .Play do q.times = 0
			doc_set_cue(d, t.i, q)
		}
	}
	if doc_text(&e.doc) == before {
		ui.history_drop_last(&e.history)
		return
	}
	changed(e)
}

// Seconds, as typed: `4.5`, `4.5s`. Never before the start.
parse_secs :: proc(s: string) -> (f32, bool) {
	t := strings.trim_suffix(strings.trim_space(s), "s")
	v := ui.to_f32(t, -1)
	if v < 0 do return 0, false
	return v, true
}

@(private = "file")
one_word :: proc(s: string) -> string {
	f := strings.fields(s, context.temp_allocator)
	return f[0] if len(f) > 0 else ""
}
