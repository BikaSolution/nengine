package nengine

import "core:math"

// The synth: a .song in, stereo samples out.
//
// Each track is rendered on its own, a voice per note (or per slurred
// phrase, on a `legato` track), then given its volume over time, placed left
// or right by `pan`, and sent to the song's room by `rev`. The room and the
// dry sound are added, and the mix bus (master.odin) brings the whole to its
// loudness and keeps it under the ceiling.
//
// A voice is up to three oscillators with their own envelopes, some breath,
// a filter whose cutoff can follow the key, an envelope and the velocity, an
// optional high-pass, and a click of noise at the start. `string` is a
// Karplus-Strong plucked string instead of an oscillator, and `fm` a
// two-operator FM pair. A voice can slide and bend inside a note, be damped
// after its written length, dip with a tremolo on the song's clock and
// break up through a soft drive. After its notes a track can have its own
// filters, peaks and tape echo (master.odin), and a send to a second room.
// Every voice has a
// seed of its own, from its track and its place in it: it sets where in its
// cycle the voice starts, its noise and its pluck. So two notes are never
// the same noise, and one file always renders the same samples.

// The rate a one-pole number (`tone`, a .sound's `lp` and `hp`) was tuned
// at. They are per-sample coefficients, so at another rate they are
// converted to the same cutoff in hertz.
@(private)
REF_RATE :: 22050

// Pitch modulation (vibrato, sweep, glide) and the filter's cutoff are
// worked out this often, not per sample.
@(private = "file")
CONTROL_FRAMES :: 32

// A one-pole coefficient tuned at REF_RATE, at another rate (SAMPLE_RATE
// unless said): the same pole, so the same cutoff.
@(private)
rate_coef :: proc(c: f32, rate := SAMPLE_RATE) -> f32 {
	if c >= 1 do return 1
	if c <= 0 do return 0
	if rate == REF_RATE do return c
	return 1 - math.pow(1 - c, f32(REF_RATE) / f32(rate))
}

// The cutoff, in hertz, of a one-pole coefficient tuned at REF_RATE.
@(private)
coef_hz :: proc(c: f32) -> f32 {
	if c >= 1 do return f32(SAMPLE_RATE) // open
	return -math.ln(1 - max(c, 1e-6)) * f32(REF_RATE) / (2 * math.PI)
}

@(private)
hz_coef :: proc(hz: f32) -> f32 {
	return 1 - math.exp(-2 * math.PI * hz / f32(SAMPLE_RATE))
}

// White noise at a higher rate spreads the same power over more hertz, so a
// filtered hiss would come out quieter. This puts it back.
@(private)
NOISE_SCALE :: f32(1.4142135) // sqrt(SAMPLE_RATE / REF_RATE), for 44100 / 22050

// --- Time ---

// Seconds at each tick from 0 to `upto`, through the song's tempo changes.
song_times :: proc(s: ^Song, upto: i32, allocator := context.temp_allocator) -> []f64 {
	n := max(int(upto), 1)
	secs := make([]f64, n + 1, allocator)
	bpm := f64(max(s.tempo, 1))
	from, to: f64 = bpm, bpm
	ramp_at, ramp_len := 0, 0
	ev := 0
	for t in 0 ..< n {
		for ev < len(s.tempos) && int(s.tempos[ev].at) <= t {
			e := s.tempos[ev]
			from, to = bpm, f64(max(e.bpm, 1))
			ramp_at, ramp_len = int(e.at), int(e.glide)
			ev += 1
		}
		if ramp_len > 0 && t < ramp_at + ramp_len {
			bpm = from + (to - from) * (f64(t - ramp_at) + 0.5) / f64(ramp_len)
		} else {
			bpm = to
		}
		secs[t + 1] = secs[t] + 60 / (bpm * TPQ)
	}
	return secs
}

@(private = "file")
time_at :: #force_inline proc(secs: []f64, tick: i32) -> f64 {
	last := len(secs) - 1
	if int(tick) <= last do return secs[max(tick, 0)]
	// Past the end: carry on at the last tempo.
	step := secs[last] - secs[last - 1] if last > 0 else 0
	return secs[last] + f64(int(tick) - last) * step
}

// How long the song lasts, in seconds, its tempo changes and all.
song_seconds :: proc(s: ^Song) -> f32 {
	total := song_total_ticks(s)
	return f32(time_at(song_times(s, total), total))
}

// --- The song ---

// Renders the whole song to stereo at SAMPLE_RATE, mastered: in its room, at
// its loudness, under its ceiling.
//
// A looping song is exactly as long as its bars say, and a note that runs off
// the end wraps round to the start — which is what makes a game's background
// bed join up instead of clicking. Its room wraps the same way. A song with
// `loop no` is left to ring out, the room's tail and all.
//
// `set` is where instrument keys are looked up; the song's own definitions
// win over it. Passing nil means everything plays as a plain square wave,
// which is audible rather than silent, so a missing instruments folder is
// something you hear and not something you debug.
render_song :: proc(s: ^Song, set: ^Instrument_Set = nil, allocator := context.allocator) -> Audio {
	total := song_total_ticks(s)
	end := song_end_tick(s)
	horizon := max(total, end) + 8 * TPQ
	secs := song_times(s, horizon)
	rate := f64(SAMPLE_RATE)
	frame_of :: proc(secs: []f64, tick: i32, rate: f64) -> int { return int(math.round(time_at(secs, tick) * rate)) }

	room := s.reverb
	has_room := room.mix > 0
	// The second room, if anything is sent to it.
	room2 := s.reverb2
	has_room2 := false
	if room2.mix > 0 do for &t in s.tracks do if t.rev2 > 0 && track_audible(s, &t) do has_room2 = true
	frames := frame_of(secs, total, rate)
	if !s.loop {
		frames = frame_of(secs, max(total, end + i32(4 * TPQ)), rate) // room to ring out
		if has_room do frames = max(frames, frame_of(secs, end, rate) + int(reverb_tail(room) * f32(rate)))
		// And whatever rings on past that — a struck note's decay, an echo —
		// with the rooms' tails after it, so a piece ends on silence rather
		// than on the edge of a note.
		tail: f32 = 0.1
		if has_room do tail = max(tail, reverb_tail(room))
		if has_room2 do tail = max(tail, reverb_tail(room2, s.reverb2_kind))
		frames = max(frames, int((song_ring_end(s, set, secs) + f64(tail)) * rate))
	}
	if frames <= 0 do return {channels = 2, rate = SAMPLE_RATE}
	loop_secs := f32(f64(frames) / rate) if s.loop else 0

	dry := make([]f32, 2 * frames, allocator)
	buf := make([]f32, frames)
	defer delete(buf)
	send, send2: []f32
	if has_room do send = make([]f32, frames)
	if has_room2 do send2 = make([]f32, frames)
	defer delete(send)
	defer delete(send2)

	for &t, ti in s.tracks {
		if !track_audible(s, &t) do continue
		ins := track_instrument(s, set, &t)

		for &v in buf do v = 0
		render_track(buf, s, &t, ti, &ins, secs, loop_secs)
		track_automation(buf, &t, secs)
		track_effects(buf, &t, track_echo_seconds(s, &t), s.loop)

		p := clamp(t.pan + ins.pan, -1, 1)
		angle := (p + 1) * math.PI / 4 // constant power: as loud anywhere across
		gl, gr := math.cos(angle), math.sin(angle)
		for v, i in buf {
			dry[2 * i] += v * gl
			dry[2 * i + 1] += v * gr
		}
		if has_room do for v, i in buf do send[i] += v * t.rev
		if has_room2 && t.rev2 > 0 do for v, i in buf do send2[i] += v * t.rev2
	}

	if has_room {
		wet := reverb_render(send, room, s.loop)
		defer delete(wet)
		for v, i in wet do dry[i] += v
	}
	if has_room2 {
		wet := reverb_render(send2, room2, s.loop, kind = s.reverb2_kind)
		defer delete(wet)
		for v, i in wet do dry[i] += v
	}
	master(dry, 2, s.level, s.ceiling, s.loop, short = s.level_short)
	if !s.loop do fade_out(dry, 2, 0.05)
	return {dry, 2, SAMPLE_RATE}
}

// The instrument a track plays. The song's own definitions win over the
// shared set, so a tune that carries a sound plays the same wherever it is
// opened.
@(private = "file")
track_instrument :: proc(s: ^Song, set: ^Instrument_Set, t: ^Track) -> Instrument {
	ins := instrument_get(set, t.inst)
	if mine, ok := instrument_find(&s.own, t.inst); ok do ins = mine^
	return ins
}

// A track's echo time in seconds: milliseconds, or ticks at the opening tempo.
@(private)
track_echo_seconds :: proc(s: ^Song, t: ^Track) -> f32 {
	e := t.echo
	if e.mix <= 0 do return 0
	if e.sync > 0 do return f32(e.sync) * 60 / (max(s.tempo, 1) * TPQ)
	return e.ms / 1000
}

// When the last thing a piece plays is 60 dB down, in seconds: every note's
// own ring, damper, nudge and echo counted.
@(private = "file")
song_ring_end :: proc(s: ^Song, set: ^Instrument_Set, secs: []f64) -> f64 {
	last: f64
	for &t in s.tracks {
		if !track_audible(s, &t) do continue
		ins := track_instrument(s, set, &t)
		echo := f64(echo_tail(track_echo_seconds(s, &t), t.echo.feedback))
		for n in t.notes {
			at := time_at(secs, n.tick) + f64(n.nudge) / 1000
			gate := f32(time_at(secs, n.tick + n.len) - time_at(secs, n.tick))
			last = max(last, at + f64(voice_life(&ins, gate, note_damp(n, &t, &ins), 60)) + echo)
		}
	}
	return last
}

// A note's damper: its own, else its track's, else its instrument's; 0 is none.
@(private = "file")
note_damp :: proc(n: Note, t: ^Track, ins: ^Instrument) -> f32 {
	d := n.damp
	if d == 0 do d = t.damp
	if d == 0 do d = ins.damp
	return max(d, 0)
}

// One note on its own, for the click you hear when picking an instrument or
// placing a note. Mono, dry, and simply kept under 0.9.
render_note :: proc(ins: ^Instrument, note: int, seconds: f32 = 0.6, allocator := context.allocator) -> Audio {
	out := make([]f32, int(seconds * f32(SAMPLE_RATE)), allocator)
	seg := [1]Voice_Seg{{note = f32(note), len = seconds * 0.6, vel = 100, vel_end = 100, amp = 1, amp_end = 1}}
	render_voice(out, 0, ins, seg[:], seconds * 0.6, {seed = 987654321, damp = ins.damp})
	loudest: f32
	for v in out do loudest = max(loudest, abs(v))
	if loudest > 0.9 do for &v in out do v *= 0.9 / loudest
	return {out, 1, SAMPLE_RATE}
}

// Seconds from tick `from` to `ticks` after it.
@(private = "file")
span_secs :: proc(secs: []f64, from, ticks: i32) -> f32 {
	return f32(time_at(secs, from + ticks) - time_at(secs, from))
}

// Every note of one track into `buf` (mono, the song's length).
@(private = "file")
render_track :: proc(buf: []f32, s: ^Song, t: ^Track, ti: int, ins: ^Instrument, secs: []f64, loop_secs: f32) {
	rate := f64(SAMPLE_RATE)
	notes := t.notes[:]
	// A slur needs a voice that holds: a plucked string re-plucks.
	legato := t.legato && ins.sustain > 0 && ins.wave != .String
	segs := make([dynamic]Voice_Seg, context.temp_allocator)

	i := 0
	for i < len(notes) {
		n := notes[i]
		clear(&segs)
		first := n.tick
		phrase_end := n.tick + n.len
		j := i + 1
		add :: proc(segs: ^[dynamic]Voice_Seg, n: Note, first: Note, secs: []f64, volume: f32) {
			at := f32(time_at(secs, n.tick) - time_at(secs, first.tick)) + (n.nudge - first.nudge) / 1000
			ln := f32(time_at(secs, n.tick + n.len) - time_at(secs, n.tick))
			vel := f32(n.vel)
			vel_end := f32(n.vel_end) if n.vel_end > 0 else vel
			append(segs, Voice_Seg{
				at = max(at, 0), len = ln, note = f32(pitch_midi(n.pitch)), vel = vel, vel_end = vel_end,
				amp = vel / f32(DEFAULT_VELOCITY) * volume, amp_end = vel_end / f32(DEFAULT_VELOCITY) * volume,
				slide = n.slide, slide_len = span_secs(secs, n.tick, n.slide_ticks),
				bend = n.bend, bend_at = span_secs(secs, n.tick, n.bend_at),
				bend_len = span_secs(secs, n.tick + n.bend_at, n.bend_ticks),
			})
		}
		add(&segs, n, n, secs, t.volume)
		if legato {
			// The phrase goes on while each note starts before (or as) the
			// last one stops — but not a chord, and not the same pitch again,
			// which a player would play as a new note.
			for j < len(notes) {
				m, prev := notes[j], notes[j - 1]
				if m.tick > phrase_end || m.tick <= prev.tick || pitch_midi(m.pitch) == pitch_midi(prev.pitch) do break
				add(&segs, m, n, secs, t.volume)
				phrase_end = max(phrase_end, m.tick + m.len)
				j += 1
			}
		}

		start_t := time_at(secs, first) + f64(n.nudge) / 1000
		start := int(math.round(start_t * rate))
		gate := f32(time_at(secs, phrase_end) - time_at(secs, first))
		// A little air before the same note again, or two quarter notes on
		// one pitch play as one half note. Only then: a line into a
		// different note keeps its full length.
		last := notes[j - 1]
		for k := j; k < len(notes) && notes[k].tick <= phrase_end + 1; k += 1 {
			if notes[k].tick >= phrase_end - 1 && pitch_midi(notes[k].pitch) == pitch_midi(last.pitch) {
				gate -= min(0.02, gate * 0.12)
				break
			}
		}
		// One voice to a mono track: the next note (a loop's first, coming
		// round) stops this one.
		stop: f32
		if t.mono {
			for k := j; k < len(notes); k += 1 {
				if notes[k].tick > last.tick {
					stop = f32(time_at(secs, notes[k].tick) + f64(notes[k].nudge) / 1000 - start_t)
					break
				}
			}
			if stop == 0 && s.loop && loop_secs > 0 {
				stop = f32(f64(loop_secs) + time_at(secs, notes[0].tick) + f64(notes[0].nudge) / 1000 - start_t)
			}
			if stop != 0 {
				stop = max(stop, 0.001)
				gate = min(gate, stop)
			}
		}
		seed := voice_seed(u32(ti), u32(i), u32(pitch_midi(n.pitch)) * 7919 + u32(n.tick))
		render_voice(buf, start, ins, segs[:], gate, {
			glide = t.glide, seed = seed, wrap = s.loop, t0 = start_t, loop_secs = loop_secs,
			stop = stop, damp = note_damp(n, t, ins),
		})
		i = j
	}
}

// The track's `vol` points, applied to what it played.
@(private = "file")
track_automation :: proc(buf: []f32, t: ^Track, secs: []f64) {
	if len(t.vols) == 0 do return
	rate := f64(SAMPLE_RATE)
	k := 0
	for &v, i in buf {
		for k < len(t.vols) && int(math.round(time_at(secs, t.vols[k].tick) * rate)) <= i do k += 1
		level: f32
		switch {
		case k == 0:
			level = t.vols[0].level
		case k >= len(t.vols):
			level = t.vols[len(t.vols) - 1].level
		case:
			a, b := t.vols[k - 1], t.vols[k]
			fa, fb := time_at(secs, a.tick) * rate, time_at(secs, b.tick) * rate
			u := f32((f64(i) - fa) / max(fb - fa, 1))
			level = a.level + (b.level - a.level) * u
		}
		v *= level
	}
}

// --- A voice ---

// One note of a voice; a slurred phrase is several. Times in seconds from
// the voice's start.
Voice_Seg :: struct {
	at:        f32,
	len:       f32, // how long it was written for: vel_end is reached by then
	note:      f32, // MIDI, fractional allowed
	vel:       f32, // 1..127, for the filter, the click and the pluck
	vel_end:   f32,
	amp:       f32, // velocity times the track's volume
	amp_end:   f32,
	// Pitch inside the note, in semitones and seconds from its start: it
	// starts `slide` off and is home by `slide_len`; from `bend_at` it moves
	// `bend` away over `bend_len`, and stays there.
	slide:     f32,
	slide_len: f32,
	bend:      f32,
	bend_at:   f32,
	bend_len:  f32,
}

// How a voice is played, beyond its notes.
Voice_Opts :: struct {
	glide:     f32,  // seconds of portamento between slurred notes
	seed:      u32,
	wrap:      bool, // a loop: what runs off the end comes round to the start
	t0:        f64,  // the song's clock at the voice's start: the tremolo runs on it
	loop_secs: f32,  // a loop's length, so its tremolo comes round whole
	stop:      f32,  // seconds: a mono track's next note stops it here (0: never)
	damp:      f32,  // seconds: a struck note's damper (0: none, it rings)
}

// How long a voice can be heard for, until it is `db` down. A struck or
// plucked instrument (sustain 0) rings for its own decay however short the
// note is written — that is what a harp string does — and on until it is
// inaudible (it is 40 dB down at `decay`), unless a damper stops it after
// its written length.
@(private)
voice_life :: proc(ins: ^Instrument, gate, damp: f32, db: f32 = 90) -> f32 {
	ring :: proc(e: Env, gate, damp, db: f32) -> f32 {
		if e.sustain > 0 do return gate + max(e.release, 0.005)
		life := e.attack + max(e.decay, 1e-3) * db / 40
		if damp > 0 do life = min(life, max(gate, e.attack) + damp * db / 60)
		return max(life, 0.005)
	}
	life := ring(Env{ins.attack, ins.decay, ins.sustain, ins.release}, gate, damp, db)
	if ins.has_env2 && ins.mix2 > 0 do life = max(life, ring(ins.env2, gate, damp, db))
	if ins.has_env3 && ins.mix3 > 0 do life = max(life, ring(ins.env3, gate, damp, db))
	if ins.click[0] > 0 do life = max(life, ins.click[1] * 1.5)
	return life
}

// The pitch a note's own slide and bend add, `t` seconds into it.
@(private = "file")
seg_bend :: #force_inline proc(sg: Voice_Seg, t: f32) -> f32 {
	ease :: #force_inline proc(u: f32) -> f32 { return u * u * (3 - 2 * u) }
	b: f32
	if sg.slide != 0 do b += sg.slide * (1 - ease(clamp(t / max(sg.slide_len, 1e-3), 0, 1)))
	if sg.bend != 0 do b += sg.bend * ease(clamp((t - sg.bend_at) / max(sg.bend_len, 1e-3), 0, 1))
	return b
}

// One voice, added into `out` from `start`. See the top of this file.
@(private)
render_voice :: proc(out: []f32, start: int, ins: ^Instrument, segs: []Voice_Seg, gate: f32, opts: Voice_Opts) {
	if len(out) == 0 || start >= len(out) || len(segs) == 0 do return
	rate := f32(SAMPLE_RATE)
	main := Env{ins.attack, ins.decay, ins.sustain, ins.release}
	damp := opts.damp

	natural := int(voice_life(ins, gate, damp) * rate)
	frames := natural
	if opts.wrap {
		// A note can't ring for longer than the whole loop, or it comes round
		// and overlaps itself. A bell in a one-second loop is a bell, not a wash.
		frames = min(frames, len(out))
	} else {
		frames = min(frames, len(out) - start)
	}
	// A mono track's next note stops this one: quickly, but not with a click.
	fade_n := int(0.004 * rate)
	if opts.stop > 0 do frames = min(frames, int(opts.stop * rate) + fade_n)
	if frames <= 0 do return
	// Cut short of its own end (by the loop, the song or the next note), it
	// fades over its last 4 ms instead of stopping dead.
	fade_from := frames
	if frames < natural do fade_from = max(frames - fade_n, 0)

	rng := seed_scramble(opts.seed)
	base := segs[0].note

	// Where in its cycle the voice starts: anywhere, so a chord's notes and a
	// bass and a drum on one downbeat do not all start in phase and add up
	// to one spike. Every oscillator moves by the same TIME, so a layer keeps
	// its place against the first and the instrument sounds as designed.
	r := rand01(&rng)
	ratio2 := math.pow(f32(2), ins.semis2 / 12)
	ratio3 := math.pow(f32(2), ins.semis3 / 12)
	phase, phase2, phase3 := r, fract(r * ratio2), fract(r * ratio3)
	lfsr1, lfsr2, lfsr3 := lfsr_seed(&rng), lfsr_seed(&rng), lfsr_seed(&rng)
	nclock1, nclock2, nclock3, nout1, nout2, nout3: f32
	w1 := max(1 - ins.mix2 - ins.mix3, 0)

	// The FM pair's modulator, in step with the carrier like the layers.
	is_fm := ins.wave == .FM
	fm_ratio := max(ins.fm_ratio, 0.001)
	pm := fract(r * fm_ratio)
	m1, m2, fm_idx: f32

	// Does any note move its pitch? A plucked string then needs a loop whose
	// length can follow it.
	bending := false
	lowest := base
	for sg in segs {
		if sg.slide != 0 || sg.bend != 0 do bending = true
		lowest = min(lowest, sg.note + min(sg.slide, 0) + min(sg.bend, 0) + min(sg.slide + sg.bend, 0))
	}

	// The pluck.
	ks: Pluck
	if ins.wave == .String {
		if bending {
			ks = pluck_new_bending(ins, midi_hz(base + segs[0].slide), segs[0].vel, &rng, midi_hz(lowest - 2 - ins.vib_depth - abs(ins.sweep)))
		} else {
			ks = pluck_new(ins, midi_hz(base), segs[0].vel, &rng)
		}
	}
	defer delete(ks.buf)

	// The filter: a two-pole state-variable low-pass if `filter` is set,
	// otherwise the one-pole `tone` it has always been.
	two_pole := ins.filter_hz > 0
	tone := clamp(ins.tone, 0.01, 1)
	cutoff := ins.filter_hz if two_pole else coef_hz(tone)
	moves := ins.keytrack != 0 || ins.fenv[2] != 0 || ins.vel_tone != 0
	one_pole := rate_coef(tone)
	lp: f32
	svf: Svf
	if two_pole do svf_set(&svf, cutoff, ins.resonance)
	hp: Svf
	if ins.highpass > 0 do svf_set(&hp, ins.highpass, 0)
	click_coef := rate_coef(ins.click[2] if ins.click[2] > 0 else 1)
	click_lp: f32
	// The half, abs and quarter waves and a valve's lean have an offset; a
	// slow high-pass takes it out.
	dc_block := (is_fm && (ins.fm_wave[1] != .Sine)) || ins.drive > 0
	dc: f32

	// Tremolo runs on the song's clock, so every note of the instrument
	// shares one motor; in a loop it is nudged to whole cycles so the seam
	// does not jump.
	trem := ins.trem_depth > 0 && ins.trem_rate > 0
	trem_hz := f64(ins.trem_rate)
	if trem && opts.loop_secs > 0 do trem_hz = max(math.round(trem_hz * f64(opts.loop_secs)), 1) / f64(opts.loop_secs)
	trem_gain: f32 = 1

	seg := 0
	note_now := base
	glide_from := base
	glide_at: f32
	f := midi_hz(base)
	amp := segs[0].amp
	amp_to := amp
	vel_now := segs[0].vel
	smooth := 1 - math.exp(-1 / (0.005 * rate)) // 5 ms between one note's level and the next's

	for j in 0 ..< frames {
		time := f32(j) / rate

		for seg + 1 < len(segs) && time >= segs[seg + 1].at {
			seg += 1
			glide_from, glide_at = note_now, time
		}

		if j % CONTROL_FRAMES == 0 {
			sg := segs[seg]
			note_now = sg.note
			if opts.glide > 0 && seg > 0 && time - glide_at < opts.glide {
				note_now = glide_from + (sg.note - glide_from) * (time - glide_at) / opts.glide
			}
			semis: f32 = 0
			if sg.slide != 0 || sg.bend != 0 do semis += seg_bend(sg, time - sg.at)
			if ins.vib_depth > 0 && time > ins.vib_delay {
				// Vibrato arrives, it doesn't switch on: a quarter of a second
				// of fading in is the difference between a violin and a siren.
				fade := min((time - ins.vib_delay) / 0.25, 1)
				semis += ins.vib_depth * fade * math.sin(2 * math.PI * ins.vib_rate * (time - ins.vib_delay))
			}
			if ins.sweep != 0 do semis += ins.sweep * math.exp(-time / max(ins.sweep_time, 1e-3))
			f = midi_hz(note_now + semis)

			u := clamp((time - sg.at) / max(sg.len, 1e-4), 0, 1)
			amp_to = sg.amp + (sg.amp_end - sg.amp) * u
			vel_now = sg.vel + (sg.vel_end - sg.vel) * u

			if moves && (two_pole || tone < 1) {
				oct := ins.keytrack * (note_now - 60) / 12 + ins.vel_tone * (vel_now - 100) / 100
				if ins.fenv[2] != 0 do oct += ins.fenv[2] * filter_env_level(ins.fenv, time)
				hz := clamp(cutoff * math.pow(f32(2), oct), 20, 0.45 * rate)
				if two_pole do svf_set(&svf, hz, ins.resonance)
				else do one_pole = hz_coef(hz)
			}
			if is_fm {
				idx := ins.fm_index
				if ins.fm_keyscale > 0 do idx *= min(math.pow(f32(2), -ins.fm_keyscale * (note_now + semis - 60) / 12), 1)
				if ins.vel_index > 0 do idx *= max(1 + ins.vel_index * (vel_now - 100) / 100, 0)
				// Carson's rule: the spectrum reaches about (I + 1) x ratio x f.
				// Kept under 18 kHz, or the top folds back down as a whistle.
				fm_idx = clamp(idx, 0, max(18000 / (fm_ratio * f) - 1, 0))
			}
			if trem {
				fade: f32 = 1
				if ins.trem_delay > 0 do fade = clamp((time - ins.trem_delay) / 0.25, 0, 1)
				dip := 0.5 - 0.5 * f32(math.cos(2 * math.PI * (opts.t0 + f64(time)) * trem_hz))
				trem_gain = math.pow(10, -ins.trem_depth * dip * fade / 20)
			}
		}
		amp += (amp_to - amp) * smooth

		dt := f / rate
		dt2 := dt * ratio2
		dt3 := dt * ratio3

		// The NES noise is clocked from the pitch, so a higher note hisses brighter.
		if ins.wave == .Noise do nout1 = lfsr_clock(&nclock1, dt, &lfsr1, ins.metallic)
		if ins.mix2 > 0 && ins.wave2 == .Noise do nout2 = lfsr_clock(&nclock2, dt2, &lfsr2, ins.metallic)
		if ins.mix3 > 0 && ins.wave3 == .Noise do nout3 = lfsr_clock(&nclock3, dt3, &lfsr3, ins.metallic)
		if ins.wave == .White do nout1 = white(&rng)
		if ins.mix2 > 0 && ins.wave2 == .White do nout2 = white(&rng)
		if ins.mix3 > 0 && ins.wave3 == .White do nout3 = white(&rng)

		e := envelope(main, time, gate, damp)
		v1: f32
		if ins.wave == .String {
			if ks.bending {
				v1 = pluck_step_bending(&ks, rate / f)
			} else {
				v1 = pluck_step(&ks)
			}
		} else if is_fm {
			// Two operators: the modulator (feeding itself back, as an
			// OPL's does) moves the carrier's phase by up to the index.
			ie := envelope(ins.fm_env, time, gate, damp) if ins.has_fm_env else e
			fb := ins.fm_fb * math.PI * (m1 + m2) * 0.5
			m := fm_shape(ins.fm_wave[0], pm + fb / (2 * math.PI))
			v1 = fm_shape(ins.fm_wave[1], phase + fm_idx * ie * m / (2 * math.PI))
			m2, m1 = m1, m
			pm = fract(pm + dt * fm_ratio)
		} else {
			v1 = osc(ins.wave, phase, dt, ins.duty, nout1)
		}
		x := v1 * w1 * e
		if ins.mix2 > 0 {
			e2 := envelope(ins.env2, time, gate, damp) if ins.has_env2 else e
			x += osc(ins.wave2, phase2, dt2, ins.duty, nout2) * ins.mix2 * e2
		}
		if ins.mix3 > 0 {
			e3 := envelope(ins.env3, time, gate, damp) if ins.has_env3 else e
			x += osc(ins.wave3, phase3, dt3, ins.duty, nout3) * ins.mix3 * e3
		}
		if ins.breath > 0 do x += ins.breath * NOISE_SCALE * white(&rng) * e

		phase = fract(phase + dt)
		phase2 = fract(phase2 + dt2)
		phase3 = fract(phase3 + dt3)

		// Drive: a valve amp's soft break-up, harder for a harder note. As
		// loud as it was for a quiet note; only the peaks are rounded (and a
		// little lopsided, as a valve's are, which is where its warmth is).
		if ins.drive > 0 {
			vf := max(vel_now / 100, 0.05)
			k := 4 * ins.drive
			bias := 0.15 * ins.drive
			tb := math.tanh(bias)
			x = (math.tanh(k * x * vf + bias) - tb) / (k * (1 - tb * tb)) / vf
		}

		// Low-pass: a cello and a violin can both be a saw and still not
		// sound alike.
		if two_pole {
			x = svf_low(&svf, x)
		} else {
			lp += one_pole * (x - lp)
			x = lp
		}
		if ins.highpass > 0 do x = svf_high(&hp, x)
		if dc_block {
			dc += 0.0007 * (x - dc)
			x -= dc
		}

		if ins.click[0] > 0 && time < ins.click[1] * 1.5 {
			c := white(&rng) * ins.click[0] * math.exp(-time * 4.6 / max(ins.click[1], 1e-4))
			click_lp += click_coef * (c - click_lp)
			x += click_lp
		}

		g := ins.gain * amp * trem_gain
		if j >= fade_from do g *= f32(frames - j) / f32(max(frames - fade_from, 1))
		at := start + j
		if opts.wrap {
			at %%= len(out)
		} else if at < 0 {
			continue
		}
		out[at] += x * g
	}
}

// Envelope level at `time` seconds, for a note held `gate` seconds.
@(private = "file")
envelope :: proc(e: Env, time, gate: f32, damp: f32 = 0) -> f32 {
	held :: proc(e: Env, t: f32) -> f32 {
		if t < e.attack do return t / max(e.attack, 1e-4)
		d := t - e.attack
		// Struck: an exponential fall, which is what a real decay is. 4.6 is
		// ln(100), so it has lost 40 dB by the time `decay` is up.
		if e.sustain <= 0 do return math.exp(-d * 4.6 / max(e.decay, 1e-3))
		if d < e.decay do return 1 - (1 - e.sustain) * d / max(e.decay, 1e-4)
		return e.sustain
	}
	if e.sustain <= 0 {
		// A struck note ignores its written length and falls on until it is
		// inaudible — unless it has a damper, which from the end of its
		// written length takes it 60 dB down in `damp` seconds.
		v := held(e, time)
		if damp > 0 {
			from := max(gate, e.attack)
			if time > from do v *= math.exp(-(time - from) * 6.9078 / damp)
		}
		return v
	}
	if time < gate do return held(e, time)
	r := (time - gate) / max(e.release, 1e-3)
	return r >= 1 ? 0 : held(e, gate) * (1 - r)
}

// The filter envelope: up over `attack`, then an exponential fall over `decay`.
@(private = "file")
filter_env_level :: proc(fe: [3]f32, time: f32) -> f32 {
	if time < fe[0] do return time / max(fe[0], 1e-4)
	return math.exp(-(time - fe[0]) * 4.6 / max(fe[1], 1e-3))
}

// --- The two-pole filter (a state-variable filter, the trapezoidal kind,
// which stays stable however fast the cutoff moves) ---

@(private = "file")
Svf :: struct {
	k, a1, a2, a3: f32,
	ic1, ic2:      f32,
}

@(private = "file")
svf_set :: proc(f: ^Svf, hz, resonance: f32) {
	g := math.tan(math.PI * clamp(hz, 10, 0.45 * f32(SAMPLE_RATE)) / f32(SAMPLE_RATE))
	// No resonance is a Butterworth (Q 0.707); full is nearly singing.
	f.k = 1.4142 - 1.36 * clamp(resonance, 0, 1)
	f.a1 = 1 / (1 + g * (g + f.k))
	f.a2 = g * f.a1
	f.a3 = g * f.a2
}

@(private = "file")
svf_tick :: #force_inline proc(f: ^Svf, x: f32) -> (low, band: f32) {
	v3 := x - f.ic2
	v1 := f.a1 * f.ic1 + f.a2 * v3
	v2 := f.ic2 + f.a2 * f.ic1 + f.a3 * v3
	f.ic1 = 2 * v1 - f.ic1
	f.ic2 = 2 * v2 - f.ic2
	return v2, v1
}

@(private = "file")
svf_low :: #force_inline proc(f: ^Svf, x: f32) -> f32 {
	low, _ := svf_tick(f, x)
	return low
}

@(private = "file")
svf_high :: #force_inline proc(f: ^Svf, x: f32) -> f32 {
	low, band := svf_tick(f, x)
	return x - f.k * band - low
}

// --- Karplus-Strong ---
//
// A plucked string is a short loop of noise, run round and round through a
// gentle low-pass: the high frequencies die first, so it starts bright and
// mellows. That is the whole of Karplus-Strong, and it sounds far better
// than it has any right to.
//
// Three things make it a real instrument rather than a toy:
//   * TUNING. A loop is a whole number of samples, which is out of tune high
//     up (A5 was 30 cents flat). An all-pass filter in the loop adds exactly
//     the fraction of a sample still missing, at the note's own frequency.
//   * THE PLUCK. A burst of full-band noise starts every note with a spike
//     louder than the note itself. Instead it starts from the shape a real
//     plucked string has (a triangle), with a little noise, low-passed more
//     for a softer note (a soft pluck is a dull one), with no offset and a
//     set energy, so every note starts at the level it rings at.
//   * A SEED per note: where it is plucked, and its noise, so no two
//     plucks are the same.

@(private = "file")
Pluck :: struct {
	buf:          []f32,
	i:            int,
	damp:         f32, // the loop's low-pass
	lp:           f32,
	c:            f32, // the all-pass
	ax, ay:       f32,
	// A string whose pitch moves (a slide, a hammer-on, a bend): the loop is
	// read from a moving point instead, between two samples.
	bending:      bool,
	w:            int,
	fdelay:       f32, // the loop's low-pass delays it by this many samples
}

// The level the pluck is set to, chosen so a harp sits in a mix where its
// old self did.
@(private = "file")
PLUCK_LEVEL :: f32(0.22)

// What the loss per trip round the loop is: the classic 0.996.
@(private = "file")
PLUCK_LOSS :: f32(0.996)

@(private = "file")
pluck_new :: proc(ins: ^Instrument, hz: f32, vel: f32, rng: ^u32) -> Pluck {
	rate := f32(SAMPLE_RATE)
	f0 := clamp(hz, 20, rate / 4)
	period := rate / f0
	// The loop's low-pass, as strong as the classic string's two-point
	// average was at 22050 Hz when `string_damp` is 0.5, and stronger or
	// weaker in proportion. (At a higher rate the same filter would let the
	// highs ring on longer, because a period is more samples.)
	d := clamp(ins.string_damp if ins.string_damp > 0 else 0.5, 0.01, 0.95)
	ratio := f32(SAMPLE_RATE) / f32(REF_RATE)
	loss := ratio * ratio / 4 * d / 0.5
	a := ((2 * loss + 1) - math.sqrt(4 * loss + 1)) / (2 * loss)
	w := 2 * math.PI * f0 / rate
	// The loop's low-pass delays the fundamental by this much...
	filter_delay := math.atan2(a * math.sin(w), 1 - a * math.cos(w)) / w
	n := max(int(math.floor(period - filter_delay - 0.1)), 2)
	// ...and the all-pass makes up the rest, exactly, at this frequency.
	delta := clamp(period - f32(n) - filter_delay, 0.1, 1.1)
	p := Pluck{damp = a}
	p.c = math.sin(w * (1 - delta) / 2) / math.sin(w * (1 + delta) / 2)
	p.buf = make([]f32, n)

	// The pluck: the shape a plucked string really starts from, a triangle
	// with its peak where the finger is, and some noise in it for the nail —
	// more for a brighter or harder pluck — all low-passed by the brightness
	// and the velocity, its offset taken out and its energy set. A triangle
	// is a gentle start (its peak is 1.7 times its level, where a burst of
	// noise's is three times and more), so the note does not open on a spike.
	bright := ins.string_bright if ins.string_bright > 0 else DEFAULT_STRING_BRIGHT
	soft := clamp(vel / 127, 0.05, 1)
	at := 0.12 + 0.1 * rand01(rng) // where along the string, a little different each time
	nail := 0.05 + 0.4 * bright * soft
	tri := make([]f32, n, context.temp_allocator)
	noise := make([]f32, n, context.temp_allocator)
	for i in 0 ..< n {
		u := (f32(i) + 0.5) / f32(n)
		tri[i] = u / at if u < at else (1 - u) / (1 - at)
		noise[i] = white(rng)
	}
	settle :: proc(x: []f32) {
		mean: f32
		for v in x do mean += v
		mean /= f32(len(x))
		e: f32
		for &v in x { v -= mean; e += v * v }
		level := math.sqrt(e / f32(len(x)))
		if level > 1e-9 do for &v in x do v /= level
	}
	settle(tri)
	settle(noise)
	for i in 0 ..< n do p.buf[i] = (1 - nail) * tri[i] + nail * noise[i]
	// Low-passed round and round, so the buffer still joins end to start.
	coef := rate_coef(clamp(bright * (0.35 + 0.65 * soft), 0.01, 1))
	y := p.buf[n - 1]
	for pass in 0 ..< 2 {
		for i in 0 ..< n {
			y += coef * (p.buf[i] - y)
			if pass == 1 do p.buf[i] = y
		}
	}
	settle(p.buf)
	for &v in p.buf do v *= PLUCK_LEVEL
	return p
}

// A pluck whose loop can change length as it rings, for a note that slides
// or bends: the same excitation, in a buffer long enough for the lowest
// pitch it will reach. The note keeps ringing while its pitch moves, which
// is what a finger sliding up a string does.
@(private = "file")
pluck_new_bending :: proc(ins: ^Instrument, hz: f32, vel: f32, rng: ^u32, lowest_hz: f32) -> Pluck {
	p := pluck_new(ins, hz, vel, rng)
	rate := f32(SAMPLE_RATE)
	f0 := clamp(hz, 20, rate / 4)
	w := 2 * math.PI * f0 / rate
	p.fdelay = math.atan2(p.damp * math.sin(w), 1 - p.damp * math.cos(w)) / w
	n := len(p.buf)
	size := max(int(rate / clamp(lowest_hz, 20, rate / 4)) + 8, n + 8)
	buf := make([]f32, size)
	for k in 0 ..< n do buf[size - n + k] = p.buf[k]
	delete(p.buf)
	p.buf = buf
	p.bending = true
	return p
}

@(private = "file")
pluck_step_bending :: #force_inline proc(p: ^Pluck, period: f32) -> f32 {
	size := len(p.buf)
	d := clamp(period - p.fdelay, 2, f32(size - 2))
	at := f32(p.w) - d
	if at < 0 do at += f32(size)
	k0 := int(at)
	fr := at - f32(k0)
	x := p.buf[k0 % size] * (1 - fr) + p.buf[(k0 + 1) % size] * fr
	p.lp = (1 - p.damp) * x + p.damp * p.lp
	p.buf[p.w] = p.lp * PLUCK_LOSS
	p.w = (p.w + 1) % size
	return x
}

@(private = "file")
pluck_step :: #force_inline proc(p: ^Pluck) -> f32 {
	x := p.buf[p.i]
	p.lp = (1 - p.damp) * x + p.damp * p.lp
	ap := p.c * p.lp + p.ax - p.c * p.ay
	p.ax, p.ay = p.lp, ap
	p.buf[p.i] = ap * PLUCK_LOSS
	p.i += 1
	if p.i == len(p.buf) do p.i = 0
	return x
}

// The fundamental a pluck at `hz` really rings at, for the tests: the loop's
// own length, filters and all, measured from its output.
@(private)
pluck_for_test :: proc(hz: f32, seconds: f32) -> []f32 {
	ins := DEFAULT_INSTRUMENT
	ins.wave = .String
	rng := u32(12345)
	p := pluck_new(&ins, hz, 100, &rng)
	defer delete(p.buf)
	out := make([]f32, int(seconds * f32(SAMPLE_RATE)))
	for &v in out do v = pluck_step(&p)
	return out
}

// --- Oscillators ---

// PolyBLEP: rounds the corner off a jump so it doesn't alias. A naive square
// or saw high up folds its harmonics back down past half the sample rate as
// a whistle that follows the tune the wrong way up.
@(private = "file")
blep :: #force_inline proc(t, dt: f32) -> f32 {
	if t < dt {
		x := t / dt
		return x + x - x * x - 1
	} else if t > 1 - dt {
		x := (t - 1) / dt
		return x * x + x + x + 1
	}
	return 0
}

@(private = "file")
fract :: #force_inline proc(x: f32) -> f32 {
	return x - math.floor(x)
}

@(private = "file")
osc :: #force_inline proc(w: Wave, ph, dt, duty: f32, noise_out: f32) -> f32 {
	switch w {
	case .Pulse:
		d := clamp(duty, 0.01, 0.99)
		v: f32 = 1 if ph < d else -1
		v += blep(ph, dt)
		v -= blep(fract(ph + 1 - d), dt)
		// Keep it centred whatever the duty, or a 12.5% pulse is mostly a
		// DC offset and everything else in the mix ducks around it.
		return v - (2 * d - 1)
	case .Triangle:
		return 4 * abs(ph - 0.5) - 1
	case .NES_Triangle:
		tri := 4 * abs(ph - 0.5) - 1
		return math.floor((tri + 1) * 7.5 + 0.5) / 7.5 - 1 // the NES's 16 steps
	case .Saw:
		return 2 * ph - 1 - blep(ph, dt)
	case .Sine:
		return math.sin(2 * math.PI * ph)
	case .Noise, .White:
		return noise_out
	case .String:
		// Only the primary wave can be a string: it needs a buffer of its
		// own, which render_voice holds. As a layer it stands in as a triangle.
		return 4 * abs(ph - 0.5) - 1
	case .FM:
		// Likewise an FM pair: as a layer it is its carrier, a sine.
		return math.sin(2 * math.PI * ph)
	}
	return 0
}

// The OPL2's waves, at a phase in cycles.
@(private = "file")
fm_shape :: #force_inline proc(w: Fm_Wave, ph: f32) -> f32 {
	p := fract(ph)
	s := math.sin(2 * math.PI * p)
	switch w {
	case .Sine:
		return s
	case .Half:
		return s if p < 0.5 else 0
	case .Abs:
		return abs(s)
	case .Quarter:
		return abs(s) if (p < 0.25 || (p >= 0.5 && p < 0.75)) else 0
	}
	return s
}

// One FM voice's samples, for the tests: `seconds` of a note at `hz`.
@(private)
fm_for_test :: proc(ins: ^Instrument, note: f32, seconds: f32, vel: f32 = 100) -> []f32 {
	out := make([]f32, int(seconds * f32(SAMPLE_RATE)))
	seg := [1]Voice_Seg{{note = note, len = seconds, vel = vel, vel_end = vel, amp = 1, amp_end = 1}}
	render_voice(out, 0, ins, seg[:], seconds, {seed = 7})
	return out
}

// The NES noise channel: a 15-bit shift register, stepped 8 times a cycle of
// the note. Tap 1 is hiss; tap 6 (the "short" mode) repeats every 93 steps
// and turns metallic.
@(private = "file")
lfsr_clock :: #force_inline proc(clock: ^f32, dt: f32, r: ^u32, metallic: bool) -> f32 {
	out := f32(1) if (r^ & 1) == 1 else -1
	clock^ += dt * 8
	for clock^ >= 1 {
		clock^ -= 1
		tap: u32 = 6 if metallic else 1
		bit := (r^ ~ (r^ >> tap)) & 1
		r^ = (r^ >> 1) | (bit << 14)
		out = 1 if (r^ & 1) == 1 else -1
	}
	return out
}

// A shift register's start: anywhere but all zeros, which never moves.
@(private = "file")
lfsr_seed :: proc(rng: ^u32) -> u32 {
	return (next_u32(rng) & 0x7FFF) | 1
}

// --- Seeds ---

@(private = "file")
next_u32 :: #force_inline proc(state: ^u32) -> u32 {
	state^ ~= state^ << 13
	state^ ~= state^ >> 17
	state^ ~= state^ << 5
	return state^
}

@(private = "file")
white :: #force_inline proc(state: ^u32) -> f32 {
	return f32(next_u32(state)) / f32(max(u32)) * 2 - 1
}

@(private = "file")
rand01 :: #force_inline proc(state: ^u32) -> f32 {
	return f32(next_u32(state) >> 8) / f32(1 << 24)
}

// A voice's seed, from where it is in the song.
@(private)
voice_seed :: proc(a, b, c: u32) -> u32 {
	h := a * 0x9E3779B1 ~ (b + 0x7F4A7C15) * 0x85EBCA77 ~ c * 0xC2B2AE3D
	return seed_scramble(h)
}

@(private = "file")
seed_scramble :: proc(x: u32) -> u32 {
	h := x
	h ~= h >> 16
	h *= 0x7FEB352D
	h ~= h >> 15
	h *= 0x846CA68B
	h ~= h >> 16
	return h if h != 0 else 0x6D2B79F5
}

// A band-limited saw at one phase, so the tests can compare it against a
// naive ramp. Not used by anything that makes noise.
@(private)
osc_for_test :: proc(phase, dt: f32) -> f32 {
	return osc(.Saw, phase, dt, 0.5, 0)
}
