package ui

import rl "vendor:raylib"

// Scrolling a column of rows: the browser's list and its places, and anything
// else that grows past the bottom of its box.
//
// Kept apart from drawing because the browser's list once got it wrong in a
// way no screenshot of a still list shows: it pulled the view back to the
// selected row on every frame, so the wheel moved the list and the next frame
// moved it straight back. Following the selection is something to do when the
// selection *moves*, not a rule the view must obey.

// The furthest a column `content` tall can be scrolled in a box `view` tall.
scroll_max :: proc(content, view: f32) -> f32 {
	return max(content - view, 0)
}

// `offset` kept within what there is to show.
scroll_clamp :: proc(offset, content, view: f32) -> f32 {
	return clamp(offset, 0, scroll_max(content, view))
}

// The offset after a turn of the wheel: `notches` as raylib reports them
// (positive is away from you, which moves the list up and shows what is
// above), `step` pixels a notch. Clamped.
scroll_by_wheel :: proc(offset, notches, step, content, view: f32) -> f32 {
	return scroll_clamp(offset - notches * step, content, view)
}

// The smallest move that brings the row at `top`, `height` tall, into view.
// Already in view, nothing moves.
scroll_to_show :: proc(offset, top, height, content, view: f32) -> f32 {
	o := offset
	if top < o do o = top
	if top + height > o + view do o = top + height - view
	return scroll_clamp(o, content, view)
}

// A column's wheel: true when the pointer is over `r` and the wheel turned,
// with the new offset.
scroll_wheel :: proc(offset: ^f32, r: rl.Rectangle, step, content: f32) -> bool {
	if !rl.CheckCollisionPointRec(mouse(), r) do return false
	w := wheel()
	if w == 0 do return false
	offset^ = scroll_by_wheel(offset^, w, step, content, r.height)
	return true
}

// A thin bar down the right of `r`, when there is more than fits.
scrollbar :: proc(r: rl.Rectangle, offset, content: f32) {
	if content <= r.height do return
	track := rl.Rectangle{r.x + r.width - 5, r.y, 3, r.height}
	rl.DrawRectangleRec(track, {40, 40, 50, 255})
	frac := r.height / content
	at := (offset / scroll_max(content, r.height)) * (track.height * (1 - frac))
	rl.DrawRectangleRec({track.x, track.y + at, track.width, track.height * frac}, DIM)
}
