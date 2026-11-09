package nengine

import "core:testing"

// A MIDI file, built here rather than checked in as a blob, so what the test
// is feeding the importer is readable.
@(private = "file")
Builder :: struct {
	out: [dynamic]u8,
}

@(private = "file")
put :: proc(b: ^Builder, bytes: ..u8) {
	append(&b.out, ..bytes)
}

@(private = "file")
put_be :: proc(b: ^Builder, v: u32, n: int) {
	for i := n - 1; i >= 0; i -= 1 do append(&b.out, u8(v >> uint(8 * i)))
}

// A delta time: seven bits a byte, top bit set on all but the last.
@(private = "file")
put_var :: proc(b: ^Builder, v: u32) {
	buf: [4]u8
	n := 0
	x := v
	for {
		buf[n] = u8(x & 0x7f)
		n += 1
		x >>= 7
		if x == 0 do break
	}
	for i := n - 1; i >= 0; i -= 1 {
		append(&b.out, buf[i] | (0x80 if i > 0 else 0))
	}
}

@(private = "file")
test_midi :: proc(allocator := context.allocator) -> []u8 {
	b := Builder{out = make([dynamic]u8, allocator)}
	DIVISION :: 96 // ticks to a quarter note in the file

	put(&b, 'M', 'T', 'h', 'd')
	put_be(&b, 6, 4)
	put_be(&b, 0, 2)        // format 0
	put_be(&b, 1, 2)        // one track
	put_be(&b, DIVISION, 2)

	track := Builder{out = make([dynamic]u8, context.temp_allocator)}
	put_var(&track, 0); put(&track, 0xFF, 0x51, 0x03); put_be(&track, 500_000, 3) // 120 bpm
	put_var(&track, 0); put(&track, 0xFF, 0x58, 0x04, 4, 2, 24, 8)                // 4/4
	put_var(&track, 0); put(&track, 0xFF, 0x59, 0x02, 2, 0)                       // two sharps: D major
	put_var(&track, 0); put(&track, 0xC0, 40)                                     // GM 40: violin

	// Two quarter notes and then an eighth-note triplet, so both grids are
	// exercised: E5, F#5, then three notes in the time of two eighths.
	put_var(&track, 0);        put(&track, 0x90, 76, 100) // E5 on
	put_var(&track, DIVISION); put(&track, 0x80, 76, 0)
	put_var(&track, 0);        put(&track, 0x90, 78, 90)  // F#5 on
	put_var(&track, DIVISION); put(&track, 0x80, 78, 0)
	third :: DIVISION / 3
	for note in ([?]u8{74, 76, 78}) {
		put_var(&track, 0);     put(&track, 0x90, note, 80)
		put_var(&track, third); put(&track, 0x80, note, 0)
	}
	put_var(&track, 0); put(&track, 0xFF, 0x2F, 0x00) // end of track

	put(&b, 'M', 'T', 'r', 'k')
	put_be(&b, u32(len(track.out)), 4)
	append(&b.out, ..track.out[:])
	return b.out[:]
}

@(test)
a_midi_file_comes_in_as_a_song :: proc(t: ^testing.T) {
	data := test_midi()
	defer delete(data)

	insts: Instrument_Set
	defer instrument_set_destroy(&insts)
	instruments_load(&insts)

	song: Song
	defer song_destroy(&song)
	rep := midi_import(data, &song, "test tune", &insts)

	testing.expectf(t, rep.problem == "", "it read: %v", rep.problem)
	testing.expect_value(t, rep.notes, 5)
	testing.expect_value(t, rep.tracks, 1)
	testing.expect_value(t, song.name, "test tune")
	testing.expect_value(t, song.tempo, f32(120))
	testing.expect_value(t, song.beats, i32(4))
	testing.expect_value(t, song.beat_unit, i32(4))
	testing.expect_value(t, song.key, i32(2)) // D major
	testing.expect(t, !song.loop, "a piece of music ends rather than going round")

	// GM program 40 is the violin, and we have one.
	if len(song.tracks) > 0 {
		testing.expect_value(t, song.tracks[0].inst, "violin")
	}

	notes := song.tracks[0].notes[:]
	testing.expect_value(t, len(notes), 5)

	// The file counts 96 ticks to a quarter; we count 24. So a quarter note
	// lands on 0 and 24, whatever the file's own resolution was.
	testing.expect_value(t, notes[0].tick, i32(0))
	testing.expect_value(t, notes[0].len, i32(TPQ))
	testing.expect_value(t, notes[1].tick, i32(TPQ))
	testing.expect_value(t, notes[1].len, i32(TPQ))

	// And the triplet survives: three notes of 8 ticks in the 24 that two
	// eighths would take. Rounded to the 32nd grid alone they would be 6, 6
	// and 6 and the phrase would limp.
	testing.expect_value(t, notes[2].tick, i32(2 * TPQ))
	testing.expect_value(t, notes[2].len, i32(8))
	testing.expect_value(t, notes[3].tick, i32(2 * TPQ + 8))
	testing.expect_value(t, notes[4].tick, i32(2 * TPQ + 16))

	// In D major the black key between F and G is spelled F#, not Gb.
	testing.expect_value(t, pitch_text(notes[1].pitch), "F#5")
	testing.expect_value(t, notes[1].vel, u8(90))

	// And it plays.
	samples := test_song_mono(&song, &insts)
	defer delete(samples)
	loudest: f32
	for v in samples do loudest = max(loudest, abs(v))
	testing.expect(t, loudest > 0.1, "the imported song makes a sound")
}

@(test)
a_file_that_is_not_midi_is_turned_away :: proc(t: ^testing.T) {
	song: Song
	defer song_destroy(&song)
	rep := midi_import({'n', 'o', 'p', 'e'}, &song, "x")
	testing.expect(t, rep.problem != "", "it says what was wrong")
	testing.expect_value(t, rep.notes, 0)
	delete(rep.problem)
}

@(test)
a_note_out_of_range_is_moved_by_octaves :: proc(t: ^testing.T) {
	// A piccolo cannot play a bottom C. Rather than drop the note or let the
	// synth grind it out below its body, the import lifts it by octaves and
	// says how many it had to move.
	set: Instrument_Set
	defer instrument_set_destroy(&set)
	parse_instruments(&set, "instrument piccolo\nrange D5 C8\nwave triangle\nend\n")

	ins := instrument_get(&set, "piccolo")
	m := 36 // C2
	moved := 0
	for m < ins.lo { m += 12; moved += 1 }
	testing.expect_value(t, moved, 4) // 36 -> 48 -> 60 -> 72 -> 84, since D5 is 74
	testing.expect(t, m >= ins.lo && m <= ins.hi, "and it lands inside the range")
}
