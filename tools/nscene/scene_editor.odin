package main

import ne "../../"
import ac "../assetcache"
import px "../pixel"
import ui "../ui"
import "core:fmt"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

// The scene editor: one .scene file, its room drawn as the game draws it, and
// everything about whatever is selected in the panel down the right.
//
// What it ac.holds is the file's lines (doc.odin), so nothing in the file is
// lost or moved by opening and saving it, and every field of every line can
// be seen and changed. What it shows is the backdrop and the art the room's
// objects name, loaded as they are drawn (art.odin) — nothing else from the
// game, and no shelf of every sprite there is. Choosing art is done by going
// to look for it: Backdrop..., Sprite... and Character... open the file
// browser as a question (ui/pick.odin).
//
//   1 select, 2 floor        what a click in the room does
//   L                        the next light: day, sunset, night, sunrise
//   drag                     move what is under the pointer, or its handles
//   Delete                   remove what is selected
//   ^C ^V                    copy an object, paste it renamed
//   ^Z ^Y                    undo, redo
//   ^S                       save
//   Esc                      stop adding, drop the selection, then leave

Scene_Tool :: enum {
	Select,
	Floor,
}

Sel_Kind :: enum {
	Room, // nothing in it: the room itself
	Object,
	Exit,
	Trigger,
	Scenery,
	Window, // a `window` line: its glass, and the feet line of somebody outside
	Corner,
	Side,   // a `side` line: a border walked across into the room next door
}

Sel :: struct {
	kind: Sel_Kind,
	i:    int,
}

// What is being added, from the toolbar: named first, then put in the room.
Add_Kind :: enum {
	None,
	Object,
	Person,
	Peep,
	Exit,
	Trigger,
	Scenery,
	Window,
	Side,
}

ADD_LABELS := [Add_Kind]string {
	.None    = "",
	.Object  = "object",
	.Person  = "person",
	.Peep    = "peep",
	.Exit    = "exit",
	.Trigger = "trigger",
	.Scenery = "scenery",
	.Window  = "window",
	.Side    = "side",
}

Scene_Editor :: struct {
	path:      string,
	doc:       Doc,
	art:       ac.Art,
	light:     ne.Light,
	size:      [2]f32, // the room, in the file's numbers
	view:      ui.View,
	text:      ui.Text_Input,
	history:   ui.History,
	pick:      ui.Picker,
	pick_art:  px.Browse, // the picker's preview of the file under its cursor
	pick_sound: ac.Sound_Preview, // ...of a sound
	pick_room: ac.Room_Preview, // ...of a room
	ask_for:   Target, // the field a sound or room question is for

	tool:      Scene_Tool,
	sel:       Sel,
	adding:    Add_Kind,
	placing:   bool, // named, and waiting for a click (or a drag) in the room
	add_name:  string, // owned

	drag:      Drag,
	names:     bool, // every object's name on the room, not just the selected one's
	dirty:     bool,
	loaded:    bool,
	scroll:    f32, // the panel's
	panel_h:   f32, // how tall the panel's contents were last frame
	frame:     int,
	sweep_at:  int, // let go of art not drawn on this frame; 0 for no
	gen:       int, // bumped by every change, so a panel half-drawn knows to stop
	focus:     Target, // what the field being typed into is for (panel.odin)
	asked_bg:  bool, // a room without a backdrop asks for one, once
	clip:      string, // owned: a copied object's lines
	flags:     ac.Flag_View, // the room as these flags have it (flags.odin)

	// The selected side's partner in the room next door, read from its file
	// and kept until the side, or anything, changes (panel.odin).
	partner_key:  string, // owned
	partner_text: string, // owned
	partner_span: [2]f32,
	partner_ok:   bool,
}

// The width art is authored at, which everything else is a multiple of.
DESIGN_W :: 320

PANEL_W :: f32(340)
HEADER_H :: 40
TOOLBAR_H :: 30

scene_editor_open :: proc(e: ^Scene_Editor, path: string, asset_dir: string = "assets") -> bool {
	e^ = {path = strings.clone(path), size = ac.DEFAULT_ROOM, add_name = strings.clone("")}
	e.art.scale = ac.SCENE_SCALE
	// Absolute, so a file the browser hands back can be found in it.
	ac.index_build(&e.art.index, ui.abs_path(asset_dir, context.temp_allocator))
	if !doc_load(&e.doc, path) {
		// A file that is not there yet is a new room.
		doc_set_text_all(&e.doc, scene_template(ui.base_name(path)))
		e.dirty = true
	}
	room_size(e)
	e.loaded = true
	trace("open %v", path)
	return true
}

scene_editor_close :: proc(e: ^Scene_Editor) {
	if !e.loaded do return
	ui.pick_close(&e.pick)
	px.browse_close(&e.pick_art)
	ac.sound_preview_close(&e.pick_sound)
	ac.room_preview_close(&e.pick_room)
	ac.art_destroy(&e.art)
	ac.flags_destroy(&e.flags)
	doc_destroy(&e.doc)
	ui.text_input_destroy(&e.text)
	ui.history_destroy(&e.history)
	delete(e.path)
	delete(e.add_name)
	delete(e.clip)
	delete(e.partner_key)
	delete(e.partner_text)
	trace("close")
	e^ = {}
}

// How big the room is: its backdrop, blown up as the game blows it up.
room_size :: proc(e: ^Scene_Editor) {
	e.size = ac.DEFAULT_ROOM
	if e.doc.bg < 0 do return
	bg := doc_head(&e.doc, e.doc.bg, 0)
	key, _ := ac.lit_name(&e.art.index, bg, .Day, images = true)
	if key == "" do return
	s := ac.art_sprite(&e.art, key, images = true)
	if s.texture.id != 0 do e.size = {f32(s.frame_w), f32(s.frame_h)}
}

scene_editor_step :: proc(e: ^Scene_Editor, status: ^ui.Status) -> bool {
	if !e.loaded do return false
	e.frame += 1
	e.art.frame = e.frame
	switch ui.leave_answer() {
	case .Save:    if scene_save(e, status) do return false
	case .Discard: return false
	case .None:
	}

	// A question asked of the file browser takes the window until it is
	// answered.
	if ui.pick_active(&e.pick) {
		a := ui.pick_step(&e.pick, status)
		if a.done {
			px.browse_close(&e.pick_art)
			ac.sound_preview_close(&e.pick_sound)
			ac.room_preview_close(&e.pick_room)
			if a.path != "" do picked(e, a.asking, a.path, status)
		}
		return true
	}
	// A room with no backdrop asks for one as it opens.
	if !e.asked_bg && e.doc.bg < 0 {
		e.asked_bg = true
		ask_backdrop(e)
		return true
	}
	e.asked_bg = true

	screen := [2]f32{f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
	keys := footer_keys(e)
	foot := ui.footer_h(keys)
	body_h := screen.y - HEADER_H - foot
	panel_x := ui.split_right("nscene.panel", PANEL_W, screen.x, HEADER_H, body_h, 240, max(screen.x - 300, 240))
	area := rl.Rectangle{0, HEADER_H + TOOLBAR_H, panel_x, body_h - TOOLBAR_H}
	bar := rl.Rectangle{0, HEADER_H, panel_x, TOOLBAR_H}
	panel := rl.Rectangle{panel_x, HEADER_H, screen.x - panel_x, body_h}
	if e.view.zoom == 0 do e.view = ui.fit_view(e.size, area)

	// An edit left in a field is kept before anything else this frame can
	// move the lines it belongs to.
	if ui.text_input_clicked_away(&e.text) {
		commit(e, e.focus, ui.text_input_value(&e.text))
		ui.text_input_blur(&e.text)
	}
	typing := ui.typing(&e.text)

	leaving := false
	if !typing {
		if ui.key_pressed(.ESCAPE) {
			switch {
			case e.adding != .None: stop_adding(e)
			case e.drag.what != .None: e.drag = {}
			case e.sel.kind != .Room: e.sel = {}
			case: leaving = ui.leave_request(e.dirty, ui.file_of(e.path))
			}
		}
		if ui.back_pressed() do leaving = ui.leave_request(e.dirty, ui.file_of(e.path))
		if ui.undo_pressed() do step_back(e, status, false)
		if ui.redo_pressed() do step_back(e, status, true)
		if ui.save_pressed() do scene_save(e, status)
		if ui.copy_pressed() && e.sel.kind == .Object && e.sel.i < len(e.doc.objects) {
			delete(e.clip)
			e.clip = doc_object_block(&e.doc, e.sel.i)
			ui.say(status, "copied %v", e.doc.objects[e.sel.i].name)
		}
		if ui.paste_pressed() && e.clip != "" {
			mark(e)
			if i := doc_paste_object(&e.doc, e.clip, {16, 16}); i >= 0 {
				changed(e)
				e.sel = {.Object, i}
				ui.say(status, "pasted %v", e.doc.objects[i].name)
			}
		}
		if !ui.ctrl_down() {
			if ui.key_pressed(.ONE) do e.tool = .Select
			if ui.key_pressed(.TWO) do e.tool = .Floor
			if ui.key_pressed(.L) do set_light(e, ne.Light((int(e.light) + 1) % len(ne.Light)))
			if ui.key_pressed(.N) do e.names = !e.names
			if ui.key_pressed(.F) do e.view = ui.fit_view(e.size, area)
			if ui.key_pressed(.DELETE) do remove_selected(e, status)
		}
	}

	rl.ClearBackground(ui.BG)
	draw_room(e, area)
	draw_header(e, screen.x, panel_x, &leaving)
	draw_toolbar(e, bar, status)
	draw_panel(e, panel, status)
	canvas_input(e, area, status)
	ui.splits_draw()
	ui.footer(status, keys)

	ui.text_input_sweep(&e.text)
	if e.sweep_at != 0 && e.frame >= e.sweep_at {
		ac.art_sweep(&e.art)
		e.sweep_at = 0
		trace("art: %v pictures loaded", e.art.loaded)
	}
	return !leaving
}

@(private = "file")
footer_keys :: proc(e: ^Scene_Editor) -> string {
	if e.adding != .None {
		if !e.placing do return "type its name  Enter to go on  Esc to stop"
		switch e.adding {
		case .Exit, .Trigger: return "drag out its area in the room  Esc to stop"
		case .Window: return "drag out its glass in the room  Esc to stop"
		case .Side: return "drag along the floor's edge where the band crosses it  Esc to stop"
		case .None, .Object, .Person, .Peep, .Scenery:
		}
		return "click in the room where it stands  Esc to stop"
	}
	if e.tool == .Floor do return "click near an edge to add a corner  drag a corner  Del removes it  1 select  L light  ^Z undo  ^S save  Esc ^B files"
	return "1 select  2 floor  L light  N names  F fit  drag to move  Del remove  ^C ^V object  ^Z ^Y  ^S save  Esc ^B files"
}

@(private = "file")
draw_header :: proc(e: ^Scene_Editor, width, panel_x: f32, leaving: ^bool) {
	ui.panel({0, 0, width, HEADER_H})
	if ui.back_button() do leaving^ = leaving^ || ui.leave_request(e.dirty, ui.file_of(e.path))
	name := doc_head(&e.doc, e.doc.scene, 0) if e.doc.scene >= 0 else ui.base_name(e.path)
	tools := [Scene_Tool]string{.Select = "1 select", .Floor = "2 floor"}
	bw: f32 = 76
	x := width - (bw + 4) * len(Scene_Tool) - 6
	ui.title_bar(name, e.path, e.dirty, x - 10, ui.BACK_W)
	for t in Scene_Tool {
		if ui.button({x, 7, bw, 26}, tools[t], e.tool == t) {
			e.tool = t
			stop_adding(e)
		}
		x += bw + 4
	}
}

// The strip over the room: which light it is shown in, and the things that
// can be added to it.
@(private = "file")
draw_toolbar :: proc(e: ^Scene_Editor, r: rl.Rectangle, status: ^ui.Status) {
	rl.DrawRectangleRec(r, {30, 30, 38, 255})
	ui.hline(i32(r.x), i32(r.y + r.height) - 1, i32(r.width))
	x := r.x + 8
	// The lights the backdrop was painted in are bright; the others borrow.
	painted: bit_set[ne.Light]
	if e.doc.bg >= 0 do painted = ac.painted_lights(&e.art.index, doc_head(&e.doc, e.doc.bg, 0), images = true)
	names := [ne.Light]string{.Day = "day", .Sunset = "sunset", .Night = "night", .Sunrise = "sunrise"}
	for l in ne.Light {
		text := names[l] if l in painted || e.doc.bg < 0 else fmt.tprintf("%v~", names[l])
		w := f32(ui.measure(text, ui.SMALL) + 14)
		if ui.chip({x, r.y + 4, w, 22}, text, e.light == l) do set_light(e, l)
		x += w + 3
	}
	x += 12
	ui.label(i32(x), i32(r.y) + 8, "add", {110, 110, 126, 255}, ui.SMALL)
	x += 30
	// The flags the room is shown as, at the right end when there is room:
	// lit while it is on, so a dimmed room is never a mystery.
	fw := f32(ui.measure("flags: hide", ui.SMALL) + 14)
	for k in Add_Kind {
		if k == .None do continue
		w := f32(ui.measure(ADD_LABELS[k], ui.SMALL) + 14)
		if x + w > r.x + r.width - fw - 10 do break
		if ui.chip({x, r.y + 4, w, 22}, ADD_LABELS[k], e.adding == k) do start_adding(e, k)
		x += w + 3
	}
	if x + fw < r.x + r.width - 4 {
		text := "flags" if e.flags.mode == .Off else fmt.tprintf("flags: %v", ac.FLAG_MODE_NAMES[e.flags.mode])
		if ui.chip({r.x + r.width - fw - 6, r.y + 4, fw, 22}, text, e.flags.mode != .Off) {
			// Off, or on as dimmed; the room's panel says which flags.
			e.flags.mode = .Dim if e.flags.mode == .Off else .Off
			e.sel = {}
		}
	}
}

set_light :: proc(e: ^Scene_Editor, l: ne.Light) {
	if e.light == l do return
	e.light = l
	e.sweep_at = e.frame + 1
}

// --- Changing the document ---

// Remembers the file as it is, before something changes it.
mark :: proc(e: ^Scene_Editor) {
	ui.history_mark(&e.history, doc_text(&e.doc))
}

// After any change: the file needs saving, the panel stops drawing what it
// had, and art the room no longer shows is let go on the next frame.
changed :: proc(e: ^Scene_Editor) {
	e.dirty = true
	e.gen += 1
	e.sweep_at = e.frame + 1
	clamp_selection(e)
}

clamp_selection :: proc(e: ^Scene_Editor) {
	n := 0
	switch e.sel.kind {
	case .Room:    return
	case .Object:  n = len(e.doc.objects)
	case .Exit:    n = len(e.doc.exits)
	case .Trigger: n = len(e.doc.triggers)
	case .Scenery: n = len(e.doc.scenery)
	case .Window:  n = len(e.doc.windows)
	case .Corner:  n = len(e.doc.walk)
	case .Side:    n = len(e.doc.sides)
	}
	if e.sel.i < 0 || e.sel.i >= n do e.sel = {}
}

scene_save :: proc(e: ^Scene_Editor, status: ^ui.Status) -> bool {
	if !doc_save(&e.doc, e.path) {
		ui.say(status, "could not write %v", e.path)
		return false
	}
	e.dirty = false
	ui.say(status, "saved %v", ui.file_of(e.path))
	return true
}

@(private = "file")
step_back :: proc(e: ^Scene_Editor, status: ^ui.Status, forward: bool) {
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
	e.drag = {}
	changed(e)
	room_size(e)
	ui.say(status, "redone" if forward else "undone")
}

@(private = "file")
remove_selected :: proc(e: ^Scene_Editor, status: ^ui.Status) {
	what := ""
	switch e.sel.kind {
	case .Room: return
	case .Object:
		what = strings.clone(e.doc.objects[e.sel.i].name, context.temp_allocator)
		mark(e)
		doc_remove_object(&e.doc, e.sel.i)
	case .Exit:
		what = strings.clone(e.doc.exits[e.sel.i].name, context.temp_allocator)
		mark(e)
		doc_remove_exit(&e.doc, e.sel.i)
	case .Trigger:
		what = strings.clone(e.doc.triggers[e.sel.i].name, context.temp_allocator)
		mark(e)
		doc_remove(&e.doc, e.doc.triggers[e.sel.i].line)
	case .Scenery:
		what = strings.clone(e.doc.scenery[e.sel.i].name, context.temp_allocator)
		mark(e)
		doc_remove(&e.doc, e.doc.scenery[e.sel.i].line)
	case .Window:
		what = strings.clone(e.doc.windows[e.sel.i].name, context.temp_allocator)
		mark(e)
		doc_remove(&e.doc, e.doc.windows[e.sel.i].line)
	case .Side:
		what = fmt.tprintf("the %v side", ne.COMPASS_WORDS[e.doc.sides[e.sel.i].dir])
		mark(e)
		doc_remove_side(&e.doc, e.sel.i)
	case .Corner:
		if len(e.doc.walk) <= 3 {
			ui.say(status, "a floor needs at least three corners")
			return
		}
		mark(e)
		pts := make([dynamic][2]f32, context.temp_allocator)
		for p, i in e.doc.walk do if i != e.sel.i do append(&pts, p)
		doc_set_walk(&e.doc, pts[:])
		what = "the corner"
	}
	e.sel = {}
	changed(e)
	ui.say(status, "removed %v", what)
}

// --- Adding things ---

start_adding :: proc(e: ^Scene_Editor, k: Add_Kind) {
	if e.adding == k {
		stop_adding(e)
		return
	}
	e.adding = k
	e.placing = false
	e.tool = .Select
	// A side is named by the way it faces: straight to the drag.
	if k == .Side {
		e.placing = true
		if e.text.focus == "add.name" do ui.text_input_blur(&e.text)
		return
	}
	want := ADD_LABELS[k]
	if k == .Object do want = "thing"
	ui.reset_string(&e.add_name, doc_free_name(&e.doc, want))
	ui.text_input_focus(&e.text, "add.name", e.add_name)
}

stop_adding :: proc(e: ^Scene_Editor) {
	e.adding = .None
	e.placing = false
	if e.text.focus == "add.name" do ui.text_input_blur(&e.text)
}

// The name has been typed: scenery goes in at once (it stands nowhere);
// everything else waits for the room to be clicked.
named :: proc(e: ^Scene_Editor, typed: string, status: ^ui.Status) {
	name := clean_name(typed)
	if name == "" {
		ui.say(status, "a name, one word")
		ui.text_input_focus(&e.text, "add.name", e.add_name)
		return
	}
	ui.reset_string(&e.add_name, doc_free_name(&e.doc, name))
	if e.adding == .Scenery {
		mark(e)
		i := doc_add_scenery(&e.doc, e.add_name, "")
		changed(e)
		e.sel = {.Scenery, i}
		stop_adding(e)
		ui.say(status, "added %v: say what it looks like in the panel", e.doc.scenery[i].name)
		return
	}
	e.placing = true
	switch e.adding {
	case .Exit, .Trigger: ui.say(status, "drag out where %v is", e.add_name)
	case .Window: ui.say(status, "drag out the glass of %v", e.add_name)
	case .Side: ui.say(status, "drag along the edge where the band crosses")
	case .None, .Object, .Person, .Peep, .Scenery: ui.say(status, "click where %v stands", e.add_name)
	}
}

// The click (or drag) that puts what is being added into the room.
place :: proc(e: ^Scene_Editor, at: [2]f32, area: [4]f32, status: ^ui.Status) {
	p := [2]f32{f32(i32(at.x)), f32(i32(at.y))}
	mark(e)
	switch e.adding {
	case .None, .Scenery:
		return
	case .Object:
		i := doc_add_object(&e.doc, "obj", e.add_name, p, {"reach", "circle:128"})
		e.sel = {.Object, i}
		ui.say(status, "added %v: choose its sprite in the panel", e.add_name)
	case .Person:
		i := doc_add_object(&e.doc, "obj", e.add_name, p, {"facing", "front"})
		e.sel = {.Object, i}
		changed(e)
		stop_adding(e)
		ask_art(e, "char")
		return
	case .Peep:
		i := doc_add_object(&e.doc, "peep", e.add_name, p, {"kind", "window"}, {"walk_to", vec(p + {0, 30})}, {"reach", "circle:128"})
		e.sel = {.Object, i}
		ui.say(status, "added %v: say which room it looks into", e.add_name)
	case .Exit:
		here := doc_head(&e.doc, e.doc.scene, 0) if e.doc.scene >= 0 else ui.base_name(e.path)
		i := doc_add_exit(&e.doc, e.add_name, area, here, {512, 560})
		e.sel = {.Exit, i}
		ui.say(status, "added %v: say where it goes in the panel", e.add_name)
	case .Trigger:
		i := doc_add_trigger(&e.doc, e.add_name, area, "")
		e.sel = {.Trigger, i}
		ui.say(status, "added %v: name the action it fires", e.add_name)
	case .Window:
		i := doc_add_window(&e.doc, e.add_name, area)
		e.sel = {.Window, i}
		ui.say(status, "added %v: drag its feet line, and name its frame in the panel", e.add_name)
	case .Side:
		// Wider than tall is along the back or the front of the floor (north
		// or south, by which half of it); taller than wide is a side.
		dir: ne.Compass
		span: [2]f32
		if area[2] >= area[3] {
			mid := f32(0)
			for q in e.doc.walk do mid += q.y
			if len(e.doc.walk) > 0 do mid /= f32(len(e.doc.walk))
			dir = .North if area[1] + area[3] / 2 < mid else .South
			span = {area[0], area[0] + area[2]}
		} else {
			dir = .West if area[0] + area[2] / 2 < e.size.x / 2 else .East
			span = {area[1], area[1] + area[3]}
		}
		i := doc_add_side(&e.doc, dir, "", {snap_span(span[0]), snap_span(span[1])})
		e.sel = {.Side, i}
		ui.say(status, "added the %v side: say which room is next door in the panel", ne.COMPASS_WORDS[dir])
	}
	changed(e)
	stop_adding(e)
}

// Spans sit on 5 art px steps (16 canvas px), so neighbours' edges meet.
snap_span :: proc(v: f32) -> f32 {
	return f32(int(max(v, 0) / 16 + 0.5)) * 16
}

// --- Asking the file browser ---

ROOM_ART := [?]ui.File_Kind {
	{suffix = ".sprite", label = "sprite", color = {120, 200, 230, 255}},
}

ask_backdrop :: proc(e: ^Scene_Editor) {
	start := ui.parent_dir(ui.abs_path(e.path, context.temp_allocator))
	current := ""
	if e.doc.bg >= 0 {
		if p, ok := e.art.index.sprites[doc_head(&e.doc, e.doc.bg, 0)]; ok do current = p
	}
	ui.pick_open(&e.pick, "bg", "Choose a backdrop", ROOM_ART[:], current if current != "" else start, preview = px.art_preview, ctx = &e.pick_art, accept = px.art_is_backdrop)
}

// A sprite (`what` = "sprite") or a character ("char") for the selected
// object. It starts where the one it has now is, or in the room's folder.
ask_art :: proc(e: ^Scene_Editor, what: string) {
	start := ui.parent_dir(ui.abs_path(e.path, context.temp_allocator))
	current := ""
	if e.sel.kind == .Object && e.sel.i < len(e.doc.objects) {
		o := e.doc.objects[e.sel.i]
		if what == "char" {
			if p, ok := e.art.index.chars[o.char]; ok do current = p
			// People are kept together, so start among them.
			if current == "" do for _, p in e.art.index.chars {
				current = ui.parent_dir(p)
				break
			}
		} else if p, ok := e.art.index.sprites[o.sprite]; ok {
			current = p
		}
	}
	kinds := px.ART_KINDS[1:] if what == "char" else px.ART_KINDS[:1]
	title := "Choose a character" if what == "char" else "Choose a sprite"
	ui.pick_open(&e.pick, what, title, kinds, current if current != "" else start, preview = px.art_preview, ctx = &e.pick_art)
}

// The browser has answered.
@(private = "file")
picked :: proc(e: ^Scene_Editor, asking, path: string, status: ^ui.Status) {
	switch asking {
	case "sound", "room":
		chose_name(e, asking, path, status)
		return
	}
	// The name the game will look it up by: the file's own name for itself,
	// which the index has; a file outside the game's assets is not one it
	// could ever load, so it says so rather than writing a name that will
	// not be found.
	name := ""
	pool := e.art.index.chars if asking == "char" else e.art.index.sprites
	for n, p in pool do if p == path do name = n
	if name == "" {
		// Made since the editor opened, perhaps: look again.
		root := strings.clone(e.art.index.root, context.temp_allocator)
		ac.index_destroy(&e.art.index)
		ac.index_build(&e.art.index, root)
		pool = e.art.index.chars if asking == "char" else e.art.index.sprites
		for n, p in pool do if p == path do name = n
	}
	if name == "" {
		ui.say(status, "%v is not in this game's assets, so the game could not load it", ui.file_of(path))
		return
	}
	name = strings.clone(name, context.temp_allocator)
	// A light's own painting is chosen as the thing itself: pick
	// admin.night and the room gets `bg admin`, worn at night as painted.
	for suffix in ne.LIGHT_SUFFIX do if suffix != "" && strings.has_suffix(name, suffix) do name = name[:len(name) - len(suffix)]

	switch asking {
	case "bg":
		mark(e)
		doc_set_room_word(&e.doc, "bg", name)
		changed(e)
		room_size(e)
		e.view = {}
		ui.say(status, "backdrop: %v", name)
	case "sprite", "char":
		if e.sel.kind != .Object || e.sel.i >= len(e.doc.objects) do return
		line := e.doc.objects[e.sel.i].line
		mark(e)
		if asking == "char" {
			doc_set_field(&e.doc, line, "char", name)
			doc_set_field(&e.doc, line, "sprite", "")
		} else {
			doc_set_field(&e.doc, line, "sprite", name)
			doc_set_field(&e.doc, line, "char", "")
			doc_set_field(&e.doc, line, "pose", "")
		}
		changed(e)
		ui.say(status, "%v: %v", e.doc.objects[e.sel.i].name, name)
	}
}

// --- The scene file a new room starts as ---

// Used by the browser and the command line: a room with a name and a floor.
scene_file_new :: proc(path, name: string) -> bool {
	return os.write_entire_file(path, transmute([]byte)scene_template(name)) == nil
}

// --- Sounds and rooms, by name ---
//
// A sound field — an ambience, the footstep, an object's `loop=` and `tick=`
// — names one of the game's sounds, which it plays from the .wav of that
// name; an exit's `to=` and a peep's `into=` name a room. Each is chosen by
// going to look for it, as art is: Sound... lists the game's sounds with a
// waveform and a play button, Room... every room with its picture. The field
// still takes typing, for a name that has no file yet.

// Asks for a sound for field `t`, starting on the one it names now.
ask_sound :: proc(e: ^Scene_Editor, t: Target, current: string) {
	e.ask_for = t
	root := e.art.index.root
	start := ac.find_sound(root, current)
	if start == "" do start = ui.path_join(root, "sounds")
	if !os.exists(start) do start = root
	ac.sound_preview_close(&e.pick_sound)
	ui.pick_open(&e.pick, "sound", "Choose a sound", ac.SOUND_KINDS[:], start, preview = ac.sound_preview, ctx = &e.pick_sound, accept = ac.sound_listed)
}

// Asks for a room for field `t`: every room in the game, starting on the one
// it names now.
ask_room :: proc(e: ^Scene_Editor, t: Target, current: string) {
	e.ask_for = t
	root := e.art.index.root
	start := ui.path_join(root, "scenes")
	if !os.is_dir(start) do start = root
	ac.room_preview_close(&e.pick_room)
	e.pick_room.root = strings.clone(root)
	ui.pick_open(&e.pick, "room", "Choose a room", ac.ROOM_KINDS[:], start, select = ac.find_scene(root, current), preview = ac.room_preview, ctx = &e.pick_room, deep = true)
}

// The name the game knows the chosen file by goes into the field asked for,
// as if it had been typed: one undo step, none if it is what was there.
@(private = "file")
chose_name :: proc(e: ^Scene_Editor, asking, path: string, status: ^ui.Status) {
	name := ui.base_name(path)
	if asking == "room" {
		// A room is known by its `scene` line, which is nearly always its
		// file's name.
		d: Doc
		if doc_load(&d, path) && d.scene >= 0 do name = strings.clone(doc_head(&d, d.scene, 0), context.temp_allocator)
		doc_destroy(&d)
	}
	if e.art.index.root != "" && !strings.has_prefix(path, e.art.index.root) {
		ui.say(status, "%v is not in this game's assets, so the game will not find it", ui.file_of(path))
	}
	commit(e, e.ask_for, name, status)
}
