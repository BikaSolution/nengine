package cutscene

import ne "../../../"
import ac "../../assetcache"
import ui "../../ui"
import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

// The panel down the right: everything about whatever is selected, each
// part of it editable where it is shown. With nothing selected it is the cut
// itself — its name, its room, its cast, every cue — and the way to the rest.
//
// A value is shown as the file has it (`at 470,500`, `lines 3-5`), because
// that is what you would type and what you will read in the file afterwards;
// one of a few words (a facing, a kind of cue, who it is for) is a row of
// chips; anything chosen from the game — a room, a character, a sound, a
// node's lines — has a button that goes to look for it.

@(private = "file")
Lay :: struct {
	e:      ^Editor,
	status: ^ui.Status,
	r:      rl.Rectangle,
	x, y, w: f32,
	gen:    int,
}

LABEL_W :: f32(74)
ROW :: f32(24)

@(private = "file")
stale :: proc(l: ^Lay) -> bool {
	return l.e.gen != l.gen
}

@(private = "file")
vis :: proc(l: ^Lay, h: f32) -> bool {
	return l.y + h > l.r.y && l.y < l.r.y + l.r.height
}

@(private = "file")
heading :: proc(l: ^Lay, text: string, ink := ui.GOLD) {
	l.y += 4
	ui.label(i32(l.x), i32(l.y), text, ink, ui.SMALL)
	l.y += 18
}

@(private = "file")
rule :: proc(l: ^Lay) {
	l.y += 4
	ui.hline(i32(l.x), i32(l.y), i32(l.w))
	l.y += 8
}

@(private = "file")
note :: proc(l: ^Lay, words: string, ink := rl.Color{120, 120, 136, 255}) {
	// What the font can draw: an em dash as --, curly quotes straight.
	text := ne.plain_text(words)
	for row in ui.text_rows(text, l.w) {
		ui.label(i32(l.x), i32(l.y), text[row.start:row.end], ink, ui.SMALL)
		l.y += 16
	}
}

@(private = "file")
notes :: proc(l: ^Lay, line: int) {
	above := make([dynamic]string, context.temp_allocator)
	// The marker every file starts with is not a note.
	for a in doc_notes_above(&l.e.doc, line) do if a != "nengine cutscene" do append(&above, a)
	if len(above) == 0 do return
	note(l, strings.join(above[:], " ", context.temp_allocator))
	l.y += 4
}

// A field with its name to the left. Returns true on the frame it commits.
@(private = "file")
field :: proc(l: ^Lay, label, id, value: string, t: Target, ink := ui.DIM, w: f32 = 0) -> bool {
	e := l.e
	focused := e.text.focus == id
	defer l.y += ROW + 4
	if !vis(l, ROW) && !focused do return false
	ui.label(i32(l.x), i32(l.y) + 5, ui.ellipsize(label, LABEL_W - 6, ui.SMALL), ink, ui.SMALL)
	fw := w if w > 0 else l.w - LABEL_W
	v, done := ui.text_field(&e.text, {l.x + LABEL_W, l.y, fw, ROW}, id, value)
	if e.text.focus == id do e.focus = t
	if done {
		commit(e, t, v, l.status)
		return true
	}
	return false
}

@(private = "file")
prose :: proc(l: ^Lay, id, value: string, t: Target) -> bool {
	e := l.e
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
		w := min(f32(ui.measure(o, ui.SMALL) + 14), l.w - LABEL_W)
		if x + w > l.x + l.w {
			x = l.x + LABEL_W
			l.y += ROW + 2
		}
		if vis(l, ROW) && ui.chip({x, l.y, w, ROW - 2}, ui.ellipsize(o, w - 6, ui.SMALL), o == current) do picked, ok = o, true
		x += w + 3
	}
	l.y += ROW + 4
	return
}

@(private = "file")
button :: proc(l: ^Lay, x, w: f32, text: string, active := false) -> bool {
	if !vis(l, ROW) do return false
	return ui.button({x, l.y, w, ROW - 2}, text, active)
}

// A row of the panel that is a link: click it to select what it names.
@(private = "file")
link :: proc(l: ^Lay, ink: rl.Color, text: string, picked := false) -> bool {
	clicked := false
	if vis(l, 18) {
		row := rl.Rectangle{l.x, l.y, l.w, 18}
		hot := rl.CheckCollisionPointRec(ui.mouse(), row) && rl.CheckCollisionPointRec(ui.mouse(), l.r)
		if picked do rl.DrawRectangleRec(row, {56, 52, 36, 255})
		rl.DrawRectangleRec({l.x + 2, l.y + 5, 8, 8}, ink)
		ui.label(i32(l.x) + 16, i32(l.y) + 2, ui.ellipsize(ne.plain_text(text), l.w - 18, ui.SMALL), ui.INK if hot || picked else rl.Color{170, 186, 206, 255}, ui.SMALL)
		clicked = hot && ui.mouse_pressed(.LEFT)
	}
	l.y += 18
	return clicked
}

// A picture of a character or a sprite, fitted to a box at the left.
@(private = "file")
look :: proc(l: ^Lay, s: ne.Sprite, frame: i32, info: string) {
	box := f32(84)
	if s.texture.id != 0 && vis(l, box) {
		fit := min(box / f32(s.frame_w), box / f32(s.frame_h), 3)
		w, h := f32(s.frame_w) * fit, f32(s.frame_h) * fit
		ui.checkerboard({l.x, l.y, box, box}, 6)
		ne.draw_sprite_pro(s, clamp(frame, 0, max(s.frames - 1, 0)), {l.x + (box - w) / 2, l.y + (box - h) / 2, w, h})
		for row, k in ui.text_rows(info, l.w - box - 10) {
			ui.label(i32(l.x + box + 8), i32(l.y) + 4 + i32(k) * 16, info[row.start:row.end], ui.DIM, ui.SMALL)
		}
	}
	if s.texture.id != 0 do l.y += box + 6
}

// --- The panel ---

draw_panel :: proc(e: ^Editor, r: rl.Rectangle, status: ^ui.Status) {
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

	if e.adding {
		adding_box(&l)
		rule(&l)
	}
	switch e.sel.kind {
	case .Cut:  cut_panel(&l)
	case .Cast: if e.sel.i < len(e.doc.people) do cast_panel(&l, e.sel.i)
	case .Cue:  if e.sel.i < len(e.doc.cues) do cue_panel(&l, e.sel.i)
	}
}

@(private = "file")
adding_box :: proc(l: ^Lay) {
	e := l.e
	heading(l, "NEW IN THE CAST")
	note(l, "their name: one word, what the cues call them. Named like somebody in the room, they are that person; named like the player, they are her")
	l.y += 2
	v, done := ui.text_field(&e.text, {l.x, l.y, l.w - 70, ROW}, "add.name", e.add_name)
	if e.text.focus == "add.name" do e.focus = {kind = .Add_Name}
	if !done && ui.button({l.x + l.w - 64, l.y, 64, ROW}, "add") do v, done = e.add_name, true
	l.y += ROW + 6
	if done do named(e, v, l.status)
}

// --- The cut ---

@(private = "file")
cut_panel :: proc(l: ^Lay) {
	e := l.e
	d := &e.doc
	heading(l, "CUTSCENE")
	if d.head >= 0 do notes(l, d.head)
	field(l, "name", "cut.name", d.name, {kind = .Cut_Name}, ui.INK)
	if stale(l) do return

	// The room: its name, a look at it, and the way to choose another.
	ui.label(i32(l.x), i32(l.y) + 5, "room", ui.DIM, ui.SMALL)
	ui.label(i32(l.x + LABEL_W), i32(l.y) + 5, ui.ellipsize(d.scene if d.scene != "" else "none", l.w - LABEL_W - 76, ui.SMALL), ui.INK if d.scene != "" else ui.DIM, ui.SMALL)
	if button(l, l.x + l.w - 70, 70, "Room...", d.scene == "") do ask_room(e)
	l.y += ROW + 4
	switch {
	case d.scene == "":
		note(l, "the room the editor shows. In the game a cut plays in whatever room she is in.")
	case !e.has_room:
		note(l, fmt.tprintf("there is no %v.scene in this game's assets", d.scene), {220, 150, 110, 255})
	case:
		bg := e.room.background_name
		s, painted := ac.art_lit(&e.art, bg, e.light, images = true)
		if s.texture.id != 0 {
			h := l.w * f32(s.frame_h) / f32(s.frame_w)
			if vis(l, h) do ne.draw_sprite_pro(s, 0, {l.x, l.y, l.w, h})
			rl.DrawRectangleLinesEx({l.x, l.y, l.w, h}, 1, ui.EDGE)
			l.y += h + 4
		}
		lights := ac.painted_lights(&e.art.index, bg, images = true)
		b := strings.builder_make(context.temp_allocator)
		for li in ne.Light do if li in lights do fmt.sbprintf(&b, "%v ", LIGHT_NAMES[li])
		note(l, fmt.tprintf("%v, painted for %v; shown %v%v", bg, strings.trim_space(strings.to_string(b)), LIGHT_NAMES[e.light], "" if painted else " (borrowed)"))
		flags_box(l)
		if stale(l) do return
	}

	length := doc_length(d)
	ends := false
	for c in d.cues do if c.q.action == .End do ends = true
	l.y += 4
	note(l, fmt.tprintf("%.1f seconds: %v", length, "the end cue" if ends else "no end cue, so it ends a breath after the last"), ui.DIM)

	rule(l)
	heading(l, fmt.tprintf("CAST  %v", len(d.people)))
	for c, i in d.people {
		v := cast_view(e, i)
		who := c.m.character if c.m.character != "" else (fmt.tprintf("%v?", v.char) if v.guessed else (v.char if v.char != "" else "-"))
		where_ := fmt.tprintf("at %v", vec_text(c.m.at)) if !c.m.keep_place else "where they stand"
		if link(l, {140, 220, 130, 255}, fmt.tprintf("%v   %v   %v", c.m.name, who, where_)) {
			e.sel, e.who = {.Cast, i}, i
		}
	}
	l.y += 4
	if button(l, l.x, 100, "+ cast (C)") do start_adding(e)
	l.y += ROW + 4

	rule(l)
	heading(l, fmt.tprintf("CUES  %v, in the order they fire", len(d.cues)))
	for i in d.order {
		q := d.cues[i].q
		who := q.who if q.who != "" else "-"
		if link(l, cue_colour(q.action, true), fmt.tprintf("%.2f  %v  %v", q.at, who, cue_label(q))) do e.sel = {.Cue, i}
	}
	l.y += 4
	if button(l, l.x, 150, "+ cue at playhead (A)") do add_cue(e, l.status)
	l.y += ROW + 4
	if len(d.ignored) > 0 {
		rule(l)
		heading(l, "LINES THE GAME READS AS NOTHING", {220, 150, 110, 255})
		for line in d.ignored do note(l, fmt.tprintf("line %v: %v", line + 1, strings.trim_space(d.lines[line])), {220, 150, 110, 255})
	}
}

vec_text :: proc(p: [2]f32) -> string {
	return fmt.tprintf("%v,%v", int(p.x), int(p.y))
}

// --- Somebody in the cast ---

@(private = "file")
cast_panel :: proc(l: ^Lay, i: int) {
	e := l.e
	d := &e.doc
	c := d.people[i]
	m := c.m
	v := cast_view(e, i)
	heading(l, fmt.tprintf("CAST  %v", m.name))
	if ui.button({l.x + l.w - 64, l.y - 20, 64, 18}, "delete") {
		remove_selected(e, l.status)
		return
	}
	notes(l, c.line)
	field(l, "name", fmt.tprintf("cast%v.name", i), m.name, {.Cast_Name, i}, ui.INK)
	if stale(l) do return

	// What they wear.
	rule(l)
	heading(l, "CHARACTER", ui.DIM)
	shown := m.character if m.character != "" else "none of their own"
	ui.label(i32(l.x), i32(l.y) + 5, ui.ellipsize(shown, l.w - 160, ui.SMALL), ui.INK if m.character != "" else ui.DIM, ui.SMALL)
	if button(l, l.x + l.w - 150, 100, "Character...", m.character == "") do ask_char(e, i)
	if m.character != "" && button(l, l.x + l.w - 46, 46, "none") {
		mark(e)
		doc_set_cast_field(d, i, "char", "")
		changed(e)
		return
	}
	l.y += ROW + 4
	who := ""
	switch {
	case v.person >= 0:
		o := e.room.objects[v.person]
		who = fmt.tprintf("%v in the room, wearing %v%v: the cut moves them, and puts them back after", o.name, o.char_name, fmt.tprintf(" (when=%v)", o.only) if o.only != "" else "")
	case v.player:
		who = fmt.tprintf("the player, it seems (cast in most of the cutscenes here): wears the .char called %v", v.char if v.char != "" else "-")
	case v.guessed:
		who = fmt.tprintf("not in the room: an extra, brought on for the cut and gone after, in the .char called %v", m.name)
	case m.character != "":
		who = "not in the room: an extra, brought on for the cut and gone after"
	case:
		who = "not in the room, and no character: nothing will be drawn"
	}
	note(l, who)
	l.y += 4

	// A look at them, in any of their poses.
	if v.char != "" {
		poses := ac.art_char_poses(&e.art, v.char)
		pose := e.look_pose
		found := false
		for p in poses do if p == pose do found = true
		if !found do pose = ne.facing_text(v.facing)
		s := ac.art_char_part(&e.art, v.char, pose)
		frame := i32(0)
		if cd := ac.art_char_data(&e.art, v.char); cd != nil {
			if cp := ne.character_part(cd, pose); cp != nil && cp.fps > 0 && s.frames > 1 do frame = i32(ui.now() * f64(cp.fps)) % s.frames
		}
		look(l, s, frame, fmt.tprintf("%v: %v, %vx%v, %v frame%v", v.char, pose, s.w, s.h, s.frames, "" if s.frames == 1 else "s"))
		if len(poses) > 0 {
			if picked, ok := choice(l, "poses", poses, pose); ok do ui.reset_string(&e.look_pose, picked)
			note(l, "a look only: a `play` cue puts somebody in a pose")
			l.y += 4
		}
	}

	// Where they start.
	rule(l)
	heading(l, "WHERE THEY START", ui.DIM)
	place := "at" if !m.keep_place else "where they stand"
	if picked, ok := choice(l, "place", {"at", "where they stand"}, place); ok && picked != place {
		mark(e)
		doc_set_cast_field(d, i, "at", vec_text(snap(v.start)) if picked == "at" else "")
		changed(e)
		return
	}
	if !m.keep_place {
		field(l, "at", fmt.tprintf("cast%v.at", i), vec_text(m.at), {.Cast_At, i})
		if stale(l) do return
		note(l, "or drag them on the stage")
	} else if v.person >= 0 {
		note(l, fmt.tprintf("where %v stands in the room: %v", e.room.objects[v.person].name, vec_text(v.start)))
	} else if v.player {
		note(l, "where she stands when it plays")
	} else {
		_, walks := first_walk(e, m.name)
		note(l, fmt.tprintf("off the %v side of the room, %v; drag their tag on the edge in, or choose at", "left" if v.start.x < 0 else "right", "until their first walk brings them on" if walks else "out of sight: they never walk on"))
	}
	face := ne.facing_text(m.facing) if !m.keep_facing else "their own way"
	if picked, ok := choice(l, "facing", {"their own way", "front", "back", "left", "right"}, face); ok && picked != face {
		mark(e)
		doc_set_cast_field(d, i, "facing", "" if picked == "their own way" else picked)
		changed(e)
		return
	}

	// Everything they do.
	rule(l)
	n := 0
	for q in d.cues do if q.q.who == m.name do n += 1
	heading(l, fmt.tprintf("THEIR CUES  %v", n))
	for k in d.order {
		q := d.cues[k].q
		if q.who != m.name do continue
		if link(l, cue_colour(q.action, true), fmt.tprintf("%.2f  %v  %v", q.at, action_name(q.action), cue_label(q))) do e.sel = {.Cue, k}
	}
	l.y += 4
	if button(l, l.x, 150, "+ cue at playhead (A)") do add_cue(e, l.status)
	l.y += ROW + 4
	rule(l)
	note(l, fmt.tprintf("line %v: %v", c.line + 1, strings.trim_space(d.lines[c.line])), {100, 100, 116, 255})
}

// --- A cue ---

PERSON_KINDS :: bit_set[ne.Cue_Action]{.Walk_To, .Face, .Play, .Say, .Think, .Leave}

@(private = "file")
cue_panel :: proc(l: ^Lay, i: int) {
	e := l.e
	d := &e.doc
	c := d.cues[i]
	q := c.q
	heading(l, fmt.tprintf("CUE  %v", action_name(q.action)))
	bw := f32(26)
	hx := l.x + l.w - 64 - (bw + 3) * 2
	if ui.button({hx, l.y - 20, bw, 18}, "up") {
		mark(e)
		e.sel.i = doc_move_cue(d, i, true)
		changed(e)
		return
	}
	if ui.button({hx + bw + 3, l.y - 20, bw, 18}, "dn") {
		mark(e)
		e.sel.i = doc_move_cue(d, i, false)
		changed(e)
		return
	}
	if ui.button({l.x + l.w - 64, l.y - 20, 64, 18}, "delete") {
		remove_selected(e, l.status)
		return
	}
	notes(l, c.line)
	field(l, "time", fmt.tprintf("cue%v.time", i), time_text(q.at), {.Cue_Time, i}, ui.INK, 90)
	if stale(l) do return
	if button(l, l.x + LABEL_W, 130, "to the playhead") {
		commit(e, {.Cue_Time, i}, fmt.tprintf("%.2f", f32(int(e.t * 10 + 0.5)) / 10), l.status)
		return
	}
	l.y += ROW + 4

	// What kind of cue it is. Changing it here is how a `say` becomes a
	// `think` without the line being typed again.
	kinds := make([dynamic]string, context.temp_allocator)
	for a in ne.Cue_Action do append(&kinds, action_name(a))
	if picked, ok := choice(l, "kind", kinds[:], action_name(q.action)); ok && picked != action_name(q.action) {
		for a in ne.Cue_Action do if action_name(a) == picked {
			change_kind(e, i, a, l.status)
			return
		}
	}
	if q.action in PERSON_KINDS {
		names := make([dynamic]string, context.temp_allocator)
		for p in d.people do append(&names, p.m.name)
		if picked, ok := choice(l, "who", names[:], q.who); ok && picked != q.who {
			mark(e)
			q.who = picked
			doc_set_cue(d, i, q)
			changed(e)
			e.who = doc_member(d, picked)
			return
		}
	}
	rule(l)

	switch q.action {
	case .Say, .Think, .Narrate:
		ui.label(i32(l.x), i32(l.y), "what is said" if q.action != .Think else "what is thought", ui.DIM, ui.SMALL)
		l.y += 17
		prose(l, fmt.tprintf("cue%v.text", i), q.text, {.Cue_Text, i})
		if stale(l) do return
		note(l, fmt.tprintf("up for %.1fs, as any box is", ne.line_secs(q.text)))
	case .Line:
		ui.label(i32(l.x), i32(l.y) + 5, "node", ui.DIM, ui.SMALL)
		ui.label(i32(l.x + LABEL_W), i32(l.y) + 5, ui.ellipsize(q.text, l.w - LABEL_W - 70, ui.SMALL), ui.INK, ui.SMALL)
		if button(l, l.x + l.w - 64, 64, "Line...") do ask_node(e, i, l.status)
		l.y += ROW + 4
		field(l, "lines", fmt.tprintf("cue%v.lines", i), ne.line_range_text(q.lines), {.Cue_Lines, i}, ui.DIM, 90)
		if stale(l) do return
		nodes_load(&e.nodes, e.asset_dir)
		n := node_of(&e.nodes, q.text)
		if n == nil {
			note(l, fmt.tprintf("there is no node %v in the game's dialogue%v", q.text, "" if e.nodes.dir != "" else " (none found)"), {220, 150, 110, 255})
			break
		}
		// The telling: the untagged lines alone, or with one tag's.
		tags := make([dynamic]string, context.temp_allocator)
		append(&tags, "untagged only")
		for t in node_tags(n) do if strings.index_byte(t, ' ') < 0 do append(&tags, t)
		current := q.tag if q.tag != "" else "untagged only"
		if picked, ok := choice(l, "telling", tags[:], current); ok && picked != current {
			mark(e)
			q.tag = "" if picked == "untagged only" else picked
			doc_set_cue(d, i, q)
			changed(e)
			return
		}
		if n.title != "" do note(l, n.title, ui.DIM)
		lines := node_telling(n, q.tag)
		secs := line_cue_secs(&e.nodes, q)
		note(l, fmt.tprintf("%v of its %v lines, %.1fs to read", q.lines[1] - q.lines[0] + 1, len(lines), secs), ui.DIM)
		l.y += 4
		for tl, k in lines {
			if k + 1 < q.lines[0] || k + 1 > q.lines[1] do continue
			note(l, fmt.tprintf("%v  %v", k + 1, tl.text), ui.INK)
		}
		if q.lines[1] > len(lines) do note(l, fmt.tprintf("it has no line %v: the game says nothing there", q.lines[1]), {220, 150, 110, 255})
	case .Sound:
		ui.label(i32(l.x), i32(l.y) + 5, "sound", ui.DIM, ui.SMALL)
		ui.label(i32(l.x + LABEL_W), i32(l.y) + 5, ui.ellipsize(q.text, l.w - LABEL_W - 76, ui.SMALL), ui.INK, ui.SMALL)
		if button(l, l.x + l.w - 70, 70, "Sound...") do ask_sound(e, i)
		l.y += ROW + 4
		note(l, "the game's sound of that name: its .wav, baked from the .sound")
	case .Face:
		if picked, ok := choice(l, "facing", {"front", "back", "left", "right"}, ne.facing_text(q.facing)); ok {
			mark(e)
			q.facing = ne.parse_facing(picked)
			doc_set_cue(d, i, q)
			changed(e)
			return
		}
	case .Walk_To:
		field(l, "to", fmt.tprintf("cue%v.to", i), vec_text(q.to), {.Cue_To, i}, ui.DIM, 110)
		if stale(l) do return
		m := doc_member(d, q.who)
		if m >= 0 {
			from := person_at(e, m, q.at)
			note(l, fmt.tprintf("from %v: %.1fs at the walking speed. Drag the ring on the stage to move it", vec_text(from), rl.Vector2Distance(from, q.to) / WALK_SPEED))
		}
	case .Play:
		// Which part: the poses their character has.
		m := doc_member(d, q.who)
		char := cast_view(e, m).char if m >= 0 else ""
		poses := ac.art_char_poses(&e.art, char)
		if len(poses) > 0 {
			if picked, ok := choice(l, "part", poses, q.text); ok && picked != q.text {
				mark(e)
				q.text = picked
				doc_set_cue(d, i, q)
				changed(e)
				return
			}
			found := false
			for p in poses do if p == q.text do found = true
			if !found do note(l, fmt.tprintf("%v has no part called %v", char, q.text), {220, 150, 110, 255})
		} else {
			field(l, "part", fmt.tprintf("cue%v.part", i), q.text, {.Cue_Part, i})
			if stale(l) do return
			note(l, "no character to choose a part from")
		}
		how := "once" if q.times == 1 else ("times" if q.times > 1 else "seconds")
		if picked, ok := choice(l, "for", {"once", "times", "seconds"}, how); ok && picked != how {
			mark(e)
			switch picked {
			case "once":    q.times = 1
			case "times":   q.times = 2
			case "seconds": q.times, q.amount = 0, max(q.amount, 2)
			}
			doc_set_cue(d, i, q)
			changed(e)
			return
		}
		if q.times > 1 {
			field(l, "times", fmt.tprintf("cue%v.times", i), fmt.tprintf("%v", q.times), {.Cue_Times, i}, ui.DIM, 70)
			if stale(l) do return
		} else if q.times == 0 {
			field(l, "seconds", fmt.tprintf("cue%v.secs", i), fmt.tprintf("%.2f", q.amount), {.Cue_Secs, i}, ui.DIM, 90)
			if stale(l) do return
		}
		if s := ac.art_char_part(&e.art, char, q.text); s.texture.id != 0 {
			look(l, s, i32(ui.now() * 6) % max(s.frames, 1), fmt.tprintf("%v %v: %.1fs", char, q.text, play_secs(e, char, q)))
		}
	case .Shake:
		field(l, "seconds", fmt.tprintf("cue%v.secs", i), fmt.tprintf("%.2f", q.amount), {.Cue_Secs, i}, ui.DIM, 90)
		if stale(l) do return
		note(l, "the camera shakes for this long")
	case .Leave:
		if picked, ok := choice(l, "side", {"north", "east", "south", "west"}, ne.COMPASS_WORDS[q.dir]); ok {
			if nd, good := ne.compass_of(picked); good && nd != q.dir {
				mark(e)
				q.dir = nd
				doc_set_cue(d, i, q)
				changed(e)
				return
			}
		}
		note(l, "off through that side of the room and out of sight; the next cut can bring them on with `enter=`")
	case .End:
		note(l, "the cut stops here, whatever is still to come")
	}

	rule(l)
	note(l, fmt.tprintf("line %v: %v", c.line + 1, strings.trim_space(d.lines[c.line])), {100, 100, 116, 255})
}

// A cue made into another kind, keeping what carries over: the words of a
// say into a think, who it is for, where it is in time. A kind that is
// chosen from the game asks at once: a sound, a node's lines.
@(private = "file")
change_kind :: proc(e: ^Editor, i: int, a: ne.Cue_Action, status: ^ui.Status) {
	d := &e.doc
	q := d.cues[i].q
	was := q.action
	q.action = a
	if a in PERSON_KINDS {
		if q.who == "" {
			if len(d.people) == 0 {
				ui.say(status, "a %v is somebody's: add somebody to the cast first", action_name(a))
				return
			}
			q.who = d.people[e.who if e.who >= 0 && e.who < len(d.people) else 0].m.name
		}
	} else {
		q.who = ""
	}
	speech := bit_set[ne.Cue_Action]{.Say, .Think, .Narrate}
	if a in speech && was not_in speech do q.text = "..."
	m := doc_member(d, q.who)
	switch a {
	case .Walk_To: if m >= 0 do q.to = snap(person_at(e, m, q.at))
	case .Face:    q.facing = .Front
	case .Play:
		q.text = "front"
		if poses := ac.art_char_poses(&e.art, cast_view(e, m).char if m >= 0 else ""); len(poses) > 0 do q.text = poses[0]
		q.times = 1
	case .Line:    q.text, q.lines, q.tag = "?", {1, 1}, ""
	case .Sound:   q.text = "?"
	case .Shake:   if q.amount <= 0 do q.amount = 0.4
	case .Leave:   q.dir = .East
	case .Say, .Think, .Narrate, .End:
	}
	mark(e)
	doc_set_cue(d, i, q)
	changed(e)
	if m >= 0 do e.who = m
	#partial switch a {
	case .Line:  ask_node(e, i, status)
	case .Sound: ask_sound(e, i)
	}
}

// The flags the room is shown as: off, dimmed or hidden, and a chip for every
// flag the room's conditions name, lit when it is on. Nothing is written to
// the file; it is the room as it would be at the moment the cut plays.
@(private = "file")
flags_box :: proc(l: ^Lay) {
	e := l.e
	l.y += 4
	ui.label(i32(l.x), i32(l.y), "THE ROOM AS THESE FLAGS HAVE IT", ui.DIM, ui.SMALL)
	l.y += 20
	current := ac.FLAG_MODE_NAMES[e.flags.mode]
	if picked, ok := choice(l, "show", {"off", "dim", "hide"}, current); ok && picked != current {
		for m in ac.Flag_Mode do if ac.FLAG_MODE_NAMES[m] == picked do e.flags.mode = m
		e.sweep_at = e.frame + 1
	}
	names := ac.scene_flags(&e.room)
	if len(names) > 0 && e.flags.mode != .Off {
		ui.label(i32(l.x), i32(l.y) + 5, "flags", ui.DIM, ui.SMALL)
		x := l.x + LABEL_W
		for n in names {
			w := min(f32(ui.measure(n, ui.SMALL) + 14), l.w - LABEL_W)
			if x + w > l.x + l.w {
				x = l.x + LABEL_W
				l.y += ROW + 2
			}
			if vis(l, ROW) && ui.chip({x, l.y, w, ROW - 2}, ui.ellipsize(n, w - 6, ui.SMALL), ac.flag_is(&e.flags, n)) {
				ac.flag_toggle(&e.flags, n)
				e.sweep_at = e.frame + 1
			}
			x += w + 3
		}
		l.y += ROW + 4
	}
	people, things, gone := 0, 0, 0
	for o in e.room.objects {
		switch {
		case !ac.holds(&e.flags, o.only): gone += 1
		case o.char_name != "":           people += 1
		case o.sprite_name != "":         things += 1
		}
	}
	note(l, fmt.tprintf("%v people and %v things stand in it%v", people, things, fmt.tprintf("; %v more are not there under these flags", gone) if gone > 0 else ""))
}
