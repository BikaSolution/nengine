package nengine

import "core:testing"

// The editors' undo keeps each step as the text the document would be saved
// as, and restores by parsing it back. That only works if text and parse are
// exact inverses — so these check the two halves against each other without
// touching the disk.

@(test)
a_sprite_survives_a_text_round_trip :: proc(t: ^testing.T) {
	d := sprite_data_new("lamp", 7, 5, 3)
	defer sprite_data_destroy(&d)
	append(&d.palette, Palette_Entry{'#', {10, 20, 30, 255}})
	append(&d.palette, Palette_Entry{'o', {200, 180, 40, 255}})
	for f in 0 ..< i32(3) {
		for y in 0 ..< i32(5) do for x in 0 ..< i32(7) {
			sprite_data_at(&d, f, x, y)^ = u8((int(x) + int(y) + int(f)) % 3)
		}
	}

	back, ok := parse_sprite_data(sprite_data_text(&d))
	defer sprite_data_destroy(&back)
	testing.expect(t, ok)
	testing.expect_value(t, back.name, d.name)
	testing.expect_value(t, back.w, d.w)
	testing.expect_value(t, back.h, d.h)
	testing.expect_value(t, back.frames, d.frames)
	for f in 0 ..< d.frames do for y in 0 ..< d.h do for x in 0 ..< d.w {
		if sprite_data_at(&back, f, x, y)^ != sprite_data_at(&d, f, x, y)^ {
			testing.expectf(t, false, "pixel %v,%v of frame %v came back different", x, y, f)
			return
		}
	}
}

@(test)
a_song_survives_a_text_round_trip :: proc(t: ^testing.T) {
	s := song_new("theme", 96, 12)
	defer song_destroy(&s)
	song_add_track(&s, "organ", "organ", 0.4)
	song_add_track(&s, "box", "marimba", 0.25)
	s.key = -2
	// A held chord note, a dotted quarter and a triplet eighth: the lengths
	// the old grid could not say at all.
	track_put(&s.tracks[0], Note{tick = 0, len = note_ticks(.Whole, .None), pitch = {step = 16, alter = -1}, vel = 100})
	track_put(&s.tracks[0], Note{tick = 96, len = note_ticks(.Quarter, .Dotted), pitch = {step = 18, alter = 0}, vel = 64})
	track_put(&s.tracks[1], Note{tick = 36, len = note_ticks(.Eighth, .Triplet), pitch = {step = 40, alter = 1}, vel = 127})

	back, ok := parse_song(song_text(&s))
	defer song_destroy(&back)
	testing.expect(t, ok)
	testing.expect_value(t, back.name, s.name)
	testing.expect_value(t, back.tempo, s.tempo)
	testing.expect_value(t, back.bars, s.bars)
	testing.expect_value(t, back.key, s.key)
	testing.expect_value(t, back.beats, s.beats)
	testing.expect_value(t, back.beat_unit, s.beat_unit)
	testing.expect_value(t, len(back.tracks), len(s.tracks))
	for track, i in back.tracks {
		testing.expect_value(t, track.inst, s.tracks[i].inst)
		testing.expect_value(t, track.volume, s.tracks[i].volume)
		testing.expect_value(t, len(track.notes), len(s.tracks[i].notes))
		for n, j in track.notes {
			testing.expectf(t, n == s.tracks[i].notes[j],
				"track %v note %v: %v became %v", i, j, s.tracks[i].notes[j], n)
		}
	}
}

@(test)
the_old_grid_format_still_opens :: proc(t: ^testing.T) {
	// Every .song written before time was measured in ticks. A run of "-"
	// after a note was that note being held, so it becomes its length.
	s, ok := parse_song(`
song old
bpm 120
steps 16
track bass sine vol=0.4
A2 - - - . . . . F2 - - - . . . .
track lead bell vol=0.2
. . . . E5 . . . . . . . . . . .
`)
	defer song_destroy(&s)
	testing.expect(t, ok)
	testing.expect_value(t, s.name, "old")
	testing.expect_value(t, s.tempo, f32(120))
	testing.expect_value(t, len(s.tracks), 2)
	testing.expect_value(t, s.tracks[0].inst, "sine")

	// 16 sixteenths is one 4/4 bar.
	testing.expect_value(t, s.bars, i32(1))
	testing.expect_value(t, len(s.tracks[0].notes), 2)
	sixteenth := i32(TPQ / 4)
	testing.expect_value(t, s.tracks[0].notes[0].tick, i32(0))
	testing.expect_value(t, s.tracks[0].notes[0].len, 4 * sixteenth) // struck, then three holds
	testing.expect_value(t, pitch_midi(s.tracks[0].notes[0].pitch), parse_note("A2"))
	testing.expect_value(t, s.tracks[0].notes[1].tick, 8 * sixteenth)
	testing.expect_value(t, s.tracks[0].notes[1].len, 4 * sixteenth)
	testing.expect_value(t, len(s.tracks[1].notes), 1)
	testing.expect_value(t, s.tracks[1].notes[0].tick, 4 * sixteenth)
	testing.expect_value(t, s.tracks[1].notes[0].len, sixteenth)
}

@(test)
two_objects_of_one_name_keep_their_own_lines :: proc(t: ^testing.T) {
	text := `scene yard
obj fire pos=10,10 when=laid
text fire Laid, not lit.
on fire look when=laid Kindling.
obj fire pos=10,10 when=!laid
text fire Burning.
`
	s, ok := parse_scene(text, nil)
	defer {
		free_scene_strings(&s)
		delete(s.objects); delete(s.exits); delete(s.triggers)
		delete(s.walk_area); delete(s.scenery); delete(s.said)
	}
	testing.expect(t, ok)
	testing.expect_value(t, len(s.objects), 2)
	testing.expect_value(t, s.objects[0].description, "Laid, not lit.")
	testing.expect_value(t, len(s.objects[0].on), 1)
	testing.expect_value(t, s.objects[1].description, "Burning.")
	testing.expect_value(t, len(s.objects[1].on), 0)
}
