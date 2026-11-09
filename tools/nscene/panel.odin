package main

import ne "../../"
import ac "../assetcache"
import ui "../ui"
import "core:fmt"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

// The panel down the right: everything about whatever is selected, every
// field of its line and every line that belongs to it, each one editable
// where it is shown. With nothing selected it is the room: its descriptions,
// backdrop, sounds and floor, and a list of what is in it.
//
// A field shows the value as the file has it — `pos 407,488`,
// `block box:80,20,0,-10` — because that is what you would type, and what
// you will read in the file afterwards. Where a value is one of a few words
// (depth, facing, a peep's kind) or on/off, it is a row of chips instead.

// What a field is for: where its value goes when it is committed. Kept for
// the field being typed into (Scene_Editor.focus), so a click somewhere else
// can commit it first thing on the next frame, before anything it clicked
// has moved the lines about.
Target_Kind :: enum {
	None,
	Add_Name,  // the name of something being added
	Field,     // a `key=value` on line `line`
	Head,      // plain word `i` of line `line`
	Line_Text, // the free text at the end of line `line`
	Obj_Name,  // object `i`, and every line that belongs to it
	Obj_Text,  // object `i`'s `text` line, made if it has none
	Exit_Name, // exit `i`, and its `shut` lines
	Shut,      // what exit `i` says when shut
	Step,      // a `step` line: everything after the name
	Room_Word, // a one-word room line: `scene`, `bg`, `footstep`
	Corner,    // corner `i` of the floor, as X,Y
	Side_Shut, // what side `i` says when its gate is shut
}

Target :: struct {
	kind:   Target_Kind,
	line:   int,
	i:      int,
	name:   [32]u8,
	name_n: int,
}

target :: proc(kind: Target_Kind, line := -1, i := 0, name := "") -> (t: Target) {
	t.kind, t.line, t.i = kind, line, i
	t.name_n = copy(t.name[:], name)
	return
}

@(private = "file")
target_name :: proc(t: ^Target) -> string {
	return string(t.name[:t.name_n])
}

// Puts a committed value where it belongs. One undo step, and none at all if
// the file came out the same.
commit :: proc(e: ^Scene_Editor, t: Target, value: string, status: ^ui.Status = nil) {
	t := t
	if t.kind == .None do return
	if t.kind == .Add_Name {
		if status != nil do named(e, value, status)
		return
	}
	before := strings.clone(doc_text(&e.doc), context.temp_allocator)
	mark(e)
	d := &e.doc
	v := strings.trim_space(value)
	switch t.kind {
	case .None, .Add_Name:
	case .Field:
		doc_set_field(d, t.line, target_name(&t), strings.join(strings.fields(v, context.temp_allocator), "_", context.temp_allocator) if target_name(&t) != "when" else strings.join(strings.fields(v, context.temp_allocator), "", context.temp_allocator))
	case .Head:
		word := clean_name(v) if t.i == 0 else strings.join(strings.fields(v, context.temp_allocator), "_", context.temp_allocator)
		if word != "" do doc_set_head(d, t.line, t.i, word)
	case .Line_Text:
		doc_set_line_text(d, t.line, v)
	case .Obj_Name:
		doc_rename_object(d, t.i, v)
	case .Obj_Text:
		doc_set_object_text(d, t.i, v)
	case .Exit_Name:
		doc_rename_exit(d, t.i, v)
	case .Shut:
		doc_set_shut(d, t.i, v)
	case .Side_Shut:
		doc_set_side_shut(d, t.i, v)
	case .Step:
		if v != "" && t.line >= 0 && t.line < len(d.lines) {
			name := doc_head(d, t.line, 0)
			doc_replace(d, t.line, fmt.tprintf("step %v %v", name, v))
		}
	case .Room_Word:
		doc_set_room_word(d, target_name(&t), v)
	case .Corner:
		if q, ok := ne.parse_vec2(v); ok && t.i < len(d.walk) {
			pts := make([dynamic][2]f32, context.temp_allocator)
			append(&pts, ..d.walk[:])
			pts[t.i] = q
			doc_set_walk(d, pts[:])
		}
	}
	if doc_text(&e.doc) == before {
		ui.history_drop_last(&e.history)
		return
	}
	changed(e)
	if t.kind == .Room_Word do room_size(e)
}

// --- Laying the panel out ---

@(private = "file")
Lay :: struct {
	e:      ^Scene_Editor,
	status: ^ui.Status,
	r:      rl.Rectangle, // the panel
	x, y, w: f32,
	gen:    int, // e.gen as drawing began: once it moves, what is cached is stale
}

LABEL_W :: f32(74)
ROW :: f32(24)

@(private = "file")
stale :: proc(l: ^Lay) -> bool {
	return l.e.gen != l.gen
}

// Whether a row at the current y, `h` tall, can be seen and so clicked.
@(private = "file")
vis :: proc(l: ^Lay, h: f32) -> bool {
	return l.y + h > l.r.y && l.y < l.r.y + l.r.height
}

@(private = "file")
gap :: proc(l: ^Lay, h: f32 = 6) {
	l.y += h
}

@(private = "file")
heading :: proc(l: ^Lay, text: string, ink := ui.GOLD) {
	gap(l, 4)
	ui.label(i32(l.x), i32(l.y), text, ink, ui.SMALL)
	l.y += 18
}

@(private = "file")
rule :: proc(l: ^Lay) {
	gap(l, 4)
	ui.hline(i32(l.x), i32(l.y), i32(l.w))
	gap(l, 8)
}

// Prose that is read, not edited: the comments above a line, a hint.
@(private = "file")
note :: proc(l: ^Lay, text: string, ink := rl.Color{120, 120, 136, 255}) {
	for row in ui.text_rows(text, l.w) {
		ui.label(i32(l.x), i32(l.y), text[row.start:row.end], ink, ui.SMALL)
		l.y += 16
	}
}

// A field with its name to the left. Returns true on the frame it commits.
@(private = "file")
field :: proc(l: ^Lay, label, id, value: string, t: Target, ink := ui.DIM) -> bool {
	e := l.e
	focused := e.text.focus == id
	defer l.y += ROW + 4
	if !vis(l, ROW) && !focused do return false
	ui.label(i32(l.x), i32(l.y) + 5, ui.ellipsize(label, LABEL_W - 6, ui.SMALL), ink, ui.SMALL)
	v, done := ui.text_field(&e.text, {l.x + LABEL_W, l.y, l.w - LABEL_W, ROW}, id, value)
	if e.text.focus == id do e.focus = t
	if done {
		commit(e, t, v, l.status)
		return true
	}
	return false
}

// A field whose value is chosen from the game — a sound, a room — with a
// button that goes to look for it. Typing into it still works.
Ask_Kind :: enum {
	Sound,
	Room,
}

@(private = "file")
asked_field :: proc(l: ^Lay, label, id, value: string, t: Target, kind: Ask_Kind) {
	e := l.e
	focused := e.text.focus == id
	defer l.y += ROW + 4
	if !vis(l, ROW) && !focused do return
	bw := f32(72)
	ui.label(i32(l.x), i32(l.y) + 5, ui.ellipsize(label, LABEL_W - 6, ui.SMALL), ui.DIM, ui.SMALL)
	v, done := ui.text_field(&e.text, {l.x + LABEL_W, l.y, l.w - LABEL_W - bw - 4, ROW}, id, value)
	if e.text.focus == id do e.focus = t
	if done {
		commit(e, t, v, l.status)
		return
	}
	text := "Sound..." if kind == .Sound else "Room..."
	if ui.button({l.x + l.w - bw, l.y, bw, ROW}, text, value == "") {
		if kind == .Sound do ask_sound(e, t, value)
		else do ask_room(e, t, value)
	}
}

// Two short fields side by side, each with its name: with= and anim= on an
// interaction, which are usually empty and need not take a row each.
@(private = "file")
field_pair :: proc(l: ^Lay, line: int, a, b: string) {
	e := l.e
	d := &e.doc
	half := (l.w - 6) / 2
	lw := f32(44)
	ids := [2]string{lid(line, a), lid(line, b)}
	names := [2]string{a, b}
	focused := e.text.focus == ids[0] || e.text.focus == ids[1]
	defer l.y += ROW + 4
	if !vis(l, ROW) && !focused do return
	for n in 0 ..< 2 {
		x := l.x + f32(n) * (half + 6)
		ui.label(i32(x), i32(l.y) + 5, names[n], ui.DIM, ui.SMALL)
		v, done := ui.text_field(&e.text, {x + lw, l.y, half - lw, ROW}, ids[n], doc_field(d, line, names[n]))
		if e.text.focus == ids[n] do e.focus = target(.Field, line, name = names[n])
		if done {
			commit(e, target(.Field, line, name = names[n]), v, l.status)
			return
		}
	}
}

// The comments straight above a line, as one paragraph.
@(private = "file")
notes :: proc(l: ^Lay, line: int) {
	above := doc_notes_above(&l.e.doc, line)
	if len(above) == 0 do return
	note(l, strings.join(above, " ", context.temp_allocator))
}

// Prose: a label over a box the width of the panel, as tall as the text.
@(private = "file")
prose :: proc(l: ^Lay, label, id, value: string, t: Target) -> bool {
	e := l.e
	if label != "" {
		ui.label(i32(l.x), i32(l.y), label, ui.DIM, ui.SMALL)
		l.y += 17
	}
	h := ui.text_area_height(&e.text, id, value, l.w, 2)
	defer l.y += h + 4
	if !vis(l, h) && e.text.focus != id do return false
	v, done, _ := ui.text_area(&e.text, l.x, l.y, l.w, id, value, 2)
	if e.text.focus == id do e.focus = t
	if done {
		commit(e, t, v, l.status)
		return true
	}
	return false
}

// One of a few words, as chips. Returns the word clicked.
@(private = "file")
choice :: proc(l: ^Lay, label: string, options: []string, current: string) -> (picked: string, ok: bool) {
	ui.label(i32(l.x), i32(l.y) + 5, label, ui.DIM, ui.SMALL)
	x := l.x + LABEL_W
	for o in options {
		w := f32(ui.measure(o, ui.SMALL) + 14)
		if x + w > l.x + l.w {
			x = l.x + LABEL_W
			l.y += ROW + 2
		}
		if vis(l, ROW) && ui.chip({x, l.y, w, ROW - 2}, o, o == current) {
			picked, ok = o, true
		}
		x += w + 3
	}
	l.y += ROW + 4
	return
}

@(private = "file")
toggle :: proc(l: ^Lay, label: string, on: bool) -> bool {
	_, clicked := choice(l, label, {"yes" if on else "no"}, "yes" if on else "")
	return clicked
}

// A row of small buttons along the right: up, down, remove. Returns which.
@(private = "file")
Row_Act :: enum {
	None,
	Up,
	Down,
	Remove,
}

@(private = "file")
row_buttons :: proc(l: ^Lay, y: f32, first, last: bool) -> Row_Act {
	if !(y + ROW > l.r.y && y < l.r.y + l.r.height) do return .None
	bw := f32(26)
	x := l.x + l.w - bw * 3 - 6
	act := Row_Act.None
	if !first && ui.button({x, y, bw, 20}, "up") do act = .Up
	if !last && ui.button({x + bw + 3, y, bw, 20}, "dn") do act = .Down
	if ui.button({x + (bw + 3) * 2, y, bw, 20}, "x") do act = .Remove
	return act
}

@(private = "file")
button :: proc(l: ^Lay, x, w: f32, text: string, active := false) -> bool {
	if !vis(l, ROW) do return false
	return ui.button({x, l.y, w, ROW - 2}, text, active)
}

@(private = "file")
lid :: proc(line: int, name: string) -> string {
	return fmt.tprintf("L%v.%v", line, name)
}

// --- The panel ---

draw_panel :: proc(e: ^Scene_Editor, r: rl.Rectangle, status: ^ui.Status) {
	ui.panel(r)
	ui.scroll_wheel(&e.scroll, r, 48, e.panel_h + 24)
	e.scroll = ui.scroll_clamp(e.scroll, e.panel_h + 24, r.height)
	rl.BeginScissorMode(i32(r.x), i32(r.y), i32(r.width), i32(r.height))
	l := Lay{e = e, status = status, r = r, x = r.x + 10, w = r.width - 24, y = r.y + 8 - e.scroll, gen = e.gen}
	top := l.y
	defer {
		rl.EndScissorMode()
		if !stale(&l) do e.panel_h = l.y - top
		ui.scrollbar(r, e.scroll, e.panel_h + 24)
	}

	if e.adding != .None {
		adding_box(&l)
		rule(&l)
	}
	switch e.sel.kind {
	case .Room:    room_panel(&l)
	case .Object:  object_panel(&l, e.sel.i)
	case .Exit:    exit_panel(&l, e.sel.i)
	case .Trigger: trigger_panel(&l, e.sel.i)
	case .Scenery: scenery_panel(&l, e.sel.i)
	case .Window:  window_panel(&l, e.sel.i)
	case .Corner:  corner_panel(&l, e.sel.i)
	case .Side:    side_panel(&l, e.sel.i)
	}
}

@(private = "file")
adding_box :: proc(l: ^Lay) {
	e := l.e
	heading(l, fmt.tprintf("NEW %v", strings.to_upper(ADD_LABELS[e.adding], context.temp_allocator)))
	if !e.placing {
		note(l, "its name: one word, the noun the parser will know it by")
		gap(l, 2)
		v, done := ui.text_field(&e.text, {l.x, l.y, l.w - 70, ROW}, "add.name", e.add_name)
		if e.text.focus == "add.name" do e.focus = target(.Add_Name)
		if !done && ui.button({l.x + l.w - 64, l.y, 64, ROW}, "next") {
			v, done = e.add_name, true
		}
		l.y += ROW + 6
		if done do named(e, v, l.status)
		return
	}
	switch e.adding {
	case .Exit, .Trigger: note(l, fmt.tprintf("drag out where %v is, in the room", e.add_name), ui.INK)
	case .Window: note(l, fmt.tprintf("drag out the glass of %v, in the room", e.add_name), ui.INK)
	case .Side: note(l, "drag along the edge of the floor where the walk band crosses it: along the back or the front for north or south, up a side for east or west", ui.INK)
	case .None, .Object, .Person, .Peep, .Scenery: note(l, fmt.tprintf("click where %v stands, in the room", e.add_name), ui.INK)
	}
	gap(l, 2)
	if button(l, l.x, 80, "cancel") do stop_adding(e)
	l.y += ROW
}

// --- The room ---

@(private = "file")
room_panel :: proc(l: ^Lay) {
	e := l.e
	d := &e.doc
	heading(l, "ROOM")
	name := doc_head(d, d.scene, 0) if d.scene >= 0 else ""
	field(l, "name", "room.name", name, target(.Room_Word, name = "scene"))
	if stale(l) do return

	// The backdrop: its name, a look at it in this light, and the way to
	// choose another.
	bg := doc_head(d, d.bg, 0) if d.bg >= 0 else ""
	ui.label(i32(l.x), i32(l.y) + 5, "backdrop", ui.DIM, ui.SMALL)
	ui.label(i32(l.x + LABEL_W), i32(l.y) + 5, ui.ellipsize(bg if bg != "" else "none", l.w - LABEL_W - 100, ui.SMALL), ui.INK if bg != "" else ui.DIM, ui.SMALL)
	if button(l, l.x + l.w - 92, 92, "Backdrop...", bg == "") do ask_backdrop(e)
	l.y += ROW + 4
	if bg != "" {
		s, painted := ac.art_lit(&e.art, bg, e.light, images = true)
		if s.texture.id != 0 {
			h := l.w * f32(s.frame_h) / f32(s.frame_w)
			if vis(l, h) do ne.draw_sprite_pro(s, 0, {l.x, l.y, l.w, h})
			rl.DrawRectangleLinesEx({l.x, l.y, l.w, h}, 1, ui.EDGE)
			l.y += h + 4
		}
		lights := ac.painted_lights(&e.art.index, bg, images = true)
		names := [ne.Light]string{.Day = "day", .Sunset = "sunset", .Night = "night", .Sunrise = "sunrise"}
		b := strings.builder_make(context.temp_allocator)
		for li in ne.Light do if li in lights do fmt.sbprintf(&b, "%v ", names[li])
		note(l, fmt.tprintf("painted for %v", strings.trim_space(strings.to_string(b))))
		note(l, fmt.tprintf("shown %v%v", names[e.light], "" if painted else ", borrowed from another light"))
	}
	gap(l)
	if toggle(l, "indoors", d.indoors >= 0) {
		mark(e)
		doc_set_indoors(d, d.indoors < 0)
		changed(e)
	}
	if stale(l) do return
	asked_field(l, "footstep", "room.footstep", doc_head(d, d.footstep, 0) if d.footstep >= 0 else "", target(.Room_Word, name = "footstep"), .Sound)
	if stale(l) do return

	// The room as a set of flags has it (flags.odin).
	rule(l)
	flags_box(l)
	if stale(l) do return

	// What LOOK says: the plain one, and the ones for a condition. The first
	// whose condition ac.holds is the one the room reads.
	rule(l)
	heading(l, fmt.tprintf("DESCRIPTIONS  %v", len(d.descs)))
	reads := read_desc(e)
	for line, n in d.descs {
		y0 := l.y
		switch row_buttons(l, y0, n == 0, n == len(d.descs) - 1) {
		case .None:
		case .Up:     swap_lines(e, line, d.descs[n - 1]); return
		case .Down:   swap_lines(e, line, d.descs[n + 1]); return
		case .Remove: remove_line(e, line); return
		}
		ui.label(i32(l.x), i32(l.y) + 4, fmt.tprintf("#%v", n + 1), ui.DIM, ui.SMALL)
		if e.flags.mode != .Off {
			read := line == reads
			ui.label(i32(l.x) + 30, i32(l.y) + 4, "the room reads this one" if read else ("not under these flags" if !ac.holds(&e.flags, doc_field(d, line, "when")) else "not read: another comes first"), ui.GOLD if read else ui.DIM, ui.SMALL)
		}
		l.y += 22
		field(l, "when", lid(line, "when"), doc_field(d, line, "when"), target(.Field, line, name = "when"))
		if stale(l) do return
		prose(l, "", lid(line, "text"), doc_line_text(d, line), target(.Line_Text, line))
		if stale(l) do return
		gap(l, 4)
	}
	if button(l, l.x, 130, "+ description") {
		mark(e)
		doc_add_desc(d, "", "What the room looks like.")
		changed(e)
		return
	}
	l.y += ROW + 4

	rule(l)
	heading(l, fmt.tprintf("AMBIENCE  %v", len(d.ambiences)))
	for line, n in d.ambiences {
		switch row_buttons(l, l.y, n == 0, n == len(d.ambiences) - 1) {
		case .None:
		case .Up:     swap_lines(e, line, d.ambiences[n - 1]); return
		case .Down:   swap_lines(e, line, d.ambiences[n + 1]); return
		case .Remove: remove_line(e, line); return
		}
		l.y += 22
		asked_field(l, "sound", lid(line, "name"), doc_head(d, line, 0), target(.Head, line, 0), .Sound)
		if stale(l) do return
		field(l, "when", lid(line, "when"), doc_field(d, line, "when"), target(.Field, line, name = "when"))
		if stale(l) do return
	}
	if button(l, l.x, 130, "+ ambience") {
		mark(e)
		doc_add_ambience(d, "room_quiet", "" if len(d.ambiences) == 0 else "night")
		changed(e)
		return
	}
	l.y += ROW + 4

	rule(l)
	heading(l, "FLOOR")
	note(l, fmt.tprintf("%v corners. 2 for the floor tool: drag a corner, click near an edge for a new one, Del removes one.", len(d.walk)))
	gap(l)
	if button(l, l.x, 110, "edit the floor", e.tool == .Floor) do e.tool = .Floor
	l.y += ROW + 4

	// Everything in the room, for what cannot be clicked on: a thing with no
	// picture, scenery, five people standing in one place under five
	// conditions.
	rule(l)
	heading(l, fmt.tprintf("IN THE ROOM  %v", len(d.objects) + len(d.exits) + len(d.triggers) + len(d.scenery) + len(d.windows) + len(d.sides)))
	for &o, i in d.objects {
		if vis(l, 18) {
			gone := !ac.holds(&e.flags, o.only)
			ac.mark_icon(mark_kind(&o), {l.x + 6, l.y + 8}, false, 1)
			text := o.name if o.only == "" else fmt.tprintf("%v  when=%v", o.name, o.only)
			hot := rl.CheckCollisionPointRec(ui.mouse(), {l.x, l.y, l.w, 18}) && rl.CheckCollisionPointRec(ui.mouse(), l.r)
			ui.label(i32(l.x) + 16, i32(l.y) + 2, ui.ellipsize(text, l.w - 18, ui.SMALL), ui.INK if hot else (rl.Color{100, 100, 114, 255} if gone else rl.Color{170, 186, 206, 255}), ui.SMALL)
			if hot && ui.mouse_pressed(.LEFT) do e.sel = {.Object, i}
		}
		l.y += 18
	}
	list_row :: proc(l: ^Lay, ink: rl.Color, text: string) -> bool {
		clicked := false
		if vis(l, 18) {
			rl.DrawRectangleRec({l.x + 2, l.y + 4, 9, 9}, ink)
			hot := rl.CheckCollisionPointRec(ui.mouse(), {l.x, l.y, l.w, 18}) && rl.CheckCollisionPointRec(ui.mouse(), l.r)
			ui.label(i32(l.x) + 16, i32(l.y) + 2, ui.ellipsize(text, l.w - 18, ui.SMALL), ui.INK if hot else rl.Color{170, 186, 206, 255}, ui.SMALL)
			clicked = hot && ui.mouse_pressed(.LEFT)
		}
		l.y += 18
		return clicked
	}
	for s, i in d.sides do if list_row(l, SIDE_INK, fmt.tprintf("side %v -> %v  %v..%v%v%v", ne.COMPASS_WORDS[s.dir], s.to, s.span[0], s.span[1], "" if s.gate == "" else fmt.tprintf("  gate=%v", s.gate), "" if s.only == "" else fmt.tprintf("  when=%v", s.only))) do e.sel = {.Side, i}
	for x, i in d.exits do if list_row(l, ac.EXIT_INK, fmt.tprintf("exit %v -> %v%v", x.name, x.to, "" if x.only == "" else fmt.tprintf("  when=%v", x.only))) do e.sel = {.Exit, i}
	for t, i in d.triggers do if list_row(l, ac.TRIGGER_INK, fmt.tprintf("trigger %v -> %v", t.name, t.action)) do e.sel = {.Trigger, i}
	for s, i in d.scenery do if list_row(l, {150, 150, 160, 255}, fmt.tprintf("scenery %v", s.name)) do e.sel = {.Scenery, i}
	for w, i in d.windows do if list_row(l, ac.WINDOW_INK, fmt.tprintf("window %v%v", w.name, "" if w.only == "" else fmt.tprintf("  when=%v", w.only))) do e.sel = {.Window, i}
	if d.strays > 0 {
		gap(l)
		note(l, fmt.tprintf("%v line%v name something not above %v in the file, and the game ignores %v.", d.strays, "" if d.strays == 1 else "s", "them" if d.strays > 1 else "it", "them" if d.strays > 1 else "it"), {220, 150, 110, 255})
	}
}

@(private = "file")
swap_lines :: proc(e: ^Scene_Editor, a, b: int) {
	mark(e)
	doc_swap(&e.doc, a, b)
	changed(e)
}

@(private = "file")
remove_line :: proc(e: ^Scene_Editor, line: int) {
	mark(e)
	doc_remove(&e.doc, line)
	changed(e)
}

// The fields of a line that no list of the panel's covers.
@(private = "file")
other_fields :: proc(l: ^Lay, line: int, known: []string) {
	others := doc_other_fields(&l.e.doc, line, known)
	if len(others) == 0 do return
	heading(l, "OTHER FIELDS", ui.DIM)
	for f in others {
		name := strings.clone(f[0], context.temp_allocator)
		field(l, name, lid(line, name), f[1], target(.Field, line, name = name))
		if stale(l) do return
	}
}

// The usual `key=value` rows for a line, for the fields in `names`.
@(private = "file")
fields :: proc(l: ^Lay, line: int, names: ..string) {
	d := &l.e.doc
	for n in names {
		field(l, n, lid(line, n), doc_field(d, line, n), target(.Field, line, name = n))
		if stale(l) do return
	}
}

// A shape: none, box or circle, and its numbers.
@(private = "file")
shape_field :: proc(l: ^Lay, line: int, name: string) {
	e := l.e
	value := doc_field(&e.doc, line, name)
	kind := "none"
	if strings.has_prefix(value, "box:") do kind = "box"
	if strings.has_prefix(value, "circle:") do kind = "circle"
	if picked, ok := choice(l, name, {"none", "box", "circle"}, kind); ok && picked != kind {
		mark(e)
		switch picked {
		case "none":   doc_set_field(&e.doc, line, name, "")
		case "box":    doc_set_field(&e.doc, line, name, "box:96,32" if name == "block" else "box:256,128")
		case "circle": doc_set_field(&e.doc, line, name, "circle:64" if name == "block" else "circle:128")
		}
		changed(e)
		return
	}
	if kind != "none" do field(l, "", lid(line, name), value, target(.Field, line, name = name))
}

// --- An object, a person or a peep ---

@(private = "file")
object_panel :: proc(l: ^Lay, i: int) {
	e := l.e
	d := &e.doc
	if i >= len(d.objects) do return
	o := d.objects[i]
	line := o.line
	kind := "PEEP" if o.peep else ("PERSON" if o.person else "OBJECT")
	heading(l, fmt.tprintf("%v  %v", kind, o.name))
	bw := f32(64)
	if ui.button({l.x + l.w - bw, l.y - 20, bw, 18}, "delete") {
		remove_object(e, i)
		return
	}
	if ui.button({l.x + l.w - bw * 2 - 4, l.y - 20, bw, 18}, "copy") {
		delete(e.clip)
		e.clip = doc_object_block(d, i)
		ui.say(l.status, "copied %v; ^V to paste", o.name)
	}
	notes(l, line)
	gap(l, 4)

	field(l, "name", lid(line, "@name"), o.name, target(.Obj_Name, i = i), ui.INK)
	if stale(l) do return
	field(l, "when", lid(line, "when"), o.only, target(.Field, line, name = "when"))
	if stale(l) do return
	prose(l, "text (LOOK AT)", lid(line, "@text"), doc_line_text(d, o.text), target(.Obj_Text, i = i))
	if stale(l) do return

	// Its art.
	rule(l)
	if o.person {
		heading(l, "CHARACTER", ui.DIM)
		ui.label(i32(l.x), i32(l.y) + 5, ui.ellipsize(o.char, l.w - 120, ui.SMALL), ui.INK, ui.SMALL)
		if button(l, l.x + l.w - 112, 112, "Character...") do ask_art(e, "char")
		l.y += ROW + 4
		if button(l, l.x + l.w - 112, 112, "make it a thing") {
			mark(e)
			doc_set_field(d, line, "char", "")
			doc_set_field(d, line, "pose", "")
			doc_set_field(d, line, "facing", "")
			doc_set_field(d, line, "speed", "")
			changed(e)
			return
		}
		l.y += ROW + 4
		poses := make([dynamic]string, context.temp_allocator)
		append(&poses, "(facing)")
		append(&poses, ..ac.art_char_poses(&e.art, o.char))
		current := o.pose if o.pose != "" else "(facing)"
		if picked, ok := choice(l, "pose", poses[:], current); ok {
			mark(e)
			doc_set_field(d, line, "pose", "" if picked == "(facing)" else picked)
			changed(e)
			return
		}
		face := doc_field(d, line, "facing")
		if picked, ok := choice(l, "facing", {"front", "back", "left", "right"}, face if face != "" else "front"); ok {
			mark(e)
			doc_set_field(d, line, "facing", picked)
			changed(e)
			return
		}
		fields(l, line, "speed")
		if stale(l) do return
	} else {
		heading(l, "SPRITE", ui.DIM)
		ui.label(i32(l.x), i32(l.y) + 5, ui.ellipsize(o.sprite if o.sprite != "" else "none: it is not drawn", l.w - 180, ui.SMALL), ui.INK if o.sprite != "" else ui.DIM, ui.SMALL)
		if button(l, l.x + l.w - 170, 80, "Sprite...", o.sprite == "") do ask_art(e, "sprite")
		if o.sprite != "" && button(l, l.x + l.w - 86, 40, "none") {
			mark(e)
			doc_set_field(d, line, "sprite", "")
			changed(e)
			return
		}
		if button(l, l.x + l.w - 42, 42, "char") do ask_art(e, "char")
		l.y += ROW + 4
	}
	// What it looks like in this light, as the room draws it.
	if s, f := object_art(e, &d.objects[i]); s.texture.id != 0 {
		box := f32(72)
		fit := min(box / f32(s.frame_w), box / f32(s.frame_h), 2)
		w, h := f32(s.frame_w) * fit, f32(s.frame_h) * fit
		if vis(l, box) {
			ui.checkerboard({l.x, l.y, box, box}, 6)
			ne.draw_sprite_pro(s, f, {l.x + (box - w) / 2, l.y + (box - h) / 2, w, h})
			names := [ne.Light]string{.Day = "day", .Sunset = "sunset", .Night = "night", .Sunrise = "sunrise"}
			info := fmt.tprintf("%vx%v art, %v frame%v", s.w, s.h, s.frames, "" if s.frames == 1 else "s")
			ui.label(i32(l.x + box + 8), i32(l.y) + 4, info, ui.DIM, ui.SMALL)
			if !o.person && o.sprite != "" {
				painted := ac.painted_lights(&e.art.index, o.sprite)
				b := strings.builder_make(context.temp_allocator)
				for li in ne.Light do if li in painted do fmt.sbprintf(&b, "%v ", names[li])
				ui.label(i32(l.x + box + 8), i32(l.y) + 22, ui.ellipsize(fmt.tprintf("painted: %v", strings.to_string(b)), l.w - box - 10, ui.SMALL), ui.DIM, ui.SMALL)
			}
		}
		l.y += box + 6
	}

	// Where it is and how it sits.
	rule(l)
	heading(l, "PLACE", ui.DIM)
	fields(l, line, "pos", "walk_to")
	if stale(l) do return
	if o.walk_to == {} && button(l, l.x + LABEL_W, l.w - LABEL_W, "put walk_to by its feet") {
		mark(e)
		doc_set_field(d, line, "walk_to", vec(o.pos + {0, 24}))
		changed(e)
		return
	}
	if o.walk_to == {} do l.y += ROW + 4
	shape_field(l, line, "reach")
	if stale(l) do return
	shape_field(l, line, "block")
	if stale(l) do return
	depth := doc_field(d, line, "depth")
	if picked, ok := choice(l, "depth", {"back", "normal", "front"}, depth if depth != "" else "normal"); ok {
		mark(e)
		doc_set_field(d, line, "depth", "" if picked == "normal" else picked)
		changed(e)
		return
	}
	fields(l, line, "base", "frame", "fps")
	if stale(l) do return
	if toggle(l, "glow", o.glow) {
		mark(e)
		doc_set_field(d, line, "glow", "" if o.glow else "true")
		changed(e)
		return
	}
	show := ne.field_bool(ne.parse_line(d.lines[line]), "show")
	if toggle(l, "show", show) {
		mark(e)
		doc_set_field(d, line, "show", "" if show else "true")
		changed(e)
		return
	}
	asked_field(l, "loop", lid(line, "loop"), doc_field(d, line, "loop"), target(.Field, line, name = "loop"), .Sound)
	if stale(l) do return
	asked_field(l, "tick", lid(line, "tick"), doc_field(d, line, "tick"), target(.Field, line, name = "tick"), .Sound)
	if stale(l) do return
	fields(l, line, "ticks")
	if stale(l) do return

	if o.peep {
		rule(l)
		heading(l, "PEEP", ui.DIM)
		asked_field(l, "into", lid(line, "into"), doc_field(d, line, "into"), target(.Field, line, name = "into"), .Room)
		if stale(l) do return
		fields(l, line, "dress")
		if stale(l) do return
		k := doc_field(d, line, "kind")
		if picked, ok := choice(l, "kind", {"window", "net", "vent", "hatch", "grating", "door"}, k if k != "" else "window"); ok {
			mark(e)
			doc_set_field(d, line, "kind", picked)
			changed(e)
			return
		}
		fields(l, line, "blind", "near")
		if stale(l) do return
	}
	other_fields(l, line, PEEP_FIELDS if o.peep else OBJ_FIELDS)
	if stale(l) do return

	// What it does when a verb lands on it.
	rule(l)
	ons := doc_attached(d, i, "on")
	heading(l, fmt.tprintf("WHEN SOMEBODY...  %v", len(ons)))
	if len(ons) > 0 do note(l, "the first that fits is the one that answers")
	gap(l, 2)
	for on, n in ons {
		switch row_buttons(l, l.y, n == 0, n == len(ons) - 1) {
		case .None:
		case .Up:     swap_lines(e, on, ons[n - 1]); return
		case .Down:   swap_lines(e, on, ons[n + 1]); return
		case .Remove: remove_line(e, on); return
		}
		rl.DrawRectangleRec({l.x - 6, l.y + 2, 2, 18}, ui.GOLD)
		ui.label(i32(l.x), i32(l.y) + 4, fmt.tprintf("#%v", n + 1), ui.DIM, ui.SMALL)
		l.y += 22
		field(l, "verb", lid(on, "@verb"), doc_head(d, on, 1), target(.Head, on, 1), ui.INK)
		if stale(l) do return
		fields(l, on, "when", "action")
		if stale(l) do return
		field_pair(l, on, "with", "anim")
		if stale(l) do return
		prose(l, "", lid(on, "@text"), doc_line_text(d, on), target(.Line_Text, on))
		if stale(l) do return
		other_fields(l, on, ON_FIELDS)
		if stale(l) do return
		gap(l, 6)
	}
	if button(l, l.x, 120, "+ interaction") {
		mark(e)
		doc_add_on(d, i, "look")
		changed(e)
		return
	}
	l.y += ROW + 4

	// A person's day: steps it walks through, round and round if it loops.
	steps := doc_attached(d, i, "step")
	if o.person || len(steps) > 0 {
		rule(l)
		heading(l, fmt.tprintf("ROUTINE  %v steps", len(steps)))
		note(l, "walk_to X,Y  wait S  face front  play POSE S|once|3x  say TEXT")
		loops := false
		for r in doc_attached(d, i, "routine") do for w in parts_of(d.lines[r]).head do if w == "loop" do loops = true
		if toggle(l, "loops", loops) {
			mark(e)
			doc_set_routine_loop(d, i, !loops)
			changed(e)
			return
		}
		for st, n in steps {
			switch row_buttons(l, l.y, n == 0, n == len(steps) - 1) {
			case .None:
			case .Up:     swap_lines(e, st, steps[n - 1]); return
			case .Down:   swap_lines(e, st, steps[n + 1]); return
			case .Remove: remove_line(e, st); return
			}
			l.y += 22
			p := parts_of(d.lines[st])
			rest := strings.trim_space(strings.trim_prefix(strings.trim_space(d.lines[st]), fmt.tprintf("step %v", p.head[0] if len(p.head) > 0 else "")))
			field(l, fmt.tprintf("step %v", n + 1), lid(st, "@step"), rest, target(.Step, st))
			if stale(l) do return
		}
		if button(l, l.x, 100, "+ step") {
			mark(e)
			doc_add_step(d, i, "wait 2")
			changed(e)
			return
		}
		l.y += ROW + 4
	}
}

@(private = "file")
remove_object :: proc(e: ^Scene_Editor, i: int) {
	mark(e)
	doc_remove_object(&e.doc, i)
	e.sel = {}
	changed(e)
}

// --- An exit ---

@(private = "file")
exit_panel :: proc(l: ^Lay, i: int) {
	e := l.e
	d := &e.doc
	if i >= len(d.exits) do return
	x := d.exits[i]
	line := x.line
	heading(l, fmt.tprintf("EXIT  %v", x.name))
	if ui.button({l.x + l.w - 64, l.y - 20, 64, 18}, "delete") {
		mark(e)
		doc_remove_exit(d, i)
		e.sel = {}
		changed(e)
		return
	}
	notes(l, line)
	gap(l, 4)
	field(l, "name", lid(line, "@name"), x.name, target(.Exit_Name, i = i), ui.INK)
	if stale(l) do return
	asked_field(l, "to", lid(line, "to"), doc_field(d, line, "to"), target(.Field, line, name = "to"), .Room)
	if stale(l) do return
	fields(l, line, "area", "arrive", "when")
	if stale(l) do return
	if toggle(l, "closed", x.closed) {
		mark(e)
		doc_set_field(d, line, "closed", "" if x.closed else "true")
		changed(e)
		return
	}
	shuts := doc_shuts(d, i)
	prose(l, "said when it is shut", lid(line, "@shut"), doc_line_text(d, shuts[len(shuts) - 1]) if len(shuts) > 0 else "", target(.Shut, i = i))
	if stale(l) do return
	rule(l)
	heading(l, "GOING THROUGH AS SOMETHING SHE DOES", ui.DIM)
	fields(l, line, "anim", "at")
	if stale(l) do return
	face := doc_field(d, line, "face")
	if picked, ok := choice(l, "face", {"-", "front", "back", "left", "right"}, face if face != "" else "-"); ok {
		mark(e)
		doc_set_field(d, line, "face", "" if picked == "-" else picked)
		changed(e)
		return
	}
	fields(l, line, "arrive_anim")
	if stale(l) do return
	other_fields(l, line, EXIT_FIELDS)
}

// --- A side ---

@(private = "file")
side_panel :: proc(l: ^Lay, i: int) {
	e := l.e
	d := &e.doc
	if i >= len(d.sides) do return
	s := d.sides[i]
	line := s.line
	heading(l, fmt.tprintf("SIDE  %v", ne.COMPASS_WORDS[s.dir]))
	if ui.button({l.x + l.w - 64, l.y - 20, 64, 18}, "delete") {
		mark(e)
		doc_remove_side(d, i)
		e.sel = {}
		changed(e)
		return
	}
	notes(l, line)
	gap(l, 4)
	if picked, ok := choice(l, "facing", {"north", "east", "south", "west"}, ne.COMPASS_WORDS[s.dir]); ok {
		if dir, good := ne.compass_of(picked); good && dir != s.dir {
			mark(e)
			doc_set_side_dir(d, i, dir)
			changed(e)
			return
		}
	}
	asked_field(l, "to", lid(line, "to"), doc_field(d, line, "to"), target(.Field, line, name = "to"), .Room)
	if stale(l) do return
	fields(l, line, "span", "gate", "name", "when", "arrive")
	if stale(l) do return
	note(l, "span: where the walk band crosses, along the side (x for north and south, y for east and west); gate: one of the game's gates; arrive: a long walk's own landing", ui.DIM)
	shuts := doc_side_shuts(d, i)
	prose(l, "said when its gate is shut", lid(line, "@shut"), doc_line_text(d, shuts[len(shuts) - 1]) if len(shuts) > 0 else "", target(.Side_Shut, i = i))
	if stale(l) do return
	rule(l)
	heading(l, "THE ROOM NEXT DOOR", ui.DIM)
	text, span, ok := side_partner_line(e, i)
	note(l, text, ui.INK if ok else rl.Color{220, 150, 110, 255})
	if ok && (s.dir == .East || s.dir == .West) && span != s.span {
		if button(l, l.x, 150, "take its span") {
			mark(e)
			doc_set_side_span(d, i, span)
			changed(e)
			return
		}
		l.y += ROW + 4
	}
	other_fields(l, line, SIDE_FIELDS)
}

// What the room next door says back: its side facing this way, leading here,
// and whether the spans agree. Read from its file, beside this one's, and
// kept until anything changes.
@(private = "file")
side_partner_line :: proc(e: ^Scene_Editor, i: int) -> (text: string, span: [2]f32, ok: bool) {
	d := &e.doc
	s := d.sides[i]
	if s.has_arrive do return fmt.tprintf("a long walk: she arrives in %v at %v, wherever she left", s.to, vec(s.arrive)), {}, false
	if s.to == "" || s.to == "nowhere" do return "say which room is next door: to", {}, false
	key := fmt.tprintf("%v|%v|%v|%v", s.to, ne.COMPASS_WORDS[s.dir], i, e.gen)
	if key != e.partner_key {
		ui.reset_string(&e.partner_key, key)
		e.partner_ok, e.partner_span = false, {}
		here := doc_head(d, d.scene, 0) if d.scene >= 0 else ui.base_name(e.path)
		want := ne.opposite(s.dir)
		said := fmt.tprintf("there is no %v.scene beside this room", s.to)
		if data, found := ne.read_data_file(neighbour_path(e.path, s.to)); found {
			nd: Doc
			defer doc_destroy(&nd)
			doc_set_text_all(&nd, data)
			said = fmt.tprintf("%v has no %v side back here: `nscene world` will say so", s.to, ne.COMPASS_WORDS[want])
			for o in nd.sides do if o.dir == want && o.to == here {
				e.partner_ok, e.partner_span = true, o.span
				agree := "the same span" if o.span == s.span else "a different span"
				said = fmt.tprintf("%v's %v side comes back here: span %v..%v, %v%v", s.to, ne.COMPASS_WORDS[want], o.span[0], o.span[1], agree, fmt.tprintf(", gate %v", o.gate) if o.gate != "" else "")
				break
			}
		}
		ui.reset_string(&e.partner_text, said)
	}
	return e.partner_text, e.partner_span, e.partner_ok
}

// A room's file, beside this one: scenes/<room>/<room>.scene, or loose.
neighbour_path :: proc(path, room: string) -> string {
	dir := ui.parent_dir(path)
	scenes := dir
	if ui.base_name(dir) == ui.base_name(path) do scenes = ui.parent_dir(dir)
	own := fmt.tprintf("%v/%v/%v.scene", scenes, room, room)
	if os.exists(own) do return own
	return fmt.tprintf("%v/%v.scene", scenes, room)
}

// --- A trigger ---

@(private = "file")
trigger_panel :: proc(l: ^Lay, i: int) {
	e := l.e
	d := &e.doc
	if i >= len(d.triggers) do return
	t := d.triggers[i]
	heading(l, fmt.tprintf("TRIGGER  %v", t.name))
	if ui.button({l.x + l.w - 64, l.y - 20, 64, 18}, "delete") {
		remove_line(e, t.line)
		e.sel = {}
		return
	}
	notes(l, t.line)
	gap(l, 4)
	field(l, "name", lid(t.line, "@name"), t.name, target(.Head, t.line, 0), ui.INK)
	if stale(l) do return
	note(l, "fires its action the moment she steps into its area")
	fields(l, t.line, "action", "area", "when")
	if stale(l) do return
	other_fields(l, t.line, TRIGGER_FIELDS)
}

// --- Scenery: a thing with words and no place ---

@(private = "file")
scenery_panel :: proc(l: ^Lay, i: int) {
	e := l.e
	d := &e.doc
	if i >= len(d.scenery) do return
	s := d.scenery[i]
	heading(l, fmt.tprintf("SCENERY  %v", s.name))
	if ui.button({l.x + l.w - 64, l.y - 20, 64, 18}, "delete") {
		remove_line(e, s.line)
		e.sel = {}
		return
	}
	notes(l, s.line)
	note(l, "something that can be looked at and is not drawn: the sky, a smell")
	gap(l, 4)
	field(l, "name", lid(s.line, "@name"), s.name, target(.Head, s.line, 0), ui.INK)
	if stale(l) do return
	fields(l, s.line, "when")
	if stale(l) do return
	prose(l, "what LOOK AT says", lid(s.line, "@text"), doc_line_text(d, s.line), target(.Line_Text, s.line))
	if stale(l) do return
	other_fields(l, s.line, WHEN_ONLY)
}

// --- A window: an opening onto the outside ---

@(private = "file")
window_panel :: proc(l: ^Lay, i: int) {
	e := l.e
	d := &e.doc
	if i >= len(d.windows) do return
	w := d.windows[i]
	heading(l, fmt.tprintf("WINDOW  %v", w.name))
	if ui.button({l.x + l.w - 64, l.y - 20, 64, 18}, "delete") {
		remove_line(e, w.line)
		e.sel = {}
		return
	}
	notes(l, w.line)
	note(l, "an opening onto the outside: somebody going past at night is drawn through its glass, under its frame")
	gap(l, 4)
	field(l, "name", lid(w.line, "@name"), w.name, target(.Head, w.line, 0), ui.INK)
	if stale(l) do return
	fields(l, w.line, "glass")
	if stale(l) do return
	field(l, "feet", lid(w.line, "feet"), doc_field(d, w.line, "feet"), target(.Field, w.line, name = "feet"))
	if stale(l) do return
	if w.feet == 0 {
		note(l, fmt.tprintf("none: the default, %v, the foot of the glass and half a person. Drag the dashed line to set one.", doc_window_feet(w)))
	} else {
		note(l, "where a figure outside stands: the sill should cut them about the waist")
		if button(l, l.x + LABEL_W, l.w - LABEL_W, "back to the default") {
			mark(e)
			doc_set_field(d, w.line, "feet", "")
			changed(e)
			return
		}
		l.y += ROW + 4
	}
	field(l, "frame", lid(w.line, "frame"), w.frame, target(.Field, w.line, name = "frame"))
	if stale(l) do return
	frame_found := false
	for o in d.objects do if o.name == w.frame do frame_found = true
	if w.frame == "" {
		note(l, "no frame named: the figure is drawn after everything at depth=back")
	} else if !frame_found {
		note(l, fmt.tprintf("there is no object called %v here", w.frame), {220, 150, 110, 255})
	}
	// The depth=back things whose picture covers the glass: the frame is one.
	cands := make([dynamic]string, context.temp_allocator)
	centre := [2]f32{w.glass[0] + w.glass[2] / 2, w.glass[1] + w.glass[3] / 2}
	for &o in d.objects {
		if o.depth != .Back || o.glow || o.person do continue
		s, _ := object_art(e, &o)
		if s.texture.id == 0 do continue
		r := [4]f32{o.pos.x - f32(s.frame_w) / 2, o.pos.y - f32(s.frame_h), f32(s.frame_w), f32(s.frame_h)}
		if centre.x < r[0] || centre.x > r[0] + r[2] || centre.y < r[1] || centre.y > r[1] + r[3] do continue
		dup := false
		for c in cands do if c == o.name do dup = true
		if !dup do append(&cands, o.name)
	}
	if len(cands) > 0 {
		if picked, ok := choice(l, "under", cands[:], w.frame); ok && picked != w.frame {
			mark(e)
			doc_set_field(d, w.line, "frame", picked)
			changed(e)
			return
		}
	}
	fields(l, w.line, "when")
	if stale(l) do return
	other_fields(l, w.line, WINDOW_FIELDS)
}

// --- A corner of the floor ---

@(private = "file")
corner_panel :: proc(l: ^Lay, i: int) {
	e := l.e
	d := &e.doc
	if i >= len(d.walk) do return
	heading(l, fmt.tprintf("FLOOR CORNER  %v of %v", i + 1, len(d.walk)))
	p := d.walk[i]
	ui.label(i32(l.x), i32(l.y) + 5, "at", ui.DIM, ui.SMALL)
	v, done := ui.text_field(&e.text, {l.x + LABEL_W, l.y, l.w - LABEL_W, ROW}, "corner", vec(p))
	if e.text.focus == "corner" do e.focus = target(.Corner, i = i)
	l.y += ROW + 4
	if done do commit(e, target(.Corner, i = i), v, l.status)
	note(l, "drag it in the room; Del removes it")
}

// --- The room as these flags have it ---

// Off, dimmed or hidden, and the flags: every one the room's conditions name,
// a chip each, lit when it is on.
@(private = "file")
flags_box :: proc(l: ^Lay) {
	e := l.e
	heading(l, "SHOW THE ROOM AS THESE FLAGS HAVE IT")
	current := ac.FLAG_MODE_NAMES[e.flags.mode]
	if picked, ok := choice(l, "show", {"off", "dim", "hide"}, current); ok && picked != current {
		for m in ac.Flag_Mode do if ac.FLAG_MODE_NAMES[m] == picked do e.flags.mode = m
	}
	if e.flags.mode == .Off {
		note(l, "everything is drawn, whatever its when= says. Dim or hide what a set of flags would not show")
		return
	}
	names := room_flags(&e.doc)
	if len(names) == 0 {
		note(l, "nothing in this room has a when=")
		return
	}
	ui.label(i32(l.x), i32(l.y) + 5, "flags", ui.DIM, ui.SMALL)
	x := l.x + LABEL_W
	for n in names {
		w := min(f32(ui.measure(n, ui.SMALL) + 14), l.w - LABEL_W)
		if x + w > l.x + l.w {
			x = l.x + LABEL_W
			l.y += ROW + 2
		}
		if vis(l, ROW) && ui.chip({x, l.y, w, ROW - 2}, ui.ellipsize(n, w - 6, ui.SMALL), ac.flag_is(&e.flags, n)) do ac.flag_toggle(&e.flags, n)
		x += w + 3
	}
	l.y += ROW + 4
	hidden := 0
	for o in e.doc.objects do if !ac.holds(&e.flags, o.only) do hidden += 1
	note(l, fmt.tprintf("%v of %v things are not here under these flags", hidden, len(e.doc.objects)))
}

// The description the room reads under the flags shown, as the engine picks
// it (scene_description): the first with a when= that ac.holds, else the first
// with none. -1 with the view off, or none.
read_desc :: proc(e: ^Scene_Editor) -> int {
	if e.flags.mode == .Off do return -1
	d := &e.doc
	for line in d.descs {
		w := doc_field(d, line, "when")
		if w != "" && ac.holds(&e.flags, w) do return line
	}
	for line in d.descs do if doc_field(d, line, "when") == "" do return line
	return -1
}
