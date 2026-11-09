package ui

import rl "vendor:raylib"

// Draggable dividers between panes.
//
// Every tool has a column down one side — the track names in nsound, the
// object list in nscene, the poses and the palette in nart, the places and the
// preview in the browser — and every one of them was a constant. A constant is
// wrong for anything holding a name: `triangle_bass` runs off the end of a
// 150-pixel column, and no amount of picking a better number fixes it for the
// next name along.
//
// So they are all dragged now, and each remembers where it was left.
//
// Used in two halves, because a pane's width has to be known before anything
// can be laid out inside it, while its handle has to be drawn after everything
// else or the panels cover it:
//
//     side := ui.split("side", 150, top, height, 90, 400)  // width, and dragging
//     ... lay out and draw both panes ...
//     ui.splits_draw()                                     // the handles, on top

GRIP :: 9 // how near the line you must be to grab it

// Nine rather than five. A divider is a two-pixel line and the only thing that
// says it can be moved was three dots that appeared once you were already on
// it — so finding it meant knowing it was there and aiming at it. Widening the
// catch costs nothing (there is nothing else within nine pixels of a divider)
// and it is the difference between a control and a secret.

@(private = "file")
Split :: struct {
	key:            string,
	x, top, height: f32,
	live:           bool, // recorded this frame
	across:         bool, // a horizontal divider, dragged up and down
}

@(private = "file")
MAX_SPLITS :: 8

@(private = "file")
splits: [MAX_SPLITS]Split

@(private = "file")
split_count: int

@(private = "file")
dragging: string // the key being dragged, "" for none

// The width of the pane to the left of divider `key`, after any dragging this
// frame. `lo` and `hi` are as narrow and as wide as it may be dragged, and are
// applied to the stored value too — so a column dragged wide in a big window
// doesn't strand a small one with no room for anything else.
split :: proc(key: string, fallback, top, height, lo, hi: f32) -> f32 {
	return drag(key, clamp(setting_num(key, fallback), lo, max(lo, hi)), top, height, lo, hi, 0)
}

// The same, for a pane against the right-hand edge. What is remembered is its
// width rather than where its edge happened to be, so a pane dragged wide
// stays that wide when the window is next a different size — which is what
// anyone dragging the right-hand pane meant.
split_right :: proc(key: string, fallback_w, right, top, height, lo_w, hi_w: f32) -> f32 {
	w := clamp(setting_num(key, fallback_w), lo_w, max(lo_w, hi_w))
	return drag(key, right - w, top, height, right - max(lo_w, hi_w), right - lo_w, right)
}

// A divider that runs across rather than down: the stage over the timeline in
// the cutscene editor. `y` is where the line sits; the pane above it is that
// tall.
split_h :: proc(key: string, fallback, top, bottom, lo, hi: f32) -> f32 {
	y := clamp(setting_num(key, fallback), lo, max(lo, hi))
	mouse := mouse()
	over := mouse.y >= y - GRIP && mouse.y <= y + GRIP

	switch {
	case dragging == key:
		y = clamp(mouse.y, lo, max(lo, hi))
		setting_set_num(key, y)
		if !mouse_down(.LEFT) do dragging = ""
	case dragging == "" && over && mouse_pressed(.LEFT):
		dragging = key
	}
	if split_count < MAX_SPLITS {
		splits[split_count] = {key, y, top, bottom - top, true, true}
		split_count += 1
	}
	return y
}

// `anchor` is 0 for a width measured from the left, or the right-hand edge for
// one measured back from there; it decides what gets written down.
@(private = "file")
drag :: proc(key: string, at, top, height, lo, hi, anchor: f32) -> f32 {
	x := clamp(at, lo, max(lo, hi))
	mouse := mouse()
	over := mouse.x >= x - GRIP && mouse.x <= x + GRIP && mouse.y >= top && mouse.y <= top + height

	switch {
	case dragging == key:
		x = clamp(mouse.x, lo, max(lo, hi))
		setting_set_num(key, x if anchor == 0 else anchor - x)
		if !mouse_down(.LEFT) do dragging = ""
	case dragging == "" && over && mouse_pressed(.LEFT):
		dragging = key
	}

	// Recorded so splits_draw can put the handle on top of the panels.
	if split_count < MAX_SPLITS {
		splits[split_count] = {key, x, top, height, true, false}
		split_count += 1
	}
	return x
}

// True while a divider is being dragged, or while the pointer is near enough to
// one to grab it.
//
// Panes use this to keep out of the way. The nine pixels either side of a
// divider belong to the divider, and a pane that is right up against one — the
// drawing canvas is, by construction — would otherwise act on every click
// aimed at the handle. Reaching for the divider would leave a stray pixel in
// the art, which is the sort of thing you find three days later and cannot
// explain.
//
// Call it after the frame's splits have been declared, which for every editor
// here is the first thing that happens.
split_hot :: proc() -> bool {
	if dragging != "" do return true
	mouse := mouse()
	for i in 0 ..< split_count {
		s := splits[i]
		if s.across {
			if mouse.y >= s.x - GRIP && mouse.y <= s.x + GRIP do return true
		} else if mouse.x >= s.x - GRIP && mouse.x <= s.x + GRIP &&
		   mouse.y >= s.top && mouse.y <= s.top + s.height {
			return true
		}
	}
	return false
}

// Draws every handle recorded this frame, and sets the pointer when it is over
// one. Call it once, last, after the panes are drawn.
splits_draw :: proc() {
	cursor := rl.MouseCursor.DEFAULT
	mouse := mouse()
	for i in 0 ..< split_count {
		s := splits[i]
		held := dragging == s.key
		over := false
		line: rl.Rectangle
		mid: rl.Vector2
		if s.across {
			over = mouse.y >= s.x - GRIP && mouse.y <= s.x + GRIP
			line = {s.top, s.x - 1, s.height, 2}
			mid = {s.top + s.height / 2, s.x}
			if over || held do cursor = .RESIZE_NS
		} else {
			over = mouse.x >= s.x - GRIP && mouse.x <= s.x + GRIP && mouse.y >= s.top && mouse.y <= s.top + s.height
			line = {s.x - 1, s.top, 2, s.height}
			mid = {s.x, s.top + s.height / 2}
			if over || held do cursor = .RESIZE_EW
		}

		switch {
		case held: rl.DrawRectangleRec(line, GOLD)
		case over: rl.DrawRectangleRec(line, DIM)
		case:      rl.DrawRectangleRec(line, EDGE)
		}

		// Three dots at the middle, so a divider you can move doesn't look
		// like a divider you can't. Always drawn — they used to appear only
		// once the pointer was on the line, which is no use for finding it.
		dots := BG if held else (INK if over else DIM)
		for d in -1 ..= 1 {
			if s.across {
				rl.DrawRectangleRec({mid.x + f32(d) * 7 - 1, mid.y - 1, 3, 3}, dots)
			} else {
				rl.DrawRectangleRec({mid.x - 1, mid.y + f32(d) * 7 - 1, 3, 3}, dots)
			}
		}
	}
	rl.SetMouseCursor(cursor)
	split_count = 0
}

// Forgets any half-finished drag. For a view that swaps out from under one.
splits_reset :: proc() {
	dragging = ""
	split_count = 0
}
