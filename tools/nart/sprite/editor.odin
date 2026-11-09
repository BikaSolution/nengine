package sprite

import ne "../../../"
import ui "../../ui"
import px "../../pixel"
import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

// The pixel art editor. Draws into a .sprite file: a grid of palette
// indices, one grid per animation frame.
//
//   left mouse    paint with the chosen colour
//   right mouse   rub out (back to transparent)
//   middle drag   pan, wheel zooms
//   [ ]           previous / next frame
//   N             add a frame (a copy of this one)
//   Shift+N       remove this frame
//   G             grid on/off
//   Ctrl+S        save
//   Esc, ^B       back to the files (the < files button too); asks first if unsaved

Editor :: struct {
	path:    string,
	data:    ne.Sprite_Data,
	frame:   i32,
	canvas:  px.Canvas,
	text:    ui.Text_Input,
	history: ui.History,
	dirty:   bool,
	loaded:  bool,
	preview: px.Preview,
}

// Opens `path`, or starts a new sprite of that size if the file isn't there.
open :: proc(e: ^Editor, path: string, w: i32 = 16, h: i32 = 16) -> bool {
	e^ = {path = strings.clone(path), canvas = {grid = true}}

	if data, ok := ne.load_sprite_data(path); ok {
		e.data = data
	} else {
		e.data = ne.sprite_data_new(px.asset_base(path), w, h, 1)
		e.dirty = true
	}
	e.loaded = true
	e.preview.stale = true
	return true
}

close :: proc(e: ^Editor) {
	if !e.loaded do return
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
			// Esc drops the selection first, and only then leaves.
			if e.canvas.has_sel {
				e.canvas.has_sel = false
			} else if ui.leave_request(e.dirty, ui.file_of(e.path)) {
				return false
			}
		}
		if ui.back_pressed() && ui.leave_request(e.dirty, ui.file_of(e.path)) do return false
		if ui.undo_pressed() do sprite_step_back(e, status, false)
		if ui.redo_pressed() do sprite_step_back(e, status, true)
		if ui.select_all_pressed() do px.canvas_select_all(&e.canvas, &e.data)
		if ui.copy_pressed() || ui.cut_pressed() {
			r := px.canvas_selection(&e.canvas, &e.data)
			px.clip_copy(&e.data, e.frame, r)
			if ui.cut_pressed() {
				sprite_mark(e)
				for y in 0 ..< r[3] do for x in 0 ..< r[2] {
					if cell := ne.sprite_data_at(&e.data, e.frame, r[0] + x, r[1] + y); cell != nil do cell^ = 0
				}
				e.dirty, e.preview.stale, e.canvas.stale = true, true, true
			}
			ui.say(status, "%v x %v copied", r[2], r[3])
		}
		if ui.paste_pressed() {
			sprite_mark(e)
			at := px.canvas_selection(&e.canvas, &e.data)
			if px.clip_paste(&e.data, e.frame, at[0], at[1]) {
				e.dirty, e.preview.stale, e.canvas.stale = true, true, true
				ui.say(status, "pasted %v x %v", px.clipboard.w, px.clipboard.h)
			} else {
				ui.say(status, "nothing to paste")
			}
		}
		if ui.key_pressed(.G) do e.canvas.grid = !e.canvas.grid
		px.canvas_brush_keys(&e.canvas, &e.data, status)
		if ui.key_pressed(.LEFT_BRACKET) do e.frame = (e.frame + e.data.frames - 1) % e.data.frames
		if ui.key_pressed(.RIGHT_BRACKET) do e.frame = (e.frame + 1) % e.data.frames
		if ui.key_pressed(.N) {
			sprite_mark(e)
			if ui.shift_down() {
				if px.canvas_remove_frame(&e.data, e.frame) {
					e.frame = min(e.frame, e.data.frames - 1)
					e.dirty, e.preview.stale, e.canvas.stale = true, true, true
					ui.say(status, "%v frames left", e.data.frames)
				}
			} else {
				px.canvas_add_frame(&e.data, e.frame)
				e.frame = e.data.frames - 1
				e.dirty, e.preview.stale, e.canvas.stale = true, true, true
				ui.say(status, "frame %v of %v", e.frame + 1, e.data.frames)
			}
		}
		if ui.save_pressed() do save(e, status)
	}
	// One snapshot per stroke, taken as the button goes down.
	if px.canvas_stroke_started(&e.canvas, area) do sprite_mark(e)
	if px.canvas_paint(&e.canvas, &e.data, e.frame, area) {
		e.dirty, e.preview.stale = true, true
	}

	// --- draw ---
	rl.ClearBackground(ui.BG)
	px.canvas_draw(&e.canvas, &e.data, e.frame, area)

	ui.panel({0, 0, screen.x, 40})
	leaving := ui.back_button() && ui.leave_request(e.dirty, ui.file_of(e.path))
	ui.label(ui.BACK_W, 11, fmt.tprintf("%v  %vx%v  frame %v/%v%v", e.data.name, e.data.w, e.data.h,
		e.frame + 1, e.data.frames, "  *" if e.dirty else ""))
	ui.label(ui.BACK_W, 26, px.canvas_mode_line(&e.data), ui.DIM, ui.SMALL)

	ui.panel(side)
	x := side.x + 10
	w := side.width - 20
	ui.label(i32(x), 50, "colours  (shift + -)", ui.DIM, ui.SMALL)
	used := px.canvas_palette(&e.canvas, &e.data, x, 70, w)
	used += px.canvas_brush_panel(&e.canvas, x, 70 + used + 10, w) + 10
	used += px.canvas_dither_panel(&e.canvas, &e.data, x, 70 + used + 10, w) + 10
	used += px.canvas_mixer(&e.canvas, &e.data, x, 70 + used, w)

	// Size. A backdrop is 320x200; a hat is 12x10. Both start somewhere else,
	// so this has to be somewhere you can find it.
	y := 70 + used + 14
	ui.label(i32(x), i32(y), "size  (shift steps by 8)", ui.DIM, ui.SMALL)
	y += 18
	ui.label(i32(x), i32(y) + 6, "w", ui.DIM, ui.SMALL)
	if v, done := ui.number_field(&e.text, {x + 14, y, w - 14, 24}, "s.w", int(e.data.w)); done {
		resize_sprite(e, i32(v), e.data.h, status)
	}
	y += 28
	ui.label(i32(x), i32(y) + 6, "h", ui.DIM, ui.SMALL)
	if v, done := ui.number_field(&e.text, {x + 14, y, w - 14, 24}, "s.h", int(e.data.h)); done {
		resize_sprite(e, e.data.w, i32(v), status)
	}

	y += 32
	if ui.button({x, y, w, 24}, "export .png") do export_png(e, status)

	y += 34
	ui.label(i32(x), i32(y), "as the game sees it", ui.DIM, ui.SMALL)
	px.preview_draw(&e.preview, &e.data, {x, y + 18}, 2, w)

	ui.splits_draw()
	ui.footer(status, KEYS)
	return !leaving
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

// Remembers the document as it is, before something changes it.
@(private = "file")
sprite_mark :: proc(e: ^Editor) {
	ui.history_mark(&e.history, ne.sprite_data_text(&e.data))
}

@(private = "file")
sprite_step_back :: proc(e: ^Editor, status: ^ui.Status, forward: bool) {
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
	e.frame = clamp(e.frame, 0, e.data.frames - 1)
	e.canvas.has_sel = false
	e.dirty, e.preview.stale, e.canvas.stale = true, true, true
	ui.say(status, "redone" if forward else "undone")
}

@(private = "file")
resize_sprite :: proc(e: ^Editor, w, h: i32, status: ^ui.Status) {
	if w == e.data.w && h == e.data.h do return
	sprite_mark(e)
	ne.sprite_data_resize(&e.data, w, h)
	e.canvas.view = {} // fit the new shape
	e.canvas.stale = true
	e.dirty, e.preview.stale = true, true
	ui.say(status, "%vx%v", e.data.w, e.data.h)
}

// Writes the sprite out as a picture, beside the file, at the scale the game
// blows it up to. This is how a backdrop becomes the .png a scene loads.
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

// How much a picture is blown up on the way out. The same 320-to-1024 scale
// the engine loads sprites at, so an exported backdrop is canvas-sized.
PNG_SCALE :: 3.2

// Used by the CLI: make a blank sprite file without opening a window.
write_blank :: proc(path, name: string, w, h, frames: i32, mode := px.DEFAULT_MODE) -> bool {
	d := px.new_data(name, w, h, frames, mode)
	defer ne.sprite_data_destroy(&d)
	return ne.save_sprite_data(&d, path)
}

// The footer: this editor's keys, then the brush's, which every painting
// editor shares (px.BRUSH_KEYS).
KEYS :: "LMB paint  RMB erase  shift-drag select  ^C ^V ^X  ^Z undo  [ ] frame  N +frame  G grid  ^S save  Esc ^B files  " + px.BRUSH_KEYS
