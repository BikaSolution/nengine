package background

import ne "../../../"
import ui "../../ui"
import px "../../pixel"
import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

// The backdrop editor. Same pixels as everything else in nart, but a room is
// not a hat, and the differences are what this is for.
//
// A backdrop is one 320x200 picture with no frames, so there is nothing to
// animate and no [ ] keys. What there is instead is the room it belongs to:
// where the floor is, where the objects stand, where the ways out are. Paint a
// wall across a doorway the player walks through and you'll find out in the
// game; paint it here and the floor is drawn over your wall while you work.
//
//   left mouse    paint          right mouse   rub out
//   middle drag   pan, wheel zooms
//   G             grid           H  thirds and the horizon
//   F             the room's floor, objects and exits, over the art
//   E             export the .png the game loads
//   Ctrl+S        save
//   Esc, ^B       back to the files (the < files button too); asks first if unsaved

// A backdrop is the design screen, exactly.
W :: i32(px.DESIGN_W)
H :: i32(px.DESIGN_H)

Editor :: struct {
	path:    string,
	data:    ne.Sprite_Data,
	canvas:  px.Canvas,
	text:    ui.Text_Input,
	history: ui.History,
	dirty:   bool,
	loaded:  bool,
	preview: px.Preview,

	guides:  bool, // thirds and the horizon
	overlay: bool, // the room this backdrop belongs to

	// The scene that names this backdrop, if one does. Loaded once when the
	// editor opens: it is reference, not something this editor changes.
	room:      Room,
}

open :: proc(e: ^Editor, path: string) -> bool {
	e^ = {path = strings.clone(path), canvas = {grid = false}, guides = true, overlay = true}

	if data, ok := ne.load_sprite_data(path); ok {
		e.data = data
	} else {
		e.data = px.new_data(px.asset_base(path), W, H, 1)
		e.dirty = true
	}
	room_find(&e.room, path)
	e.loaded = true
	e.preview.stale = true
	return true
}

close :: proc(e: ^Editor) {
	if !e.loaded do return
	room_close(&e.room)
	px.preview_destroy(&e.preview)
	px.canvas_destroy(&e.canvas)
	ui.text_input_destroy(&e.text)
	ui.history_destroy(&e.history)
	ne.sprite_data_destroy(&e.data)
	delete(e.path)
	e^ = {}
}

step :: proc(e: ^Editor, status: ^ui.Status) -> bool {
	if !e.loaded do return false
	// Leaving with unsaved changes asked a question last frame; this is the
	// answer, if it has come.
	switch ui.leave_answer() {
	case .Save:    if save(e, status) do return false
	case .Discard: return false
	case .None:
	}
	screen := [2]f32{f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
	body_h := screen.y - 40 - ui.footer_h(KEYS) // the header above, and the keys below
	side_x := ui.split_right("nart.side", px.SIDE_W, screen.x, 40, body_h, 150, max(screen.x - 220, 150))
	area := rl.Rectangle{0, 40, side_x, body_h}
	side := rl.Rectangle{side_x, 40, screen.x - side_x, body_h}
	px.canvas_ready(&e.canvas, &e.data, area)

	// --- input ---
	if !ui.typing(&e.text) {
		if ui.key_pressed(.ESCAPE) {
			if e.canvas.has_sel {
				e.canvas.has_sel = false
			} else if ui.leave_request(e.dirty, ui.file_of(e.path)) {
				return false
			}
		}
		if ui.back_pressed() && ui.leave_request(e.dirty, ui.file_of(e.path)) do return false
		if ui.undo_pressed() do step_back(e, status, false)
		if ui.redo_pressed() do step_back(e, status, true)
		if ui.select_all_pressed() do px.canvas_select_all(&e.canvas, &e.data)
		if ui.copy_pressed() || ui.cut_pressed() {
			r := px.canvas_selection(&e.canvas, &e.data)
			px.clip_copy(&e.data, 0, r)
			if ui.cut_pressed() {
				mark(e)
				for y in 0 ..< r[3] do for x in 0 ..< r[2] {
					if cell := ne.sprite_data_at(&e.data, 0, r[0] + x, r[1] + y); cell != nil do cell^ = 0
				}
				e.dirty, e.preview.stale, e.canvas.stale = true, true, true
			}
			ui.say(status, "%v x %v copied", r[2], r[3])
		}
		if ui.paste_pressed() {
			mark(e)
			at := px.canvas_selection(&e.canvas, &e.data)
			if px.clip_paste(&e.data, 0, at[0], at[1]) {
				e.dirty, e.preview.stale, e.canvas.stale = true, true, true
				ui.say(status, "pasted %v x %v", px.clipboard.w, px.clipboard.h)
			} else {
				ui.say(status, "nothing to paste")
			}
		}
		if ui.key_pressed(.G) do e.canvas.grid = !e.canvas.grid
		px.canvas_brush_keys(&e.canvas, &e.data, status)
		if ui.key_pressed(.H) do e.guides = !e.guides
		if ui.key_pressed(.F) {
			e.overlay = !e.overlay
			if e.overlay && !e.room.ok do ui.say(status, "no .scene uses this backdrop")
		}
		if ui.key_pressed(.E) do export_png(e, status)
		if ui.save_pressed() do save(e, status)
	}
	if px.canvas_stroke_started(&e.canvas, area) do mark(e)
	if px.canvas_paint(&e.canvas, &e.data, 0, area) do e.dirty, e.preview.stale = true, true

	// --- draw ---
	rl.ClearBackground(ui.BG)
	px.canvas_draw(&e.canvas, &e.data, 0, area)
	if e.guides do draw_guides(e, area)
	if e.overlay do room_draw(&e.room, e.canvas.view, area)

	ui.panel({0, 0, screen.x, 40})
	leaving := ui.back_button() && ui.leave_request(e.dirty, ui.file_of(e.path))
	ui.title_bar(e.data.name, e.path, e.dirty, side_x - 10, ui.BACK_W)
	ui.label(i32(side_x) + 10, 11, px.canvas_mode_line(&e.data), ui.DIM, ui.SMALL)

	ui.panel(side)
	x := side.x + 10
	w := side.width - 20
	ui.label(i32(x), 50, "colours  (shift + -)", ui.DIM, ui.SMALL)
	used := px.canvas_palette(&e.canvas, &e.data, x, 70, w)
	used += px.canvas_brush_panel(&e.canvas, x, 70 + used + 10, w) + 10
	used += px.canvas_dither_panel(&e.canvas, &e.data, x, 70 + used + 10, w) + 10
	used += px.canvas_mixer(&e.canvas, &e.data, x, 70 + used, w)

	y := 70 + used + 14
	// A backdrop that isn't the size of the screen will be stretched or
	// cropped by the engine, so say so rather than letting it be a surprise.
	if e.data.w != W || e.data.h != H {
		ui.label(i32(x), i32(y), fmt.tprintf("%vx%v, not %vx%v", e.data.w, e.data.h, W, H), ui.GOLD, ui.SMALL)
		y += 18
		if ui.button({x, y, w, 22}, "make it 320x200") {
			mark(e)
			ne.sprite_data_resize(&e.data, W, H)
			e.canvas.view = {}
			e.canvas.stale, e.dirty, e.preview.stale = true, true, true
		}
		y += 30
	}

	ui.label(i32(x), i32(y), "showing", ui.DIM, ui.SMALL)
	y += 18
	if ui.button({x, y, w / 3 - 2, 22}, "grid", e.canvas.grid) do e.canvas.grid = !e.canvas.grid
	if ui.button({x + w / 3, y, w / 3 - 2, 22}, "thirds", e.guides) do e.guides = !e.guides
	if ui.button({x + 2 * w / 3, y, w / 3, 22}, "room", e.overlay) do e.overlay = !e.overlay
	y += 30

	if e.room.ok {
		ui.label(i32(x), i32(y), ui.ellipsize(fmt.tprintf("room: %v", e.room.name), w, ui.SMALL), {150, 172, 196, 255}, ui.SMALL)
		y += 18
		ui.label(i32(x), i32(y), fmt.tprintf("%v objects, %v exits", len(e.room.objects), len(e.room.exits)), ui.DIM, ui.SMALL)
	} else {
		ui.label(i32(x), i32(y), "no .scene uses this yet", {96, 96, 112, 255}, ui.SMALL)
	}
	y += 28

	if ui.button({x, y, w, 24}, "export .png") do export_png(e, status)
	y += 34

	ui.label(i32(x), i32(y), "as the game sees it", ui.DIM, ui.SMALL)
	px.preview_draw(&e.preview, &e.data, {x, y + 18}, 1, w)

	ui.splits_draw()
	ui.footer(status, KEYS)
	return !leaving
}

// Thirds, and a horizon two-thirds down. Not rules — a room drawn to them
// looks composed rather than centred, and it costs one keypress to hide them.
@(private = "file")
draw_guides :: proc(e: ^Editor, area: rl.Rectangle) {
	rl.BeginScissorMode(i32(area.x), i32(area.y), i32(area.width), i32(area.height))
	defer rl.EndScissorMode()
	tl := ui.to_screen(e.canvas.view, {0, 0})
	br := ui.to_screen(e.canvas.view, {f32(e.data.w), f32(e.data.h)})
	faint := rl.Color{120, 140, 200, 60}
	for i in 1 ..< 3 {
		x := tl.x + (br.x - tl.x) * f32(i) / 3
		y := tl.y + (br.y - tl.y) * f32(i) / 3
		rl.DrawLineEx({x, tl.y}, {x, br.y}, 1, faint)
		rl.DrawLineEx({tl.x, y}, {br.x, y}, 1, faint)
	}
	// The horizon: where a standing figure's eyes are, which is what makes a
	// room read as a room rather than a pattern.
	hy := tl.y + (br.y - tl.y) * 0.62
	rl.DrawLineEx({tl.x, hy}, {br.x, hy}, 1, {200, 170, 110, 90})
}

@(private = "file")
save :: proc(e: ^Editor, status: ^ui.Status) -> bool {
	if !ne.save_sprite_data(&e.data, e.path) {
		ui.say(status, "could not write %v", e.path)
		return false
	}
	e.dirty = false
	ui.say(status, "saved %v", e.path)
	return true
}

@(private = "file")
mark :: proc(e: ^Editor) {
	ui.history_mark(&e.history, ne.sprite_data_text(&e.data))
}

@(private = "file")
step_back :: proc(e: ^Editor, status: ^ui.Status, forward: bool) {
	now := ne.sprite_data_text(&e.data)
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
	back, good := ne.parse_sprite_data(step)
	if !good do return
	ne.sprite_data_destroy(&e.data)
	e.data = back
	e.canvas.has_sel = false
	e.dirty, e.preview.stale, e.canvas.stale = true, true, true
	ui.say(status, "redone" if forward else "undone")
}

// The picture the game actually loads, written beside the source at the scale
// the engine blows art up by. A backdrop is the one kind of art that has to be
// exported: scenes load the .png, not the .sprite.
@(private = "file")
export_png :: proc(e: ^Editor, status: ^ui.Status) {
	png := fmt.tprintf("%v.png", strings.trim_suffix(e.path, ".sprite"))
	img := ne.sprite_data_to_image(&e.data, PNG_SCALE)
	defer rl.UnloadImage(img)
	if rl.ExportImage(img, fmt.ctprintf("%v", png)) {
		ui.say(status, "wrote %v  (%vx%v)", png, img.width, img.height)
	} else {
		ui.say(status, "could not write %v", png)
	}
}

// 320 wide becomes 1024, the canvas the game runs at.
PNG_SCALE :: 3.2

// A new backdrop is the screen, full of nothing, in the mode it will be drawn in.
write_blank :: proc(path, name: string, mode := px.DEFAULT_MODE) -> bool {
	d := px.new_data(name, W, H, 1, mode)
	defer ne.sprite_data_destroy(&d)
	return ne.save_sprite_data(&d, path)
}

// Is this .sprite a backdrop? By size: a room fills the screen and a hat does
// not, and nothing else in the format says which is which.
is_backdrop :: proc(path: string) -> bool {
	d, ok := ne.load_sprite_data(path)
	if !ok do return strings.contains(path, "/scenes/") // unreadable: guess by where it lives
	defer ne.sprite_data_destroy(&d)
	return d.w >= W - 8 && d.h >= H - 8
}

// The footer: this editor's keys, then the brush's, which every painting
// editor shares (px.BRUSH_KEYS).
KEYS :: "LMB paint  RMB erase  shift-drag select  ^C ^V ^X  ^Z undo  G grid  H thirds  F room  E export  ^S save  Esc ^B files  " + px.BRUSH_KEYS
