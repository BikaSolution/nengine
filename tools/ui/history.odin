package ui

import "core:strings"

// Undo.
//
// A step is kept as **the text the document would be saved as** — the same
// string `save` would write. That costs a little memory and buys certainty:
// what you undo to is exactly a file that would have loaded, so undo can
// never leave an editor holding something the format can't express.
//
// Mark *before* a change, not after, and mark once per gesture: a brush
// stroke is one undo, not four hundred.
//
// The clipboard is not here. Each editor is its own program now, so there is
// nothing to share between them, and what they copy is different anyway: a
// patch of pixels, an object in a room, a track of notes.

STEPS :: 64 // far enough back to recover from a bad afternoon

History :: struct {
	undo: [dynamic]string,
	redo: [dynamic]string,
}

history_destroy :: proc(h: ^History) {
	for s in h.undo do delete(s)
	for s in h.redo do delete(s)
	delete(h.undo)
	delete(h.redo)
	h^ = {}
}

// Call with the document as it is *now*, just before changing it.
history_mark :: proc(h: ^History, current: string) {
	append(&h.undo, strings.clone(current))
	if len(h.undo) > STEPS {
		delete(h.undo[0])
		ordered_remove(&h.undo, 0)
	}
	for s in h.redo do delete(s)
	clear(&h.redo)
}

// Hands back the previous state, and keeps the current one for redo. The
// returned string belongs to the History and is good until the next call.
history_undo :: proc(h: ^History, current: string) -> (string, bool) {
	if len(h.undo) == 0 do return "", false
	append(&h.redo, strings.clone(current))
	return pop(&h.undo), true
}

history_redo :: proc(h: ^History, current: string) -> (string, bool) {
	if len(h.redo) == 0 do return "", false
	append(&h.undo, strings.clone(current))
	return pop(&h.redo), true
}

// A step handed back by undo/redo has been removed from its stack, so the
// caller owns it.
history_done :: proc(step: string) {
	delete(step)
}

// Throw away the last mark. For a gesture that turned out to change nothing —
// a click on a note that was meant to be a drag — where leaving the step in
// would make Ctrl+Z do nothing visible once and confuse everyone.
history_drop_last :: proc(h: ^History) {
	if len(h.undo) == 0 do return
	delete(pop(&h.undo))
}

undo_pressed :: proc() -> bool {
	return ctrl_down() && key_pressed(.Z) && !shift_down()
}

redo_pressed :: proc() -> bool {
	return ctrl_down() && (key_pressed(.Y) || (key_pressed(.Z) && shift_down()))
}

copy_pressed :: proc() -> bool { return ctrl_down() && key_pressed(.C) }
cut_pressed :: proc() -> bool { return ctrl_down() && key_pressed(.X) }
paste_pressed :: proc() -> bool { return ctrl_down() && key_pressed(.V) }
select_all_pressed :: proc() -> bool { return ctrl_down() && key_pressed(.A) }

ctrl_down :: proc() -> bool {
	return key_down(.LEFT_CONTROL) || key_down(.RIGHT_CONTROL) || key_down(.LEFT_SUPER)
}

shift_down :: proc() -> bool {
	return key_down(.LEFT_SHIFT) || key_down(.RIGHT_SHIFT)
}

