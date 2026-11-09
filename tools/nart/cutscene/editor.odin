package cutscene

import ne "../../../"
import ac "../../assetcache"
import px "../../pixel"
import ui "../../ui"
import "core:fmt"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

// The cutscene editor. The odd one out in nart: there are no pixels in it.
//
// A cutscene is a room, a cast and a list of cues on a clock, so this is the
// room with the cast standing in it and the clock underneath, and a panel
// down the right with everything about whatever is selected — the cut itself,
// somebody in its cast, or one cue — every field of it shown and editable.
//
// What it holds is the file's lines (doc.odin), so nothing in the file is
// lost or moved by opening and saving it. What it shows is the room's
// backdrop, the things standing in it and the cast's characters, loaded as
// they are drawn and let go when they are not (assetcache) — nothing else
// from the game. Choosing anything is going to look for it: Room...,
// Character... and Sound... open the file browser as a question
// (ui/pick.odin), and Line... a list of the game's dialogue (lines.odin).
//
//   space         play or stop
//   click a cue   select it; drag it to move it in time
//   A             a cue at the playhead, for whoever is selected
//   C             somebody new in the cast
//   Delete        remove the selected cue, or person and their cues
//   L             the next light: day, sunset, night, sunrise
//   ^Z ^Y ^S      undo, redo, save
//   Esc           stop adding, drop the selection, then back to the files

STAGE_MIN :: f32(160)
ROW_H :: f32(26)
RULER_H :: f32(22)
HEAD_H :: f32(40)
TOOLBAR_H :: f32(30)
PANEL_W :: f32(340)

// Sprites are drawn 320 wide and blown up to the canvas the game runs at.
ROOM_SCALE :: ac.SCENE_SCALE
ROOM_W :: f32(1024)
ROOM_H :: f32(640)

Sel_Kind :: enum {
	Cut, // nothing: the cutscene itself
	Cast,
	Cue,
}

Sel :: struct {
	kind: Sel_Kind,
	i:    int,
}

Drag :: enum {
	None,
	Cue,     // moving a cue in time
	Person,  // moving where somebody starts
	Walk_To, // moving where a walk_to cue sends them
	Scrub,   // dragging the playhead
}

Editor :: struct {
	path:       string,
	asset_dir:  string,
	doc:        Cut_Doc,
	art:        ac.Art, // the assets' names, and the pictures on show
	light:      ne.Light,
	size:       [2]f32, // the room, in the file's numbers

	room:       ne.Scene, // the scene it plays in, read with no art: names and places
	has_room:   bool,
	room_name:  string, // owned: the scene= that `room` was read for
	room_path:  string, // owned

	flags:      ac.Flag_View, // the room as these flags have it (assetcache/flags.odin)
	nodes:      Node_Index, // the game's dialogue, read when first wanted
	line_pick:  Line_Pick,

	sel:        Sel,
	who:        int, // the cast member lit in the timeline; -1 for the nobody row
	player:     string, // owned: who the player probably is (guess_player); "" for nobody known
	t:          f32, // the playhead, in seconds
	playing:    bool,
	started:    f64,

	drag:       Drag,
	drag_moved: bool,
	drag_grab:  f32, // where in the cue the pointer took hold, in seconds

	view:       ui.View,
	text:       ui.Text_Input,
	focus:      Target, // what the field being typed into is for (panel.odin)
	history:    ui.History,
	pick:       ui.Picker,
	pick_art:   px.Browse,        // the picker's preview of a character
	pick_room:  ac.Room_Preview,  // ...of a room
	pick_sound: ac.Sound_Preview, // ...of a sound
	choose:     ui.Chooser,
	ask_for:    int, // the cast member or cue a question is about

	adding:     bool, // naming somebody new
	add_name:   string, // owned
	look_pose:  string, // owned: the pose the cast panel shows

	dirty:      bool,
	loaded:     bool,
	frame:      int,
	sweep_at:   int, // let go of art not drawn on this frame; 0 for no
	gen:        int, // bumped by every change, so a panel half-drawn knows to stop
	scroll:     f32, // the panel's
	tl_scroll:  f32, // the timeline's rows
	panel_h:    f32,
}

open :: proc(e: ^Editor, path: string, asset_dir: string) -> bool {
	e^ = {
		path      = strings.clone(path),
		asset_dir = strings.clone(ui.abs_path(asset_dir, context.temp_allocator)),
		add_name  = strings.clone(""),
		look_pose = strings.clone(""),
		room_name = strings.clone(""),
		room_path = strings.clone(""),
		size      = {ROOM_W, ROOM_H},
		who       = -1,
	}
	e.art.scale = ROOM_SCALE
	// Things a room has only under a condition are not drawn until flags
	// say they are there.
	e.flags.mode = .Hide
	// The names of the game's art, not the art: pictures are loaded as the
	// stage draws them.
	ac.index_build(&e.art.index, e.asset_dir)
	if !doc_load(&e.doc, path) {
		doc_set_text_all(&e.doc, fmt.tprintf("# nengine cutscene\ncut %v\n\n4.00 end\n", ui.base_name(path)))
		e.dirty = true
	}
	if len(e.doc.people) > 0 do e.who = 0
	e.player = guess_player(path)
	load_room(e)
	e.loaded = true
	ac.trace("open %v", path)
	return true
}

close :: proc(e: ^Editor) {
	if !e.loaded do return
	ui.pick_close(&e.pick)
	px.browse_close(&e.pick_art)
	ac.room_preview_close(&e.pick_room)
	ac.sound_preview_close(&e.pick_sound)
	ui.choose_close(&e.choose)
	line_pick_destroy(&e.line_pick)
	nodes_destroy(&e.nodes)
	if e.has_room do ac.scene_free(&e.room)
	ac.flags_destroy(&e.flags)
	ac.art_destroy(&e.art)
	doc_destroy(&e.doc)
	ui.text_input_destroy(&e.text)
	ui.history_destroy(&e.history)
	delete(e.player)
	delete(e.room_name)
	delete(e.room_path)
	delete(e.add_name)
	delete(e.look_pose)
	delete(e.asset_dir)
	delete(e.path)
	ac.trace("close")
	e^ = {}
}

// Who the player is, as far as a cutscene file can say: the game knows (it is
// whoever she is, World.player_name or the .char she wears) and the files do
// not. So: whoever is cast in most of the cutscenes beside this one, if that
// is more than half of them — the one person every scene has. Somebody the
// editor takes for her starts where she stands; anybody else with no at=, not
// standing in the room, is an extra, and waits off the side.
guess_player :: proc(path: string) -> string {
	dir := ui.parent_dir(ui.abs_path(path, context.temp_allocator))
	infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil do return strings.clone("")
	counts := make(map[string]int, allocator = context.temp_allocator)
	files := 0
	for f in infos {
		if !strings.has_suffix(f.name, ".cut") do continue
		data, rerr := os.read_entire_file(ui.path_join(dir, f.name), context.temp_allocator)
		if rerr != nil do continue
		files += 1
		seen := make(map[string]bool, allocator = context.temp_allocator)
		rest := string(data)
		for line in strings.split_lines_iterator(&rest) {
			w := strings.fields(line, context.temp_allocator)
			if len(w) < 2 || w[0] != "cast" || w[1] in seen do continue
			seen[w[1]] = true
			counts[w[1]] += 1
		}
	}
	best, most := "", 0
	for name, n in counts do if n > most || (n == most && name < best) do best, most = name, n
	if files < 2 || most * 2 <= files do return strings.clone("")
	return strings.clone(best)
}

// --- The room ---

// Reads the room the cut names, if it is not the one read already: its
// objects, floor and backdrop by name. Its pictures load as they are drawn.
load_room :: proc(e: ^Editor) {
	if e.has_room do ac.scene_free(&e.room)
	e.has_room = false
	ui.reset_string(&e.room_name, e.doc.scene)
	ui.reset_string(&e.room_path, ac.find_scene(e.asset_dir, e.doc.scene))
	if e.room_path != "" do e.room, e.has_room = ac.scene_read(e.room_path)
	e.sweep_at = e.frame + 1
	e.view = {}
	ac.trace("room %v: %v", e.doc.scene, e.room_path if e.has_room else "not found")
}

// --- A frame ---

step :: proc(e: ^Editor, status: ^ui.Status) -> bool {
	if !e.loaded do return false
	e.frame += 1
	e.art.frame = e.frame
	// Leaving with unsaved changes asked a question last frame; this is the
	// answer, if it has come.
	switch ui.leave_answer() {
	case .Save:    if save(e, status) do return false
	case .Discard: return false
	case .None:
	}

	// A question takes the window until it is answered.
	if ui.pick_active(&e.pick) {
		if a := ui.pick_step(&e.pick, status); a.done {
			px.browse_close(&e.pick_art)
			ac.room_preview_close(&e.pick_room)
			ac.sound_preview_close(&e.pick_sound)
			e.sweep_at = e.frame + 1
			if a.path != "" do picked(e, a.asking, a.path, status)
		}
		return true
	}
	if ui.choose_active(&e.choose) {
		if a := ui.choose_step(&e.choose, status); a.done {
			if a.key != "" && a.asking == "node" do chose_node(e, a.key, status)
			nodes_choices_free(&e.nodes)
		}
		return true
	}
	if e.doc.scene != e.room_name do load_room(e)

	screen := [2]f32{f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
	keys := footer_keys(e)
	foot := ui.footer_h(keys)
	body_y := HEAD_H + TOOLBAR_H
	body_h := screen.y - body_y - foot
	panel_x := ui.split_right("ncut.panel", PANEL_W, screen.x, HEAD_H, screen.y - HEAD_H - foot, 240, max(screen.x - 320, 240))
	split_y := ui.split_h("ncut.stage", body_y + body_h * 0.55, body_y, body_y + body_h, body_y + STAGE_MIN, body_y + body_h - 90)
	stage := rl.Rectangle{0, body_y, panel_x, split_y - body_y}
	line := rl.Rectangle{0, split_y, panel_x, body_y + body_h - split_y}
	bar := rl.Rectangle{0, HEAD_H, panel_x, TOOLBAR_H}
	panel := rl.Rectangle{panel_x, HEAD_H, screen.x - panel_x, screen.y - HEAD_H - foot}

	room_size(e)
	if e.view.zoom == 0 do e.view = ui.fit_view(e.size, stage)

	length := doc_length(&e.doc)
	if e.playing {
		e.t = f32(ui.now() - e.started)
		if e.t >= length {
			e.t = length
			e.playing = false
		}
	}

	// An edit left in a field is kept before anything else this frame can
	// move the lines it belongs to.
	if ui.text_input_clicked_away(&e.text) {
		commit(e, e.focus, ui.text_input_value(&e.text), status)
		ui.text_input_blur(&e.text)
	}

	leaving := false
	if !ui.typing(&e.text) {
		if ui.key_pressed(.ESCAPE) {
			switch {
			case e.adding:        stop_adding(e)
			case e.drag != .None: e.drag = .None
			case e.sel.kind != .Cut: e.sel = {}
			case: leaving = ui.leave_request(e.dirty, ui.file_of(e.path))
			}
		}
		if ui.back_pressed() do leaving = ui.leave_request(e.dirty, ui.file_of(e.path))
		if ui.undo_pressed() do step_back(e, status, false)
		if ui.redo_pressed() do step_back(e, status, true)
		if ui.save_pressed() do save(e, status)
		if !ui.ctrl_down() {
			if ui.key_pressed(.SPACE) do toggle_play(e)
			if ui.key_pressed(.A) do add_cue(e, status)
			if ui.key_pressed(.C) do start_adding(e)
			if ui.key_pressed(.DELETE) do remove_selected(e, status)
			if ui.key_pressed(.L) do set_light(e, ne.Light((int(e.light) + 1) % len(ne.Light)))
			if ui.key_pressed(.F) do e.view = ui.fit_view(e.size, stage)
		}
	}
	if rl.CheckCollisionPointRec(ui.mouse(), stage) do ui.pan_and_zoom(&e.view)

	rl.ClearBackground(ui.BG)
	draw_stage(e, stage)
	draw_timeline(e, line, length, status)
	draw_panel(e, panel, status)
	draw_toolbar(e, bar, status)
	ui.panel({0, 0, screen.x, HEAD_H})
	if ui.back_button() do leaving = leaving || ui.leave_request(e.dirty, ui.file_of(e.path))
	ui.title_bar(e.doc.name if e.doc.name != "" else ui.base_name(e.path), e.path, e.dirty, screen.x - 200, ui.BACK_W)
	if ui.button({screen.x - 186, 8, 60, 24}, "stop" if e.playing else "play") do toggle_play(e)
	ui.label(i32(screen.x) - 116, 13, fmt.tprintf("%.1f / %.1fs", e.t, length), ui.DIM, ui.SMALL)

	ui.splits_draw()
	ui.footer(status, keys)
	ui.text_input_sweep(&e.text)
	if e.sweep_at != 0 && e.frame >= e.sweep_at {
		ac.art_sweep(&e.art)
		e.sweep_at = 0
		ac.trace("art: %v pictures loaded", e.art.loaded)
	}
	return !leaving
}

@(private = "file")
footer_keys :: proc(e: ^Editor) -> string {
	if e.adding do return "type their name  Enter to add them  Esc to stop"
	return "space play  click a cue, drag it in time  drag somebody, or their walk ring  A +cue  C +cast  Del remove  L light  F fit  ^Z ^Y  ^S save  Esc ^B files"
}

// How big the room is: its backdrop in this light, blown up as the game
// blows it up.
@(private = "file")
room_size :: proc(e: ^Editor) {
	size := [2]f32{ROOM_W, ROOM_H}
	if e.has_room && e.room.background_name != "" {
		s, _ := ac.art_lit(&e.art, e.room.background_name, e.light, images = true)
		if s.texture.id != 0 do size = {f32(s.frame_w), f32(s.frame_h)}
	}
	if size != e.size {
		e.size = size
		e.view = {}
	}
}

// The strip over the stage: which light the room is shown in, and adding.
@(private = "file")
draw_toolbar :: proc(e: ^Editor, r: rl.Rectangle, status: ^ui.Status) {
	rl.DrawRectangleRec(r, {30, 30, 38, 255})
	ui.hline(i32(r.x), i32(r.y + r.height) - 1, i32(r.width))
	x := r.x + 8
	ui.label(i32(x), i32(r.y) + 8, "light", {110, 110, 126, 255}, ui.SMALL)
	x += 38
	painted: bit_set[ne.Light]
	if e.has_room do painted = ac.painted_lights(&e.art.index, e.room.background_name, images = true)
	for l in ne.Light {
		text := LIGHT_NAMES[l] if l in painted || !e.has_room else fmt.tprintf("%v~", LIGHT_NAMES[l])
		w := f32(ui.measure(text, ui.SMALL) + 14)
		if ui.chip({x, r.y + 4, w, 22}, text, e.light == l) do set_light(e, l)
		x += w + 3
	}
	x += 12
	ui.label(i32(x), i32(r.y) + 8, "add", {110, 110, 126, 255}, ui.SMALL)
	x += 30
	if x + 140 < r.x + r.width {
		if ui.chip({x, r.y + 4, 64, 22}, "cue (A)") do add_cue(e, status)
		if ui.chip({x + 68, r.y + 4, 70, 22}, "cast (C)", e.adding) do start_adding(e)
	}
}

LIGHT_NAMES := [ne.Light]string{.Day = "day", .Sunset = "sunset", .Night = "night", .Sunrise = "sunrise"}

set_light :: proc(e: ^Editor, l: ne.Light) {
	if e.light == l do return
	e.light = l
	e.sweep_at = e.frame + 1
}

@(private = "file")
toggle_play :: proc(e: ^Editor) {
	e.playing = !e.playing
	if e.playing {
		if e.t >= doc_length(&e.doc) - 0.01 do e.t = 0
		e.started = ui.now() - f64(e.t)
	}
}

save :: proc(e: ^Editor, status: ^ui.Status) -> bool {
	if !doc_save(&e.doc, e.path) {
		ui.say(status, "could not write %v", e.path)
		return false
	}
	e.dirty = false
	ui.say(status, "saved %v", ui.file_of(e.path))
	return true
}

// --- Asking the file browser, and the list of nodes ---

// Every room in the game in one list — each has a folder of its own, so the
// list is the scenes folder searched rather than walked — starting on the
// room it plays in now.
ask_room :: proc(e: ^Editor) {
	start := ui.path_join(e.asset_dir, "scenes")
	if !os.is_dir(start) do start = e.asset_dir
	ac.room_preview_close(&e.pick_room)
	e.pick_room.root = strings.clone(e.asset_dir)
	ui.pick_open(&e.pick, "room", "Choose the room it plays in", ac.ROOM_KINDS[:], start, select = e.room_path, preview = ac.room_preview, ctx = &e.pick_room, deep = true)
}

// A character for cast member `i`, starting where theirs is, or among the
// game's characters.
ask_char :: proc(e: ^Editor, i: int) {
	e.ask_for = i
	start := e.asset_dir
	if i >= 0 && i < len(e.doc.people) {
		if p, ok := e.art.index.chars[cast_view(e, i).char]; ok do start = p
	}
	if start == e.asset_dir do for _, p in e.art.index.chars {
		start = ui.parent_dir(p)
		break
	}
	ui.pick_open(&e.pick, "char", "Choose a character", px.ART_KINDS[1:], start, preview = px.art_preview, ctx = &e.pick_art)
}

// A sound for cue `i`, from the game's sounds.
ask_sound :: proc(e: ^Editor, i: int) {
	e.ask_for = i
	start := ""
	if i >= 0 && i < len(e.doc.cues) do start = ac.find_sound(e.asset_dir, e.doc.cues[i].q.text)
	if start == "" do start = ui.path_join(e.asset_dir, "sounds")
	if !os.exists(start) do start = e.asset_dir
	ac.sound_preview_close(&e.pick_sound)
	ui.pick_open(&e.pick, "sound", "Choose a sound", ac.SOUND_KINDS[:], start, preview = ac.sound_preview, ctx = &e.pick_sound, accept = ac.sound_listed)
}

// A node and its lines for `line` cue `i`.
ask_node :: proc(e: ^Editor, i: int, status: ^ui.Status) {
	nodes_load(&e.nodes, e.asset_dir)
	if len(e.nodes.ids) == 0 {
		ui.say(status, "no dialogue found beside %v", e.asset_dir)
		return
	}
	e.ask_for = i
	current := ""
	if i >= 0 && i < len(e.doc.cues) {
		q := e.doc.cues[i].q
		current = q.text
		ui.reset_string(&e.line_pick.node, q.text)
		ui.reset_string(&e.line_pick.tag, q.tag)
		e.line_pick.first, e.line_pick.last, e.line_pick.scroll = q.lines[0], q.lines[1], 0
	}
	ui.choose_open(&e.choose, "node", "Choose the lines: a dialogue node", nodes_choices(&e.nodes), current, draw_node_detail, e)
}

// The browser has answered.
@(private = "file")
picked :: proc(e: ^Editor, asking, path: string, status: ^ui.Status) {
	switch asking {
	case "room":
		name := ui.base_name(path)
		if !strings.has_prefix(path, e.asset_dir) do ui.say(status, "%v is not in this game's assets: the editor will not find it", ui.file_of(path))
		mark(e)
		doc_set_head(&e.doc, e.doc.name, name)
		changed(e)
		ui.say(status, "plays in %v", name)
	case "char":
		name := ac.index_name_of(e.art.index.chars, path)
		if name == "" {
			// Made since the editor opened, perhaps: look again.
			ac.index_destroy(&e.art.index)
			ac.index_build(&e.art.index, e.asset_dir)
			name = ac.index_name_of(e.art.index.chars, path)
		}
		if name == "" {
			ui.say(status, "%v is not in this game's assets, so the game could not load it", ui.file_of(path))
			return
		}
		if e.ask_for < 0 || e.ask_for >= len(e.doc.people) do return
		mark(e)
		doc_set_cast_field(&e.doc, e.ask_for, "char", name)
		changed(e)
		ui.say(status, "%v wears %v", e.doc.people[e.ask_for].m.name, name)
	case "sound":
		if e.ask_for < 0 || e.ask_for >= len(e.doc.cues) do return
		if !strings.has_prefix(path, e.asset_dir) do ui.say(status, "%v is not in this game's assets: the game will not find it", ui.file_of(path))
		q := e.doc.cues[e.ask_for].q
		q.text = ui.base_name(path)
		mark(e)
		doc_set_cue(&e.doc, e.ask_for, q)
		changed(e)
	}
}

@(private = "file")
chose_node :: proc(e: ^Editor, id: string, status: ^ui.Status) {
	if e.ask_for < 0 || e.ask_for >= len(e.doc.cues) do return
	p := &e.line_pick
	q := e.doc.cues[e.ask_for].q
	q.action = .Line
	q.who = ""
	q.text = id
	if p.node == id {
		q.lines = {max(p.first, 1), max(p.last, p.first, 1)}
		q.tag = p.tag
	} else {
		q.lines = {1, 1}
		q.tag = ""
	}
	mark(e)
	doc_set_cue(&e.doc, e.ask_for, q)
	changed(e)
	ui.say(status, "line %v %v", id, ne.line_range_text(q.lines))
}
