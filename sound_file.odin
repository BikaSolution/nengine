package nengine

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

// Sound files: a sound effect described in text, instead of built in code.
//
// A .song is a grid of notes. A .sound is one noise — a footstep, a creak, a
// drip — written as a handful of layers stacked on each other:
//
//     sound step
//     length 0.09
//     norm 0.45
//     lowpass 0.3
//     layer sine from=90 to=54 decay=50 vol=0.7
//     layer noise decay=150 vol=0.3
//
// Everything a layer can do is one of four things: a shape (sine, square,
// saw, noise, bell), a pitch that may move, a volume that may move, and a
// filter. That's enough for footsteps, hinges, taps, engines and cats.
//
// The whole sound can also have a room and a loudness (master.odin):
//
//     reverb 0.6 0.4 0.3   # size damp mix [predelay] [width]; none if not said
//     level -20            # LUFS, instead of `norm`'s peak
//
// A sound renders at 22050 Hz, mono, which is what every .sound was
// designed and tuned at: `rate 44100` asks for the full band (a hiss then
// has an octave of air above 11 kHz it never had, so it is a choice, not a
// default). The filters' numbers (`lp`, `hp`, `lowpass`) are one-pole
// coefficients as tuned at 22050 Hz; at any rate they mean the same cutoff.
//
// The game never loads one of these. `just bake` renders them to .wav and
// the game loads the .wav, because rendering sound at startup is a cost the
// player pays for nothing.

Sound_Wave :: enum {
	Sine,
	Square,
	Saw,
	Noise,
	Bell, // struck metal: partials that aren't whole multiples
}

// One voice in a sound. Only `wave` and `vol` are required.
Sound_Layer :: struct {
	wave:       Sound_Wave,
	at:         f32, // starts this many seconds in
	dur:        f32, // 0 = to the end of the sound

	// Pitch. `freq` alone is a steady note; with `to` it slides. `curve`
	// makes the slide exponential (fast at first), which is what a drip does.
	freq:       f32,
	to:         f32,
	curve_exp:  bool,
	rate:       f32, // how fast the exponential slide settles
	bend:       f32, // added to the pitch, shaped like a hill over `dur`
	vib:        f32, // pitch wobble, in Hz either side
	vib_hz:     f32,

	partials:   [8]f32, // harmonic mix: 1,0.5,0.3 is fundamental plus two
	n_partials: int,

	// Volume.
	vol:        f32,
	attack:     f32, // seconds to fade in
	attack_pow: f32, // bends the fade-in: 2 starts slower and arrives faster
	decay:      f32, // exponential fall-off per second
	fade:       bool, // straight line down to nothing across `dur`
	hump:       f32, // fade up and down again; the number is the curve's shape
	trem:       f32, // volume wobble, 0..1
	trem_hz:    f32,
	trem_pow:   f32, // sharpens the wobble into pulses. 1 = a plain wave
	trem2:      f32, // a second, usually slower wobble on top: breathing
	trem2_hz:   f32,

	sparse:     f32, // noise only: the fraction that gets through, for crackle
	lp:         f32, // one-pole low pass, 0 = off, 1 = no filtering
	lp_to:      f32, // filter opens (or shuts) across `dur`
	hp:         f32, // one-pole high pass: keeps the fizz, drops the rumble
}

Sound :: struct {
	name:    string,
	length:  f32,
	norm:    f32,  // loudest sample after normalising. 0 = leave it alone
	lowpass: f32,  // muffle the finished sound. 0 or 1 = don't
	loop:    bool, // a layer running off the end wraps to the start, so it joins
	layers:  [dynamic]Sound_Layer,
	// LUFS to master to, instead of `norm`; LEVEL_NONE (the default) keeps
	// `norm`, because a sound's level against the game's other sounds is
	// part of its design: a footstep is not as loud as a rifle.
	level:   f32,
	reverb:  Reverb, // mix 0 (the default) is dry
	rate:    int,    // frames a second; SOUND_RATE unless it says
}

// What a .sound renders at unless it says `rate`.
SOUND_RATE :: 22050

sound_destroy :: proc(s: ^Sound) {
	delete(s.layers)
	delete(s.name)
	s^ = {}
}

sound_new :: proc(name: string, length: f32) -> Sound {
	return {name = strings.clone(name), length = length, norm = 0.5, lowpass = 1, level = LEVEL_NONE, rate = SOUND_RATE}
}

// --- File ---

load_sound :: proc(path: string) -> (s: Sound, ok: bool) {
	text := read_data_file(path) or_return
	s.length = 1
	s.norm = 0.5
	s.lowpass = 1
	s.level = LEVEL_NONE
	s.rate = SOUND_RATE

	for raw in data_lines(text) {
		l := parse_line(raw)
		switch l.key {
		case "sound":
			if len(l.words) > 0 do s.name = strings.clone(l.words[0])
		case "length":
			if len(l.words) > 0 do s.length = word_f32(l.words[0], s.length)
		case "norm":
			if len(l.words) > 0 do s.norm = word_f32(l.words[0], s.norm)
		case "lowpass":
			if len(l.words) > 0 do s.lowpass = word_f32(l.words[0], s.lowpass)
		case "loop":
			s.loop = true
		case "rate":
			if len(l.words) > 0 do s.rate = clamp(int(word_f32(l.words[0], SOUND_RATE)), 8000, 96000)
		case "level":
			if len(l.words) > 0 do s.level = LEVEL_NONE if l.words[0] == "none" else word_f32(l.words[0], -20)
		case "reverb":
			s.reverb = {}
			if len(l.words) > 0 && l.words[0] != "none" && l.words[0] != "off" {
				w := l.words
				s.reverb = DEFAULT_REVERB
				s.reverb.size = clamp(word_f32(w[0], s.reverb.size), 0, 1)
				if len(w) > 1 do s.reverb.damp = clamp(word_f32(w[1], s.reverb.damp), 0, 1)
				if len(w) > 2 do s.reverb.mix = max(word_f32(w[2], s.reverb.mix), 0)
				if len(w) > 3 do s.reverb.predelay = clamp(word_f32(w[3], s.reverb.predelay), 0, 0.5)
				if len(w) > 4 do s.reverb.width = clamp(word_f32(w[4], s.reverb.width), 0, 1)
			}
		case "layer":
			append(&s.layers, parse_layer(l))
		}
	}
	return s, s.length > 0
}

@(private = "file")
parse_layer :: proc(l: Line) -> (v: Sound_Layer) {
	v.wave = .Sine
	if len(l.words) > 0 {
		switch l.words[0] {
		case "sine":   v.wave = .Sine
		case "square": v.wave = .Square
		case "saw":    v.wave = .Saw
		case "noise":  v.wave = .Noise
		case "bell":   v.wave = .Bell
		}
	}
	v.at = field_f32(l, "at")
	v.dur = field_f32(l, "dur")
	v.vol = field_f32(l, "vol", 1)
	v.attack = field_f32(l, "attack")
	v.attack_pow = field_f32(l, "attack_pow", 1)
	v.decay = field_f32(l, "decay")
	v.fade = field_bool(l, "fade")
	v.hump = field_f32(l, "hump")
	v.trem = field_f32(l, "trem")
	v.trem_hz = field_f32(l, "trem_hz")
	v.trem_pow = field_f32(l, "trem_pow", 1)
	v.trem2 = field_f32(l, "trem2")
	v.trem2_hz = field_f32(l, "trem2_hz")
	v.hp = field_f32(l, "hp")
	v.sparse = field_f32(l, "sparse")
	v.lp = field_f32(l, "lp")
	v.lp_to = field_f32(l, "lp_to", v.lp)
	v.bend = field_f32(l, "bend")
	v.vib = field_f32(l, "vib")
	v.vib_hz = field_f32(l, "vib_hz")
	v.rate = field_f32(l, "rate", 20)
	if curve, has := field(l, "curve"); has do v.curve_exp = curve == "exp"

	// Pitch may be given as a number or as a note: freq=440 or freq=A4.
	v.freq = pitch(l, "freq", pitch(l, "from", 0))
	v.to = pitch(l, "to", 0)

	v.partials[0] = 1
	v.n_partials = 1
	if list, has := field(l, "partials"); has {
		v.n_partials = 0
		for part in strings.split(list, ",", context.temp_allocator) {
			if v.n_partials >= len(v.partials) do break
			v.partials[v.n_partials] = word_f32(strings.trim_space(part), 0)
			v.n_partials += 1
		}
		if v.n_partials == 0 {
			v.partials[0] = 1
			v.n_partials = 1
		}
	}
	return
}

// A frequency written either as a number (440) or as a note (A4).
@(private = "file")
pitch :: proc(l: Line, name: string, fallback: f32) -> f32 {
	s, has := field(l, name)
	if !has do return fallback
	if v, good := strconv.parse_f32(s); good do return v
	if n := parse_note(s); n >= 0 do return note_hz(n)
	return fallback
}

@(private = "file")
word_f32 :: proc(s: string, fallback: f32) -> f32 {
	if v, ok := strconv.parse_f32(s); ok do return v
	return fallback
}

save_sound :: proc(s: ^Sound, path: string) -> bool {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "# nengine sound\nsound %v\nlength %v\n", s.name, s.length)
	if s.norm != 0 do fmt.sbprintf(&b, "norm %v\n", s.norm)
	if s.lowpass != 0 && s.lowpass != 1 do fmt.sbprintf(&b, "lowpass %v\n", s.lowpass)
	if s.loop do strings.write_string(&b, "loop\n")
	if s.rate != SOUND_RATE && s.rate != 0 do fmt.sbprintf(&b, "rate %v\n", s.rate)
	if s.level != LEVEL_NONE do fmt.sbprintf(&b, "level %v\n", s.level)
	if s.reverb.mix > 0 {
		r := s.reverb
		fmt.sbprintf(&b, "reverb %v %v %v %v %v\n", r.size, r.damp, r.mix, r.predelay, r.width)
	}

	names := [Sound_Wave]string{.Sine = "sine", .Square = "square", .Saw = "saw", .Noise = "noise", .Bell = "bell"}
	for v in s.layers {
		fmt.sbprintf(&b, "layer %v", names[v.wave])
		if v.at != 0 do fmt.sbprintf(&b, " at=%v", v.at)
		if v.dur != 0 do fmt.sbprintf(&b, " dur=%v", v.dur)
		if v.freq != 0 do fmt.sbprintf(&b, " freq=%v", v.freq)
		if v.to != 0 do fmt.sbprintf(&b, " to=%v", v.to)
		if v.curve_exp do fmt.sbprintf(&b, " curve=exp rate=%v", v.rate)
		if v.bend != 0 do fmt.sbprintf(&b, " bend=%v", v.bend)
		if v.vib != 0 do fmt.sbprintf(&b, " vib=%v vib_hz=%v", v.vib, v.vib_hz)
		if v.n_partials > 1 {
			strings.write_string(&b, " partials=")
			for i in 0 ..< v.n_partials {
				if i > 0 do strings.write_byte(&b, ',')
				fmt.sbprintf(&b, "%v", v.partials[i])
			}
		}
		if v.attack != 0 {
			fmt.sbprintf(&b, " attack=%v", v.attack)
			if v.attack_pow != 1 do fmt.sbprintf(&b, " attack_pow=%v", v.attack_pow)
		}
		if v.decay != 0 do fmt.sbprintf(&b, " decay=%v", v.decay)
		if v.fade do strings.write_string(&b, " fade=true")
		if v.hump != 0 do fmt.sbprintf(&b, " hump=%v", v.hump)
		if v.trem != 0 {
			fmt.sbprintf(&b, " trem=%v trem_hz=%v", v.trem, v.trem_hz)
			if v.trem_pow != 1 do fmt.sbprintf(&b, " trem_pow=%v", v.trem_pow)
		}
		if v.trem2 != 0 do fmt.sbprintf(&b, " trem2=%v trem2_hz=%v", v.trem2, v.trem2_hz)
		if v.hp != 0 do fmt.sbprintf(&b, " hp=%v", v.hp)
		if v.sparse != 0 do fmt.sbprintf(&b, " sparse=%v", v.sparse)
		if v.lp != 0 {
			fmt.sbprintf(&b, " lp=%v", v.lp)
			if v.lp_to != v.lp do fmt.sbprintf(&b, " lp_to=%v", v.lp_to)
		}
		fmt.sbprintf(&b, " vol=%v\n", v.vol)
	}
	return write_data_file(path, strings.to_string(b))
}

// --- Rendering ---

// Turns a sound into mono samples at its rate. Deterministic: the same
// file renders the same noise every time, so a baked .wav never changes
// unless the .sound does.
render_sound :: proc(s: ^Sound, allocator := context.allocator) -> Audio {
	rate := s.rate if s.rate > 0 else SOUND_RATE
	RATE := f32(rate)
	// White noise at a higher rate spreads the same power over more hertz,
	// so a filtered hiss would come out quieter. This puts it back.
	noise_scale := math.sqrt(RATE / f32(REF_RATE))
	total := int(s.length * RATE)
	if total <= 0 do return {channels = 1, rate = rate}
	out := make([]f32, total, allocator)

	noise_state: u32 = 2463534242
	rand :: proc(state: ^u32) -> f32 {
		state^ ~= state^ << 13
		state^ ~= state^ >> 17
		state^ ~= state^ << 5
		return f32(state^) / f32(max(u32)) * 2 - 1
	}

	for v in s.layers {
		dur := v.dur if v.dur > 0 else s.length - v.at
		if dur <= 0 do continue
		start := int(v.at * RATE)
		count := int(dur * RATE)
		// The phase is added up in f64: in f32 the error piles up over a
		// loop's length, and a tone the maths says ends on a whole cycle does
		// not, and the seam clicks.
		phase: f64
		filtered: f32
		// The coefficients at this rate; a filter that sweeps works its out as it goes.
		hp_coef := rate_coef(clamp(v.hp, 0, 1), rate)
		lp_coef := rate_coef(clamp(v.lp, 0, 1), rate)
		lp_moves := v.lp_to != v.lp
		sparked := true
		spark_at := -1
		// A looping sound's filters start where they will end: the layer's
		// last half second is run through them first and thrown away, so the
		// join is not a filter waking up from silence.
		warm := 0
		if s.loop && (v.hp > 0 || v.lp > 0) do warm = min(count, rate / 2)

		for step in 0 ..< warm + count {
			j := step - warm if step >= warm else count - warm + step
			t := f32(j) / RATE
			u := t / dur // 0..1 through the layer

			// --- pitch ---
			f := v.freq
			if v.to != 0 && v.freq != 0 {
				if v.curve_exp {
					f = v.to + (v.freq - v.to) * math.exp(-t * v.rate)
				} else {
					f = v.freq + (v.to - v.freq) * u
				}
			}
			if v.bend != 0 do f += v.bend * math.sin(math.PI * u)
			if v.vib != 0 do f += v.vib * math.sin(2 * math.PI * v.vib_hz * t)
			phase += f64(f) / f64(rate)
			frac := f32(phase - math.floor(phase))

			// --- shape ---
			value: f32
			switch v.wave {
			case .Sine:
				for p in 0 ..< v.n_partials {
					value += v.partials[p] * f32(math.sin(2 * math.PI * phase * f64(p + 1)))
				}
			case .Square:
				value = 1 if frac < 0.5 else -1
			case .Saw:
				value = 2 * frac - 1
			case .Noise:
				value = rand(&noise_state)
				if rate != REF_RATE do value *= noise_scale
				// Crackle: let only some of the noise through, in sparks. Each
				// is as long as one sample was at 22050 Hz, so the crackle is
				// the same crackle at any rate.
				if v.sparse > 0 {
					if at := j * REF_RATE / rate; at != spark_at {
						spark_at = at
						sparked = (rand(&noise_state) + 1) * 0.5 <= v.sparse
					}
					if !sparked do value = 0
				}
			case .Bell:
				for ratio, k in ([6]f32{0.5, 1, 1.19, 1.56, 2, 2.74}) {
					value += f32(math.sin(2 * math.PI * phase * f64(ratio))) * math.exp(-t * (1 + f32(k) * 0.6))
				}
			}

			// --- volume ---
			env := v.vol
			if v.attack > 0 {
				ramp := min(t / v.attack, 1)
				env *= ramp if v.attack_pow == 1 else math.pow(ramp, v.attack_pow)
			}
			if v.decay > 0 do env *= math.exp(-t * v.decay)
			if v.fade do env *= max(1 - u, 0)
			if v.hump > 0 do env *= math.pow(max(math.sin(math.PI * u), 0), v.hump)
			if v.trem > 0 {
				wobble := (1 - v.trem) + v.trem * math.sin(2 * math.PI * v.trem_hz * t)
				if v.trem_pow != 1 do wobble = math.pow(max(wobble, 0), v.trem_pow)
				env *= wobble
			}
			if v.trem2 > 0 {
				env *= (1 - v.trem2) + v.trem2 * math.sin(2 * math.PI * v.trem2_hz * t)
			}
			value *= env

			// --- filter ---
			if v.hp > 0 {
				filtered += hp_coef * (value - filtered)
				value -= filtered // what the low pass kept is what we throw away
			} else if v.lp > 0 {
				c := lp_coef
				if lp_moves do c = rate_coef(clamp(v.lp + (v.lp_to - v.lp) * u, 0, 1), rate)
				filtered += c * (value - filtered)
				value = filtered
			}

			if step < warm do continue // only settling the filter
			at := start + j
			if s.loop {
				at %= total // a tail that runs off the end joins the start
			} else if at >= total {
				break
			}
			out[at] += value
		}
	}

	if s.lowpass > 0 && s.lowpass < 1 {
		y: f32
		c := rate_coef(s.lowpass, rate)
		// A loop: settle the filter on its own tail first (see the layers).
		if s.loop do for value in out[max(len(out) - rate / 2, 0):] do y += c * (value - y)
		for &value in out {
			y += c * (value - y)
			value = y
		}
	}
	if s.reverb.mix > 0 {
		wet := reverb_render(out, s.reverb, s.loop, rate)
		defer delete(wet)
		for &value, i in out do value += 0.5 * (wet[2 * i] + wet[2 * i + 1])
	}
	if s.level != LEVEL_NONE {
		master(out, 1, s.level, DEFAULT_CEILING, s.loop, rate)
	} else if s.norm > 0 {
		loudest: f32
		for value in out do loudest = max(loudest, abs(value))
		if loudest > 0 do for &value in out do value *= s.norm / loudest
	}
	return {out, 1, rate}
}
