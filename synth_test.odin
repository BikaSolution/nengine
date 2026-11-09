package nengine

import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"

// The synth's own tests: the mix bus, the room, the stereo, the pluck, the
// noise, and the things a song can now say. Agents cannot hear, so every
// one of these is a measurement.

// A song rendered and folded to mono, for tests that only want to know how
// loud something is and when.
test_song_mono :: proc(s: ^Song, set: ^Instrument_Set = nil) -> []f32 {
	a := render_song(s, set)
	defer audio_destroy(&a)
	return audio_mono(a)
}

@(private = "file")
TEST_INSTRUMENTS :: `
instrument t_saw
wave saw
envelope 0.002 0.1 1 0.05
tone 1
gain 1
end
instrument t_sine
wave sine
envelope 0.005 0.1 1 0.05
tone 1
gain 1
end
instrument t_white
wave white
envelope 0.001 0.1 1 0.01
tone 1
gain 1
end
instrument t_nes
wave noise
envelope 0.001 0.1 1 0.01
tone 1
gain 1
end
instrument t_slow
wave saw
envelope 0.15 0.1 1 0.05
tone 1
gain 1
end
instrument t_bright
wave saw
envelope 0.002 0.1 1 0.05
filter 800 0.2
vel_tone 2
gain 1
end
`

@(private = "file")
test_set :: proc() -> Instrument_Set {
	set: Instrument_Set
	parse_instruments(&set, TEST_INSTRUMENTS)
	return set
}

@(private = "file")
energy :: proc(x: []f32) -> f64 {
	e: f64
	for v in x do e += f64(v) * f64(v)
	return e
}

// --- Level ---

// The meter is a meter: a full-scale 997 Hz sine in one channel reads
// -3.01 LUFS (BS.1770's own calibration), half scale 6 dB less, and the same
// in both channels 3 dB more.
@(test)
the_loudness_meter_reads_a_sine_correctly :: proc(t: ^testing.T) {
	n := SAMPLE_RATE * 3
	mono := make([]f32, n)
	defer delete(mono)
	stereo := make([]f32, 2 * n)
	defer delete(stereo)
	for i in 0 ..< n {
		v := 0.5 * math.sin(2 * math.PI * 997 * f32(i) / f32(SAMPLE_RATE))
		mono[i] = v
		stereo[2 * i], stereo[2 * i + 1] = v, v
	}
	m := loudness(mono, 1)
	s := loudness(stereo, 2)
	testing.expectf(t, abs(m - (-9.03)) < 0.15, "mono half-scale sine: %v LUFS", m)
	testing.expectf(t, abs(s - (-6.02)) < 0.15, "stereo: %v LUFS", s)
}

// Six saws an octave apart, all on one downbeat, as loud as asked: whatever
// the target, nothing comes out over the ceiling, and the loudness lands on
// the target within a decibel (here, in fact, within a tenth).
@(test)
the_limiter_never_clips_and_the_level_lands :: proc(t: ^testing.T) {
	set := test_set()
	defer instrument_set_destroy(&set)
	for target in ([?]f32{-23, -16, -9}) {
		s := song_new("loud", 100, 2)
		defer song_destroy(&s)
		s.level = target
		for k in 0 ..< 6 {
			song_add_track(&s, "t", "t_saw", 1)
			for bar in 0 ..< 2 {
				track_put(&s.tracks[k], Note{tick = i32(bar * 96), len = 40, pitch = pitch_from_midi(36 + 12 * (k % 4) + k, 0), vel = 127})
			}
		}
		a := render_song(&s, &set)
		defer audio_destroy(&a)
		ceiling := math.pow(10, DEFAULT_CEILING / 20)
		peak := audio_peak(a)
		testing.expectf(t, peak <= ceiling + 1e-6, "target %v: peak %v over the ceiling %v", target, peak, ceiling)
		got := loudness(a.samples, 2)
		testing.expectf(t, abs(got - target) <= 1, "target %v LUFS, got %v", target, got)
	}

	// And the limiter on its own, on spikes far over the line, between
	// samples as well as on them.
	x := make([]f32, SAMPLE_RATE)
	defer delete(x)
	for &v, i in x do v = 0.3 * math.sin(f32(i) * 0.05) + (4 if i % 5000 == 17 else 0)
	limit(x, 1, -1, false)
	ceiling := math.pow(10, f32(-1) / 20)
	worst: f32
	for i in 1 ..< len(x) - 2 {
		mid := (-x[i - 1] + 9 * x[i] + 9 * x[i + 1] - x[i + 2]) / 16
		worst = max(worst, abs(x[i]), abs(mid))
	}
	testing.expectf(t, worst <= ceiling * 1.0001, "limited, the worst peak is %v against %v", worst, ceiling)
}

// --- The room ---

@(test)
the_reverb_tail_is_finite :: proc(t: ^testing.T) {
	r := Reverb{size = 1, damp = 0.2, mix = 1, width = 1}
	tail := reverb_tail(r)
	testing.expectf(t, tail > 1 && tail < 20, "the biggest room dies in %v s", tail)
	n := int((tail + 1) * f32(SAMPLE_RATE))
	send := make([]f32, n)
	defer delete(send)
	send[0] = 1
	wet := reverb_render(send, r, false)
	defer delete(wet)
	peak: f32
	for v in wet {
		testing.expect(t, !math.is_nan(v) && !math.is_inf(v), "no NaN or infinity")
		peak = max(peak, abs(v))
	}
	late: f32
	for v in wet[2 * int(tail * f32(SAMPLE_RATE)):] do late = max(late, abs(v))
	testing.expectf(t, peak > 0, "the room answers")
	testing.expectf(t, late < peak * 0.001, "after its tail time it is 60 dB down: %v against %v", late, peak)

	// A piece in a room is long enough for the room to finish, and stops on silence.
	set := test_set()
	defer instrument_set_destroy(&set)
	s := song_new("hall", 120, 1)
	defer song_destroy(&s)
	s.loop = false
	s.reverb = {size = 0.9, damp = 0.3, mix = 0.5, width = 1}
	song_add_track(&s, "a", "t_saw", 0.5)
	track_put(&s.tracks[0], Note{tick = 0, len = 12, pitch = pitch_from_midi(60, 0), vel = 100})
	a := render_song(&s, &set)
	defer audio_destroy(&a)
	frames := audio_frames(a)
	testing.expectf(t, audio_seconds(a) >= reverb_tail(s.reverb), "the piece lasts %v s, the room %v", audio_seconds(a), reverb_tail(s.reverb))
	testing.expect_value(t, a.samples[len(a.samples) - 1], f32(0))
	last := energy(a.samples[2 * (frames - SAMPLE_RATE / 2):])
	testing.expectf(t, last < energy(a.samples) * 1e-5, "the last half second is all but silent: %v of %v", last, energy(a.samples))
}

// A loop's room wraps: the start hears the end's tail.
@(test)
a_loops_room_rings_into_its_start :: proc(t: ^testing.T) {
	set := test_set()
	defer instrument_set_destroy(&set)
	s := song_new("bed", 120, 1)
	defer song_destroy(&s)
	s.reverb = {size = 0.8, damp = 0.3, mix = 0.6, width = 1}
	song_add_track(&s, "a", "t_saw", 0.5)
	track_put(&s.tracks[0], Note{tick = 72, len = 12, pitch = pitch_from_midi(60, 0), vel = 100})
	a := render_song(&s, &set)
	defer audio_destroy(&a)
	testing.expect_value(t, audio_frames(a), 2 * SAMPLE_RATE)
	start := energy(a.samples[:2 * SAMPLE_RATE / 4])
	testing.expectf(t, start > 0, "the first quarter second has the room in it: %v", start)
}

// --- Stereo ---

@(test)
pan_places_the_sound :: proc(t: ^testing.T) {
	set := test_set()
	defer instrument_set_destroy(&set)
	side :: proc(set: ^Instrument_Set, pan: f32) -> (left, right: f64) {
		s := song_new("pan", 120, 1)
		defer song_destroy(&s)
		s.reverb = {}
		i := song_add_track(&s, "a", "t_sine", 0.5)
		s.tracks[i].pan = pan
		track_put(&s.tracks[i], Note{tick = 0, len = 48, pitch = pitch_from_midi(69, 0), vel = 100})
		a := render_song(&s, set)
		defer audio_destroy(&a)
		for k in 0 ..< audio_frames(a) {
			left += f64(a.samples[2 * k]) * f64(a.samples[2 * k])
			right += f64(a.samples[2 * k + 1]) * f64(a.samples[2 * k + 1])
		}
		return
	}
	l, r := side(&set, -1)
	testing.expectf(t, r < l * 1e-6, "hard left is left: %v / %v", l, r)
	l, r = side(&set, 0)
	testing.expectf(t, abs(l - r) < l * 1e-3, "centre is both: %v / %v", l, r)
	l, r = side(&set, 0.5)
	share := r / (l + r)
	want := math.pow(math.sin(f64(1.5) * math.PI / 4), 2)
	testing.expectf(t, abs(share - want) < 0.02, "half right puts %v of it right, want %v", share, want)
}

// --- The pluck ---

// Tuned to within 3 cents from C2 to C7. The loop alone, a whole number of
// samples long, was 30 cents flat by A5.
@(test)
a_plucked_string_is_in_tune :: proc(t: ^testing.T) {
	worst: f32
	worst_note := 0
	for note := 36; note <= 96; note += 5 {
		hz := midi_hz(f32(note))
		x := pluck_for_test(hz, 1.2)
		defer delete(x)
		got := strongest_near(x[SAMPLE_RATE / 20:], hz)
		cents := 1200 * math.log2(got / hz)
		if abs(cents) > abs(worst) do worst, worst_note = cents, note
	}
	testing.expectf(t, abs(worst) <= 3, "worst %v cents, at %v", worst, note_text(worst_note))
}

// The frequency near `hz` with the most energy, to a hundredth of a cent:
// a Hann-windowed single-bin DFT swept across 60 cents, then refined.
@(private = "file")
strongest_near :: proc(x: []f32, hz: f32) -> f32 {
	n := min(len(x), SAMPLE_RATE)
	power :: proc(x: []f32, n: int, f: f32) -> f64 {
		w := 2 * math.PI * f64(f) / f64(SAMPLE_RATE)
		re, im: f64
		for i in 0 ..< n {
			hann := 0.5 - 0.5 * math.cos(2 * math.PI * f64(i) / f64(n - 1))
			v := f64(x[i]) * hann
			re += v * math.cos(w * f64(i))
			im -= v * math.sin(w * f64(i))
		}
		return re * re + im * im
	}
	best := hz
	best_p := -1.0
	step := f32(1) // cents
	lo, hi := f32(-30), f32(30)
	for _ in 0 ..< 3 {
		for c := lo; c <= hi; c += step {
			f := hz * math.pow(2, c / 1200)
			if p := power(x, n, f); p > best_p do best, best_p = f, p
		}
		centre := 1200 * math.log2(best / hz)
		lo, hi, step = centre - 2 * step, centre + 2 * step, step / 10
	}
	return best
}

// --- Noise ---

// Every note's noise is its own, and a render is the same render every time.
@(test)
seeded_noise_differs_per_note_and_not_per_render :: proc(t: ^testing.T) {
	set := test_set()
	defer instrument_set_destroy(&set)
	for key in ([?]string{"t_white", "t_nes"}) {
		s := song_new("hiss", 120, 1)
		defer song_destroy(&s)
		s.reverb = {}
		s.level = LEVEL_NONE
		song_add_track(&s, "a", key, 0.5)
		track_put(&s.tracks[0], Note{tick = 0, len = 24, pitch = pitch_from_midi(84, 0), vel = 100})
		track_put(&s.tracks[0], Note{tick = 48, len = 24, pitch = pitch_from_midi(84, 0), vel = 100})
		one := test_song_mono(&s, &set)
		defer delete(one)
		two := test_song_mono(&s, &set)
		defer delete(two)
		same := true
		for v, i in one do if v != two[i] { same = false; break }
		testing.expectf(t, same, "%v renders the same twice", key)

		// The two notes, a beat apart, side by side: correlated, they are one noise.
		beat := SAMPLE_RATE / 2
		a := one[1000:][:beat / 2]
		b := one[SAMPLE_RATE + 1000:][:beat / 2]
		dot: f64
		for v, i in a do dot += f64(v) * f64(b[i])
		corr := dot / math.sqrt(energy(a) * energy(b))
		testing.expectf(t, abs(corr) < 0.2, "%v: two notes are two noises (correlation %v)", key, corr)
	}
}

// --- The loop trap ---

// A note past the end of a looping song does not make the song longer:
// the loop is its bars, the note is wrapped round, and it is said.
@(test)
a_loop_keeps_its_length :: proc(t: ^testing.T) {
	text := `song bed
tempo 120
bars 1
loop yes
track a inst=t_sine vol=0.5
note 0 24 A4
note 84 48 C5
note 120 12 E5
`
	s, ok := parse_song(text)
	defer song_destroy(&s)
	testing.expect(t, ok)
	testing.expect_value(t, s.bars, i32(1))
	testing.expect_value(t, len(s.warnings), 1)
	if len(s.warnings) == 1 do testing.expectf(t, strings.contains(s.warnings[0], "starts after the loop ends"), "%v", s.warnings[0])
	testing.expect_value(t, song_tails_wrapping(&s), 1)
	set := test_set()
	defer instrument_set_destroy(&set)
	a := render_song(&s, &set)
	defer audio_destroy(&a)
	testing.expect_value(t, audio_frames(a), 2 * SAMPLE_RATE)

	// A piece, though, still grows to hold what is in it.
	piece, _ := parse_song("song p\ntempo 120\nbars 1\nloop no\ntrack a inst=t_sine\nnote 120 12 E5\n")
	defer song_destroy(&piece)
	testing.expect_value(t, piece.bars, i32(2))
}

// --- Expression ---

// On a legato track a slurred note does not start again: the level never
// falls into the join the way a fresh attack's does.
@(test)
legato_slurs_without_a_new_attack :: proc(t: ^testing.T) {
	set := test_set()
	defer instrument_set_destroy(&set)
	join_dip :: proc(set: ^Instrument_Set, legato: bool) -> f32 {
		s := song_new("line", 120, 1)
		defer song_destroy(&s)
		s.reverb = {}
		s.level = LEVEL_NONE
		i := song_add_track(&s, "a", "t_slow", 0.5)
		s.tracks[i].legato = legato
		s.tracks[i].glide = 0.03
		track_put(&s.tracks[i], Note{tick = 0, len = 48, pitch = pitch_from_midi(69, 0), vel = 100})
		track_put(&s.tracks[i], Note{tick = 48, len = 48, pitch = pitch_from_midi(72, 0), vel = 100})
		x := test_song_mono(&s, set)
		defer delete(x)
		// One second in is the join. Its quietest 10 ms against the note before.
		before, at := f32(0), f32(1e9)
		win := SAMPLE_RATE / 100
		for k in 0 ..< 20 {
			from := SAMPLE_RATE / 2 + k * win
			e := f32(energy(x[from:][:win]))
			before = max(before, e)
		}
		for k in -2 ..< 6 {
			from := SAMPLE_RATE + k * win
			at = min(at, f32(energy(x[from:][:win])))
		}
		return at / before
	}
	slurred := join_dip(&set, true)
	struck := join_dip(&set, false)
	testing.expectf(t, slurred > 0.7, "slurred, the join keeps %v of the level", slurred)
	testing.expectf(t, struck < 0.3, "struck again, it dips to %v", struck)
}

// `tempo ... at=` changes the speed from that tick: a bar at 120 and a bar
// at 60 are two seconds and four.
@(test)
tempo_changes_move_time :: proc(t: ^testing.T) {
	s, _ := parse_song("song slow\ntempo 120\ntempo 60 at=96\nbars 2\ntrack a inst=t_sine\nnote 0 24 A4\n")
	defer song_destroy(&s)
	testing.expect_value(t, len(s.tempos), 1)
	testing.expectf(t, abs(song_seconds(&s) - 6) < 0.001, "%v seconds", song_seconds(&s))
	set := test_set()
	defer instrument_set_destroy(&set)
	a := render_song(&s, &set)
	defer audio_destroy(&a)
	testing.expect_value(t, audio_frames(a), 6 * SAMPLE_RATE)

	// A glide gets there gradually: between the two.
	g, _ := parse_song("song rit\ntempo 120\ntempo 60 at=96 glide=96\nbars 2\n")
	defer song_destroy(&g)
	testing.expectf(t, song_seconds(&g) > 4.5 && song_seconds(&g) < 6, "%v seconds", song_seconds(&g))
}

// A swell inside one note (vel_end) and a crescendo across a track (`vol`
// points) both get louder as they go.
@(test)
a_held_note_can_swell :: proc(t: ^testing.T) {
	set := test_set()
	defer instrument_set_destroy(&set)
	halves :: proc(s: ^Song, set: ^Instrument_Set) -> (first, second: f64) {
		x := test_song_mono(s, set)
		defer delete(x)
		h := len(x) / 2
		return energy(x[SAMPLE_RATE / 10:h]), energy(x[h:][:h - SAMPLE_RATE / 10])
	}
	s, _ := parse_song("song swell\ntempo 120\nbars 1\nlevel none\nreverb none\ntrack a inst=t_sine vol=0.5\nnote 0 96 A4 vel=20 vel_end=120\n")
	defer song_destroy(&s)
	a, b := halves(&s, &set)
	testing.expectf(t, b > 3 * a, "vel_end: %v then %v", a, b)

	c, _ := parse_song("song cresc\ntempo 120\nbars 1\nlevel none\nreverb none\ntrack a inst=t_sine vol=0.5\nvol 0 0.1\nvol 96 1\nnote 0 96 A4\n")
	defer song_destroy(&c)
	a, b = halves(&c, &set)
	testing.expectf(t, b > 4 * a, "vol points: %v then %v", a, b)
}

// --- The filter ---

// With vel_tone, a harder note is a brighter one, not just a louder one.
@(test)
velocity_opens_the_filter :: proc(t: ^testing.T) {
	set := test_set()
	defer instrument_set_destroy(&set)
	ins := instrument_get(&set, "t_bright")
	brightness :: proc(ins: ^Instrument, vel: f32) -> f32 {
		out := make([]f32, SAMPLE_RATE / 2)
		defer delete(out)
		seg := [1]Voice_Seg{{note = 57, len = 0.4, vel = vel, vel_end = vel, amp = 1, amp_end = 1}}
		render_voice(out, 0, ins, seg[:], 0.4, {seed = 1})
		return harmonic(out[SAMPLE_RATE / 10:], 8 * 220) / harmonic(out[SAMPLE_RATE / 10:], 220)
	}
	soft := brightness(&ins, 40)
	hard := brightness(&ins, 127)
	testing.expectf(t, hard > 2 * soft, "the 8th harmonic: %v hard, %v soft", hard, soft)
}

// A clean triangle has far less top than the NES's staircase.
@(test)
the_triangle_is_clean_and_the_nes_one_is_kept :: proc(t: ^testing.T) {
	top :: proc(w: Wave) -> f32 {
		ins := DEFAULT_INSTRUMENT
		ins.wave = w
		ins.tone = 1
		out := make([]f32, SAMPLE_RATE / 2)
		defer delete(out)
		seg := [1]Voice_Seg{{note = 45, len = 0.4, vel = 100, vel_end = 100, amp = 1, amp_end = 1}}
		render_voice(out, 0, &ins, seg[:], 0.4, {seed = 1})
		// 110 Hz: its 31st harmonic, which a triangle has at 1/961 and a
		// 16-step staircase has a good deal more of.
		return harmonic(out[SAMPLE_RATE / 10:], 31 * 110) / harmonic(out[SAMPLE_RATE / 10:], 110)
	}
	clean := top(.Triangle)
	nes := top(.NES_Triangle)
	testing.expectf(t, clean < 0.003, "clean: %v", clean)
	testing.expectf(t, nes > 3 * clean, "nes: %v against %v", nes, clean)
}

@(private = "file")
harmonic :: proc(s: []f32, freq: f32) -> f32 {
	w := 2 * math.PI * freq / f32(SAMPLE_RATE)
	coeff := 2 * math.cos(w)
	s1, s2: f32
	for v in s {
		s0 := v + coeff * s1 - s2
		s2, s1 = s1, s0
	}
	return math.sqrt(max(s1 * s1 + s2 * s2 - coeff * s1 * s2, 0)) / f32(len(s))
}

// Everything new a song and an instrument can say survives being written
// out and read back.
@(test)
the_new_words_survive_a_round_trip :: proc(t: ^testing.T) {
	text := `song rt
tempo 90
tempo 70 at=192 glide=48
bars 4
level -18
ceiling -2
reverb 0.7 0.3 0.4 0.02 0.8
instrument mine
wave triangle
layer sine 0.3 12
layer3 white 0.1 0
envelope 0.01 0.5 0.6 0.3
layer_envelope 0.001 0.2 0 0.1
filter 1200 0.4
keytrack 0.5
filter_env 0.02 0.4 1.5
vel_tone 1
highpass 200
click 0.3 0.02 0.5
string 0.4 0.8
end
track a inst=mine vol=0.4 pan=-0.25 rev=0.3 legato=1 glide=0.05
vol 0 0.5
vol 96 1
note 0 48 A4 vel=60 vel_end=110
`
	s, _ := parse_song(text)
	defer song_destroy(&s)
	back, _ := parse_song(song_text(&s))
	defer song_destroy(&back)
	testing.expect_value(t, back.level, f32(-18))
	testing.expect_value(t, back.ceiling, f32(-2))
	testing.expect_value(t, back.reverb, Reverb{0.7, 0.3, 0.4, 0.02, 0.8})
	testing.expect_value(t, len(back.tempos), 1)
	if len(back.tempos) == 1 do testing.expect_value(t, back.tempos[0], Tempo_Change{192, 70, 48})
	tr := back.tracks[0]
	testing.expect_value(t, tr.pan, f32(-0.25))
	testing.expect_value(t, tr.rev, f32(0.3))
	testing.expect(t, tr.legato)
	testing.expect_value(t, tr.glide, f32(0.05))
	testing.expect_value(t, len(tr.vols), 2)
	testing.expect_value(t, tr.notes[0].vel_end, u8(110))
	ins, found := instrument_find(&back.own, "mine")
	testing.expect(t, found)
	if found {
		testing.expect_value(t, ins.wave, Wave.Triangle)
		testing.expect_value(t, ins.wave3, Wave.White)
		testing.expect_value(t, ins.mix3, f32(0.1))
		testing.expect(t, ins.has_env2)
		testing.expect_value(t, ins.env2.decay, f32(0.2))
		testing.expect_value(t, ins.filter_hz, f32(1200))
		testing.expect_value(t, ins.resonance, f32(0.4))
		testing.expect_value(t, ins.keytrack, f32(0.5))
		testing.expect_value(t, ins.fenv, [3]f32{0.02, 0.4, 1.5})
		testing.expect_value(t, ins.vel_tone, f32(1))
		testing.expect_value(t, ins.highpass, f32(200))
		testing.expect_value(t, ins.click, [3]f32{0.3, 0.02, 0.5})
		testing.expect_value(t, ins.string_damp, f32(0.4))
		testing.expect_value(t, ins.string_bright, f32(0.8))
	}
	// A song that says nothing new writes nothing new.
	plain, _ := parse_song("song p\ntempo 100\nbars 1\ntrack a inst=sine vol=0.3\nnote 0 24 A4\n")
	defer song_destroy(&plain)
	out := song_text(&plain)
	for word in ([?]string{"level", "reverb", "ceiling", "rev=", "legato", "vel_end"}) {
		testing.expectf(t, !strings.contains(out, word), "%v written for a song that never said it:\n%v", word, out)
	}
	// And the room can be taken away.
	dry, _ := parse_song("song d\nreverb none\nlevel none\n")
	defer song_destroy(&dry)
	testing.expect_value(t, dry.reverb.mix, f32(0))
	testing.expect_value(t, dry.level, LEVEL_NONE)
	testing.expect(t, strings.contains(song_text(&dry), "reverb none"))
}

// A .sound with a room and a level: dry and peak-normalised unless it says.
// And at the rate it was designed at, 22050, unless it says `rate`.
@(test)
a_sound_can_have_a_room_and_a_level :: proc(t: ^testing.T) {
	s := sound_new("knock", 1.5)
	defer sound_destroy(&s)
	append(&s.layers, Sound_Layer{wave = .Noise, dur = 0.03, decay = 80, lp = 0.3, lp_to = 0.3, vol = 1, trem_pow = 1, n_partials = 1, partials = {0 = 1}})
	dry := render_sound(&s)
	defer audio_destroy(&dry)
	testing.expect_value(t, dry.channels, 1)
	testing.expect_value(t, dry.rate, SOUND_RATE)
	late := energy(dry.samples[dry.rate / 2:])
	testing.expectf(t, late < 1e-9, "dry, it is over in half a second: %v", late)

	s.reverb = {size = 0.7, damp = 0.4, mix = 0.5, width = 1}
	s.level = -20
	wet := render_sound(&s)
	defer audio_destroy(&wet)
	testing.expectf(t, energy(wet.samples[wet.rate / 2:]) > 1e-4, "in a room it rings on")
	got := loudness(wet.samples, 1, wet.rate)
	testing.expectf(t, abs(got - (-20)) <= 1, "level -20, got %v", got)

	// At 44.1 kHz: twice the samples, and the same filtered hiss, as loud.
	s.reverb, s.level, s.norm = {}, LEVEL_NONE, 0
	s.rate = 44100
	full := render_sound(&s)
	defer audio_destroy(&full)
	testing.expect_value(t, len(full.samples), 2 * len(dry.samples))
	s.rate = SOUND_RATE
	again := render_sound(&s)
	defer audio_destroy(&again)
	a := loudness(again.samples, 1, again.rate)
	b := loudness(full.samples, 1, full.rate)
	testing.expectf(t, abs(a - b) < 1, "the same hiss at both rates: %v and %v LUFS", a, b)
}

// --- Round two: what the composers asked for ---

@(private = "file")
TEST_INSTRUMENTS_2 :: `
instrument t_bell
wave sine
envelope 0.002 0.5 0 0.05
tone 1
gain 1
end
instrument t_vibes
wave sine
envelope 0.002 1 1 0.05
tremolo 5 6
tone 1
gain 1
end
instrument t_pluck
wave string
envelope 0.001 2 0 0.1
tone 1
gain 1
end
instrument t_amp
wave sine
envelope 0.002 0.1 1 0.05
drive 0.8
tone 1
gain 1
end
`

@(private = "file")
test_set2 :: proc() -> Instrument_Set {
	set: Instrument_Set
	parse_instruments(&set, TEST_INSTRUMENTS)
	parse_instruments(&set, TEST_INSTRUMENTS_2)
	return set
}

// A song from text, rendered and folded to mono.
@(private = "file")
render_text :: proc(text: string, set: ^Instrument_Set) -> []f32 {
	s, _ := parse_song(text, set)
	defer song_destroy(&s)
	return test_song_mono(&s, set)
}

// A dry piece at 120 (a tick is 1/48 s, a quarter half a second), unlevelled.
@(private = "file")
DRY :: "song t\ntempo 120\nbars 2\nloop no\nlevel none\nreverb none\n"

@(private = "file")
secs_at :: proc(x: []f32, from, length: f32) -> []f32 {
	a := min(int(from * f32(SAMPLE_RATE)), len(x))
	b := min(a + int(length * f32(SAMPLE_RATE)), len(x))
	return x[a:b]
}

@(private = "file")
db :: proc(a, b: f64) -> f64 {
	return 10 * math.log10(max(a, 1e-30) / max(b, 1e-30))
}

// A sine's frequency, from its upward zero crossings.
@(private = "file")
crossing_hz :: proc(x: []f32) -> f32 {
	first, last, n := -1, -1, 0
	for i in 1 ..< len(x) {
		if x[i - 1] < 0 && x[i] >= 0 {
			if first < 0 do first = i
			last = i
			n += 1
		}
	}
	if n < 2 do return 0
	return f32(n - 1) * f32(SAMPLE_RATE) / f32(last - first)
}

// Damping. A struck note no longer stops dead 40 dB down when its decay is
// up: it falls on until it is inaudible. A damper (`damp`) ends it that many
// seconds after its written length; a note can say its own, or `damp=off`.
@(test)
a_struck_note_rings_out_and_a_damper_stops_it :: proc(t: ^testing.T) {
	set := test_set2()
	defer instrument_set_destroy(&set)
	ins := instrument_get(&set, "t_bell")
	strike :: proc(ins: ^Instrument, damp: f32) -> []f32 {
		out := make([]f32, 2 * SAMPLE_RATE)
		seg := [1]Voice_Seg{{note = 69, len = 0.05, vel = 100, vel_end = 100, amp = 1, amp_end = 1}}
		render_voice(out, 0, ins, seg[:], 0.05, {seed = 3, damp = damp})
		return out
	}
	ring := strike(&ins, 0)
	defer delete(ring)
	testing.expectf(t, energy(secs_at(ring, 0.6, 0.1)) > 0, "it rings on past its decay (0.5 s), where it used to stop")
	peak: f32
	last := 0
	for v, i in ring {
		peak = max(peak, abs(v))
		if v != 0 do last = i
	}
	testing.expectf(t, abs(ring[last]) < peak * 1e-4, "it ends inaudible: its last sample is %v of its peak", abs(ring[last]) / peak)

	damped := strike(&ins, 0.1)
	defer delete(damped)
	// 0.1 s after its written end it is 60 dB under where it would have rung.
	down := db(energy(secs_at(damped, 0.15, 0.005)), energy(secs_at(ring, 0.15, 0.005)))
	testing.expectf(t, down < -55 && down > -66, "damped, 0.1 s after its end it is %v dB down", down)
	testing.expectf(t, energy(secs_at(damped, 0.3, 1)) < 1e-12, "and soon silent")
	testing.expectf(t, abs(energy(secs_at(damped, 0.01, 0.03)) - energy(secs_at(ring, 0.01, 0.03))) < 1e-6 * energy(secs_at(ring, 0.01, 0.03)) + 1e-12,
		"while it is held, the damper does nothing")

	// In a song: the instrument's damper, a note's own, and a note's `damp=off`.
	song := DRY + `instrument t_damped
wave sine
envelope 0.002 0.5 0 0.05
damp 0.05
gain 1
end
track a inst=t_damped vol=0.5
note 0 6 A4
note 48 6 A4 damp=off
`
	x := render_text(song, &set)
	defer delete(x)
	gone := energy(secs_at(x, 0.35, 0.1))
	rings := energy(secs_at(x, 1.35, 0.1))
	testing.expectf(t, gone < rings * 1e-6, "the damped note is gone (%v), the undamped one rings (%v)", gone, rings)
}

// Tremolo dips by its depth at its rate, on the song's clock: a note that
// starts later is in step with one that started earlier, as two bars of one
// vibraphone share its motor.
@(test)
tremolo_runs_on_the_songs_clock :: proc(t: ^testing.T) {
	set := test_set2()
	defer instrument_set_destroy(&set)
	ins := instrument_get(&set, "t_vibes")
	levels :: proc(ins: ^Instrument, t0: f64) -> []f64 {
		out := make([]f32, 2 * SAMPLE_RATE)
		defer delete(out)
		seg := [1]Voice_Seg{{note = 69, len = 2, vel = 100, vel_end = 100, amp = 1, amp_end = 1}}
		render_voice(out, 0, ins, seg[:], 2, {seed = 5, t0 = t0})
		w := SAMPLE_RATE / 100
		lv := make([]f64, len(out) / w)
		for &v, k in lv do v = math.sqrt(energy(out[k * w:][:w]) / f64(w))
		return lv
	}
	a := levels(&ins, 0)
	defer delete(a)
	hi, lo: f64 = 0, 1e9
	dips := 0
	for k in 20 ..< 180 {
		hi, lo = max(hi, a[k]), min(lo, a[k])
		least := true
		for d in -5 ..= 5 do if d != 0 && a[k + d] < a[k] do least = false
		if least do dips += 1
	}
	depth := 20 * math.log10(hi / lo)
	testing.expectf(t, abs(depth - 6) < 0.8, "6 dB asked, %v dB deep", depth)
	testing.expectf(t, dips >= 7 && dips <= 9, "5 Hz over 1.6 s: %v dips", dips)
	b := levels(&ins, 0.1)
	defer delete(b)
	worst: f64
	for k in 20 ..< 170 do worst = max(worst, abs(20 * math.log10(b[k] / a[k + 10])))
	testing.expectf(t, worst < 0.3, "a note 0.1 s later is in step with the motor: %v dB off", worst)
}

// FM: a sine at index 0, partials in as the index rises (at c +/- n m, so
// an odd ratio is inharmonic), its own envelope, velocity and key scaling,
// the OPL's waves and feedback, and an index held back where it would alias.
@(test)
an_fm_pair_puts_partials_in :: proc(t: ^testing.T) {
	ins := DEFAULT_INSTRUMENT
	ins.wave = .FM
	ins.fm_ratio, ins.fm_index = 1, 0
	ins.sustain = 1
	part :: proc(x: []f32, f, k: f32) -> f32 {
		y := x[SAMPLE_RATE / 10:]
		return harmonic(y, k * f) / harmonic(y, f)
	}
	pure := fm_for_test(&ins, 57, 0.5)
	defer delete(pure)
	testing.expectf(t, part(pure, 220, 2) < 0.01, "index 0 is a sine: %v", part(pure, 220, 2))
	ins.fm_index = 2
	rich := fm_for_test(&ins, 57, 0.5)
	defer delete(rich)
	testing.expectf(t, part(rich, 220, 2) > 0.2 && part(rich, 220, 3) > 0.05, "index 2: %v, %v", part(rich, 220, 2), part(rich, 220, 3))

	ins.fm_ratio, ins.fm_index = 3.5, 1.5
	bell := fm_for_test(&ins, 57, 0.5)
	defer delete(bell)
	testing.expectf(t, part(bell, 220, 2.5) > 0.3 && part(bell, 220, 4.5) > 0.3, "1:3.5 has 2.5x and 4.5x: %v %v", part(bell, 220, 2.5), part(bell, 220, 4.5))

	// At C7, ratio 2, an index of 12 would reach 54 kHz; it is held to the
	// index that stays under 18 kHz, so the two render the same.
	ins.fm_ratio, ins.fm_index = 2, 12
	wild := fm_for_test(&ins, 96, 0.2)
	defer delete(wild)
	ins.fm_index = 18000 / (2 * midi_hz(96)) - 1
	held := fm_for_test(&ins, 96, 0.2)
	defer delete(held)
	same: f32
	for v, i in wild do same = max(same, abs(v - held[i]))
	testing.expectf(t, same < 1e-4, "the index is clamped: %v apart", same)

	// The index's own envelope: bright at the strike, a sine by the end.
	ins.fm_ratio, ins.fm_index = 1, 4
	ins.has_fm_env, ins.fm_env = true, Env{0.001, 0.1, 0, 0.05}
	struck := fm_for_test(&ins, 57, 1)
	defer delete(struck)
	early := harmonic(secs_at(struck, 0.005, 0.05), 440) / harmonic(secs_at(struck, 0.005, 0.05), 220)
	late := harmonic(secs_at(struck, 0.6, 0.3), 440) / harmonic(secs_at(struck, 0.6, 0.3), 220)
	testing.expectf(t, early > 10 * late, "fm_envelope: %v at the strike, %v later", early, late)
	ins.has_fm_env = false

	// Velocity and key scaling.
	ins.fm_index, ins.vel_index = 1.5, 1
	soft := fm_for_test(&ins, 57, 0.5, 40)
	defer delete(soft)
	hard := fm_for_test(&ins, 57, 0.5, 127)
	defer delete(hard)
	testing.expectf(t, part(hard, 220, 2) > 1.5 * part(soft, 220, 2), "vel_index: %v hard, %v soft", part(hard, 220, 2), part(soft, 220, 2))
	ins.vel_index = 0
	open := fm_for_test(&ins, 81, 0.5)
	defer delete(open)
	ins.fm_keyscale = 1
	scaled := fm_for_test(&ins, 81, 0.5)
	defer delete(scaled)
	ins.fm_keyscale = 0
	testing.expectf(t, part(scaled, 880, 2) < 0.7 * part(open, 880, 2), "fm_keyscale: %v against %v", part(scaled, 880, 2), part(open, 880, 2))

	// Feedback thickens the modulator; a half-sine carrier is rich in even
	// harmonics and still centred.
	ins.fm_index = 1
	plain := fm_for_test(&ins, 57, 0.5)
	defer delete(plain)
	ins.fm_fb = 0.6
	fed := fm_for_test(&ins, 57, 0.5)
	defer delete(fed)
	testing.expectf(t, part(fed, 220, 5) > 2 * part(plain, 220, 5), "fm_feedback: %v against %v", part(fed, 220, 5), part(plain, 220, 5))
	ins.fm_fb, ins.fm_index = 0, 0
	ins.fm_wave = {.Sine, .Half}
	half := fm_for_test(&ins, 57, 1)
	defer delete(half)
	mean, sq: f64
	tail := secs_at(half, 0.5, 0.4)
	for v in tail { mean += f64(v); sq += f64(v) * f64(v) }
	mean /= f64(len(tail))
	testing.expectf(t, part(half, 220, 2) > 0.1, "a half-sine has its 2nd harmonic: %v", part(half, 220, 2))
	testing.expectf(t, abs(mean) < 0.02 * math.sqrt(sq / f64(len(tail))), "and no offset: %v", mean)
}

// The second room hears only what is sent to it.
@(test)
a_second_room_takes_only_what_is_sent :: proc(t: ^testing.T) {
	set := test_set2()
	defer instrument_set_destroy(&set)
	BASE :: DRY + "reverb2 plate\n"
	sent := render_text(BASE + "track a inst=t_sine vol=0.5 rev2=1\nnote 0 12 A4\n", &set)
	defer delete(sent)
	dry := render_text(BASE + "track a inst=t_sine vol=0.5\nnote 0 12 A4\n", &set)
	defer delete(dry)
	testing.expectf(t, energy(secs_at(sent, 0.6, 1)) > 1e-4, "sent, the plate rings after the note")
	testing.expectf(t, energy(secs_at(dry, 0.6, 1)) < 1e-9, "not sent, nothing does")
	testing.expectf(t, f32(len(sent)) / f32(SAMPLE_RATE) >= 0.3 + reverb_tail(room_preset(.Plate), .Plate), "the piece holds the plate's tail")
	plate := reverb_tail(room_preset(.Plate), .Plate)
	hall := reverb_tail(room_preset(.Hall), .Hall)
	testing.expectf(t, plate > 1 && hall > plate, "a plate (%v s) is shorter than a hall (%v s)", plate, hall)
}

// A note can scoop into its pitch and bend away from it; a plucked string
// does both and keeps ringing, in tune where it lands.
@(test)
a_note_can_slide_and_bend :: proc(t: ^testing.T) {
	set := test_set2()
	defer instrument_set_destroy(&set)
	x := render_text(DRY + "track a inst=t_sine vol=0.5\nnote 0 96 A4 slide_from=-12@24 bend=12@24 bend_at=48\n", &set)
	defer delete(x)
	start := crossing_hz(secs_at(x, 0, 0.05))
	mid := crossing_hz(secs_at(x, 0.6, 0.3))
	end := crossing_hz(secs_at(x, 1.6, 0.3))
	testing.expectf(t, start > 205 && start < 250, "it starts an octave down: %v Hz", start)
	testing.expectf(t, abs(mid - 440) < 3, "is home by half a second: %v Hz", mid)
	testing.expectf(t, abs(end - 880) < 5, "and bends up an octave after: %v Hz", end)

	y := render_text(DRY + "track a inst=t_pluck vol=0.5\nnote 0 96 A3 slide_from=-2@12\n", &set)
	defer delete(y)
	got := strongest_near(secs_at(y, 0.5, 1), 220)
	cents := 1200 * math.log2(got / 220)
	testing.expectf(t, abs(cents) < 6, "the string lands on A3: %v cents", cents)
	testing.expectf(t, energy(secs_at(y, 0.5, 0.5)) > 1e-4, "still ringing")
}

// A mono track is one voice: a new note stops the last, held or struck.
@(test)
a_mono_track_is_one_voice :: proc(t: ^testing.T) {
	set := test_set2()
	defer instrument_set_destroy(&set)
	for key in ([?]string{"t_sine", "t_gong"}) {
		BODY :: "instrument t_gong\nwave sine\nenvelope 0.002 4 0 0.05\ngain 1\nend\ntrack a inst=%v vol=0.5%v\nnote 0 96 A4\nnote 24 48 E5\n"
		poly := render_text(fmt.tprintf(DRY + BODY, key, ""), &set)
		defer delete(poly)
		mono := render_text(fmt.tprintf(DRY + BODY, key, " mono=1"), &set)
		defer delete(mono)
		a := harmonic(secs_at(poly, 0.55, 0.3), 440)
		b := harmonic(secs_at(mono, 0.55, 0.3), 440)
		testing.expectf(t, b < 0.01 * a, "%v: the first note is stopped (%v against %v)", key, b, a)
		testing.expectf(t, harmonic(secs_at(mono, 0.55, 0.3), midi_hz(76)) > 0.1 * a, "%v: and the second plays", key)
	}
}

// `level -19 short` puts the loudest 3 s at -19, whatever the rest is.
@(test)
level_short_measures_the_loudest_three_seconds :: proc(t: ^testing.T) {
	set := test_set2()
	defer instrument_set_destroy(&set)
	s, _ := parse_song("song sparse\ntempo 120\nbars 8\nloop no\nreverb none\nlevel -19 short\ntrack a inst=t_sine vol=0.5\nnote 0 48 A4\nnote 600 24 A4 vel=30\n", &set)
	defer song_destroy(&s)
	testing.expect(t, s.level_short)
	a := render_song(&s, &set)
	defer audio_destroy(&a)
	got := loudness_short_max(a.samples, 2)
	testing.expectf(t, abs(got + 19) < 0.3, "the loudest 3 s: %v LUFS", got)
	// Integrated, it would read louder: its gate hears only the note.
	whole := loudness(a.samples, 2)
	testing.expectf(t, whole > got + 1, "integrated: %v", whole)

	// And on a steady tone the two meters agree.
	n := SAMPLE_RATE * 6
	x := make([]f32, n)
	defer delete(x)
	for &v, i in x do v = 0.5 * math.sin(2 * math.PI * 997 * f32(i) / f32(SAMPLE_RATE))
	testing.expectf(t, abs(loudness_short_max(x, 1) - loudness(x, 1)) < 0.1, "steady: %v and %v", loudness_short_max(x, 1), loudness(x, 1))
}

// A track's own low-pass, high-pass and peaks.
@(test)
a_track_can_be_filtered_and_peaked :: proc(t: ^testing.T) {
	set := test_set2()
	defer instrument_set_destroy(&set)
	level :: proc(set: ^Instrument_Set, pitch: string, extra: string, eq: string) -> f64 {
		x := render_text(fmt.tprintf(DRY + "track a inst=t_sine vol=0.3%v\n%vnote 0 48 %v\n", extra, eq, pitch), set)
		defer delete(x)
		return energy(secs_at(x, 0.2, 0.6))
	}
	lo, mid, top := level(&set, "A2", "", ""), level(&set, "B5", "", ""), level(&set, "A7", "", "")
	hp_lo, hp_top := db(level(&set, "A2", " hp=500", ""), lo), db(level(&set, "A7", " hp=500", ""), top)
	testing.expectf(t, hp_lo < -20 && abs(hp_top) < 0.5, "hp=500: 110 Hz %v dB, 3.5 kHz %v dB", hp_lo, hp_top)
	lp_lo, lp_top := db(level(&set, "A2", " lp=500", ""), lo), db(level(&set, "A7", " lp=500", ""), top)
	testing.expectf(t, lp_top < -25 && abs(lp_lo) < 0.5, "lp=500: 3.5 kHz %v dB, 110 Hz %v dB", lp_top, lp_lo)
	pk_mid := db(level(&set, "B5", "", "eq 987.77 12 2\n"), mid)
	pk_lo := db(level(&set, "A2", "", "eq 987.77 12 2\n"), lo)
	testing.expectf(t, abs(pk_mid - 12) < 0.5 && abs(pk_lo) < 0.5, "eq +12 dB at 988 Hz: %v there, %v at 110", pk_mid, pk_lo)
}

// Drive rounds the peaks into harmonics; none without it.
@(test)
drive_breaks_up_gently :: proc(t: ^testing.T) {
	set := test_set2()
	defer instrument_set_destroy(&set)
	third :: proc(set: ^Instrument_Set, key: string) -> f32 {
		x := render_text(fmt.tprintf(DRY + "track a inst=%v vol=0.3\nnote 0 48 A3 vel=127\n", key), set)
		defer delete(x)
		y := secs_at(x, 0.2, 0.6)
		return harmonic(y, 660) / harmonic(y, 220)
	}
	clean, driven := third(&set, "t_sine"), third(&set, "t_amp")
	testing.expectf(t, clean < 0.003 && driven > 0.03, "3rd harmonic: %v clean, %v driven", clean, driven)
}

// `nudge` moves a note by milliseconds, finer than a tick.
@(test)
a_note_can_be_nudged :: proc(t: ^testing.T) {
	set := test_set2()
	defer instrument_set_destroy(&set)
	onset :: proc(set: ^Instrument_Set, nudge: string) -> int {
		x := render_text(fmt.tprintf(DRY + "track a inst=t_sine vol=0.5\nnote 24 24 A4%v\n", nudge), set)
		defer delete(x)
		for v, i in x do if abs(v) > 1e-4 do return i
		return -1
	}
	at, late, early := onset(&set, ""), onset(&set, " nudge=10"), onset(&set, " nudge=-10")
	testing.expectf(t, abs(late - at - 441) <= 3 && abs(at - early - 441) <= 3, "10 ms is 441 samples: %v, %v, %v", early, at, late)
}

// A tape echo repeats at its time (or a fraction of a bar), each repeat
// `feedback` of the last.
@(test)
a_track_can_have_a_tape_echo :: proc(t: ^testing.T) {
	set := test_set2()
	defer instrument_set_destroy(&set)
	x := render_text(DRY + "track a inst=t_sine vol=0.5\necho 250 0.5 0.5\nnote 0 2 A4\n", &set)
	defer delete(x)
	first := energy(secs_at(x, 0, 0.05))
	one := db(energy(secs_at(x, 0.25, 0.05)), first)
	two := db(energy(secs_at(x, 0.5, 0.05)), first)
	testing.expectf(t, abs(one + 6) < 1.5, "the first repeat at mix 0.5: %v dB", one)
	testing.expectf(t, abs(two + 12) < 2, "the second, half that again: %v dB", two)
	y := render_text(DRY + "track a inst=t_sine vol=0.5\necho 1/4 0.5 0.5\nnote 0 2 A4\n", &set)
	defer delete(y)
	testing.expectf(t, energy(secs_at(y, 0.5, 0.05)) > 0.1 * energy(secs_at(y, 0, 0.05)) && energy(secs_at(y, 0.25, 0.05)) < 1e-6 * first,
		"echo 1/4 at 120 is half a second")
}

// Everything round two added survives being written out and read back, and
// a song that says none of it writes none of it.
@(test)
round_two_words_survive_a_round_trip :: proc(t: ^testing.T) {
	text := `song rt2
tempo 100
bars 2
level -19 short
reverb2 hall 0.7 0.4 0.35 0.02 0.9
instrument fmx
wave fm 3.5 2
fm_envelope 0.001 0.3 0 0.2
fm_feedback 0.4
fm_wave half abs
fm_keyscale 0.5
vel_index 0.7
damp 0.3
tremolo 4.5 3 0.2
drive 0.25
end
track a inst=fmx vol=0.4 mono=1 rev2=0.5 damp=off lp=4000 hp=120
eq 1500 6 1.2
eq 300 -3 0.7
echo 3/16 0.35 0.3
note 0 48 E4 slide_from=-2@6 bend=-1@12 bend_at=36 nudge=-8 damp=0.4
track b inst=sine vol=0.3 damp=0.2
echo 375 0.2 0.25
note 0 24 A4 damp=off
`
	s, _ := parse_song(text)
	defer song_destroy(&s)
	back, _ := parse_song(song_text(&s))
	defer song_destroy(&back)
	testing.expect(t, back.level_short)
	testing.expect_value(t, back.level, f32(-19))
	testing.expect_value(t, back.reverb2_kind, Room_Kind.Hall)
	testing.expect_value(t, back.reverb2, Reverb{0.7, 0.4, 0.35, 0.02, 0.9})
	a, b := back.tracks[0], back.tracks[1]
	testing.expect(t, a.mono)
	testing.expect_value(t, a.rev2, f32(0.5))
	testing.expect_value(t, a.damp, f32(-1))
	testing.expect_value(t, a.lp, f32(4000))
	testing.expect_value(t, a.hp, f32(120))
	testing.expect_value(t, len(a.eqs), 2)
	if len(a.eqs) == 2 do testing.expect_value(t, a.eqs[1], Eq_Band{300, -3, 0.7})
	testing.expect_value(t, a.echo, Echo{sync = 18, feedback = 0.35, mix = 0.3})
	testing.expect_value(t, b.echo, Echo{ms = 375, feedback = 0.2, mix = 0.25})
	testing.expect_value(t, b.damp, f32(0.2))
	testing.expect_value(t, b.notes[0].damp, f32(-1))
	n := a.notes[0]
	testing.expect_value(t, n.slide, f32(-2))
	testing.expect_value(t, n.slide_ticks, i32(6))
	testing.expect_value(t, n.bend, f32(-1))
	testing.expect_value(t, n.bend_ticks, i32(12))
	testing.expect_value(t, n.bend_at, i32(36))
	testing.expect_value(t, n.nudge, f32(-8))
	testing.expect_value(t, n.damp, f32(0.4))
	ins, found := instrument_find(&back.own, "fmx")
	testing.expect(t, found)
	if found {
		testing.expect_value(t, ins.wave, Wave.FM)
		testing.expect_value(t, ins.fm_ratio, f32(3.5))
		testing.expect_value(t, ins.fm_index, f32(2))
		testing.expect(t, ins.has_fm_env)
		testing.expect_value(t, ins.fm_env, Env{0.001, 0.3, 0, 0.2})
		testing.expect_value(t, ins.fm_fb, f32(0.4))
		testing.expect_value(t, ins.fm_wave, [2]Fm_Wave{.Half, .Abs})
		testing.expect_value(t, ins.fm_keyscale, f32(0.5))
		testing.expect_value(t, ins.vel_index, f32(0.7))
		testing.expect_value(t, ins.damp, f32(0.3))
		testing.expect_value(t, ins.trem_rate, f32(4.5))
		testing.expect_value(t, ins.trem_depth, f32(3))
		testing.expect_value(t, ins.trem_delay, f32(0.2))
		testing.expect_value(t, ins.drive, f32(0.25))
	}
	plain, _ := parse_song("song p\ntempo 100\nbars 1\ntrack a inst=sine vol=0.3\nnote 0 24 A4\n")
	defer song_destroy(&plain)
	out := song_text(&plain)
	for word in ([?]string{"short", "reverb2", "mono", "rev2", "damp", "lp=", "hp=", "eq ", "echo", "slide_from", "bend", "nudge"}) {
		testing.expectf(t, !strings.contains(out, word), "%v written for a song that never said it:\n%v", word, out)
	}
}
