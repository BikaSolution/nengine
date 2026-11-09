package nengine

import "core:testing"

@(test)
staff_steps_hold_both_clefs_at_once :: proc(t: ^testing.T) {
	// C4, middle C, is step 28, and that is what makes one continuous
	// ladder hold a grand staff: the treble lines (E4 G4 B4 D5 F5) and the
	// bass lines (G2 B2 D3 F3 A3) are both just "every even step".
	testing.expect_value(t, pitch_midi({28, 0}), 60) // C4
	testing.expect_value(t, pitch_midi({5, 0}), 21)  // A0, the bottom of a piano
	testing.expect_value(t, pitch_midi({56, 0}), 108) // C8, the top

	for step in ([?]int{30, 32, 34, 36, 38}) { // E4 G4 B4 D5 F5
		testing.expectf(t, step_is_grand_staff(step), "treble line at step %v", step)
	}
	for step in ([?]int{18, 20, 22, 24, 26}) { // G2 B2 D3 F3 A3
		testing.expectf(t, step_is_grand_staff(step), "bass line at step %v", step)
	}
	// Middle C is a line, but not one of the ten: it is the ledger between.
	testing.expect(t, step_is_line(28), "middle C is on a line")
	testing.expect(t, !step_is_grand_staff(28), "and it is a ledger line, not a staff line")
	testing.expect(t, !step_is_line(29), "the space above it is a space")
}

@(test)
a_pitch_keeps_its_spelling :: proc(t: ^testing.T) {
	// F#4 and Gb4 are the same key on a piano and two different notes on
	// paper. A song that comes back from disk with its sharps turned into
	// flats has been damaged.
	sharp, ok1 := parse_pitch("F#4")
	flat, ok2 := parse_pitch("Gb4")
	testing.expect(t, ok1 && ok2)
	testing.expect_value(t, pitch_midi(sharp), pitch_midi(flat)) // the same sound
	testing.expect(t, sharp != flat, "and not the same note")
	testing.expect_value(t, pitch_text(sharp), "F#4")
	testing.expect_value(t, pitch_text(flat), "Gb4")

	for spelling in ([?]string{"C4", "C#4", "Cb4", "Cx4", "Cbb4", "A0", "C8", "bb3"}) {
		p, ok := parse_pitch(spelling)
		testing.expectf(t, ok, "%v reads", spelling)
		back, again := parse_pitch(pitch_text(p))
		testing.expectf(t, again && back == p, "%v survives a round trip", spelling)
	}
	_, bad := parse_pitch("H4")
	testing.expect(t, !bad, "there is no note called H")
}

@(test)
the_key_signature_decides_the_black_keys :: proc(t: ^testing.T) {
	// In D major (two sharps) an F is an F#, and a C is a C#; nothing else
	// is altered. Sharps arrive in the order F C G D A E B.
	F :: 3
	C :: 0
	G :: 4
	testing.expect_value(t, key_alter(2, 28 + F), i8(1))
	testing.expect_value(t, key_alter(2, 28 + C), i8(1))
	testing.expect_value(t, key_alter(2, 28 + G), i8(0))
	// In F major (one flat) the B is flat.
	B :: 6
	testing.expect_value(t, key_alter(-1, 28 + B), i8(-1))
	testing.expect_value(t, key_alter(-1, 28 + C), i8(0))
	testing.expect_value(t, key_name(2), "D major")
	testing.expect_value(t, key_name(0), "C major")
	testing.expect_value(t, key_name(-1), "F major")

	// And a MIDI number is spelled to suit: sharps in sharp keys, flats in
	// flat ones.
	testing.expect_value(t, pitch_text(pitch_from_midi(66, 2)), "F#4")
	testing.expect_value(t, pitch_text(pitch_from_midi(66, -2)), "Gb4")
}

@(test)
note_lengths_and_the_slots_they_fall_in :: proc(t: ^testing.T) {
	// 24 ticks to a quarter is the smallest number that divides evenly into
	// 32nds and into every triplet, which is the whole reason for it.
	testing.expect_value(t, note_ticks(.Quarter, .None), i32(24))
	testing.expect_value(t, note_ticks(.Whole, .None), i32(96))
	testing.expect_value(t, note_ticks(.Thirty_Second, .None), i32(3))
	testing.expect_value(t, note_ticks(.Quarter, .Dotted), i32(36)) // a half as long again
	testing.expect_value(t, note_ticks(.Eighth, .Triplet), i32(8))  // three in the time of two
	// Three eighth-triplets fill exactly one quarter. If that were not exact
	// the phrase would drift.
	testing.expect_value(t, 3 * note_ticks(.Eighth, .Triplet), note_ticks(.Quarter, .None))
	// A dotted 32nd would be 4.5 ticks, so it quietly stays a plain 32nd.
	testing.expect_value(t, note_ticks(.Thirty_Second, .Dotted), i32(3))

	// A note snaps to slots of its own length — but a DOTTED note snaps to
	// half its undotted length, because that is where dotted notes actually
	// fall: a dotted quarter lands on eighths.
	testing.expect_value(t, snap_ticks(.Quarter, .None), i32(24))
	testing.expect_value(t, snap_ticks(.Quarter, .Dotted), i32(12))
	testing.expect_value(t, snap_ticks(.Eighth, .Triplet), i32(8))

	// And a length can be recognised again from its ticks, for showing what
	// an imported note is.
	l, m := ticks_length(36)
	testing.expect_value(t, l, Length.Quarter)
	testing.expect_value(t, m, Length_Mod.Dotted)
	l2, m2 := ticks_length(8)
	testing.expect_value(t, l2, Length.Eighth)
	testing.expect_value(t, m2, Length_Mod.Triplet)
}

@(test)
bars_are_a_way_of_looking_at_the_time_line :: proc(t: ^testing.T) {
	// Changing the time signature re-flows the bars without moving a note,
	// which is the point of storing ticks rather than rows.
	s := song_new("x", 120, 4)
	defer song_destroy(&s)
	song_add_track(&s, "a", "sine", 0.5)
	track_put(&s.tracks[0], Note{tick = 96, len = 24, pitch = {28, 0}, vel = 100})

	testing.expect_value(t, bar_ticks(&s), i32(96)) // 4/4
	testing.expect_value(t, beat_ticks(&s), i32(24))

	s.beats, s.beat_unit = 3, 4
	testing.expect_value(t, bar_ticks(&s), i32(72)) // 3/4
	testing.expect_value(t, s.tracks[0].notes[0].tick, i32(96)) // the note has not moved

	s.beats, s.beat_unit = 6, 8
	testing.expect_value(t, bar_ticks(&s), i32(72)) // 6/8 is the same length
	testing.expect_value(t, beat_ticks(&s), i32(12))
}

@(test)
putting_a_note_down_replaces_what_it_overlaps :: proc(t: ^testing.T) {
	// One instrument cannot play the same string twice at once, so a note
	// dropped on top of another at the SAME SOUNDING PITCH replaces it —
	// which is what the person clicking meant.
	tr: Track
	defer track_destroy(&tr)
	track_put(&tr, Note{tick = 0, len = 48, pitch = {28, 0}, vel = 100})   // C4, two beats
	track_put(&tr, Note{tick = 24, len = 24, pitch = {28, 0}, vel = 100})  // C4 inside it
	testing.expect_value(t, len(tr.notes), 1)
	testing.expect_value(t, tr.notes[0].tick, i32(24))

	// A different pitch at the same moment is a chord, not a replacement.
	track_put(&tr, Note{tick = 24, len = 24, pitch = {30, 0}, vel = 100}) // E4
	testing.expect_value(t, len(tr.notes), 2)

	// And the same step spelled differently is the same string: Cb4 sounds
	// as B3, so it does not collide with C4.
	track_put(&tr, Note{tick = 24, len = 24, pitch = {28, -1}, vel = 100})
	testing.expect_value(t, len(tr.notes), 3)

	// Notes come back in time order, ready to be walked by the player.
	for i in 1 ..< len(tr.notes) {
		testing.expect(t, tr.notes[i - 1].tick <= tr.notes[i].tick, "sorted by tick")
	}
}

@(test)
the_tracker_grid_and_the_sheet_see_the_same_notes :: proc(t: ^testing.T) {
	// Two views, one song. Something written as cells reads back as notes of
	// real length, and something written at a tick the grid has no cell for
	// still shows up in the grid — marked, because the grid is approximating.
	s := song_new("both", 120, 1)
	defer song_destroy(&s)
	song_add_track(&s, "a", "sine", 0.5)
	tr := &s.tracks[0]

	// Four cells of the grid: struck, then held three times.
	track_write_cell(&s, tr, 0, parse_note("C4"))
	for i in 1 ..= 3 do track_write_cell(&s, tr, i, HOLD)
	testing.expect_value(t, len(tr.notes), 1)
	testing.expect_value(t, tr.notes[0].len, i32(TPQ)) // four sixteenths is a quarter
	testing.expect_value(t, track_cell(&s, tr, 0).note, parse_note("C4"))
	testing.expect_value(t, track_cell(&s, tr, 2).note, HOLD)
	testing.expect_value(t, track_cell(&s, tr, 4).note, REST)
	testing.expect(t, !track_cell(&s, tr, 0).off_grid, "it started on a cell")

	// Now an eighth-note triplet, as the sheet would place it: 8 ticks, so
	// the second one starts between cells.
	track_put(tr, Note{tick = 48, len = 8, pitch = {30, 0}, vel = 100})
	track_put(tr, Note{tick = 56, len = 8, pitch = {31, 0}, vel = 100})
	track_put(tr, Note{tick = 64, len = 8, pitch = {32, 0}, vel = 100})
	// Cell 8 is tick 48; cell 9 is tick 54, and the note at 56 falls in it.
	testing.expect_value(t, track_cell(&s, tr, 8).note, pitch_midi({30, 0}))
	testing.expect(t, !track_cell(&s, tr, 8).off_grid, "the first triplet is on a cell")
	testing.expect_value(t, track_cell(&s, tr, 9).note, pitch_midi({31, 0}))
	testing.expect(t, track_cell(&s, tr, 9).off_grid, "the second one is not, and says so")

	// Clearing a cell that a longer note runs through cuts that note short
	// rather than leaving it sounding over a rest.
	track_write_cell(&s, tr, 2, REST)
	testing.expect_value(t, tr.notes[0].len, 2 * song_grid(&s))
}

@(test)
a_song_that_loops_is_exactly_its_bars_long :: proc(t: ^testing.T) {
	// A game's background bed has to join up, so it is exactly its bars long
	// and a note running off the end wraps round to the start. A piece of
	// music is left to ring out instead.
	loop := song_new("bed", 120, 1) // one 4/4 bar at 120bpm is two seconds
	defer song_destroy(&loop)
	song_add_track(&loop, "a", "sine", 0.5)
	// A note near the end, longer than the room left for it.
	track_put(&loop.tracks[0], Note{tick = 84, len = 48, pitch = {28, 0}, vel = 100})

	samples := test_song_mono(&loop)
	defer delete(samples)
	testing.expect_value(t, len(samples), 2 * SAMPLE_RATE)
	// It wrapped: there is sound at the very beginning, from the note that
	// started near the end.
	first: f32
	for i in 0 ..< SAMPLE_RATE / 20 do first = max(first, abs(samples[i]))
	testing.expect(t, first > 0.05, "the tail of the last note is heard at the start")

	once := song_new("piece", 120, 1)
	defer song_destroy(&once)
	once.loop = false
	song_add_track(&once, "a", "sine", 0.5)
	track_put(&once.tracks[0], Note{tick = 84, len = 48, pitch = {28, 0}, vel = 100})
	tail := test_song_mono(&once)
	defer delete(tail)
	testing.expect(t, len(tail) > 2 * SAMPLE_RATE, "a piece is given room to finish")
	quiet: f32
	for i in 0 ..< SAMPLE_RATE / 20 do quiet = max(quiet, abs(tail[i]))
	testing.expect(t, quiet < 0.001, "and nothing wraps round to the start")
}

@(test)
velocity_is_how_hard_a_note_is_struck :: proc(t: ^testing.T) {
	loud := song_new("loud", 120, 1)
	defer song_destroy(&loud)
	song_add_track(&loud, "a", "sine", 0.5)
	track_put(&loud.tracks[0], Note{tick = 0, len = 24, pitch = {28, 0}, vel = 127})

	soft := song_new("soft", 120, 1)
	defer song_destroy(&soft)
	song_add_track(&soft, "a", "sine", 0.5)
	track_put(&soft.tracks[0], Note{tick = 0, len = 24, pitch = {28, 0}, vel = 32})

	// Each is mastered on its own, so take the level-setting away or both
	// would come out at the same loudness, which is the point of it.
	loud.level, soft.level = LEVEL_NONE, LEVEL_NONE
	peak :: proc(s: ^Song) -> f32 {
		samples := test_song_mono(s)
		defer delete(samples)
		out: f32
		for v in samples do out = max(out, abs(v))
		return out
	}
	testing.expect(t, peak(&loud) > peak(&soft) * 2, "127 is a good deal louder than 32")
}

@(test)
mute_and_solo_decide_what_is_heard :: proc(t: ^testing.T) {
	s := song_new("mix", 120, 1)
	defer song_destroy(&s)
	song_add_track(&s, "a", "sine", 0.5)
	song_add_track(&s, "b", "sine", 0.5)

	testing.expect(t, track_audible(&s, &s.tracks[0]))
	s.tracks[0].mute = true
	testing.expect(t, !track_audible(&s, &s.tracks[0]))
	testing.expect(t, track_audible(&s, &s.tracks[1]))

	// Any solo anywhere silences everything that isn't soloed — including
	// tracks that were perfectly happy a moment ago.
	s.tracks[0].mute = false
	s.tracks[1].solo = true
	testing.expect(t, !track_audible(&s, &s.tracks[0]))
	testing.expect(t, track_audible(&s, &s.tracks[1]))
	// And mute still wins over a track's own solo.
	s.tracks[1].mute = true
	testing.expect(t, !track_audible(&s, &s.tracks[1]))
}
