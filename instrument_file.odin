package nengine

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

// Instruments, as files.
//
// A voice used to be one of eleven names baked into the synth, each with its
// own hand-written maths. That meant a new sound needed a rebuild, and the
// eleven had nothing in common you could learn once.
//
// So an instrument is data now. A handful of oscillators — pulse (with a duty
// cycle), triangle, saw, sine, noise — and everything that makes a cello not a violin
// happens AROUND the oscillator: how fast it speaks, whether it wavers, a
// second oscillator mixed in, how dark it is. That is the whole of chip music,
// and it is about twenty numbers:
//
//     instrument harp
//     name "Harp"
//     family strings
//     range C1 G7             # sounding, low to high: names or MIDI numbers
//     wave triangle
//     layer pulse 0.15 12     # second oscillator: wave, mix 0..1, semitones up
//     envelope 0.002 1.6 0 0.4  # attack decay sustain release (sustain 0 = plucked)
//     vibrato 0 0 0           # rate Hz, depth semitones, delay seconds
//     sweep 0 0               # starts this many semitones off, glides home
//     breath 0                # white noise mixed in
//     tone 0.7                # low-pass: 1 is open, lower is darker
//     gain 0.7
//     color 246 190 120       # how it looks in the music editor
//     end
//
// Every line but the first is optional. `based_on` starts from another
// instrument, from any file, in any order — and a block whose key already
// exists changes only the lines it gives, so a game can drop
// assets/instruments/tweaks.inst next to the engine's and darken one violin
// without copying the rest of it.
//
// The engine ships nengine/instruments/. A game's own folder is loaded after,
// so it wins. See instrument_set_load.

Wave :: enum u8 {
	Pulse,        // square, with a duty cycle: 0.5 hollow, 0.25 bright, 0.125 nasal
	Triangle,     // a clean triangle: soft, round, odd harmonics falling fast
	Saw,          // buzzy: strings and brass
	Sine,         // pure
	Noise,        // the NES shift register, clocked from the pitch: drums
	String,       // a plucked string, properly modelled. See synth.odin.
	NES_Triangle, // the NES's 16-step staircase, which buzzes: the chip bass
	White,        // white noise, whatever the pitch: cymbals, shakers, breath
	FM,           // a two-operator FM pair, as an AdLib's OPL2 has. See synth.odin.
}

WAVE_NAMES := [Wave]string {
	.Pulse = "pulse", .Triangle = "triangle", .Saw = "saw", .Sine = "sine",
	.Noise = "noise", .String = "string", .NES_Triangle = "nes_triangle", .White = "white",
	.FM = "fm",
}

// The OPL2's four waveforms, for an FM pair's modulator and carrier: a sine,
// its top half only, both halves upward, and the rising quarters only.
Fm_Wave :: enum u8 {
	Sine,
	Half,
	Abs,
	Quarter,
}

FM_WAVE_NAMES := [Fm_Wave]string{.Sine = "sine", .Half = "half", .Abs = "abs", .Quarter = "quarter"}

// Attack, decay and release in seconds; sustain a level (0 = struck).
Env :: struct {
	attack, decay, sustain, release: f32,
}

Instrument :: struct {
	key:          string, // what a track asks for
	name:         string, // what the editor shows
	family:       string, // just for grouping the picker
	lo, hi:       int,    // sounding MIDI range; the editor shades the rest
	wave:         Wave,
	duty:         f32,
	// A second oscillator, mixed in at `mix2`, `semis2` semitones above the
	// first. An organ is the same pulse an octave up; a horn is a pulse
	// softened with a triangle.
	wave2:        Wave,
	mix2:         f32,
	semis2:       f32,
	// Seconds, except sustain, which is a level. Sustain 0 means struck or
	// plucked: it decays over `decay` however long the note is written for.
	attack:       f32,
	decay:        f32,
	sustain:      f32,
	release:      f32,
	vib_rate:     f32, // Hz
	vib_depth:    f32, // semitones
	vib_delay:    f32, // seconds before it comes in
	sweep:        f32, // semitones off at the start
	sweep_time:   f32, // and how fast it glides home
	breath:       f32, // white noise mixed in
	tone:         f32, // one-pole low-pass: 1 open, lower darker
	metallic:     bool, // noise only: the NES "short" mode, pitched and clangy
	gain:         f32,
	pan:          f32, // -1 left .. 1 right, added to the track's
	// A third oscillator, like the second.
	wave3:        Wave,
	mix3:         f32,
	semis3:       f32,
	// The layers' own envelopes. Without one a layer follows the main
	// envelope; with one a celesta's bright overtone can die before its
	// fundamental, as a real one does.
	env2:         Env,
	has_env2:     bool,
	env3:         Env,
	has_env3:     bool,
	// The filter. With `filter` set it is a two-pole low-pass at that many
	// hertz, with resonance; without, `tone` is the one-pole it always was.
	// Either way the cutoff can follow the key, open with an envelope and
	// brighten with velocity.
	filter_hz:    f32,  // 0 = no two-pole; `tone` filters
	resonance:    f32,  // 0..1
	keytrack:     f32,  // 0 = fixed in hertz, 1 = follows the pitch (from C4)
	fenv:         [3]f32, // filter envelope: attack s, decay s, octaves at its peak
	vel_tone:     f32,  // octaves brighter per 100 of velocity (darker below 100)
	highpass:     f32,  // Hz: takes the bottom off, for cymbals and shakers. 0 = off
	// A short burst of noise as the note starts: a bow's scrape, a reed's
	// chiff, a mallet's knock.
	click:        [3]f32, // level, decay seconds, tone (one-pole, 0 = open)
	// Karplus-Strong: how fast the highs die (0.5 is the classic string) and
	// how bright the pluck is (1 = a full-band noise burst).
	string_damp:  f32,
	string_bright: f32,
	// A struck note's damper: once its written length is over it is gone
	// (60 dB down) in this many seconds. 0 is no damper: it rings its decay.
	damp:         f32,
	// Tremolo: the level dips by `trem_depth` dB and comes back `trem_rate`
	// times a second, on the song's clock (so every note of it shares one
	// motor), arriving `trem_delay` seconds into a note.
	trem_rate:    f32,
	trem_depth:   f32,
	trem_delay:   f32,
	// `wave fm`: the modulator at `fm_ratio` times the note, `fm_index` its
	// peak depth in radians, with its own envelope if it has one (otherwise
	// it follows the main one: brighter as louder).
	fm_ratio:     f32,
	fm_index:     f32,
	fm_env:       Env,
	has_fm_env:   bool,
	fm_fb:        f32,        // the modulator feeding itself: 0..1 (1 is about noise)
	fm_wave:      [2]Fm_Wave, // modulator, carrier
	fm_keyscale:  f32,        // the index falls this many octaves' worth per octave above C4
	vel_index:    f32,        // velocity scales the index: 1 doubles it at 200, halves it at 50
	// A soft saturation, 0..1: a small valve amp starting to break up.
	drive:        f32,
	color:        [4]u8,
	source:       string, // the file it came from, for the editor to show
}

// What an instrument that says nothing about itself sounds like.
DEFAULT_INSTRUMENT :: Instrument {
	family  = "chip",
	lo      = 24,
	hi      = 108,
	wave    = .Pulse,
	duty    = 0.5,
	attack  = 0.005,
	decay   = 0.1,
	sustain = 0.8,
	release = 0.05,
	tone    = 1,
	gain    = 0.5,
	color   = {200, 200, 200, 255},
	string_damp   = 0.5,
	string_bright = DEFAULT_STRING_BRIGHT,
}

// A pluck's brightness when the instrument says nothing: dark enough that
// the first millisecond is not a spike of noise louder than the note.
DEFAULT_STRING_BRIGHT :: f32(0.6)

// Every instrument the tools and the baker know about.
Instrument_Set :: struct {
	list:    [dynamic]Instrument,
	strings: [dynamic]string, // everything the set owns, so destroy can free it
}

instrument_set_destroy :: proc(set: ^Instrument_Set) {
	for s in set.strings do delete(s)
	delete(set.strings)
	delete(set.list)
	set^ = {}
}

instrument_find :: proc(set: ^Instrument_Set, key: string) -> (^Instrument, bool) {
	if set != nil {
		for &i in set.list do if i.key == key do return &i, true
	}
	return nil, false
}

// The instrument a track plays. Never nil, so a song naming something that
// isn't there still makes a sound instead of silence you have to debug.
instrument_get :: proc(set: ^Instrument_Set, key: string) -> Instrument {
	if i, ok := instrument_find(set, key); ok do return i^
	fallback := DEFAULT_INSTRUMENT
	fallback.key, fallback.name = key, key
	return fallback
}

// Add one, or replace the one with the same key in place.
instrument_put :: proc(set: ^Instrument_Set, ins: Instrument) {
	for &e in set.list {
		if e.key == ins.key {
			e = ins
			return
		}
	}
	append(&set.list, ins)
}

// --- Files ---

INST_EXT :: ".inst"

// Load every .inst in a folder, in name order, so a file that sorts later can
// change what an earlier one said. A name starting with "_" is skipped, which
// is the easy way to switch one off.
instrument_set_load :: proc(set: ^Instrument_Set, dir: string) -> int {
	handle, err := os.open(dir)
	if err != nil do return 0
	defer os.close(handle)
	files, read_err := os.read_dir(handle, -1, context.temp_allocator)
	if read_err != nil do return 0
	slice.sort_by(files, proc(a, b: os.File_Info) -> bool { return a.name < b.name })

	count := 0
	for f in files {
		if f.type == .Directory || !strings.has_suffix(f.name, INST_EXT) do continue
		if strings.has_prefix(f.name, "_") do continue
		path := fmt.tprintf("%v/%v", dir, f.name)
		text, ok := read_data_file(path)
		if !ok do continue
		count += parse_instruments(set, text, f.name)
	}
	return count
}

// Reads `instrument` (or `define_instrument`) blocks out of any text — an
// .inst file, or a .song that carries its own instruments. Returns how many
// it found.
//
// `base` is what `based_on` falls back to when the name isn't in `set` yet.
// A song's own blocks are read into a set of their own, so this is how
// `based_on violin` inside a .song reaches the shared orchestra.
parse_instruments :: proc(set: ^Instrument_Set, text: string, source: string = "", base: ^Instrument_Set = nil) -> int {
	count := 0
	in_block := false
	lines := make([dynamic]string, context.temp_allocator)
	key := ""

	finish :: proc(set: ^Instrument_Set, key: string, lines: []string, source: string, base: ^Instrument_Set) {
		ins := build_instrument(set, key, lines, source, base)
		instrument_put(set, ins)
	}

	for raw in data_lines(text) {
		l := parse_line(raw)
		switch l.key {
		case "instrument", "define_instrument":
			// A bare `instrument name` inside a song is a track saying what
			// it plays, not a definition. Only a block that reaches `end`
			// counts, so those are harmless: they just never finish.
			if in_block do finish(set, key, lines[:], source, base)
			in_block = len(l.words) > 0
			if in_block do key = l.words[0]
			clear(&lines)
		case "end":
			if in_block {
				finish(set, key, lines[:], source, base)
				count += 1
			}
			in_block = false
			clear(&lines)
		case:
			if in_block do append(&lines, raw)
		}
	}
	return count
}

// One block's lines, applied on top of a base. The base is `based_on` if it
// says one, otherwise whatever already has this key (so a later file changes
// only what it mentions), otherwise a plain square wave.
@(private = "file")
build_instrument :: proc(set: ^Instrument_Set, key: string, lines: []string, source: string, base: ^Instrument_Set) -> Instrument {
	// This set first, then whatever it was given to fall back on.
	look :: proc(set, base: ^Instrument_Set, key: string) -> (^Instrument, bool) {
		if found, ok := instrument_find(set, key); ok do return found, true
		return instrument_find(base, key)
	}

	ins := DEFAULT_INSTRUMENT
	based := false
	for raw in lines {
		l := parse_line(raw)
		if l.key == "based_on" && len(l.words) > 0 {
			if from, ok := look(set, base, l.words[0]); ok {
				ins = from^
				based = true
			}
		}
	}
	if !based {
		if same, ok := look(set, base, key); ok do ins = same^
	}
	ins.key = own(set, key)
	ins.source = own(set, source)
	if ins.name == "" || ins.name == DEFAULT_INSTRUMENT.name do ins.name = ins.key

	for raw in lines {
		l := parse_line(raw)
		w := l.words
		switch l.key {
		case "based_on":
		case "name":     if len(w) > 0 do ins.name = own(set, unquote(line_tail(raw, 1)))
		case "family":   if len(w) > 0 do ins.family = own(set, w[0])
		case "range":
			if len(w) >= 2 {
				lo, hi := range_value(w[0]), range_value(w[1])
				if lo >= 0 && hi >= lo do ins.lo, ins.hi = lo, hi
			}
		case "wave":
			if len(w) > 0 do if v, ok := wave_from(w[0]); ok do ins.wave = v
			if len(w) > 0 && w[0] == "fm" {
				// `wave fm <ratio> <index>`
				ins.fm_ratio = max(num(w[1], 1), 0.001) if len(w) > 1 else max(ins.fm_ratio, 1)
				ins.fm_index = max(num(w[2], 1), 0) if len(w) > 2 else ins.fm_index
			} else if len(w) > 1 {
				ins.duty = num(w[1], ins.duty)
			}
		case "fm_envelope":
			ins.fm_env, ins.has_fm_env = env_from(w, ins.fm_env)
		case "fm_feedback": if len(w) > 0 do ins.fm_fb = clamp(num(w[0], 0), 0, 1)
		case "fm_wave":
			if len(w) > 0 do ins.fm_wave[0] = fm_wave_from(w[0], ins.fm_wave[0])
			if len(w) > 1 do ins.fm_wave[1] = fm_wave_from(w[1], ins.fm_wave[1])
		case "fm_keyscale": if len(w) > 0 do ins.fm_keyscale = clamp(num(w[0], 0), 0, 2)
		case "vel_index":   if len(w) > 0 do ins.vel_index = clamp(num(w[0], 0), 0, 2)
		case "damp":
			if len(w) > 0 do ins.damp = 0 if w[0] == "none" || w[0] == "off" else max(num(w[0], 0), 0)
		case "tremolo":
			if len(w) > 0 && (w[0] == "none" || w[0] == "off") {
				ins.trem_rate, ins.trem_depth, ins.trem_delay = 0, 0, 0
			} else if len(w) >= 2 {
				ins.trem_rate, ins.trem_depth = max(num(w[0], 0), 0), clamp(num(w[1], 0), 0, 60)
				ins.trem_delay = max(num(w[2], 0), 0) if len(w) > 2 else 0
			}
		case "drive":    if len(w) > 0 do ins.drive = clamp(num(w[0], 0), 0, 1)
		case "layer":
			if len(w) > 0 && w[0] == "none" {
				ins.mix2 = 0
			} else if len(w) >= 2 {
				if v, ok := wave_from(w[0]); ok do ins.wave2 = v
				ins.mix2 = num(w[1], ins.mix2)
				ins.semis2 = num(w[2], 0) if len(w) > 2 else 0
			}
		case "layer3":
			if len(w) > 0 && w[0] == "none" {
				ins.mix3 = 0
			} else if len(w) >= 2 {
				if v, ok := wave_from(w[0]); ok do ins.wave3 = v
				ins.mix3 = num(w[1], ins.mix3)
				ins.semis3 = num(w[2], 0) if len(w) > 2 else 0
			}
		case "envelope":
			if len(w) >= 4 {
				ins.attack, ins.decay = num(w[0], ins.attack), num(w[1], ins.decay)
				ins.sustain, ins.release = num(w[2], ins.sustain), num(w[3], ins.release)
			}
		case "layer_envelope":
			ins.env2, ins.has_env2 = env_from(w, ins.env2)
		case "layer3_envelope":
			ins.env3, ins.has_env3 = env_from(w, ins.env3)
		case "filter":
			if len(w) > 0 && w[0] == "none" {
				ins.filter_hz, ins.resonance = 0, 0
			} else if len(w) > 0 {
				ins.filter_hz = max(num(w[0], ins.filter_hz), 0)
				if len(w) > 1 do ins.resonance = clamp(num(w[1], 0), 0, 1)
			}
		case "keytrack":   if len(w) > 0 do ins.keytrack = num(w[0], 0)
		case "filter_env":
			if len(w) > 0 && w[0] == "none" do ins.fenv = {}
			else if len(w) >= 3 do ins.fenv = {num(w[0], 0), num(w[1], 0), num(w[2], 0)}
		case "vel_tone":   if len(w) > 0 do ins.vel_tone = num(w[0], 0)
		case "highpass":   if len(w) > 0 do ins.highpass = max(num(w[0], 0), 0)
		case "click":
			if len(w) > 0 && w[0] == "none" do ins.click = {}
			else if len(w) >= 2 do ins.click = {num(w[0], 0), num(w[1], 0), num(w[2], 0) if len(w) > 2 else 0}
		case "string":
			if len(w) > 0 do ins.string_damp = clamp(num(w[0], 0.5), 0, 0.95)
			if len(w) > 1 do ins.string_bright = clamp(num(w[1], DEFAULT_STRING_BRIGHT), 0.01, 1)
		case "vibrato":
			if len(w) >= 2 {
				ins.vib_rate, ins.vib_depth = num(w[0], 0), num(w[1], 0)
				ins.vib_delay = num(w[2], 0) if len(w) > 2 else 0
			}
		case "sweep":
			if len(w) >= 2 do ins.sweep, ins.sweep_time = num(w[0], 0), num(w[1], 0)
		case "breath":   if len(w) > 0 do ins.breath = num(w[0], 0)
		case "tone":     if len(w) > 0 do ins.tone = num(w[0], 1)
		case "metallic": if len(w) > 0 do ins.metallic = w[0] == "1" || w[0] == "true" || w[0] == "yes"
		case "gain":     if len(w) > 0 do ins.gain = num(w[0], ins.gain)
		case "pan":      if len(w) > 0 do ins.pan = num(w[0], 0)
		case "color", "colour":
			if len(w) >= 3 {
				ins.color = {u8(num(w[0], 200)), u8(num(w[1], 200)), u8(num(w[2], 200)), 255}
			}
		}
	}
	return ins
}

instrument_text :: proc(ins: ^Instrument, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "instrument %v\n", ins.key)
	fmt.sbprintf(&b, "name \"%v\"\n", ins.name)
	if ins.family != "" do fmt.sbprintf(&b, "family %v\n", ins.family)
	fmt.sbprintf(&b, "range %v %v\n", note_text(ins.lo), note_text(ins.hi))
	waves := WAVE_NAMES
	if ins.wave == .Pulse {
		fmt.sbprintf(&b, "wave pulse %v\n", ins.duty)
	} else if ins.wave == .FM {
		fmt.sbprintf(&b, "wave fm %v %v\n", ins.fm_ratio, ins.fm_index)
		fw := FM_WAVE_NAMES
		if ins.has_fm_env do fmt.sbprintf(&b, "fm_envelope %v %v %v %v\n", ins.fm_env.attack, ins.fm_env.decay, ins.fm_env.sustain, ins.fm_env.release)
		if ins.fm_fb != 0 do fmt.sbprintf(&b, "fm_feedback %v\n", ins.fm_fb)
		if ins.fm_wave != {} do fmt.sbprintf(&b, "fm_wave %v %v\n", fw[ins.fm_wave[0]], fw[ins.fm_wave[1]])
		if ins.fm_keyscale != 0 do fmt.sbprintf(&b, "fm_keyscale %v\n", ins.fm_keyscale)
		if ins.vel_index != 0 do fmt.sbprintf(&b, "vel_index %v\n", ins.vel_index)
	} else {
		fmt.sbprintf(&b, "wave %v\n", waves[ins.wave])
	}
	if ins.mix2 > 0 {
		fmt.sbprintf(&b, "layer %v %v %v\n", waves[ins.wave2], ins.mix2, ins.semis2)
	} else {
		fmt.sbprint(&b, "layer none\n")
	}
	if ins.mix3 > 0 do fmt.sbprintf(&b, "layer3 %v %v %v\n", waves[ins.wave3], ins.mix3, ins.semis3)
	fmt.sbprintf(&b, "envelope %v %v %v %v\n", ins.attack, ins.decay, ins.sustain, ins.release)
	if ins.has_env2 do fmt.sbprintf(&b, "layer_envelope %v %v %v %v\n", ins.env2.attack, ins.env2.decay, ins.env2.sustain, ins.env2.release)
	if ins.has_env3 do fmt.sbprintf(&b, "layer3_envelope %v %v %v %v\n", ins.env3.attack, ins.env3.decay, ins.env3.sustain, ins.env3.release)
	fmt.sbprintf(&b, "vibrato %v %v %v\n", ins.vib_rate, ins.vib_depth, ins.vib_delay)
	fmt.sbprintf(&b, "sweep %v %v\n", ins.sweep, ins.sweep_time)
	fmt.sbprintf(&b, "breath %v\n", ins.breath)
	fmt.sbprintf(&b, "tone %v\n", ins.tone)
	if ins.filter_hz > 0 do fmt.sbprintf(&b, "filter %v %v\n", ins.filter_hz, ins.resonance)
	if ins.keytrack != 0 do fmt.sbprintf(&b, "keytrack %v\n", ins.keytrack)
	if ins.fenv != {} do fmt.sbprintf(&b, "filter_env %v %v %v\n", ins.fenv[0], ins.fenv[1], ins.fenv[2])
	if ins.vel_tone != 0 do fmt.sbprintf(&b, "vel_tone %v\n", ins.vel_tone)
	if ins.highpass > 0 do fmt.sbprintf(&b, "highpass %v\n", ins.highpass)
	if ins.click[0] > 0 do fmt.sbprintf(&b, "click %v %v %v\n", ins.click[0], ins.click[1], ins.click[2])
	if ins.string_damp != 0.5 || ins.string_bright != DEFAULT_STRING_BRIGHT {
		fmt.sbprintf(&b, "string %v %v\n", ins.string_damp, ins.string_bright)
	}
	if ins.damp > 0 do fmt.sbprintf(&b, "damp %v\n", ins.damp)
	if ins.trem_depth > 0 && ins.trem_rate > 0 do fmt.sbprintf(&b, "tremolo %v %v %v\n", ins.trem_rate, ins.trem_depth, ins.trem_delay)
	if ins.drive > 0 do fmt.sbprintf(&b, "drive %v\n", ins.drive)
	if ins.metallic do fmt.sbprint(&b, "metallic 1\n")
	fmt.sbprintf(&b, "gain %v\n", ins.gain)
	if ins.pan != 0 do fmt.sbprintf(&b, "pan %v\n", ins.pan)
	fmt.sbprintf(&b, "color %v %v %v\nend\n", ins.color.r, ins.color.g, ins.color.b)
	return strings.to_string(b)
}

// --- Small helpers ---

// The set owns every string in it, so an instrument outlives the file text it
// was parsed out of.
@(private = "file")
own :: proc(set: ^Instrument_Set, s: string) -> string {
	if s == "" do return ""
	copy := strings.clone(s)
	append(&set.strings, copy)
	return copy
}

@(private = "file")
num :: proc(s: string, fallback: f32) -> f32 {
	if v, ok := strconv.parse_f32(s); ok do return v
	return fallback
}

// A range end: "C4", or a bare MIDI number.
@(private = "file")
range_value :: proc(s: string) -> int {
	if s == "" do return -1
	if s[0] >= '0' && s[0] <= '9' {
		if v, ok := strconv.parse_int(s); ok do return v
		return -1
	}
	n := parse_note(s)
	return n if n >= 0 else -1
}

// `a d s r`, or `none` to follow the main envelope again.
@(private = "file")
env_from :: proc(w: []string, was: Env) -> (Env, bool) {
	if len(w) > 0 && w[0] == "none" do return {}, false
	if len(w) < 4 do return was, was != {}
	return {num(w[0], 0), num(w[1], 0), num(w[2], 0), num(w[3], 0)}, true
}

@(private = "file")
fm_wave_from :: proc(s: string, was: Fm_Wave) -> Fm_Wave {
	for name, w in FM_WAVE_NAMES do if name == s do return w
	return was
}

@(private = "file")
wave_from :: proc(s: string) -> (Wave, bool) {
	for name, w in WAVE_NAMES do if name == s do return w, true
	return .Pulse, false
}

@(private = "file")
unquote :: proc(s: string) -> string {
	if len(s) >= 2 && s[0] == '"' && s[len(s) - 1] == '"' do return s[1:len(s) - 1]
	return s
}

// --- Loading the usual places ---

// The instruments everything shares, plus a game's own on top.
//
// The engine's set is found relative to wherever the program was started
// from, because the tools are run both from the repo root (`just sound`) and
// from inside a game folder. A game's assets/instruments/ is
// loaded afterwards, so it wins: dropping one file in there is how a game
// darkens the strings without copying the rest of the orchestra.
instruments_load :: proc(set: ^Instrument_Set, asset_dir: string = "") -> int {
	count := 0
	for dir in ([?]string{"nengine/instruments", "../nengine/instruments", "instruments"}) {
		if count = instrument_set_load(set, dir); count > 0 do break
	}
	if asset_dir != "" {
		count += instrument_set_load(set, fmt.tprintf("%v/instruments", asset_dir))
	}
	return count
}

// Every key, in the order the files gave them. For the editor's picker.
instrument_keys :: proc(set: ^Instrument_Set, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for &i in set.list do append(&out, i.key)
	return out[:]
}
