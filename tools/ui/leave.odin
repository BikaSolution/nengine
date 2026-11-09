package ui

import "core:fmt"
import rl "vendor:raylib"

// Going back to the browser from an editor.
//
// Every editor has the same three ways out — Esc when there is nothing else
// for Esc to drop, ^B, and the `< files` button at the top left — and they
// all come through here, because they all have the same problem: a file with
// unsaved changes. Leaving one used to throw the changes away without a word.
//
// So leaving a changed file asks first, the way Sierra's tools did: a box over
// the editor naming the file, with save, don't save and keep editing. The
// editor underneath goes on drawing but reads no input while it is up (see
// input.odin), so a click on a button never also lands on the canvas.
//
// An editor uses it like this:
//
//     switch ui.leave_answer() {            // first thing in its step
//     case .Save:    if save(e, status) do return false
//     case .Discard: return false
//     case .None:
//     }
//     ...
//     if esc_with_nothing_pending || ui.back_pressed() {
//         if ui.leave_request(e.dirty, name) do return false
//     }
//     ...
//     if ui.back_button() && ui.leave_request(e.dirty, name) do leaving = true
//
// The box itself is drawn by the host, over whatever the editor drew.

Leave_Answer :: enum {
	None,
	Save,    // save, then go
	Discard, // go without saving
}

@(private = "file")
Leave_State :: struct {
	asking:  bool,
	name:    [128]u8, // the file's name, copied: the editor may let go of its own
	name_n:  int,
	opened:  int, // the frame it went up, so the key that asked doesn't answer
	answer:  Leave_Answer,
	frame:   int,
}

@(private = "file")
leave: Leave_State

// True when the editor may go now. False when the file has unsaved changes:
// the question is up, and the answer arrives through `leave_answer`.
leave_request :: proc(dirty: bool, name: string) -> bool {
	if !dirty do return true
	if leave.asking do return false
	leave.asking = true
	leave.name_n = copy(leave.name[:], name)
	leave.opened = leave.frame + 1 // the frame now being drawn
	leave.answer = .None
	input_block(true)
	return false
}

// What was answered, once, on the frame after. `.None` the rest of the time.
leave_answer :: proc() -> Leave_Answer {
	a := leave.answer
	leave.answer = .None
	return a
}

// True while the question is up.
leave_asking :: proc() -> bool {
	return leave.asking
}

// ^B: back to the browser. Not Backspace, which a text field needs, and not B,
// which turns nart's dither on and off.
back_pressed :: proc() -> bool {
	return ctrl_down() && key_pressed(.B)
}

BACK_W :: 74 // the button, and the gap after it

// The `< files` button, top left of an editor's header. Returns true on the
// frame it is clicked; the title goes `BACK_W` along to make room for it.
back_button :: proc(y: f32 = 8) -> bool {
	return button({8, y, BACK_W - 12, 24}, "< files")
}

// Drawn by the host after the program's frame, over the top of it, and the
// only thing that reads input while it is up. `frame` is the host's count.
@(private)
leave_draw :: proc(frame: int) {
	leave.frame = frame
	if !leave.asking do return
	input_block(false)
	defer if leave.asking do input_block(true)

	w, h := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	rl.DrawRectangleRec({0, 0, w, h}, {10, 10, 14, 170})
	bw := min(f32(440), w - 32)
	box := rl.Rectangle{(w - bw) / 2, h / 2 - 70, bw, 132}
	rl.DrawRectangleRec({box.x + 4, box.y + 4, box.width, box.height}, {0, 0, 0, 120})
	panel(box)
	rl.DrawRectangleRec({box.x, box.y, box.width, 3}, GOLD)

	name := string(leave.name[:leave.name_n])
	label(i32(box.x) + 18, i32(box.y) + 18, ellipsize(fmt.tprintf("%v has changes", name), box.width - 36, FONT), INK, FONT)
	label(i32(box.x) + 18, i32(box.y) + 44, "save them before going back to the files?", DIM, SMALL)

	gap := f32(8)
	bw3 := (box.width - 36 - gap * 2) / 3
	by := box.y + box.height - 42
	fresh := frame <= leave.opened // the press that asked is not an answer
	answer := Leave_Answer.None
	stay := false
	if button({box.x + 18, by, bw3, 28}, "save  (S)", true) && !fresh do answer = .Save
	if button({box.x + 18 + bw3 + gap, by, bw3, 28}, "don't save  (D)") && !fresh do answer = .Discard
	if button({box.x + 18 + (bw3 + gap) * 2, by, bw3, 28}, "keep editing  (Esc)") && !fresh do stay = true
	if !fresh {
		switch {
		case key_pressed(.S) || key_pressed(.ENTER) || key_pressed(.KP_ENTER): answer = .Save
		case key_pressed(.D) || key_pressed(.N):                               answer = .Discard
		case key_pressed(.ESCAPE):                                             stay = true
		}
	}
	if answer != .None || stay {
		leave.asking = false
		leave.answer = answer
		input_block(false)
		// A button still held from the click that answered must not go on to
		// paint the canvas underneath once the box is gone.
		input_hold_off_mouse()
	}
}

// Forgets a question nobody will answer: the program is closing.
leave_reset :: proc() {
	leave = {}
	input_block(false)
}
