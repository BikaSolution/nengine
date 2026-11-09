package pixel

import ne "../../"

// The clipboard: a patch of pixels, lifted out of one frame and put down in
// another — or in another file, since a sprite and a character's pose are the
// same kind of grid.
//
// It carries its own palette, and pasting MATCHES BY COLOUR, adding anything
// the destination hasn't got. Paste somebody else's palette indices straight
// in and you get confetti.

Clip :: struct {
	w, h:    i32,
	px:      [dynamic]u8,
	palette: [dynamic]ne.Palette_Entry,
}

clipboard: Clip

clipboard_destroy :: proc() {
	delete(clipboard.px)
	delete(clipboard.palette)
	clipboard = {}
}

clip_copy :: proc(d: ^ne.Sprite_Data, frame: i32, r: [4]i32) {
	clear(&clipboard.px)
	clear(&clipboard.palette)
	clipboard.w, clipboard.h = r[2], r[3]
	append(&clipboard.palette, ..d.palette[:])
	for y in 0 ..< r[3] {
		for x in 0 ..< r[2] {
			cell := ne.sprite_data_at(d, frame, r[0] + x, r[1] + y)
			append(&clipboard.px, cell^ if cell != nil else 0)
		}
	}
}

// Pastes at (ox, oy), matching colours rather than indices — and snapping them
// to the destination's mode on the way in, so that lifting a patch out of an
// old VGA picture and dropping it into a bEGA one cannot smuggle a colour past
// the constraint the file declares.
clip_paste :: proc(d: ^ne.Sprite_Data, frame, ox, oy: i32) -> bool {
	if clipboard.w <= 0 || len(clipboard.px) == 0 do return false
	for y in 0 ..< clipboard.h {
		for x in 0 ..< clipboard.w {
			from := clipboard.px[int(y * clipboard.w + x)]
			if from == 0 do continue // transparent stays transparent
			cell := ne.sprite_data_at(d, frame, ox + x, oy + y)
			if cell == nil do continue
			cell^ = match_colour(d, clipboard.palette[int(from)] if int(from) < len(clipboard.palette) else {})
		}
	}
	return true
}

// The index of this colour in the document's palette, adding it if it's new,
// after putting it on the mode's grid. Out of names it gives transparent, which
// is a hole in the paste and visible; there is nowhere better for it to go.
@(private = "file")
match_colour :: proc(d: ^ne.Sprite_Data, want: ne.Palette_Entry) -> u8 {
	slot, _ := canvas_slot_for(d, ne.palette_mode_snap(d.mode, want.color))
	return slot
}
