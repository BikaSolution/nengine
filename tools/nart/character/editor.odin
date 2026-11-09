package character

import ne "../../../"
import ui "../../ui"
import px "../../pixel"
import "core:fmt"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

// The character editor. One .char file holds everything a person looks like:
// standing four ways, walking four ways, talking, and a face for close-ups.
//
// It's the pixel art editor with a list of poses down the side. The parts
// share one palette, so a character stays one character, and every part has
// its own size and its own speed — a face can be bigger and blink slower
// than the body walks.
//
// The ten standard poses are always in the list, drawn or not, because the
// engine looks them up by name. **Everything after them is an extra**, and a
// character may have as many as it likes: sitting, kneeling, at a tripod,
// dead. Nothing picks an extra on its own — a routine asks for one with
// `step moore play chair 4`, a cutscene cue does the same, and game code sets
// `Actor.pose`. Most of them start life as a copy of a pose that is already
// drawn, which is what D is for.
//
//   left mouse    paint          right mouse   rub out
//   up/down       previous / next pose         [ ] frame
//   N / Shift+N   add / remove a frame
//   A             new pose       D   copy this pose under a new name
//   R             rename an extra      Delete   remove an extra
//   P             play the pose at its own speed
//   G             grid on/off   Ctrl+S save    Esc leave

Editor :: struct {
	path:    string,
	ch:      ne.Character,
	part:    int, // index into ch.parts
	frame:   i32,
	canvas:  px.Canvas,
	text:    ui.Text_Input,
	history: ui.History,
	preview: px.Preview,
	playing: bool,
	dirty:   bool,
	loaded:  bool,
	naming:  Naming,  // the one text box, and what it is about to do
	armed:   bool,    // remove asked for once; a second press does it
	pending: Pending, // a change to the list of poses, applied next frame
}

// Naming a pose is three jobs with one text box: a new one, a copy of this
// one, or a new name for this one. The box says which.
Naming :: enum {
	None,
	New,
	Copy,
	Rename,
}

// Adding or removing a pose moves the parts array, which the canvas, the
// preview and the side panel are all holding a pointer into for the rest of
// the frame. So the click records what to do and the top of the next frame
// does it, before anything takes a pointer.
Pending :: struct {
	naming: Naming, // .None for nothing to do
	remove: bool,
	from:   string, // which pose a copy or a rename is about — owned
	name:   string, // what it is to be called — owned
}

// Where the poses list starts out; dragged from there like every other column.
PARTS_W :: f32(190)

open :: proc(e: ^Editor, path: string) -> bool {
	e^ = {path = strings.clone(path), canvas = {grid = true}}

	if ch, ok := ne.load_character(path); ok {
		e.ch = ch
	} else {
		e.ch = ne.character_new(px.asset_base(path))
		e.ch.mode = px.DEFAULT_MODE
		e.dirty = true
	}
	// Every character has the standard poses, even if they're still blank —
	// you can't draw a pose that isn't in the list.
	for name in ne.CHAR_PARTS {
		if ne.character_part(&e.ch, name) == nil {
			frames: i32 = 1
			fps: f32 = 0
			if strings.has_prefix(name, "walk") do frames, fps = 4, 8
			if name == "talk" || name == "face" do frames, fps = 3, 6
			ne.character_add_part(&e.ch, name, frames, fps)
		}
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
	ne.character_destroy(&e.ch)
	delete(e.path)
	pending_clear(e)
	e^ = {}
}

step :: proc(e: ^Editor, status: ^ui.Status) -> bool {
	if !e.loaded do return false
	if len(e.ch.parts) == 0 do return false
	// Leaving with unsaved changes asked a question last frame; this is the
	// answer, if it has come.
	switch ui.leave_answer() {
	case .Save:    if save(e, status) do return false
	case .Discard: return false
	case .None:
	}
	screen := [2]f32{f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
	body_h := screen.y - 40 - ui.footer_h(KEYS) // the header above, and the keys below
	parts_w := ui.split("nart.parts", PARTS_W, 40, body_h, 120, max(screen.x * 0.4, 120))
	side_x := ui.split_right("nart.side", px.SIDE_W, screen.x, 40, body_h, 150, max(screen.x - parts_w - 200, 150))
	area := rl.Rectangle{parts_w, 40, side_x - parts_w, body_h}
	parts := rl.Rectangle{0, 40, parts_w, body_h}
	// The panel the divider actually moves. It used to be pinned at 220 wide
	// at a fixed offset, so `side_x` moved the drawing area and the handle and
	// the panel stayed exactly as it was — the divider appeared to do nothing,
	// because for this pane it did nothing.
	side := rl.Rectangle{side_x, 40, screen.x - side_x, body_h}

	// Poses added or removed last frame, before anything takes a pointer.
	apply_pending(e, status)

	e.part = clamp(e.part, 0, len(e.ch.parts) - 1)
	part := &e.ch.parts[e.part]
	e.frame = clamp(e.frame, 0, part.data.frames - 1)
	px.canvas_ready(&e.canvas, &part.data, area)

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
		if ui.undo_pressed() do char_step_back(e, status, false)
		if ui.redo_pressed() do char_step_back(e, status, true)
		if ui.select_all_pressed() do px.canvas_select_all(&e.canvas, &part.data)
		if ui.copy_pressed() || ui.cut_pressed() {
			r := px.canvas_selection(&e.canvas, &part.data)
			px.clip_copy(&part.data, e.frame, r)
			if ui.cut_pressed() {
				char_mark(e)
				for y in 0 ..< r[3] do for x in 0 ..< r[2] {
					if cell := ne.sprite_data_at(&part.data, e.frame, r[0] + x, r[1] + y); cell != nil do cell^ = 0
				}
				e.dirty, e.preview.stale, e.canvas.stale = true, true, true
			}
			ui.say(status, "%v x %v copied", r[2], r[3])
		}
		if ui.paste_pressed() {
			char_mark(e)
			at := px.canvas_selection(&e.canvas, &part.data)
			if px.clip_paste(&part.data, e.frame, at[0], at[1]) {
				e.dirty, e.preview.stale, e.canvas.stale = true, true, true
				ui.say(status, "pasted into %v", part.name)
			} else {
				ui.say(status, "nothing to paste")
			}
		}
		if ui.key_pressed(.G) do e.canvas.grid = !e.canvas.grid
		px.canvas_brush_keys(&e.canvas, &part.data, status)
		if ui.key_pressed(.P) do e.playing = !e.playing
		// Up and down walk the list as it is shown — the ten, then the extras —
		// rather than the order the file happens to hold them in.
		if ui.key_pressed(.DOWN) do step_part(e, 1)
		if ui.key_pressed(.UP) do step_part(e, -1)

		// A pose of its own: new, a copy of this one, renamed, or gone.
		if ui.key_pressed(.A) && !ui.ctrl_down() do start_naming(e, .New, "")
		if ui.key_pressed(.D) do start_naming(e, .Copy, suggest_name(e, part.name))
		if ui.key_pressed(.R) {
			if ne.char_part_standard(part.name) {
				ui.say(status, "%v is one of the ten; it keeps its name", part.name)
			} else {
				start_naming(e, .Rename, part.name)
			}
		}
		if ui.key_pressed(.DELETE) do ask_remove(e, status, part.name)
		if ui.key_pressed(.LEFT_BRACKET) do e.frame = (e.frame + part.data.frames - 1) % part.data.frames
		if ui.key_pressed(.RIGHT_BRACKET) do e.frame = (e.frame + 1) % part.data.frames
		if ui.key_pressed(.N) {
			char_mark(e)
			if ui.shift_down() {
				if px.canvas_remove_frame(&part.data, e.frame) {
					e.frame = min(e.frame, part.data.frames - 1)
					e.dirty, e.preview.stale, e.canvas.stale = true, true, true
				}
			} else {
				px.canvas_add_frame(&part.data, e.frame)
				e.frame = part.data.frames - 1
				e.dirty, e.preview.stale, e.canvas.stale = true, true, true
			}
			ui.say(status, "%v: %v frames", part.name, part.data.frames)
		}
		if ui.save_pressed() do save(e, status)
	}
	if px.canvas_stroke_started(&e.canvas, area) do char_mark(e)
	if px.canvas_paint(&e.canvas, &part.data, e.frame, area) {
		e.dirty, e.preview.stale = true, true
	}

	// --- draw ---
	rl.ClearBackground(ui.BG)
	px.canvas_draw(&e.canvas, &part.data, e.frame, area)

	ui.panel({0, 0, screen.x, 40})
	leaving := ui.back_button() && ui.leave_request(e.dirty, ui.file_of(e.path))
	ui.label(ui.BACK_W, 11, fmt.tprintf("%v  -  %v  %vx%v  frame %v/%v%v", e.ch.name, part.name,
		part.data.w, part.data.h, e.frame + 1, part.data.frames, "  *" if e.dirty else ""))
	ui.label(ui.BACK_W, 26, px.canvas_mode_line(&part.data), ui.DIM, ui.SMALL)

	draw_parts_list(e, parts)
	draw_char_side(e, side, part)

	ui.splits_draw()
	ui.footer(status, KEYS)
	return !leaving
}

@(private = "file")
save :: proc(e: ^Editor, status: ^ui.Status) -> bool {
	if !ne.save_character(&e.ch, e.path) {
		ui.say(status, "could not write %v", e.path)
		return false
	}
	e.dirty = false
	ui.say(status, "saved %v", e.path)
	return true
}

@(private = "file")
char_mark :: proc(e: ^Editor) {
	ui.history_mark(&e.history, ne.character_text(&e.ch))
}

@(private = "file")
char_step_back :: proc(e: ^Editor, status: ^ui.Status, forward: bool) {
	now := ne.character_text(&e.ch)
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
	back, good := ne.parse_character(step)
	if !good do return
	ne.character_destroy(&e.ch)
	e.ch = back
	e.part = clamp(e.part, 0, max(len(e.ch.parts) - 1, 0))
	e.canvas.has_sel = false
	e.dirty, e.preview.stale, e.canvas.stale = true, true, true
	ui.say(status, "redone" if forward else "undone")
}

@(private = "file")
choose_part :: proc(e: ^Editor, index: int) {
	e.part = clamp(index, 0, len(e.ch.parts) - 1)
	e.frame = 0
	e.armed = false // a remove asked for on one pose doesn't carry to the next
	e.canvas.view = {} // the new pose may be a different size, so fit it again
	e.canvas.stale = true
	e.preview.stale = true
}

// How tall the block of buttons at the foot of the poses list is. It is
// pinned there so that a character with a dozen extras still has somewhere to
// add the thirteenth.
ACTIONS_H :: f32(126)

// The poses down the left: the standard ten, then the extras, then the
// buttons that make more of them.
@(private = "file")
draw_parts_list :: proc(e: ^Editor, r: rl.Rectangle) {
	ui.panel(r)
	list := rl.Rectangle{r.x, r.y, r.width, r.height - ACTIONS_H}

	// A long list runs off the bottom; the buttons below it must not.
	rl.BeginScissorMode(i32(list.x), i32(list.y), i32(list.width), i32(list.height))
	y := list.y + 10
	ui.label(i32(r.x) + 10, i32(y), "poses", ui.DIM, ui.SMALL)
	y += 22

	extras := false
	for idx in part_order(e) {
		p := &e.ch.parts[idx]
		if !extras && !ne.char_part_standard(p.name) {
			extras = true
			y = heading(r, y, "extras")
		}
		row := rl.Rectangle{r.x + 6, y, r.width - 12, 26}
		if ui.button(row, p.name, idx == e.part) do choose_part(e, idx)
		// Blank poses are the ones still to do, so they're worth pointing out.
		if !part_drawn(p) {
			ui.label(i32(row.x + row.width) - 46, i32(row.y) + 7, "empty", rl.Color{150, 90, 90, 255}, ui.SMALL)
		} else if p.data.frames > 1 {
			ui.label(i32(row.x + row.width) - 34, i32(row.y) + 7, fmt.tprintf("x%v", p.data.frames), ui.DIM, ui.SMALL)
		}
		y += 30
	}
	if !extras {
		y = heading(r, y, "extras")
		ui.label(i32(r.x) + 10, i32(y) + 4, "none yet - press A", ui.DIM, ui.SMALL)
	}
	rl.EndScissorMode()

	draw_part_actions(e, {r.x, r.y + r.height - ACTIONS_H, r.width, ACTIONS_H})
}

// A rule and a word, between the ten and the rest.
@(private = "file")
heading :: proc(r: rl.Rectangle, y: f32, text: string) -> f32 {
	ui.hline(i32(r.x) + 8, i32(y) + 6, i32(r.width) - 16)
	ui.label(i32(r.x) + 10, i32(y) + 14, text, ui.DIM, ui.SMALL)
	return y + 36
}

// New, copy, rename, remove — and the one text box all three naming jobs
// share, which says what it is about to do so that Enter is never a guess.
@(private = "file")
draw_part_actions :: proc(e: ^Editor, r: rl.Rectangle) {
	part := &e.ch.parts[clamp(e.part, 0, len(e.ch.parts) - 1)]
	standard := ne.char_part_standard(part.name)
	x := r.x + 6
	w := r.width - 12
	half := (w - 4) / 2
	y := r.y + 8
	ui.hline(i32(r.x), i32(r.y), i32(r.width))

	if e.naming != .None {
		prompt := "new pose"
		switch e.naming {
		case .Copy:   prompt = fmt.tprintf("copy %v as", part.name)
		case .Rename: prompt = fmt.tprintf("rename %v to", part.name)
		case .New, .None:
		}
		ui.label(i32(x), i32(y), ui.ellipsize(prompt, w, ui.SMALL), ui.GOLD, ui.SMALL)
		y += 20
		if name, done := ui.text_field(&e.text, {x, y, w, 26}, "p.name", ""); done {
			queue_naming(e, e.naming, part.name, strings.trim_space(name))
			e.naming = .None
		} else if e.text.focus != "p.name" {
			e.naming = .None // clicked away, or Escape
		}
		y += 32
		ui.label(i32(x), i32(y), "letters, digits, _", ui.DIM, ui.SMALL)
		return
	}

	if ui.button({x, y, w, 26}, "+ new pose") do start_naming(e, .New, "")
	y += 30

	// Copying works on anything — an extra usually starts as a copy of a pose
	// that is already drawn. Renaming and removing are for extras only, so on
	// one of the ten those buttons are not there to be pressed at all.
	if standard {
		if ui.button({x, y, w, 26}, fmt.tprintf("copy %v", ui.ellipsize(part.name, w - 60, ui.SMALL))) {
			start_naming(e, .Copy, suggest_name(e, part.name))
		}
		y += 30
		// The ten are not a matter of taste: something is looking them up.
		ui.label(i32(x), i32(y) + 6, "one of the standard ten", ui.DIM, ui.SMALL)
		return
	}

	if ui.button({x, y, half, 26}, "copy") do start_naming(e, .Copy, suggest_name(e, part.name))
	if ui.button({x + half + 4, y, half, 26}, "rename") do start_naming(e, .Rename, part.name)
	y += 30
	if ui.button({x, y, w, 26}, "remove again?" if e.armed else "remove pose", e.armed) {
		if e.armed {
			queue_remove(e, part.name)
			e.armed = false
		} else {
			e.armed = true
		}
	}
}

// The order the list is drawn in: the standard ten first, in the order the
// engine thinks of them, then every extra in the order the file holds them.
// The file itself is left alone — this is a way of looking at it.
@(private = "file")
part_order :: proc(e: ^Editor) -> []int {
	out := make([dynamic]int, 0, len(e.ch.parts), context.temp_allocator)
	for want in ne.CHAR_PARTS {
		for &p, i in e.ch.parts do if p.name == want do append(&out, i)
	}
	for &p, i in e.ch.parts do if !ne.char_part_standard(p.name) do append(&out, i)
	return out[:]
}

// Up and down, through the list as it is shown.
@(private = "file")
step_part :: proc(e: ^Editor, by: int) {
	order := part_order(e)
	at := 0
	for idx, i in order do if idx == e.part do at = i
	if len(order) == 0 do return
	choose_part(e, order[clamp(at + by, 0, len(order) - 1)])
}

// Opens the naming box with something already in it, so Enter alone does the
// obvious thing.
@(private = "file")
start_naming :: proc(e: ^Editor, what: Naming, suggestion: string) {
	e.naming = what
	e.armed = false
	ui.text_input_focus(&e.text, "p.name", suggestion)
	// The A, D or R that opened the box is still in the keyboard queue, and
	// the box is drawn later this same frame — so without this it types
	// itself into the name.
	for ui.char_pressed() != 0 {}
}

// sit -> sit_2 -> sit_3: a name near the one being copied that is free.
@(private = "file")
suggest_name :: proc(e: ^Editor, from: string) -> string {
	base := from
	if i := strings.last_index_byte(base, '_'); i > 0 {
		if _, is_number := strconv.parse_int(base[i + 1:]); is_number do base = base[:i]
	}
	for n := 2; n < 100; n += 1 {
		try := fmt.tprintf("%v_%v", base, n)
		if ne.character_part(&e.ch, try) == nil do return try
	}
	return ""
}

@(private = "file")
ask_remove :: proc(e: ^Editor, status: ^ui.Status, name: string) {
	if ne.char_part_standard(name) {
		ui.say(status, "%v is one of the ten; it stays, drawn or not", name)
		return
	}
	if e.armed {
		queue_remove(e, name)
		e.armed = false
	} else {
		e.armed = true
		ui.say(status, "press Delete again to remove %v", name)
	}
}

// --- Changes to the list of poses, held until the top of the next frame ---

@(private = "file")
queue_naming :: proc(e: ^Editor, what: Naming, from, name: string) {
	pending_clear(e)
	e.pending = {naming = what, from = strings.clone(from), name = strings.clone(name)}
}

@(private = "file")
queue_remove :: proc(e: ^Editor, name: string) {
	pending_clear(e)
	e.pending = {remove = true, from = strings.clone(name)}
}

@(private = "file")
pending_clear :: proc(e: ^Editor) {
	delete(e.pending.from)
	delete(e.pending.name)
	e.pending = {}
}

@(private = "file")
apply_pending :: proc(e: ^Editor, status: ^ui.Status) {
	if e.pending.naming == .None && !e.pending.remove do return
	apply_one(e, status)
	pending_clear(e)
}

@(private = "file")
apply_one :: proc(e: ^Editor, status: ^ui.Status) {
	from, name := e.pending.from, e.pending.name

	if e.pending.remove {
		char_mark(e)
		if ne.character_remove_part(&e.ch, from) {
			e.dirty = true
			choose_part(e, min(e.part, len(e.ch.parts) - 1))
			ui.say(status, "removed %v", from)
		}
		return
	}

	// Renaming a pose to what it is already called is a no-op, not an error:
	// the box opens with the name in it, so Enter alone means "leave it".
	if e.pending.naming == .Rename && name == from do return

	// All three naming jobs say the same things about a bad name, so they say
	// them in one place.
	if !ne.char_part_name_ok(name) {
		ui.say(status, "a pose is called something like sit or at_tripod" if name != "" else "no name, no pose")
		return
	}
	if ne.character_part(&e.ch, name) != nil {
		ui.say(status, "there is already a pose called %v", name)
		return
	}

	char_mark(e)
	switch e.pending.naming {
	case .New:
		ne.character_add_part(&e.ch, name)
		ui.say(status, "%v: blank, one frame", name)
	case .Copy:
		if ne.character_copy_part(&e.ch, from, name) == nil {
			ui.say(status, "could not copy %v", from)
			return
		}
		ui.say(status, "%v: a copy of %v", name, from)
	case .Rename:
		if !ne.character_rename_part(&e.ch, from, name) {
			ui.say(status, "could not rename %v", from)
			return
		}
		ui.say(status, "%v is now %v", from, name)
	case .None:
		return
	}
	e.dirty = true
	for &p, i in e.ch.parts do if p.name == name do choose_part(e, i)
}

@(private = "file")
part_drawn :: proc(p: ^ne.Character_Part) -> bool {
	for v in p.data.pixels do if v != 0 do return true
	return false
}

@(private = "file")
draw_char_side :: proc(e: ^Editor, r: rl.Rectangle, part: ^ne.Character_Part) {
	ui.panel(r)
	x := r.x + 10
	width0 := r.width - 20

	// What this pose is, and who asks for it. The ten have a job; an extra is
	// only ever shown because something named it.
	ui.label(i32(x), i32(r.y) + 10, part.name, ui.INK, ui.SMALL)
	if help := ne.char_part_help(part.name); help != "" {
		ui.label(i32(x), i32(r.y) + 28, ui.ellipsize(help, width0, ui.SMALL), ui.DIM, ui.SMALL)
	} else {
		ui.label(i32(x), i32(r.y) + 28, ui.ellipsize(fmt.tprintf("play %v", part.name), width0, ui.SMALL), ui.GOLD, ui.SMALL)
		ui.label(i32(x), i32(r.y) + 44, "in a routine or a cue", ui.DIM, ui.SMALL)
	}

	top := r.y + (50 if ne.char_part_standard(part.name) else 66)
	ui.label(i32(x), i32(top), "colours  (shift + -)", ui.DIM, ui.SMALL)
	used := px.canvas_palette(&e.canvas, &part.data, x, top + 20, r.width - 20)
	used += px.canvas_brush_panel(&e.canvas, x, top + 20 + used + 10, r.width - 20) + 10
	used += px.canvas_dither_panel(&e.canvas, &part.data, x, top + 20 + used + 10, r.width - 20) + 10
	used += px.canvas_mixer(&e.canvas, &part.data, x, top + 20 + used, r.width - 20)
	y := top + 20 + used + 16

	// Size and speed of this pose.
	width := r.width - 20
	half := (r.width - 24) / 2
	ui.label(i32(x), i32(y), "size of this pose", ui.DIM, ui.SMALL)
	y += 18
	ui.label(i32(x), i32(y) + 6, "w", ui.DIM, ui.SMALL)
	if v, done := ui.number_field(&e.text, {x + 14, y, width - 14, 24}, "p.w", int(part.data.w)); done {
		resize_part(e, part, i32(v), part.data.h)
	}
	y += 28
	ui.label(i32(x), i32(y) + 6, "h", ui.DIM, ui.SMALL)
	if v, done := ui.number_field(&e.text, {x + 14, y, width - 14, 24}, "p.h", int(part.data.h)); done {
		resize_part(e, part, part.data.w, i32(v))
	}
	y += 32
	ui.label(i32(x), i32(y), "frames a second", ui.DIM, ui.SMALL)
	y += 18
	if v, done := ui.text_field(&e.text, {x, y, half, 24}, "p.fps", fmt.tprintf("%v", part.fps)); done {
		part.fps = ui.to_f32(v, part.fps)
		e.dirty = true
	}
	if ui.button({x + half + 4, y, half, 24}, "stop" if e.playing else "play", e.playing) {
		e.playing = !e.playing
	}
	y += 32
	// How long the frame on the canvas shows for, in ticks of the speed above:
	// 2 shows it twice as long as a frame left at 1. See nengine/anim.odin.
	ui.label(i32(x), i32(y), fmt.tprintf("frame %v holds for", e.frame + 1), ui.DIM, ui.SMALL)
	y += 18
	hold := ne.sprite_data_hold(&part.data, e.frame)
	if v, done := ui.number_field(&e.text, {x, y, half, 24}, "p.hold", int(hold)); done && i32(v) != hold {
		char_mark(e)
		ne.sprite_data_set_hold(&part.data, e.frame, i32(v))
		e.dirty = true
	}
	ui.label(i32(x + half + 8), i32(y) + 6, fmt.tprintf("%.2fs a time through", ne.anim_secs(part.data.frames, part.fps, part.data.holds[:])), ui.DIM, ui.SMALL)
	y += 36

	// This pose at its own speed, next to the whole sheet.
	ui.label(i32(x), i32(y), "at this size in the game", ui.DIM, ui.SMALL)
	y += 18
	e.preview.stale = true // the art changes under it; it's a small sheet
	shown := e.frame
	if e.playing && part.fps > 0 do shown, _ = ne.anim_frame(f32(ui.now()), part.fps, part.data.frames, part.data.holds[:])
	px.preview_frame(&e.preview, &part.data, shown, {x, y}, 3)
	y += f32(part.data.h) * 3 + 14

	ui.label(i32(x), i32(y), "every frame", ui.DIM, ui.SMALL)
	px.preview_draw(&e.preview, &part.data, {x, y + 18}, 1)
}


// Changing a pose's size keeps whatever still fits.
@(private = "file")
resize_part :: proc(e: ^Editor, part: ^ne.Character_Part, want_w, want_h: i32) {
	if want_w == part.data.w && want_h == part.data.h do return
	char_mark(e)
	ne.sprite_data_resize(&part.data, want_w, want_h)
	e.canvas.view = {}
	e.canvas.stale = true
	e.dirty, e.preview.stale = true, true
}

// Used by the CLI and the picker: a character with the standard poses, blank.
// One mode and one palette for the whole person, because a character is one
// person in one set of colours and a pose cannot be allowed a colour its
// neighbours are not.
write_blank :: proc(path, name: string, mode := px.DEFAULT_MODE) -> bool {
	c := ne.character_new(name)
	c.mode = mode
	defer ne.character_destroy(&c)
	for part in ne.CHAR_PARTS {
		frames: i32 = 1
		fps: f32 = 0
		if strings.has_prefix(part, "walk") do frames, fps = 4, 8
		if part == "talk" || part == "face" do frames, fps = 3, 6
		p := ne.character_add_part(&c, part, frames, fps)
		// Every pose shares the character's palette, so every pose is seeded
		// from the character's mode rather than from a list of its own.
		if len(p.data.palette) <= 1 do ne.sprite_data_set_mode(&p.data, c.mode)
	}
	return ne.save_character(&c, path)
}

// The footer: this editor's keys, then the brush's, which every painting
// editor shares (px.BRUSH_KEYS).
KEYS :: "LMB paint  RMB erase  ^C ^V  ^Z undo  up/down pose  [ ] frame  N +frame  A new pose  D copy  R rename  Del remove  P play  ^S save  Esc ^B files  " + px.BRUSH_KEYS
