package main

import ne "../../"
import ui "../ui"
import "core:fmt"
import rl "vendor:raylib"

// The sheet: four bars across, the whole piano range top to bottom.
//
// VERTICALLY there is one row per line-or-space — a staff step, not a
// semitone — A0 at the bottom to C8 at the top. Every even step is a line,
// and that single fact makes one continuous "super-staff" that already holds
// the treble clef (E4..F5), the bass clef (G2..A3) and middle C's ledger line
// between them. No clef switching, ever: they are all always there. The
// treble and bass five-line groups are drawn bold and everything else faint,
// so the shape of a grand staff is visible inside the ladder.
//
// HORIZONTALLY it is ticks, 24 to a quarter. Pick a length on the left, click
// a slot, and a note of that length drops in. A note snaps to slots of its
// own length counted from the start of its bar — so a quarter note has four
// places to be in a 4/4 bar and an eighth-triplet has twelve. A dotted note
// snaps to half its undotted length, which is where dotted notes actually
// fall in real music. Hold Alt for the 32nd grid.
//
// Sharps and flats come from the key signature; hold Shift for a sharp, Ctrl
// for a flat, or set the mode in the panel. Accidentals are drawn only where
// they differ from the key, as they are on paper.
//
// Every track is drawn. The one you are editing is on top at full strength,
// the rest dim in their own colours, so you can see the chord you are writing
// against.

Acc_Mode :: enum {
	Key, // whatever the key signature says
	Sharp,
	Flat,
	Natural,
}

// A note being dragged: where it was when it was grabbed, so letting go
// somewhere illegal can put it back.
Drag :: struct {
	active: bool,
	note:   ne.Note,
	grab:   i32, // ticks between the note's start and where it was grabbed
	moved:  bool,
}

BARS_PER_PAGE :: 4
GUTTER_W :: 46
STRIP_H :: 18

// Where everything is on screen. Worked out each frame, because the window
// resizes and 52 rows have to fit in whatever is left.
Sheet_Layout :: struct {
	rows:    rl.Rectangle, // the staff itself
	row_h:   f32,
	strip:   rl.Rectangle, // the page strip under it
	bars_x:  f32,
	bars_w:  f32,
	side:    f32, // the panel down the left, as it has been dragged
}

@(private = "file")
sheet_layout :: proc(e: ^Song_Editor, screen: [2]f32) -> Sheet_Layout {
	top := f32(HEAD_H) + 22 // room for the bar numbers
	bottom := screen.y - 26 - STRIP_H - 6
	row_h := clamp(f32(int((bottom - top) / ne.STEP_COUNT)), 5, 14)
	l := Sheet_Layout {
		row_h  = row_h,
		side   = e.side,
		bars_x = e.side + GUTTER_W,
	}
	l.bars_w = screen.x - l.bars_x - 8
	l.rows = {l.bars_x, top, l.bars_w, row_h * ne.STEP_COUNT}
	l.strip = {l.bars_x, l.rows.y + l.rows.height + 4, l.bars_w, STRIP_H}
	return l
}

@(private = "file")
row_y :: proc(l: Sheet_Layout, step: int) -> f32 {
	return l.rows.y + f32(ne.STEP_HI - step) * l.row_h
}

@(private = "file")
row_middle :: proc(l: Sheet_Layout, step: int) -> f32 {
	return row_y(l, step) + l.row_h / 2
}

@(private = "file")
page_ticks :: proc(e: ^Song_Editor) -> i32 {
	return ne.bar_ticks(&e.song) * BARS_PER_PAGE
}

@(private = "file")
page_start :: proc(e: ^Song_Editor) -> i32 {
	return e.page * page_ticks(e)
}

@(private = "file")
page_count :: proc(e: ^Song_Editor) -> i32 {
	return max((e.song.bars + BARS_PER_PAGE - 1) / BARS_PER_PAGE, 1)
}

@(private = "file")
tick_x :: proc(e: ^Song_Editor, l: Sheet_Layout, tick: i32) -> f32 {
	return l.bars_x + f32(tick - page_start(e)) * l.bars_w / f32(page_ticks(e))
}

@(private = "file")
active_track :: proc(e: ^Song_Editor) -> ^ne.Track {
	if e.track < 0 || e.track >= len(e.song.tracks) do return nil
	return &e.song.tracks[e.track]
}

// The slot size notes snap to right now. Alt drops to the 32nd grid, for
// putting something exactly where the rules would not.
@(private = "file")
current_snap :: proc(e: ^Song_Editor) -> i32 {
	if ui.key_down(.LEFT_ALT) || ui.key_down(.RIGHT_ALT) do return 3
	return ne.snap_ticks(e.length, e.mod)
}

// Snap a tick to the slot grid, counted from the start of its own bar.
@(private = "file")
snap_tick :: proc(e: ^Song_Editor, tick: i32) -> i32 {
	bt := ne.bar_ticks(&e.song)
	bar := tick / bt
	within := tick - bar * bt
	snap := current_snap(e)
	return bar * bt + within / snap * snap
}

// What is under the mouse on the staff.
@(private = "file")
Hover :: struct {
	ok:       bool,
	step:     int,
	raw_tick: i32, // where the mouse actually is
	tick:     i32, // snapped to the current length's slot
}

@(private = "file")
sheet_hover :: proc(e: ^Song_Editor, l: Sheet_Layout) -> Hover {
	m := ui.mouse()
	if !rl.CheckCollisionPointRec(m, l.rows) do return {}
	h := Hover{ok = true}
	h.step = ne.STEP_HI - int((m.y - l.rows.y) / l.row_h)
	h.raw_tick = page_start(e) + i32((m.x - l.bars_x) * f32(page_ticks(e)) / l.bars_w)
	h.tick = snap_tick(e, h.raw_tick)
	return h
}

// The pitch a click on this row makes, given the key and the accidental mode.
@(private = "file")
placed_pitch :: proc(e: ^Song_Editor, step: int) -> ne.Pitch {
	alter := ne.key_alter(int(e.song.key), step)
	switch e.acc {
	case .Key:
	case .Sharp:   alter = 1
	case .Flat:    alter = -1
	case .Natural: alter = 0
	}
	if ui.shift_down() do alter = 1
	if ui.ctrl_down() do alter = -1
	return {i8(step), alter}
}

@(private = "file")
in_range :: proc(e: ^Song_Editor, t: ^ne.Track, p: ne.Pitch) -> bool {
	ins := ne.instrument_get(&e.insts, t.inst)
	m := ne.pitch_midi(p)
	return m >= ins.lo && m <= ins.hi
}

// --- Each frame ---

sheet_step :: proc(e: ^Song_Editor, screen: [2]f32, status: ^ui.Status) {
	l := sheet_layout(e, screen)
	e.page = clamp(e.page, 0, page_count(e) - 1)
	if !ui.typing(&e.text) && !e.picking do sheet_keys(e, status)
	sheet_draw(e, l)
	if !e.picking do sheet_input(e, l, status)
	sheet_panel(e, l, screen)
	// The picker is modal, and it is drawn after this, so anything the panel
	// thinks it was clicked on this frame was really a click on the picker.
	if e.picking do e.drag.active = false
}

@(private = "file")
sheet_keys :: proc(e: ^Song_Editor, status: ^ui.Status) {
	// 1 to 6 pick a length, from a whole note down to a 32nd.
	keys := [?]rl.KeyboardKey{.ONE, .TWO, .THREE, .FOUR, .FIVE, .SIX}
	for k, i in keys {
		if ui.key_pressed(k) && !ui.ctrl_down() {
			e.length = ne.Length(i)
			e.mod = .None
		}
	}
	// `.` and `,` sit next to each other and neither is a length key. T would
	// be the obvious one for triplet, but T adds a track.
	if ui.key_pressed(.PERIOD) do e.mod = .None if e.mod == .Dotted else .Dotted
	if ui.key_pressed(.COMMA) do e.mod = .None if e.mod == .Triplet else .Triplet
	if ui.key_pressed(.LEFT_BRACKET) do e.page = max(e.page - 1, 0)
	if ui.key_pressed(.RIGHT_BRACKET) do e.page = min(e.page + 1, page_count(e) - 1)
	if ui.key_pressed(.PAGE_UP) do e.page = max(e.page - 1, 0)
	if ui.key_pressed(.PAGE_DOWN) do e.page = min(e.page + 1, page_count(e) - 1)

	// With a note selected the arrows move it; with nothing selected they
	// turn the page, which is what you want when you are just reading.
	if e.selected < 0 {
		if ui.key_pressed(.LEFT) do e.page = max(e.page - 1, 0)
		if ui.key_pressed(.RIGHT) do e.page = min(e.page + 1, page_count(e) - 1)
		return
	}
	// A staff step on its own, a semitone with Shift: up from F is F#, and
	// up a step from F is G whatever the key says about it.
	if ui.key_pressed(.UP) {
		if ui.shift_down() { nudge_selected(e, 1) } else { move_selected(e, 1, 0) }
	}
	if ui.key_pressed(.DOWN) {
		if ui.shift_down() { nudge_selected(e, -1) } else { move_selected(e, -1, 0) }
	}
	if ui.key_pressed(.LEFT) do move_selected(e, 0, -1)
	if ui.key_pressed(.RIGHT) do move_selected(e, 0, 1)
	if ui.key_pressed(.DELETE) || ui.key_pressed(.BACKSPACE) {
		t := active_track(e)
		if t != nil && e.selected < len(t.notes) {
			song_mark(e)
			ordered_remove(&t.notes, e.selected)
			e.selected = -1
			e.dirty = true
		}
	}
}

@(private = "file")
sheet_draw :: proc(e: ^Song_Editor, l: Sheet_Layout) {
	t := active_track(e)
	right := l.bars_x + l.bars_w
	top, bottom := l.rows.y, l.rows.y + l.rows.height
	rl.DrawRectangleRec(l.rows, {20, 21, 28, 255})

	// Rows the active instrument cannot play, shaded — so the band it CAN
	// play stands out as the lit part of the page.
	if t != nil {
		ins := ne.instrument_get(&e.insts, t.inst)
		for step in ne.STEP_LO ..= ne.STEP_HI {
			m := ne.pitch_midi({i8(step), 0})
			if m < ins.lo || m > ins.hi {
				rl.DrawRectangleRec({l.bars_x, row_y(l, step), l.bars_w, l.row_h}, {12, 12, 17, 255})
			}
		}
	}

	hov := sheet_hover(e, l)
	if hov.ok {
		rl.DrawRectangleRec({l.side, row_y(l, hov.step), l.bars_x + l.bars_w - l.side, l.row_h}, {255, 255, 255, 12})
	}

	// The staff lines. Bold where a real clef's lines are, dashed at middle C.
	for step in ne.STEP_LO ..= ne.STEP_HI {
		if !ne.step_is_line(step) do continue
		y := row_middle(l, step)
		switch {
		case ne.step_is_grand_staff(step):
			rl.DrawLineEx({l.bars_x, y}, {right, y}, 1, {150, 156, 196, 255})
		case step == 28:
			for x := l.bars_x; x < right; x += 8 {
				rl.DrawLineEx({x, y}, {min(x + 4, right), y}, 1, {120, 124, 170, 255})
			}
		case:
			rl.DrawLineEx({l.bars_x, y}, {right, y}, 1, {62, 67, 102, 255})
		}
	}

	// Bar lines, beat lines and the slot grid you are snapping to.
	bt := ne.bar_ticks(&e.song)
	beat := ne.beat_ticks(&e.song)
	snap := current_snap(e)
	per_tick := l.bars_w / f32(page_ticks(e))
	for b in 0 ..< i32(BARS_PER_PAGE) {
		bar := e.page * BARS_PER_PAGE + b
		start := bar * bt
		for k := i32(0); k < bt; k += 1 {
			x := tick_x(e, l, start + k)
			switch {
			case k == 0:
				rl.DrawLineEx({x, top}, {x, bottom}, 2, {170, 170, 214, 255})
			case k % beat == 0:
				rl.DrawLineEx({x, top}, {x, bottom}, 1, {70, 74, 110, 255})
			case k % snap == 0 && f32(snap) * per_tick >= 5:
				rl.DrawLineEx({x, top}, {x, bottom}, 1, {30, 33, 54, 255})
			}
		}
		// Past the song's end, the bar number is faint: that is empty room.
		ui.label(i32(tick_x(e, l, start)) + 3, i32(l.rows.y) - 18,
			fmt.tprintf("%v", bar + 1), ui.DIM if bar < e.song.bars else ui.EDGE, ui.SMALL)
	}
	rl.DrawLineEx({right, top}, {right, bottom}, 2, {170, 170, 214, 255})

	draw_gutter(e, l, hov)

	playing := song_playhead_tick(e)
	for &tr, i in e.song.tracks do if i != e.track do draw_notes(e, l, &tr, false, playing)
	if t != nil do draw_notes(e, l, t, true, playing)

	// The ghost of the note a click would place.
	if hov.ok && t != nil && !e.drag.active {
		if ne.track_note_at(t, hov.step, hov.raw_tick) < 0 {
			p := placed_pitch(e, hov.step)
			col := rl_colour(ne.instrument_get(&e.insts, t.inst).color)
			if !in_range(e, t, p) do col = {230, 80, 80, 255}
			x := tick_x(e, l, hov.tick)
			w := f32(ne.note_ticks(e.length, e.mod)) * per_tick
			y := row_middle(l, hov.step) - l.row_h / 2 + 1
			h := max(l.row_h - 2, 4)
			rl.DrawRectangleRec({x, y, max(w - 1, 3), h}, {col.r, col.g, col.b, 70})
			rl.DrawRectangleLinesEx({x, y, max(w - 1, 3), h}, 1, {col.r, col.g, col.b, 160})
		}
	}

	if playing >= 0 && playing >= page_start(e) && playing < page_start(e) + page_ticks(e) {
		x := tick_x(e, l, playing)
		rl.DrawLineEx({x, top - 4}, {x, bottom}, 2, ui.GOLD)
	} else if playing >= 0 && e.follow {
		// Follow the music onto the next page as it leaves this one.
		e.page = clamp(playing / page_ticks(e), 0, page_count(e) - 1)
	}

	draw_strip(e, l)
}

@(private = "file")
draw_notes :: proc(e: ^Song_Editor, l: Sheet_Layout, t: ^ne.Track, active: bool, playing: i32) {
	ins := ne.instrument_get(&e.insts, t.inst)
	base := rl_colour(ins.color)
	from := page_start(e)
	to := from + page_ticks(e)
	left, right := l.bars_x, l.bars_x + l.bars_w
	muted := !ne.track_audible(&e.song, t)
	half := max(l.row_h / 2 - 1, 2)

	for n, i in t.notes {
		if n.tick >= to do break
		if n.tick + n.len <= from do continue
		step := int(n.pitch.step)
		if step < ne.STEP_LO || step > ne.STEP_HI do continue
		x0 := max(tick_x(e, l, n.tick), left)
		x1 := min(tick_x(e, l, n.tick + n.len), right)
		y := row_middle(l, step)
		sounding := playing >= n.tick && playing < n.tick + n.len && !muted

		col := base
		if !active do col = {base.r, base.g, base.b, 40 if muted else 95}
		else if muted do col = {base.r, base.g, base.b, 150}
		if sounding do col = lighten(base, 0.55)

		// The body says how long it lasts; the head says where it starts, as
		// a square block, because this is a pixel-art engine and not Sibelius.
		rl.DrawRectangleRec({x0 + 1, y - half + 1, max(x1 - x0 - 2, 1), max(half * 2 - 2, 2)}, col)
		if tick_x(e, l, n.tick) >= left {
			head := rl.Rectangle{x0, y - half, min(10, max(x1 - x0, 4)), half * 2}
			rl.DrawRectangleRec(head, lighten(col, 0.2) if active || sounding else col)
			if active do rl.DrawRectangleLinesEx(head, 1, {0, 0, 0, 120})
		}
		if sounding do rl.DrawRectangleLinesEx({x0 - 1, y - half - 1, x1 - x0 + 2, half * 2 + 2}, 1, rl.WHITE)
		if active && i == e.selected {
			rl.DrawRectangleLinesEx({x0 - 2, y - half - 2, x1 - x0 + 4, half * 2 + 4}, 1, ui.GOLD)
		}

		// Accidentals, only where the key signature doesn't already say so.
		if active && l.row_h >= 9 && tick_x(e, l, n.tick) - 9 >= left {
			if n.pitch.alter != ne.key_alter(int(e.song.key), step) {
				mark := "n"
				switch n.pitch.alter {
				case 1:  mark = "#"
				case -1: mark = "b"
				case 2:  mark = "x"
				case -2: mark = "bb"
				}
				ui.label(i32(x0) - 8 - i32(len(mark) - 1) * 5, i32(y) - 6, mark, ui.INK, ui.SMALL)
			}
		}
	}
}

// Note names down the left, and the three clef marks on their own lines.
@(private = "file")
draw_gutter :: proc(e: ^Song_Editor, l: Sheet_Layout, hov: Hover) {
	x := l.side
	rl.DrawRectangleRec({x, l.rows.y, GUTTER_W, l.rows.height}, ui.PANEL)
	// Only the Cs are named, and whichever row the mouse is on. Printed
	// music has no letters at all; these are the ladder you count from, and
	// a name against all 52 rows is a wall of letters nobody reads.
	for step in ne.STEP_LO ..= ne.STEP_HI {
		y := row_y(l, step)
		is_c := step % 7 == 0
		hot := hov.ok && hov.step == step
		// In a short window the rows get smaller than the font, so the names
		// go and the C lines alone carry the counting.
		if (is_c && l.row_h >= 9) || hot {
			ui.label(i32(x) + 21, i32(y) + i32(l.row_h / 2) - 7,
				ne.pitch_text({i8(step), 0}), ui.GOLD if hot else ui.INK, ui.SMALL)
		}
		if is_c do rl.DrawLineEx({x + 19, y + l.row_h}, {x + GUTTER_W, y + l.row_h}, 1, ui.EDGE)
	}
	// A clef mark on each clef's own reference line: G on G4, C on C4, F on F3.
	clef :: proc(l: Sheet_Layout, step: int, letter: string) {
		y := row_middle(l, step)
		rl.DrawRectangleRec({l.side + 3, y - 6, 13, 12}, ui.GOLD)
		ui.label(i32(l.side) + 6, i32(y) - 6, letter, ui.BG, ui.SMALL)
	}
	clef(l, 32, "G")
	clef(l, 28, "C")
	clef(l, 24, "F")
}

// Every page as a box: where you are, where the playhead is, click to jump.
@(private = "file")
draw_strip :: proc(e: ^Song_Editor, l: Sheet_Layout) {
	n := page_count(e)
	w := min((l.bars_w - 70) / f32(n), 48)
	playing := song_playhead_tick(e)
	play_page := playing / page_ticks(e) if playing >= 0 else i32(-1)
	t := active_track(e)

	for i in 0 ..< n {
		r := rl.Rectangle{l.bars_x + f32(i) * w, l.strip.y, w - 2, l.strip.height}
		fill := rl.Color{44, 44, 54, 255}
		if i == e.page do fill = ui.GOLD
		if rl.CheckCollisionPointRec(ui.mouse(), r) && i != e.page do fill = {56, 56, 68, 255}
		rl.DrawRectangleRec(r, fill)
		if i == play_page do rl.DrawRectangleRec({r.x, r.y + r.height - 3, r.width, 3}, ui.LIVE)
		// A pip in the active track's colour if it has anything on that page.
		if t != nil {
			from, to := i * page_ticks(e), (i + 1) * page_ticks(e)
			for note in t.notes {
				if note.tick >= to do break
				if note.tick + note.len > from {
					rl.DrawRectangleRec({r.x + 2, r.y + 2, 4, 4}, rl_colour(ne.instrument_get(&e.insts, t.inst).color))
					break
				}
			}
		}
		if w >= 18 {
			ui.label(i32(r.x) + i32(w / 2) - 4, i32(r.y) + 3, fmt.tprintf("%v", i + 1), ui.BG if i == e.page else ui.DIM, ui.SMALL)
		}
		if !e.picking && rl.CheckCollisionPointRec(ui.mouse(), r) && ui.mouse_pressed(.LEFT) {
			e.page = i
		}
	}
	if ui.button({l.bars_x + f32(n) * w, l.strip.y, 26, l.strip.height}, "+") && !e.picking {
		e.song.bars = (page_count(e) + 1) * BARS_PER_PAGE
		e.page = page_count(e) - 1
		e.dirty = true
	}
	ui.label(i32(l.bars_x + f32(n) * w) + 32, i32(l.strip.y) + 3,
		fmt.tprintf("page %v of %v", e.page + 1, n), ui.DIM, ui.SMALL)
}

// --- Placing, dragging and deleting ---

@(private = "file")
sheet_input :: proc(e: ^Song_Editor, l: Sheet_Layout, status: ^ui.Status) {
	t := active_track(e)
	if t == nil do return
	hov := sheet_hover(e, l)

	// A drag carries on wherever the mouse goes, in or out of the staff.
	if e.drag.active {
		if !ui.mouse_down(.LEFT) {
			drag_finish(e, t)
		} else if hov.ok {
			drag_move(e, t, hov)
		}
		return
	}

	// Clicking the piano gutter plays that row, which is how you find a note.
	gutter := rl.Rectangle{l.side, l.rows.y, GUTTER_W, l.rows.height}
	if rl.CheckCollisionPointRec(ui.mouse(), gutter) && ui.mouse_pressed(.LEFT) {
		step := ne.STEP_HI - int((ui.mouse().y - l.rows.y) / l.row_h)
		audition(e, ne.instrument_get(&e.insts, t.inst), ne.pitch_midi(placed_pitch(e, step)))
		return
	}

	if !hov.ok do return
	under := ne.track_note_at(t, hov.step, hov.raw_tick)

	if ui.mouse_pressed(.LEFT) {
		if under >= 0 {
			// Grab it: select it, hear it, be ready to drag it.
			e.selected = under
			song_mark(e)
			e.drag = {active = true, note = t.notes[under], grab = hov.raw_tick - t.notes[under].tick}
			audition(e, ne.instrument_get(&e.insts, t.inst), ne.pitch_midi(t.notes[under].pitch))
			return
		}
		p := placed_pitch(e, hov.step)
		if !in_range(e, t, p) {
			ins := ne.instrument_get(&e.insts, t.inst)
			ui.say(status, "%v is outside the %v's range (%v to %v)",
				ne.pitch_text(p), ins.name, ne.note_text(ins.lo), ne.note_text(ins.hi))
			return
		}
		song_mark(e)
		e.selected = ne.track_put(t, ne.Note{
			tick  = hov.tick,
			len   = ne.note_ticks(e.length, e.mod),
			pitch = p,
			vel   = ne.DEFAULT_VELOCITY,
		})
		ne.song_fit_bars(&e.song, BARS_PER_PAGE)
		e.dirty = true
		audition(e, ne.instrument_get(&e.insts, t.inst), ne.pitch_midi(p))
		return
	}

	if under >= 0 && ui.mouse_pressed(.RIGHT) {
		song_mark(e)
		ordered_remove(&t.notes, under)
		e.selected = -1
		e.dirty = true
		return
	}

	// The wheel over a note nudges it a semitone, respelled: F to F# to G is
	// two clicks, and the spelling follows the direction you went.
	if under >= 0 {
		if wheel := ui.wheel(); wheel != 0 {
			e.selected = under
			nudge_selected(e, 1 if wheel > 0 else -1)
		}
	}
}

@(private = "file")
drag_move :: proc(e: ^Song_Editor, t: ^ne.Track, hov: Hover) {
	if e.selected < 0 || e.selected >= len(t.notes) do return
	orig := e.drag.note
	tick := max(snap_tick(e, max(hov.raw_tick - e.drag.grab + current_snap(e) / 2, 0)), 0)
	cur := &t.notes[e.selected]
	if tick == cur.tick && hov.step == int(cur.pitch.step) do return
	// An accidental doesn't travel: a note dragged to another row takes that
	// row's key signature, as it would on paper. On the same row it keeps its
	// own spelling.
	p := orig.pitch
	if hov.step != int(orig.pitch.step) do p = {i8(hov.step), ne.key_alter(int(e.song.key), hov.step)}
	if !in_range(e, t, p) do return
	changed := hov.step != int(cur.pitch.step)
	cur.tick = tick
	cur.pitch = p
	e.drag.moved = true
	if changed do audition(e, ne.instrument_get(&e.insts, t.inst), ne.pitch_midi(p))
}

@(private = "file")
drag_finish :: proc(e: ^Song_Editor, t: ^ne.Track) {
	e.drag.active = false
	if !e.drag.moved {
		// It was only a click: nothing changed, so that undo step is noise.
		ui.history_drop_last(&e.history)
		return
	}
	if e.selected >= 0 && e.selected < len(t.notes) {
		// Take it out and put it back, so it lands in order and eats anything
		// it now overlaps.
		n := t.notes[e.selected]
		ordered_remove(&t.notes, e.selected)
		e.selected = ne.track_put(t, n)
	}
	ne.song_fit_bars(&e.song, BARS_PER_PAGE)
	e.dirty = true
}

// A semitone up or down, respelled sensibly. E#, B#, Fb and Cb are real
// spellings but not what anyone means by "a semitone up", so those and any
// double accidental are respelled on the neighbouring letter.
@(private = "file")
nudge_selected :: proc(e: ^Song_Editor, dir: int) {
	t := active_track(e)
	if t == nil || e.selected < 0 || e.selected >= len(t.notes) do return
	n := t.notes[e.selected]
	m := ne.pitch_midi(n.pitch) + dir
	p := n.pitch
	p.alter += i8(dir)
	letter := int(p.step) % 7
	odd := (p.alter == 1 && (letter == 2 || letter == 6)) || (p.alter == -1 && (letter == 3 || letter == 0))
	if abs(int(p.alter)) > 1 || odd do p = ne.pitch_from_midi(m, 1 if dir > 0 else -1)
	if !in_range(e, t, p) do return
	song_mark(e)
	t.notes[e.selected].pitch = p
	e.dirty = true
	audition(e, ne.instrument_get(&e.insts, t.inst), ne.pitch_midi(p))
}

// Move the selected note by staff steps, or by slots.
@(private = "file")
move_selected :: proc(e: ^Song_Editor, dstep: int, dslots: i32) {
	t := active_track(e)
	if t == nil || e.selected < 0 || e.selected >= len(t.notes) do return
	n := t.notes[e.selected]
	step := clamp(int(n.pitch.step) + dstep, ne.STEP_LO, ne.STEP_HI)
	p := n.pitch
	if dstep != 0 do p = {i8(step), ne.key_alter(int(e.song.key), step)}
	if !in_range(e, t, p) do return
	song_mark(e)
	ordered_remove(&t.notes, e.selected)
	n.pitch = p
	n.tick = max(n.tick + dslots * current_snap(e), 0)
	e.selected = ne.track_put(t, n)
	ne.song_fit_bars(&e.song, BARS_PER_PAGE)
	// Follow it onto another page if it walked off this one.
	e.page = clamp(n.tick / page_ticks(e), 0, page_count(e) - 1)
	e.dirty = true
	if dstep != 0 do audition(e, ne.instrument_get(&e.insts, t.inst), ne.pitch_midi(p))
}

// --- The panel down the left: layers, then length and accidental ---

@(private = "file")
sheet_panel :: proc(e: ^Song_Editor, l: Sheet_Layout, screen: [2]f32) {
	ui.panel({0, l.rows.y, l.side, screen.y - l.rows.y - 26})
	y := l.rows.y + 6

	for &t, i in e.song.tracks {
		r := rl.Rectangle{6, y, l.side - 12, 30}
		picked := i == e.track
		audible := ne.track_audible(&e.song, &t)
		rl.DrawRectangleRec(r, {40, 40, 50, 255} if picked else {30, 30, 38, 255})
		rl.DrawRectangleLinesEx(r, 1, ui.GOLD if picked else ui.EDGE)
		rl.DrawRectangleRec({r.x + 2, r.y + 2, 4, r.height - 4}, rl_colour(ne.instrument_get(&e.insts, t.inst).color))
		text_w := r.width - 52 // the M and S buttons sit in the rest
		ui.label(i32(r.x) + 10, i32(r.y) + 2, ui.ellipsize(t.name, text_w, ui.SMALL),
			(ui.INK if picked else ui.DIM) if audible else ui.EDGE, ui.SMALL)
		ui.label(i32(r.x) + 10, i32(r.y) + 16, ui.ellipsize(t.inst, text_w, ui.SMALL),
			ui.DIM if audible else ui.EDGE, ui.SMALL)

		// M and S, because a layer you cannot switch off is not a layer.
		if ui.button({r.x + r.width - 38, r.y + 15, 16, 13}, "M", t.mute) && !e.picking {
			song_mark(e)
			t.mute = !t.mute
			e.dirty = true
		}
		if ui.button({r.x + r.width - 20, r.y + 15, 16, 13}, "S", t.solo) && !e.picking {
			song_mark(e)
			t.solo = !t.solo
			e.dirty = true
		}
		if !e.picking && ui.mouse_pressed(.LEFT) &&
		   rl.CheckCollisionPointRec(ui.mouse(), {r.x, r.y, r.width - 40, r.height}) {
			e.track = i
			e.selected = -1
		}
		y += 33
		if y > screen.y - 150 do break
	}

	if ui.button({6, y, l.side - 12, 22}, "+ instrument") && !e.picking {
		song_mark(e)
		ne.song_add_track(&e.song, fmt.tprintf("track%v", len(e.song.tracks) + 1), "pulse_lead", 0.3)
		e.track = len(e.song.tracks) - 1
		e.dirty = true
		open_picker(e)
	}

	// The length and accidental pickers, laid out from the bottom up so they
	// stay put however tall the window is.
	bottom := screen.y - 52 // clear of the footer
	for mode, i in ([?]Acc_Mode{.Key, .Sharp, .Flat, .Natural}) {
		labels := [?]string{"key", "#", "b", "n"}
		if ui.button({6 + f32(i) * 35, bottom, 33, 20}, labels[i], e.acc == mode) && !e.picking do e.acc = mode
	}
	ui.label(8, i32(bottom) - 16, "accidental", ui.DIM, ui.SMALL)

	bottom -= 44
	if ui.button({6, bottom, 66, 20}, "dotted", e.mod == .Dotted) && !e.picking {
		e.mod = .None if e.mod == .Dotted else .Dotted
	}
	if ui.button({76, bottom, 68, 20}, "triplet", e.mod == .Triplet) && !e.picking {
		e.mod = .None if e.mod == .Triplet else .Triplet
	}

	bottom -= 48
	for len_i in ne.Length {
		col := f32(int(len_i) % 3)
		row := f32(int(len_i) / 3)
		if ui.button({6 + col * 46, bottom + row * 24, 44, 22}, ne.LENGTH_LABEL[len_i], e.length == len_i) &&
		   !e.picking {
			e.length = len_i
		}
	}
	ui.label(8, i32(bottom) - 16, fmt.tprintf("length  (%v ticks)", ne.note_ticks(e.length, e.mod)), ui.DIM, ui.SMALL)
}

@(private = "file")
lighten :: proc(c: rl.Color, amount: f32) -> rl.Color {
	return {
		u8(clamp(f32(c.r) + (255 - f32(c.r)) * amount, 0, 255)),
		u8(clamp(f32(c.g) + (255 - f32(c.g)) * amount, 0, 255)),
		u8(clamp(f32(c.b) + (255 - f32(c.b)) * amount, 0, 255)),
		c.a,
	}
}
