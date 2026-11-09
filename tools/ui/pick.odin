package ui

import "core:os"
import "core:strings"

// Asking for a file from inside an editor: which backdrop a room has, which
// sprite an object wears, which character a person is drawn from.
//
// It is the browser — places, breadcrumbs, find, the preview — asked a
// question instead of being the way into an editor. It takes the whole
// window while it is up, because choosing art is looking at art, and a strip
// of thumbnails squeezed down the side of an editor is how a room editor
// ended up loading every sprite in the game to draw one panel. Here only the
// file under the cursor is ever opened, by the preview the editor hands in.
//
//     // Asking:
//     ui.pick_open(&e.pick, "backdrop", "Choose a backdrop", SPRITES[:], scene_dir,
//                  select = current_file, preview = px.art_preview, ctx = &e.art_preview)
//
//     // Every frame, before the editor does anything else:
//     if ui.pick_active(&e.pick) {
//         if a := ui.pick_step(&e.pick, status); a.done {
//             if a.path != "" && a.asking == "backdrop" do set_backdrop(e, a.path)
//         }
//         return true // the picker drew the frame
//     }
//
// `accept`, if given, narrows the files listed further than their kind: only
// the sprites big enough to be a room, say (px.art_is_backdrop). `deep` lists
// every file of the kind below the folder rather than those in it, as a
// search does — for rooms, each of which has a folder of its own.
//
// `asking` says which question was answered, so one picker serves them all.
// The answer arrives once, on the frame it is given, and the picker has
// closed by then; a cancel is an answer with no path.
//
// Nothing is made, renamed or erased from a picker, and where it was left is
// not remembered as the folder the tool was last browsing.

Picker :: struct {
	browser: Browser,
	asking:  string, // owned
	active:  bool,
}

Pick_Answer :: struct {
	done:   bool,   // answered this frame
	path:   string, // the file chosen, absolute; "" when cancelled. Good for this frame
	asking: string, // which question it answers. Good for this frame
}

// Puts the question up. `start` is a folder to start in, or a file: then it
// starts in that file's folder with the file selected (the current answer,
// so choosing again starts from what is there). `select` picks a file in the
// start folder as well. `kinds` is borrowed and must outlive the picker.
pick_open :: proc(
	p: ^Picker,
	asking, title: string,
	kinds: []File_Kind,
	start: string,
	select := "",
	preview: Preview_Proc = nil,
	ctx: rawptr = nil,
	accept: Accept_Proc = nil,
	deep := false,
) {
	pick_close(p)
	dir := start
	chosen := select
	if start != "" && os.is_file(start) {
		dir = parent_dir(abs_path(start, context.temp_allocator))
		if chosen == "" do chosen = start
	}
	if dir == "" || !os.is_dir(dir) do dir = abs_path("", context.temp_allocator)
	browser_open(&p.browser, title, "pick", kinds, dir, nil, preview, ctx)
	p.browser.picking = true
	if accept != nil || deep {
		p.browser.accept = accept
		p.browser.deep = deep
		browser_refresh(&p.browser)
	}
	if chosen != "" do browser_select(&p.browser, chosen)
	p.asking = strings.clone(asking)
	p.active = true
}

pick_active :: proc(p: ^Picker) -> bool {
	return p.active
}

// One frame of the question, drawn over the whole window.
pick_step :: proc(p: ^Picker, status: ^Status) -> (a: Pick_Answer) {
	if !p.active do return
	path, chosen, running := browser_step(&p.browser, status)
	if !chosen && running do return
	a.done = true
	a.asking = strings.clone(p.asking, context.temp_allocator)
	if chosen do a.path = strings.clone(path, context.temp_allocator)
	pick_close(p)
	// Whatever answered — the Enter, the double click, the Esc — has done
	// its job and must not land on the editor underneath this same frame.
	input_swallow()
	input_hold_off_mouse()
	return
}

pick_close :: proc(p: ^Picker) {
	browser_close(&p.browser)
	delete(p.asking)
	p^ = {}
}
