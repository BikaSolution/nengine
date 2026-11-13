package cutscene

import ne "../../../"
import ui "../../ui"
import "core:fmt"
import rl "vendor:raylib"

// The clock along the bottom. One row per cast member, plus a row at the top
// for the things aimed at nobody — narration, the camera, sounds, a node's
// lines — and every cue a block you can drag left and right to change when it
// happens. What is selected is edited in the panel.
//
// This is the whole reason the format puts the time first: a cutscene you can
// read down the left-hand column is a cutscene you can draw as a timeline, and
// a timeline is the only way to see that two people are talking over each
// other.

NAMES_W :: f32(120)

@(private = "file")
row_of :: proc(e: ^Editor, who: string) -> int {
	if who == "" do return 0
	i := doc_member(&e.doc, who)
	return i + 1 if i >= 0 else 0
}

@(private = "file")
Rows :: struct {
	r:     rl.Rectangle, // the cues' area
	secs:  f32,
	top:   f32, // the first row's y, with the rows scrolled
	ruler: rl.Rectangle, // the seconds along the top, which scrub
}

@(private = "file")
to_x :: proc(rows: Rows, t: f32) -> f32 {
	return rows.r.x + rows.r.width * t / rows.secs
}

draw_timeline :: proc(e: ^Editor, r: rl.Rectangle, length: f32, status: ^ui.Status) {
	ui.panel(r, {26, 26, 33, 255})
	rows := Rows{{r.x + NAMES_W, r.y + RULER_H, r.width - NAMES_W - 8, r.height - RULER_H - 4}, max(length, 1), 0, {}}
	// More people than fit scroll, names and rows together.
	content := f32(len(e.doc.people) + 1) * ROW_H
	ui.scroll_wheel(&e.tl_scroll, {r.x, rows.r.y, r.width, rows.r.height}, ROW_H, content)
	e.tl_scroll = ui.scroll_clamp(e.tl_scroll, content, rows.r.height)
	rows.top = rows.r.y - e.tl_scroll
	rows.ruler = {rows.r.x, r.y, rows.r.width, RULER_H}

	// A `line` cue is as long as its lines take to read, so the dialogue is
	// wanted as soon as there is one.
	for c in e.doc.cues do if c.q.action == .Line {
		nodes_load(&e.nodes, e.asset_dir)
		break
	}

	draw_ruler(r, rows)
	draw_names(e, r, rows)

	rl.BeginScissorMode(i32(rows.r.x), i32(rows.r.y), i32(rows.r.width), i32(rows.r.height))
	// The rows themselves, striped so a cue can be traced back to a name.
	for i in 0 ..= len(e.doc.people) {
		y := rows.top + f32(i) * ROW_H
		if i % 2 == 1 do rl.DrawRectangleRec({rows.r.x, y, rows.r.width, ROW_H - 1}, {31, 31, 39, 255})
		if i - 1 == e.who && i > 0 do rl.DrawRectangleRec({rows.r.x, y, rows.r.width, ROW_H - 1}, {44, 42, 32, 255})
	}

	handle_timeline_mouse(e, rows, status)

	for c, i in e.doc.cues {
		q := c.q
		y := rows.top + f32(row_of(e, q.who)) * ROW_H
		block := cue_block(e, q, rows, y)
		picked := e.sel.kind == .Cue && e.sel.i == i
		rl.DrawRectangleRec(block, cue_colour(q.action, picked))
		rl.DrawRectangleLinesEx(block, 1, ui.GOLD if picked else rl.Color{0, 0, 0, 80})

		// The label goes inside the block when it fits and beside it when it
		// doesn't. A `say` is a moment, so its block is thin, and a row of
		// unlabelled thin blocks tells you nothing about what is said.
		// A block wide enough for some of it gets what fits, cut short: the
		// next block along is often where its label would go.
		label := ne.plain_text(cue_label(q))
		lw := f32(ui.measure(label, ui.SMALL))
		if lw < block.width - 8 || block.width >= 48 {
			ui.label(i32(block.x) + 4, i32(block.y) + 2, ui.ellipsize(label, block.width - 8, ui.SMALL), ui.BG, ui.SMALL)
		} else {
			room := rows.r.x + rows.r.width - (block.x + block.width) - 6
			ui.label(i32(block.x + block.width) + 4, i32(block.y) + 2,
				ui.ellipsize(label, room, ui.SMALL), cue_colour(q.action, picked), ui.SMALL)
		}
	}
	rl.EndScissorMode()

	// The playhead, over everything.
	px := to_x(rows, clamp(e.t, 0, rows.secs))
	rl.DrawLineEx({px, r.y + 4}, {px, rows.r.y + rows.r.height}, 1, ui.GOLD)
	rl.DrawRectangleRec({px - 4, r.y + 2, 8, 8}, ui.GOLD)
}

// A cue as a block: a walk as long as the walk takes, a node's lines as long
// as they take to read, a part as long as it plays, a shake as long as it
// shakes; anything else a moment. Drawing a walk as a bar is what makes it
// obvious that the next line lands before anybody has arrived.
@(private = "file")
cue_block :: proc(e: ^Editor, q: ne.Cue, rows: Rows, y: f32) -> rl.Rectangle {
	secs := cue_secs(e, q)
	w := max(rows.r.width * secs / rows.secs, 12)
	return {to_x(rows, q.at), y + 3, w, ROW_H - 7}
}

cue_secs :: proc(e: ^Editor, q: ne.Cue) -> f32 {
	#partial switch q.action {
	case .Walk_To:
		i := doc_member(&e.doc, q.who)
		if i < 0 do return 0
		return rl.Vector2Distance(person_at(e, i, q.at), q.to) / member_speed(e, i)
	case .Line:
		return line_cue_secs(&e.nodes, q)
	case .Play:
		i := doc_member(&e.doc, q.who)
		return play_secs(e, cast_view(e, i).char if i >= 0 else "", q)
	case .Shake:
		return q.amount
	}
	return 0
}

cue_colour :: proc(a: ne.Cue_Action, picked: bool) -> rl.Color {
	base: rl.Color
	switch a {
	case .Walk_To: base = {120, 190, 255, 255}
	case .Face:    base = {150, 220, 210, 255}
	case .Play:    base = {130, 210, 240, 255}
	case .Say:     base = {150, 220, 140, 255}
	case .Think:   base = {200, 180, 240, 255}
	case .Narrate: base = {220, 210, 150, 255}
	case .Line:    base = {170, 230, 190, 255}
	case .Shot:    base = {230, 170, 210, 255}
	case .Shake:   base = {240, 150, 130, 255}
	case .Sound:   base = {240, 190, 120, 255}
	case .Leave:   base = {120, 230, 230, 255}
	case .End:     base = {200, 200, 210, 255}
	}
	if picked do return base
	return {u8(f32(base.r) * 0.72), u8(f32(base.g) * 0.72), u8(f32(base.b) * 0.72), 255}
}

cue_label :: proc(q: ne.Cue) -> string {
	switch q.action {
	case .Walk_To: return fmt.tprintf("walk %v,%v", int(q.to.x), int(q.to.y))
	case .Face:    return fmt.tprintf("face %v", ne.facing_text(q.facing))
	case .Play:
		if q.times == 1 do return fmt.tprintf("play %v", q.text)
		if q.times > 1 do return fmt.tprintf("play %v %vx", q.text, q.times)
		return fmt.tprintf("play %v %.1fs", q.text, q.amount)
	case .Say:     return q.text
	case .Think:   return q.text
	case .Narrate: return q.text
	case .Line:
		// A node's lines: which node, which lines, which telling. The words
		// are in the writers' file, not here.
		label := fmt.tprintf("line %v %v", q.text, ne.line_range_text(q.lines))
		if q.tag != "" do label = fmt.tprintf("%v [%v]", label, q.tag)
		if q.shot != "" do label = fmt.tprintf("%v in %v", label, q.shot)
		return label
	case .Shot:
		if q.text == "" do return "shot off"
		return fmt.tprintf("shot %v %v", q.text, q.frame)
	case .Shake:   return fmt.tprintf("shake %.1f", q.amount)
	case .Sound:   return fmt.tprintf("sound %v", q.text)
	case .Leave:   return fmt.tprintf("leave %v", ne.COMPASS_WORDS[q.dir])
	case .End:     return "end"
	}
	return ""
}

action_name :: proc(a: ne.Cue_Action) -> string {
	switch a {
	case .Walk_To: return "walk"
	case .Face:    return "face"
	case .Play:    return "play"
	case .Say:     return "say"
	case .Think:   return "think"
	case .Narrate: return "narrate"
	case .Line:    return "line"
	case .Shot:    return "shot"
	case .Shake:   return "shake"
	case .Sound:   return "sound"
	case .Leave:   return "leave"
	case .End:     return "end"
	}
	return "?"
}

@(private = "file")
draw_ruler :: proc(r: rl.Rectangle, rows: Rows) {
	// A mark every second while there's room, every five when there isn't.
	every := f32(1)
	for rows.r.width / (rows.secs / every) < 40 do every += 1
	for t := f32(0); t <= rows.secs; t += every {
		x := to_x(rows, t)
		rl.DrawLineEx({x, r.y + 14}, {x, rows.r.y + rows.r.height}, 1, {48, 48, 58, 255})
		ui.label(i32(x) + 3, i32(r.y) + 4, fmt.tprintf("%v", int(t)), {110, 110, 126, 255}, ui.SMALL)
	}
}

// The names down the left: a click selects the person, and the panel shows
// everything about them. The nobody row selects the cut.
@(private = "file")
draw_names :: proc(e: ^Editor, r: rl.Rectangle, rows: Rows) {
	ui.label(i32(r.x) + 8, i32(r.y) + 4, "cast", {110, 110, 126, 255}, ui.SMALL)
	rl.BeginScissorMode(i32(r.x), i32(rows.r.y), i32(NAMES_W), i32(rows.r.height))
	defer rl.EndScissorMode()
	y := rows.top
	for i in -1 ..< len(e.doc.people) {
		defer y += ROW_H
		if y + ROW_H < rows.r.y || y > rows.r.y + rows.r.height do continue
		row := rl.Rectangle{r.x + 4, y, NAMES_W - 8, ROW_H - 2}
		hot := rl.CheckCollisionPointRec(ui.mouse(), row) && ui.mouse().y >= rows.r.y
		lit := i == e.who if i >= 0 else e.who < 0
		if lit do rl.DrawRectangleRec(row, {56, 52, 36, 255})
		else if hot do rl.DrawRectangleRec(row, {40, 40, 50, 255})
		text := "(nobody)" if i < 0 else e.doc.people[i].m.name
		ink := ui.GOLD if lit else (ui.INK if i >= 0 else rl.Color{110, 110, 126, 255})
		ui.label(i32(row.x) + 6, i32(y) + 5, ui.ellipsize(text, row.width - 12, ui.SMALL), ink, ui.SMALL)
		if hot && ui.mouse_pressed(.LEFT) {
			e.who = i
			e.sel = {.Cast, i} if i >= 0 else {}
		}
	}
}

// Clicking and dragging in the rows: pick a cue, move it in time, or scrub.
@(private = "file")
handle_timeline_mouse :: proc(e: ^Editor, rows: Rows, status: ^ui.Status) {
	mouse := ui.mouse()
	time_at :: proc(rows: Rows, x: f32) -> f32 {
		return clamp((x - rows.r.x) / rows.r.width * rows.secs, 0, rows.secs)
	}
	if ui.mouse_released(.LEFT) && (e.drag == .Cue || e.drag == .Scrub) {
		if e.drag == .Cue {
			if e.drag_moved {
				// Its line goes where its time belongs, among the cues it is
				// written with.
				if e.sel.kind == .Cue do e.sel.i = doc_place_cue(&e.doc, e.sel.i)
				changed(e)
			} else {
				ui.history_drop_last(&e.history)
			}
		}
		e.drag = .None
	}

	if ui.mouse_pressed(.LEFT) && rl.CheckCollisionPointRec(mouse, rows.ruler) && !ui.split_hot() {
		e.drag = .Scrub
		e.playing = false
	}
	if ui.mouse_pressed(.LEFT) && rl.CheckCollisionPointRec(mouse, rows.r) && !ui.split_hot() {
		// A cue under the pointer — the last drawn is on top — else scrub.
		#reverse for c, i in e.doc.cues {
			y := rows.top + f32(row_of(e, c.q.who)) * ROW_H
			if rl.CheckCollisionPointRec(mouse, cue_block(e, c.q, rows, y)) {
				mark(e)
				e.sel, e.drag, e.drag_moved = {.Cue, i}, .Cue, false
				e.drag_grab = time_at(rows, mouse.x) - c.q.at
				if m := row_of(e, c.q.who) - 1; m >= 0 do e.who = m
				return
			}
		}
		e.drag = .Scrub
		e.playing = false
	}

	if !ui.mouse_down(.LEFT) do return
	#partial switch e.drag {
	case .Scrub:
		e.t = time_at(rows, mouse.x)
	case .Cue:
		if e.sel.kind == .Cue && e.sel.i < len(e.doc.cues) {
			// Tenths: fine enough to time a line, coarse enough that the file
			// stays readable and a drag doesn't rewrite every decimal.
			t := max(time_at(rows, mouse.x) - e.drag_grab, 0)
			t = f32(int(t * 10 + 0.5)) / 10
			if t != e.doc.cues[e.sel.i].q.at {
				e.sel.i = doc_set_cue_time(&e.doc, e.sel.i, t, place = false)
				e.drag_moved = true
				e.dirty = true
			}
		}
	}
}
