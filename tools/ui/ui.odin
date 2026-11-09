// ui: the widgets the nengine editors are built out of.
//
// There are three editors, and they are three separate programs — nart for
// pixel art, nsound for music, nscene for rooms — because they are three
// different jobs and a tool you open to draw a hat should not carry a
// synthesiser around with it. What they share is in here: the look, the
// buttons, the text fields, undo, and the file picker.
//
// Nothing in this package is needed to *ship* a game. It is all authoring.
package ui

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

// A line of feedback at the bottom: "saved parlour.scene", "nothing to undo".
Status :: struct {
	text:  string,
	until: f64,
}

say :: proc(s: ^Status, text: string, args: ..any) {
	delete(s.text)
	s.text = fmt.aprintf(text, ..args)
	s.until = now() + 3
}

status_destroy :: proc(s: ^Status) {
	delete(s.text)
	s^ = {}
}

// --- Colours ---

BG :: rl.Color{24, 24, 30, 255}
PANEL :: rl.Color{36, 36, 44, 255}
EDGE :: rl.Color{70, 70, 84, 255}
INK :: rl.Color{224, 224, 232, 255}
DIM :: rl.Color{140, 140, 156, 255}
GOLD :: rl.Color{200, 168, 90, 255}
LIVE :: rl.Color{110, 190, 255, 255}


// --- Little immediate-mode widgets ---

FONT :: 18
SMALL :: 14
FOOTER_H :: 26

label :: proc(x, y: i32, text: string, color := INK, size: i32 = FONT) {
	rl.DrawText(fmt.ctprintf("%v", text), x, y, size, color)
}

panel :: proc(r: rl.Rectangle, fill := PANEL) {
	rl.DrawRectangleRec(r, fill)
	rl.DrawRectangleLinesEx(r, 1, EDGE)
}

// A button. Returns true on the frame it's clicked.
button :: proc(r: rl.Rectangle, text: string, active := false) -> bool {
	hot := rl.CheckCollisionPointRec(mouse(), r)
	fill := GOLD if active else (rl.Color{56, 56, 68, 255} if hot else rl.Color{44, 44, 54, 255})
	rl.DrawRectangleRec(r, fill)
	rl.DrawRectangleLinesEx(r, 1, GOLD if active || hot else EDGE)
	ink := BG if active else INK
	tw := rl.MeasureText(fmt.ctprintf("%v", text), SMALL)
	rl.DrawText(fmt.ctprintf("%v", text), i32(r.x + (r.width - f32(tw)) / 2), i32(r.y + r.height / 2) - SMALL / 2, SMALL, ink)
	return hot && mouse_pressed(.LEFT)
}

// The bar along the bottom: which keys do what, plus any status message.
//
// The keys are groups separated by two spaces — "LMB paint  RMB erase" — and
// when they will not fit on one line they wrap between groups, never inside
// one, onto as many lines as it takes. An editor that has more keys than a
// narrow window has room for should still say what every one of them does.
// Lay the rest of the screen out with `footer_h`, so nothing is drawn under it.
footer :: proc(s: ^Status, keys: string) {
	lines := footer_lines(keys)
	h := footer_h(keys)
	y := f32(rl.GetScreenHeight()) - h
	rl.DrawRectangleRec({0, y, f32(rl.GetScreenWidth()), h}, rl.Color{16, 16, 20, 255})
	for line, i in lines do label(8, i32(y) + 6 + i32(i) * FOOTER_LINE, line, DIM, SMALL)
	if s.text != "" && now() < s.until {
		// Over the right-hand end of the first line, on its own background,
		// so a message is never lost in the key list behind it.
		tw := rl.MeasureText(fmt.ctprintf("%v", s.text), SMALL)
		sx := f32(rl.GetScreenWidth()) - f32(tw) - 8
		rl.DrawRectangleRec({sx - 8, y + 2, f32(tw) + 16, FOOTER_LINE}, rl.Color{16, 16, 20, 255})
		label(i32(sx), i32(y) + 6, s.text, GOLD, SMALL)
	}
}

FOOTER_LINE :: 18 // one more line of keys

// How tall the footer is with these keys, at this window's width.
footer_h :: proc(keys: string) -> f32 {
	return f32(FOOTER_H + (len(footer_lines(keys)) - 1) * FOOTER_LINE)
}

@(private = "file")
footer_lines :: proc(keys: string) -> []string {
	width := f32(rl.GetScreenWidth()) - 16
	lines := make([dynamic]string, context.temp_allocator)
	line := ""
	rest := keys
	for group in strings.split_iterator(&rest, "  ") {
		g := strings.trim_space(group)
		if g == "" do continue
		try := g if line == "" else strings.concatenate({line, "  ", g}, context.temp_allocator)
		if line != "" && f32(measure(try, SMALL)) > width {
			append(&lines, line)
			line = g
		} else {
			line = try
		}
	}
	if line != "" || len(lines) == 0 do append(&lines, line)
	return lines[:]
}

// True when Ctrl+S (or Cmd+S) went down this frame.
save_pressed :: proc() -> bool {
	return ctrl_down() && key_pressed(.S)
}

// --- A few more widgets, for the file browser ---

measure :: proc(text: string, size: i32 = FONT) -> i32 {
	return rl.MeasureText(fmt.ctprintf("%v", text), size)
}

// `text` cut down until it fits `width`, with an ellipsis where it was cut.
// Paths are long and columns are narrow; a name that overflows its column and
// scribbles on the next one is worse than one that admits it was trimmed.
ellipsize :: proc(text: string, width: f32, size: i32 = FONT) -> string {
	if width <= 0 do return ""
	if f32(measure(text, size)) <= width do return text
	for n := len(text); n > 1; n -= 1 {
		try := fmt.tprintf("%v..", text[:n - 1])
		if f32(measure(try, size)) <= width do return try
	}
	return ".."
}

// The same, but it eats the middle instead of the end — for paths, where the
// last part is the part you actually wanted to read.
ellipsize_middle :: proc(text: string, width: f32, size: i32 = FONT) -> string {
	if width <= 0 do return ""
	if f32(measure(text, size)) <= width do return text
	for cut := 1; cut < len(text) - 1; cut += 1 {
		head := len(text) / 2 - cut / 2 - cut % 2
		tail := len(text) / 2 + cut / 2
		if head <= 0 || tail >= len(text) do break
		try := fmt.tprintf("%v..%v", text[:head], text[tail:])
		if f32(measure(try, size)) <= width do return try
	}
	return ellipsize(text, width, size)
}

// A small flat toggle. Quieter than `button`, for things you switch rather
// than press: which kind to list, which way to sort.
chip :: proc(r: rl.Rectangle, text: string, active := false) -> bool {
	hot := rl.CheckCollisionPointRec(mouse(), r)
	fill := rl.Color{58, 54, 40, 255} if active else (rl.Color{40, 40, 50, 255} if hot else BG)
	rl.DrawRectangleRec(r, fill)
	rl.DrawRectangleLinesEx(r, 1, GOLD if active else (DIM if hot else EDGE))
	ink := GOLD if active else (INK if hot else DIM)
	tw := measure(text, SMALL)
	rl.DrawText(fmt.ctprintf("%v", text), i32(r.x + (r.width - f32(tw)) / 2), i32(r.y + r.height / 2) - SMALL / 2, SMALL, ink)
	return hot && mouse_pressed(.LEFT)
}

// A coloured tag: which sort of file a row is, in three or four letters.
badge :: proc(x, y: i32, text: string, color: rl.Color) -> i32 {
	w := measure(text, SMALL) + 10
	rl.DrawRectangleRounded({f32(x), f32(y), f32(w), 17}, 0.35, 4, rl.Color{color.r / 4 + 20, color.g / 4 + 20, color.b / 4 + 24, 255})
	rl.DrawText(fmt.ctprintf("%v", text), x + 5, y + 2, SMALL, color)
	return w
}

hline :: proc(x, y, w: i32, color := EDGE) {
	rl.DrawRectangle(x, y, w, 1, color)
}

// A checkerboard, so transparent pixels read as transparent rather than as
// whatever colour the panel behind them happens to be.
checkerboard :: proc(r: rl.Rectangle, cell: f32 = 8) {
	rl.BeginScissorMode(i32(r.x), i32(r.y), i32(r.width), i32(r.height))
	defer rl.EndScissorMode()
	rl.DrawRectangleRec(r, {30, 30, 36, 255})
	dark := rl.Color{38, 38, 46, 255}
	for y := f32(0); y < r.height; y += cell {
		for x := f32(0); x < r.width; x += cell {
			if (int(x / cell) + int(y / cell)) % 2 == 0 do continue
			rl.DrawRectangleRec({r.x + x, r.y + y, cell, cell}, dark)
		}
	}
}

// True on the frame `key` goes down, and then again every 40ms while it is
// held — so holding Down runs through a long list instead of stepping once.
repeated :: proc(key: rl.KeyboardKey) -> bool {
	return key_pressed(key) || (key_down(key) && key_repeat(key))
}

// The line along the top of an editor: what is open, where it came from, and
// whether it has unsaved changes. The path is shortened from its middle when
// it won't fit, because a full path is long, the window is not, and the end of
// it — the file — is the part worth reading.
title_bar :: proc(name, path: string, dirty: bool, width: f32, left: f32 = 10) {
	star := "  *" if dirty else ""
	head := fmt.tprintf("%v%v", name, star)
	label(i32(left), 11, head, INK, FONT)
	x := left + f32(measure(head, FONT) + 14)
	room := width - x - 10
	if room < 60 do return
	label(i32(x), 15, ellipsize_middle(path, room, SMALL), DIM, SMALL)
}
