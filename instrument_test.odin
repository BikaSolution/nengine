package nengine

import "core:math"
import "core:testing"

@(test)
an_inst_block_sets_what_it_says :: proc(t: ^testing.T) {
	set: Instrument_Set
	defer instrument_set_destroy(&set)
	n := parse_instruments(&set, `
# a comment
instrument oboe
name "Oboe"
family woodwinds
range Bb3 G6
wave pulse 0.125
layer triangle 0.3 12
envelope 0.03 0.1 0.88 0.07
vibrato 5.5 0.1 0.2
sweep -0.5 0.03
breath 0.02
tone 0.6
gain 0.45
color 180 200 120
end
`)
	testing.expect_value(t, n, 1)
	ins, ok := instrument_find(&set, "oboe")
	testing.expect(t, ok, "the block was read")
	testing.expect_value(t, ins.name, "Oboe")
	testing.expect_value(t, ins.family, "woodwinds")
	testing.expect_value(t, ins.wave, Wave.Pulse)
	testing.expect_value(t, ins.duty, f32(0.125))
	testing.expect_value(t, ins.wave2, Wave.Triangle)
	testing.expect_value(t, ins.semis2, f32(12))
	testing.expect_value(t, ins.sustain, f32(0.88))
	testing.expect_value(t, ins.sweep, f32(-0.5))
	testing.expect_value(t, ins.color, [4]u8{180, 200, 120, 255})
	// "Bb3" is A#3 is MIDI 58, "G6" is 91.
	testing.expect_value(t, ins.lo, 58)
	testing.expect_value(t, ins.hi, 91)
}

@(test)
based_on_changes_only_the_lines_it_gives :: proc(t: ^testing.T) {
	set: Instrument_Set
	defer instrument_set_destroy(&set)
	parse_instruments(&set, `
instrument violin
family strings
range G3 G7
wave saw
envelope 0.03 0.1 0.85 0.08
tone 0.55
gain 0.55
end

instrument viola
based_on violin
name "Viola"
tone 0.42
end
`)
	violin, _ := instrument_find(&set, "violin")
	viola, ok := instrument_find(&set, "viola")
	testing.expect(t, ok, "the second block was read")
	testing.expect_value(t, viola.name, "Viola")
	testing.expect_value(t, viola.tone, f32(0.42)) // its own
	testing.expect_value(t, viola.wave, Wave.Saw)  // the violin's
	testing.expect_value(t, viola.gain, violin.gain)
	testing.expect_value(t, viola.attack, violin.attack)
	testing.expect_value(t, violin.tone, f32(0.55)) // and the violin is untouched
}

@(test)
a_later_block_edits_the_one_already_there :: proc(t: ^testing.T) {
	// This is how a game drops one file into assets/instruments/ and darkens
	// the violin without copying the rest of the orchestra.
	set: Instrument_Set
	defer instrument_set_destroy(&set)
	parse_instruments(&set, "instrument violin\nwave saw\ntone 0.55\ngain 0.55\nend\n")
	parse_instruments(&set, "instrument violin\ngain 0.2\nend\n")

	ins, _ := instrument_find(&set, "violin")
	testing.expect_value(t, ins.gain, f32(0.2))
	testing.expect_value(t, ins.tone, f32(0.55))
	testing.expect_value(t, ins.wave, Wave.Saw)
	testing.expect_value(t, len(set.list), 1) // replaced in place, not added
}

@(test)
an_instrument_survives_being_written_out :: proc(t: ^testing.T) {
	set: Instrument_Set
	defer instrument_set_destroy(&set)
	parse_instruments(&set, `
instrument bell
name "Bell"
family classic
range C2 C8
wave sine
layer sine 0.2 12
envelope 0.0025 2.1 0 0.05
tone 0.9
gain 1
color 230 230 255
end
`)
	first, _ := instrument_find(&set, "bell")
	text := instrument_text(first)

	back: Instrument_Set
	defer instrument_set_destroy(&back)
	parse_instruments(&back, text)
	second, ok := instrument_find(&back, "bell")
	testing.expect(t, ok, "it came back")
	testing.expect_value(t, second.name, first.name)
	testing.expect_value(t, second.wave, first.wave)
	testing.expect_value(t, second.wave2, first.wave2)
	testing.expect_value(t, second.mix2, first.mix2)
	testing.expect_value(t, second.semis2, first.semis2)
	testing.expect_value(t, second.decay, first.decay)
	testing.expect_value(t, second.sustain, first.sustain)
	testing.expect_value(t, second.lo, first.lo)
	testing.expect_value(t, second.hi, first.hi)
	testing.expect_value(t, second.color, first.color)
}

@(test)
a_song_carries_its_own_instruments :: proc(t: ^testing.T) {
	// The shared orchestra...
	shared: Instrument_Set
	defer instrument_set_destroy(&shared)
	parse_instruments(&shared, "instrument cello\nwave saw\ntone 0.32\ngain 0.6\nend\n")

	// ...and a song that starts from one of its instruments and darkens it.
	song, ok := parse_song(`
song test
bpm 120
steps 4
instrument dark_cello
based_on cello
tone 0.1
end
track a dark_cello vol=0.8
C3 - - -
`, &shared)
	defer song_destroy(&song)
	testing.expect(t, ok, "the song parsed")
	testing.expect_value(t, len(song.tracks), 1)
	testing.expect_value(t, song.tracks[0].inst, "dark_cello")

	mine, found := instrument_find(&song.own, "dark_cello")
	testing.expect(t, found, "the song's own instrument is there")
	testing.expect_value(t, mine.tone, f32(0.1))  // its own
	testing.expect_value(t, mine.gain, f32(0.6))  // inherited across the file boundary
	testing.expect_value(t, mine.wave, Wave.Saw)

	// The instrument block's lines must not be mistaken for a row of notes:
	// the track holds exactly the one note the grid row wrote, four cells long.
	testing.expect_value(t, len(song.tracks[0].notes), 1)
	testing.expect_value(t, pitch_midi(song.tracks[0].notes[0].pitch), parse_note("C3"))
	testing.expect_value(t, song.tracks[0].notes[0].len, 4 * i32(TPQ / 4))
}

@(test)
two_instruments_really_do_sound_different :: proc(t: ^testing.T) {
	set: Instrument_Set
	defer instrument_set_destroy(&set)
	parse_instruments(&set, `
instrument soft
wave sine
envelope 0.005 0.1 0.9 0.05
tone 1
gain 1
end
instrument buzzy
wave saw
envelope 0.005 0.1 0.9 0.05
tone 1
gain 1
end
instrument struck
wave sine
envelope 0.001 0.1 0 0.02
tone 1
gain 1
end
`)
	// Brightness is harmonics, not zero crossings — a saw and a sine both
	// cross twice a cycle. A saw is the fundamental plus EVERY harmonic
	// above it, at 1/n each; a sine has none at all. So listen at the 5th.
	A3 :: 220
	measure :: proc(set: ^Instrument_Set, key: string) -> (fifth, late: f32) {
		ins := instrument_get(set, key)
		s := render_note(&ins, parse_note("A3"), 1).samples
		defer delete(s)
		fifth = goertzel(s, 5 * A3) / goertzel(s, A3)
		for i in SAMPLE_RATE * 2 / 5 ..< len(s) do late = max(late, abs(s[i]))
		return
	}
	sine_fifth, sine_late := measure(&set, "soft")
	saw_fifth, _ := measure(&set, "buzzy")
	_, struck_late := measure(&set, "struck")

	// A saw's 5th harmonic is a fifth of its fundamental; a sine's is noise.
	testing.expectf(t, saw_fifth > 0.1, "a saw has harmonics: 5th is %v of the fundamental", saw_fifth)
	testing.expectf(t, sine_fifth < 0.01, "a sine has none: 5th is %v", sine_fifth)
	testing.expect(t, sine_late > 0.1, "a held note is still sounding at 0.4s")
	testing.expect(t, struck_late < sine_late / 4, "a struck one has died away")
}

@(test)
a_band_limited_saw_does_not_alias :: proc(t: ^testing.T) {
	// A saw is the fundamental plus every harmonic above it. At 22 kHz the
	// harmonics above 11 kHz have nowhere to go, so a naive saw folds them
	// back down the spectrum as tones that have nothing to do with the note
	// and slide the wrong way when the tune goes up. PolyBLEP rounds the
	// corner off the jump, which is what takes those harmonics out.
	//
	// At 22050 Hz, 1760 (A6) has its 7th harmonic at 12320 Hz, over the
	// 11025 Hz limit, so it folds back to 22050 - 12320 = 9730 Hz — a tone
	// that is not a harmonic of the note at all. At any rate, the same note
	// relative to the rate does the same: so how much of the fold is there?
	set: Instrument_Set
	defer instrument_set_destroy(&set)
	parse_instruments(&set, "instrument lead\nwave saw\nenvelope 0.001 0.1 1 0.01\ntone 1\ngain 1\nend\n")
	ins := instrument_get(&set, "lead")

	f0 := f32(1760) * f32(SAMPLE_RATE) / 22050 // A6 at 22 kHz, A7 at 44.1
	folded := f32(SAMPLE_RATE) - 7 * f0
	ours := render_note(&ins, 0, 0.3).samples // the note number doesn't matter; we set the pitch below
	defer delete(ours)
	// Render both waves by hand at exactly f0, so the only difference between
	// them is the band-limiting.
	naive := make([]f32, len(ours))
	defer delete(naive)
	limited := make([]f32, len(ours))
	defer delete(limited)
	dt := f0 / f32(SAMPLE_RATE)
	ph: f32
	for i in 0 ..< len(ours) {
		naive[i] = 2 * ph - 1
		limited[i] = osc_for_test(ph, dt)
		ph = ph + dt
		for ph >= 1 do ph -= 1
	}

	fold := goertzel(limited, folded) / goertzel(limited, f0)
	raw := goertzel(naive, folded) / goertzel(naive, f0)
	testing.expectf(t, fold < raw / 2,
		"band-limiting quietens the folded-back tone: %v of the fundamental, against %v raw", fold, raw)
	testing.expectf(t, fold < 0.1, "and what is left is well under the note: %v", fold)
}

// How much of one frequency is in a signal: Goertzel's algorithm, which is a
// single-bin discrete Fourier transform and about eight lines long.
@(private = "file")
goertzel :: proc(s: []f32, freq: f32) -> f32 {
	w := 2 * math.PI * freq / f32(SAMPLE_RATE)
	coeff := 2 * math.cos(w)
	s1, s2: f32
	for v in s {
		s0 := v + coeff * s1 - s2
		s2, s1 = s1, s0
	}
	return math.sqrt(s1 * s1 + s2 * s2 - coeff * s1 * s2) / f32(len(s))
}

@(test)
the_shipped_instrument_files_load :: proc(t: ^testing.T) {
	// Run from the repo root, so nengine/instruments is where it is.
	set: Instrument_Set
	defer instrument_set_destroy(&set)
	n := instruments_load(&set)
	if n == 0 {
		testing.expect(t, true, "no instruments folder from here; nothing to check")
		return
	}
	// Every .song written before instruments were files names one of these.
	for key in ([?]string{"sine", "square", "saw", "bell", "noise", "piano",
		"organ", "strings", "flute", "pluck", "marimba"}) {
		_, ok := instrument_find(&set, key)
		testing.expectf(t, ok, "the classic voice %v is still a real instrument", key)
	}
	for &ins in set.list {
		testing.expectf(t, ins.lo < ins.hi, "%v has a range the right way round", ins.key)
		testing.expectf(t, ins.gain > 0, "%v can be heard", ins.key)
		testing.expectf(t, ins.tone > 0, "%v is not filtered into silence", ins.key)
	}
}
