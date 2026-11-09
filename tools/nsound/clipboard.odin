package main

import ne "../../"

// The clipboard: one track's worth of notes, with the instrument and volume
// that were playing them, ready to be dropped onto another track.

Clip :: struct {
	song_notes: [dynamic]ne.Note,
	inst:       string,
	volume:     f32,
}

clipboard: Clip

clipboard_destroy :: proc() {
	delete(clipboard.song_notes)
	delete(clipboard.inst)
	clipboard = {}
}
