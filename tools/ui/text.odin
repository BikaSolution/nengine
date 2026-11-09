package ui

import "core:fmt"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

// --- Typing into a field ---
//
// One of these per editor. It remembers which field has the caret, what has
// been typed into it so far, where the caret is and what is selected; every
// other field just draws its value.
//
// A field is edited the way a field is edited anywhere else: click to put the
// caret down, drag or shift-arrow to select, ^A for all of it, ^C ^X ^V, ^ and
// an arrow for a word at a time, Home and End. Enter (or clicking somewhere
// else) keeps what was typed; Esc puts it back.
//
// The value is one line, always: every format these tools write keeps one
// thing to a line, so a paste with newlines in it comes in as spaces.

Text_Input :: struct {
	focus:   string, // id of the field being typed into, "" for none
	buf:     [dynamic]u8,
	caret:   int,  // a byte offset into buf, always on a character boundary
	anchor:  int,  // the other end of the selection; == caret when nothing is selected
	scroll:  f32,  // how far a one-line field has slid left to keep the caret in view
	drag:    bool, // the mouse went down in the field and is still down
	touched: bool, // the focused field was drawn this frame (text_input_sweep)
	want_x:  f32,  // up and down in a text area keep to this column
	rect:    rl.Rectangle, // where the focused field was drawn last
	focused: int, // the frame it was focused on: that frame's click is the one that focused it
}

text_input_destroy :: proc(t: ^Text_Input) {
	delete(t.buf)
	delete(t.focus)
	t^ = {}
}

text_input_focus :: proc(t: ^Text_Input, id, value: string) {
	delete(t.focus)
	t.focus = strings.clone(id)
	clear(&t.buf)
	append(&t.buf, value)
	t.caret, t.anchor = len(t.buf), 0 // all of it selected: typing replaces it
	t.scroll = 0
	t.drag = false
	t.touched = true
	t.want_x = -1
	t.focused = input_frame()
}

text_input_blur :: proc(t: ^Text_Input) {
	delete(t.focus)
	t.focus = ""
	clear(&t.buf)
	t.caret, t.anchor = 0, 0
	t.drag = false
}

// Call once at the end of a frame. A field that had the caret and was not
// drawn this frame has gone — its object was deleted, the panel moved on to
// something else — and what was typed into it goes with it, rather than
// leaving every single-key shortcut switched off by a field nobody can see.
text_input_sweep :: proc(t: ^Text_Input) {
	if t.focus != "" && !t.touched do text_input_blur(t)
	t.touched = false
}

// Focused this frame, so this frame's click is not a click away from it.
@(private = "file")
text_fresh :: proc(t: ^Text_Input) -> bool {
	return t.focused == input_frame()
}

// True on a frame the mouse went down somewhere other than the field being
// typed into. The field itself commits when it is next drawn; an editor that
// would rather have the edit in before anything else that frame — before a
// button it clicked moves lines about — asks this first, commits it, and
// blurs.
text_input_clicked_away :: proc(t: ^Text_Input) -> bool {
	return t.focus != "" && !text_fresh(t) && mouse_pressed(.LEFT) && !rl.CheckCollisionPointRec(mouse(), t.rect)
}

// The value being typed, while a field has the caret.
text_input_value :: proc(t: ^Text_Input) -> string {
	return string(t.buf[:])
}

// --- Editing the buffer ---
//
// Plain procedures over the buffer, kept apart from drawing so they can be
// tested without a window.

// The selection, low end first.
text_selection :: proc(t: ^Text_Input) -> (lo, hi: int) {
	return min(t.caret, t.anchor), max(t.caret, t.anchor)
}

text_has_selection :: proc(t: ^Text_Input) -> bool {
	return t.caret != t.anchor
}

text_selected :: proc(t: ^Text_Input) -> string {
	lo, hi := text_selection(t)
	return string(t.buf[lo:hi])
}

// Drops what is selected. True if there was anything.
text_delete_selection :: proc(t: ^Text_Input) -> bool {
	lo, hi := text_selection(t)
	if lo == hi do return false
	remove_range(&t.buf, lo, hi)
	t.caret, t.anchor = lo, lo
	return true
}

// Puts `s` where the caret is, over the selection if there is one. Line
// breaks become spaces and anything the font cannot draw is left out.
text_insert :: proc(t: ^Text_Input, s: string) {
	text_delete_selection(t)
	clean := make([dynamic]u8, 0, len(s), context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch {
		case c == '\r' && i + 1 < len(s) && s[i + 1] == '\n': continue
		case c == '\n' || c == '\r' || c == '\t':             append(&clean, ' ')
		case c >= 32 && c < 127:                              append(&clean, c)
		}
	}
	inject_at(&t.buf, t.caret, ..clean[:])
	t.caret += len(clean)
	t.anchor = t.caret
}

// The character boundary before / after `i`, stepping over the continuation
// bytes of anything multi-byte that was already in the file.
@(private)
prev_char :: proc(b: []u8, i: int) -> int {
	j := max(i - 1, 0)
	for j > 0 && b[j] & 0xC0 == 0x80 do j -= 1
	return j
}

@(private)
next_char :: proc(b: []u8, i: int) -> int {
	j := min(i + 1, len(b))
	for j < len(b) && b[j] & 0xC0 == 0x80 do j += 1
	return j
}

// The start of the word before `i` / the end of the word after it.
@(private)
prev_word :: proc(b: []u8, i: int) -> int {
	j := i
	for j > 0 && b[j - 1] == ' ' do j -= 1
	for j > 0 && b[j - 1] != ' ' do j -= 1
	return j
}

@(private)
next_word :: proc(b: []u8, i: int) -> int {
	j := i
	for j < len(b) && b[j] == ' ' do j += 1
	for j < len(b) && b[j] != ' ' do j += 1
	return j
}

// Moves the caret to `to`, dragging the selection along when `extend`.
text_move :: proc(t: ^Text_Input, to: int, extend: bool) {
	t.caret = clamp(to, 0, len(t.buf))
	if !extend do t.anchor = t.caret
}

text_backspace :: proc(t: ^Text_Input, word := false) {
	if text_delete_selection(t) do return
	if t.caret == 0 do return
	from := prev_word(t.buf[:], t.caret) if word else prev_char(t.buf[:], t.caret)
	remove_range(&t.buf, from, t.caret)
	t.caret, t.anchor = from, from
}

text_delete_forward :: proc(t: ^Text_Input, word := false) {
	if text_delete_selection(t) do return
	if t.caret >= len(t.buf) do return
	to := next_word(t.buf[:], t.caret) if word else next_char(t.buf[:], t.caret)
	remove_range(&t.buf, t.caret, to)
}

// --- The clipboard ---
//
// The system's, except while a script is driving the tool: a hidden test
// that copies something must not overwrite whatever the person at the
// machine had copied.

@(private = "file")
pretend_clipboard: [dynamic]u8

clipboard_set :: proc(s: string) {
	if replaying() {
		clear(&pretend_clipboard)
		append(&pretend_clipboard, s)
		return
	}
	rl.SetClipboardText(strings.clone_to_cstring(s, context.temp_allocator))
}

clipboard_get :: proc() -> string {
	if replaying() do return string(pretend_clipboard[:])
	c := rl.GetClipboardText()
	if c == nil do return ""
	return strings.clone(string(c), context.temp_allocator)
}

clipboard_text_destroy :: proc() {
	delete(pretend_clipboard)
	pretend_clipboard = nil
}

// The keys a focused field answers to, other than Enter and Esc. `rows` is
// the wrapped layout of a text area, for up and down; nil for one line.
@(private = "file")
text_keys :: proc(t: ^Text_Input, rows: []Text_Row = nil) {
	for ch := char_pressed(); ch != 0; ch = char_pressed() {
		if ch >= 32 && ch < 127 {
			c := [1]u8{u8(ch)}
			text_insert(t, string(c[:]))
			t.want_x = -1
		}
	}
	ctrl := ctrl_down()
	shift := shift_down()
	if repeated(.BACKSPACE) do text_backspace(t, ctrl)
	if repeated(.DELETE) do text_delete_forward(t, ctrl)
	if repeated(.LEFT) {
		if text_has_selection(t) && !shift {
			lo, _ := text_selection(t)
			text_move(t, lo, false)
		} else {
			text_move(t, prev_word(t.buf[:], t.caret) if ctrl else prev_char(t.buf[:], t.caret), shift)
		}
		t.want_x = -1
	}
	if repeated(.RIGHT) {
		if text_has_selection(t) && !shift {
			_, hi := text_selection(t)
			text_move(t, hi, false)
		} else {
			text_move(t, next_word(t.buf[:], t.caret) if ctrl else next_char(t.buf[:], t.caret), shift)
		}
		t.want_x = -1
	}
	if key_pressed(.HOME) {
		start := 0
		if rows != nil do start = rows[row_of(rows, t.caret)].start
		text_move(t, start if !ctrl else 0, shift)
	}
	if key_pressed(.END) {
		end := len(t.buf)
		if rows != nil do end = rows[row_of(rows, t.caret)].end
		text_move(t, end if !ctrl else len(t.buf), shift)
	}
	if rows != nil && (repeated(.UP) || repeated(.DOWN)) {
		r := row_of(rows, t.caret)
		if t.want_x < 0 do t.want_x = f32(measure(string(t.buf[rows[r].start:t.caret]), SMALL))
		up := key_pressed(.UP) || (key_down(.UP) && key_repeat(.UP))
		to := r - 1 if up else r + 1
		if to < 0 {
			text_move(t, 0, shift)
		} else if to >= len(rows) {
			text_move(t, len(t.buf), shift)
		} else {
			text_move(t, index_at_x(string(t.buf[:]), rows[to], t.want_x), shift)
		}
	}
	if ctrl {
		if key_pressed(.A) {
			t.anchor, t.caret = 0, len(t.buf)
		}
		if key_pressed(.C) && text_has_selection(t) do clipboard_set(text_selected(t))
		if key_pressed(.X) && text_has_selection(t) {
			clipboard_set(text_selected(t))
			text_delete_selection(t)
		}
		if key_pressed(.V) do text_insert(t, clipboard_get())
	}
}

// What finishes an edit: Enter keeps it, Esc throws it away. Shared by both
// kinds of field.
@(private = "file")
text_finish :: proc(t: ^Text_Input, value: string) -> (out: string, done: bool, cancelled: bool) {
	if key_pressed(.ENTER) || key_pressed(.KP_ENTER) {
		out = strings.clone(string(t.buf[:]), context.temp_allocator)
		text_input_blur(t)
		return out, true, false
	}
	if key_pressed(.ESCAPE) {
		text_input_blur(t)
		return value, false, true
	}
	return "", false, false
}

// The click that starts, moves or ends an edit, shared by both kinds of
// field. `at` turns a point into a caret position. Clicking away keeps what
// was typed, the same as pressing Enter.
@(private = "file")
text_mouse :: proc(t: ^Text_Input, r: rl.Rectangle, id, value: string, at: proc(t: ^Text_Input, p: [2]f32, data: rawptr) -> int, data: rawptr) -> (out: string, done: bool) {
	hot := rl.CheckCollisionPointRec(mouse(), r)
	mine := t.focus == id
	if mouse_pressed(.LEFT) {
		if hot {
			if !mine {
				text_input_focus(t, id, value)
				// Clicking into a field puts the caret where you clicked; the
				// select-all of a focus from the keyboard is for ^F and friends.
				t.caret = at(t, mouse(), data)
				t.anchor = t.caret
			} else {
				text_move(t, at(t, mouse(), data), shift_down())
			}
			t.drag = true
			t.want_x = -1
		} else if mine && !text_fresh(t) {
			out, done = strings.clone(string(t.buf[:]), context.temp_allocator), true
			text_input_blur(t)
			return
		}
	}
	if t.focus == id && t.drag {
		if mouse_down(.LEFT) {
			t.caret = at(t, mouse(), data)
		} else {
			t.drag = false
		}
	}
	return
}

// An editable box, one line. Returns the new value on the frame it's
// committed — the caller decides what to do with it, and must clone it to
// keep it.
text_field :: proc(t: ^Text_Input, r: rl.Rectangle, id, value: string) -> (out: string, done: bool) {
	Field :: struct {
		r:      rl.Rectangle,
		scroll: f32,
	}
	field := Field{r, t.scroll if t.focus == id else 0}
	at :: proc(t: ^Text_Input, p: [2]f32, data: rawptr) -> int {
		f := cast(^Field)data
		x := p.x - (f.r.x + 4) + f.scroll
		return index_at_x(string(t.buf[:]), {0, len(t.buf)}, x)
	}
	out, done = text_mouse(t, r, id, value, at, &field)

	mine := t.focus == id
	shown := value
	if mine {
		t.touched = true
		t.rect = r
		text_keys(t)
		if o, d, cancelled := text_finish(t, value); d || cancelled {
			if d do out, done = o, true
			mine = false
		} else {
			shown = string(t.buf[:])
		}
	}

	hot := rl.CheckCollisionPointRec(mouse(), r)
	rl.DrawRectangleRec(r, {26, 26, 32, 255})
	rl.DrawRectangleLinesEx(r, 1, GOLD if mine else (DIM if hot else EDGE))
	inner := rl.Rectangle{r.x + 4, r.y, r.width - 8, r.height}
	ty := i32(r.y + r.height / 2) - SMALL / 2
	if !mine {
		rl.BeginScissorMode(i32(r.x) + 2, i32(r.y), i32(r.width) - 4, i32(r.height))
		label(i32(inner.x), ty, shown, INK, SMALL)
		rl.EndScissorMode()
		return
	}

	// Slide the text along so the caret is always in the box.
	caret_x := f32(measure(string(t.buf[:t.caret]), SMALL))
	if caret_x - t.scroll > inner.width - 2 do t.scroll = caret_x - inner.width + 2
	if caret_x - t.scroll < 0 do t.scroll = caret_x
	t.scroll = max(t.scroll, 0)

	rl.BeginScissorMode(i32(r.x) + 2, i32(r.y), i32(r.width) - 4, i32(r.height))
	x0 := inner.x - t.scroll
	if text_has_selection(t) {
		lo, hi := text_selection(t)
		a := f32(measure(string(t.buf[:lo]), SMALL))
		b := f32(measure(string(t.buf[:hi]), SMALL))
		rl.DrawRectangleRec({x0 + a, r.y + 4, b - a, r.height - 8}, SELECTION)
	}
	label(i32(x0), ty, shown, INK, SMALL)
	if int(now() * 2) % 2 == 0 || text_has_selection(t) {
		rl.DrawRectangleRec({x0 + caret_x, r.y + 4, 1, r.height - 8}, GOLD)
	}
	rl.EndScissorMode()
	return
}

SELECTION :: rl.Color{70, 90, 140, 255}

// --- A text area: one line of the file, wrapped to the box ---

// One wrapped row: bytes start..end of the buffer, the trailing space left
// out of `end` (it is drawn as nothing and the caret may sit after it).
Text_Row :: struct {
	start, end: int,
}

TEXT_AREA_LINE :: 17

// Word-wrapped rows of `s` that fit `width`. Never empty: an empty string
// is one empty row, so there is somewhere to put the caret.
text_rows :: proc(s: string, width: f32, allocator := context.temp_allocator) -> []Text_Row {
	rows := make([dynamic]Text_Row, allocator)
	start := 0
	for start < len(s) {
		// The longest run from `start` that fits, broken at a space if it can be.
		end := start
		last_space := -1
		i := start
		for i < len(s) {
			j := next_char(transmute([]u8)s, i)
			if f32(measure(s[start:j], SMALL)) > width && i > start do break
			if s[i] == ' ' do last_space = i
			i = j
		}
		end = i
		if end < len(s) && last_space > start {
			end = last_space
			append(&rows, Text_Row{start, end})
			start = end + 1 // the space goes at the end of this row
		} else {
			append(&rows, Text_Row{start, end})
			start = end
		}
	}
	if len(rows) == 0 || (len(s) > 0 && s[len(s) - 1] == ' ' && rows[len(rows) - 1].end < len(s)) {
		append(&rows, Text_Row{len(s), len(s)})
	}
	return rows[:]
}

// Which row the caret at `i` is drawn on.
@(private)
row_of :: proc(rows: []Text_Row, i: int) -> int {
	for r, n in rows {
		next_start := rows[n + 1].start if n + 1 < len(rows) else max(int)
		if i >= r.start && i < next_start do return n
	}
	return len(rows) - 1
}

// The caret position in `row` nearest to `x` pixels from its left.
@(private)
index_at_x :: proc(s: string, row: Text_Row, x: f32) -> int {
	if x <= 0 do return row.start
	i := row.start
	for i < row.end {
		j := next_char(transmute([]u8)s, i)
		mid := (f32(measure(s[row.start:i], SMALL)) + f32(measure(s[row.start:j], SMALL))) / 2
		if x < mid do return i
		i = j
	}
	return row.end
}

// How tall a text area holding `value` is at this width, for laying out
// what comes after it before it is drawn.
text_area_height :: proc(t: ^Text_Input, id, value: string, w: f32, min_rows := 1) -> f32 {
	s := string(t.buf[:]) if t.focus == id else value
	n := max(len(text_rows(s, w - 10)), min_rows)
	return f32(n) * TEXT_AREA_LINE + 8
}

// An editable box for prose: the same editing as a field, wrapped onto as
// many rows as it takes and growing as it is typed into. Enter keeps it —
// the value is still one line of the file.
text_area :: proc(t: ^Text_Input, x, y, w: f32, id, value: string, min_rows := 1) -> (out: string, done: bool, h: f32) {
	h = text_area_height(t, id, value, w, min_rows)
	r := rl.Rectangle{x, y, w, h}
	at :: proc(t: ^Text_Input, p: [2]f32, data: rawptr) -> int {
		r := cast(^rl.Rectangle)data
		rows := text_rows(string(t.buf[:]), r.width - 10)
		row := clamp(int((p.y - r.y - 4) / TEXT_AREA_LINE), 0, len(rows) - 1)
		return index_at_x(string(t.buf[:]), rows[row], p.x - r.x - 5)
	}
	out, done = text_mouse(t, r, id, value, at, &r)

	mine := t.focus == id
	shown := value
	if mine {
		t.touched = true
		t.rect = r
		text_keys(t, text_rows(string(t.buf[:]), w - 10))
		if o, d, cancelled := text_finish(t, value); d || cancelled {
			if d do out, done = o, true
			mine = false
		} else {
			shown = string(t.buf[:])
		}
	}

	hot := rl.CheckCollisionPointRec(mouse(), r)
	rl.DrawRectangleRec(r, {26, 26, 32, 255})
	rl.DrawRectangleLinesEx(r, 1, GOLD if mine else (DIM if hot else EDGE))
	rows := text_rows(shown, w - 10)
	rl.BeginScissorMode(i32(r.x) + 1, i32(r.y) + 1, i32(r.width) - 2, i32(r.height) - 2)
	defer rl.EndScissorMode()
	lo, hi := 0, 0
	if mine do lo, hi = text_selection(t)
	for row, n in rows {
		ry := r.y + 4 + f32(n) * TEXT_AREA_LINE
		if mine && hi > lo {
			a := max(lo, row.start)
			b := min(hi, row.end)
			if b > a {
				ax := f32(measure(shown[row.start:a], SMALL))
				bx := f32(measure(shown[row.start:b], SMALL))
				rl.DrawRectangleRec({r.x + 5 + ax, ry - 1, bx - ax, TEXT_AREA_LINE}, SELECTION)
			}
		}
		label(i32(r.x) + 5, i32(ry), shown[row.start:row.end], INK, SMALL)
	}
	if mine && (int(now() * 2) % 2 == 0 || hi > lo) {
		n := row_of(rows, t.caret)
		cx := f32(measure(shown[rows[n].start:min(t.caret, rows[n].end)], SMALL))
		rl.DrawRectangleRec({r.x + 5 + cx, r.y + 3 + f32(n) * TEXT_AREA_LINE, 1, TEXT_AREA_LINE}, GOLD)
	}
	return
}

// True while any field is taking keystrokes, so editors can leave their
// single-key shortcuts alone.
typing :: proc(t: ^Text_Input) -> bool {
	return t.focus != ""
}

// A number with a minus and a plus either side of it, because a bare box
// full of digits doesn't look like anything you can change. Typing into it
// still works; the buttons are there so you can see that it's adjustable.
// Holding shift steps by `big` instead of one.
number_field :: proc(t: ^Text_Input, r: rl.Rectangle, id: string, value: int, big: int = 8) -> (int, bool) {
	step := 26 if r.width >= 110 else 20
	shift := key_down(.LEFT_SHIFT) || key_down(.RIGHT_SHIFT)
	by := big if shift else 1

	if button({r.x, r.y, f32(step), r.height}, "-") do return value - by, true
	if button({r.x + r.width - f32(step), r.y, f32(step), r.height}, "+") do return value + by, true

	inner := rl.Rectangle{r.x + f32(step) + 2, r.y, r.width - f32(step) * 2 - 4, r.height}
	if v, done := text_field(t, inner, id, fmt.tprintf("%v", value)); done {
		return to_int(v, value), true
	}
	return value, false
}

to_f32 :: proc(s: string, fallback: f32 = 0) -> f32 {
	if v, ok := strconv.parse_f32(strings.trim_space(s)); ok do return v
	return fallback
}

to_int :: proc(s: string, fallback: int = 0) -> int {
	if v, ok := strconv.parse_int(strings.trim_space(s)); ok do return v
	return fallback
}

// Replaces a string the editor owns.
reset_string :: proc(dst: ^string, value: string) {
	delete(dst^)
	dst^ = strings.clone(value)
}
