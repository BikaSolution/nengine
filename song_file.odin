package nengine

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

// Song files, and the synth that turns one into sound.
//
// TIME IS IN TICKS from the start of the song, TPQ to a quarter note — not in
// rows of a grid. A bar is a way of LOOKING at the time line, so changing 4/4
// to 3/4 re-flows the bars without moving a single note, and a triplet or a
// dotted quarter is just a length like any other. That one decision is what
// lets the same song be edited two ways:
//
//   * the TRACKER GRID, a cell to a sixteenth, which is the right tool for
//     drums and short looping beds;
//   * the SHEET, four bars across with the whole piano range top to bottom,
//     which is the right tool for writing a tune.
//
// Both are in tools/nsound, both edit this, and a MIDI file imports straight
// into it (midi.odin).
//
//     # nengine song
//     song house
//     tempo 72
//     time 4/4
//     key 0              # sharps (+) or flats (-): 2 is D major
//     bars 8
//     loop yes           # a game bed wraps; a piece of music ends
//     track bass inst=sine vol=0.3
//     note 0 96 A2
//     note 96 96 F2 vel=80
//
// And, for the mix and the playing (see synth.odin and master.odin):
//
//     level -16          # loudness to master to, LUFS; `level none` leaves it
//     ceiling -1         # nothing louder than this, dBFS
//     reverb 0.5 0.5 0.2 # the room: size damp mix [predelay s] [width]; `reverb none`
//     tempo 60 at=1536 glide=96   # slow to 60 from tick 1536, over a bar
//     track tune inst=oboe vol=0.3 pan=-0.3 rev=0.4 legato=1 glide=0.06
//     vol 0 0.5          # this track's volume, at a tick: a crescendo...
//     vol 384 1          # ...from half to full over four bars
//     note 0 96 A4 vel=60 vel_end=110   # and a swell inside one held note
//
// And what the second round added (all optional; a song that says none of
// it renders as it did):
//
//     level -19 short    # level by the loudest 3 s, not the whole: sparse cues
//     reverb2 plate 0.7 0.2 0.3        # a second room, sent to by `rev2=`
//     track gtr inst=guitar rev2=0.4 mono=1 damp=0.2 lp=4000 hp=120
//     eq 1500 6 1.2      # a peak on that track: Hz, dB, Q (any number of them)
//     echo 3/16 0.35 0.3 # tape echo: ms or a fraction of a whole note, feedback, mix
//     note 0 48 E4 slide_from=-2@6 bend=-1@12 bend_at=36 nudge=-8 damp=0.4
//
// The old grid format — `bpm`, `steps`, and rows of `A2 - - - .` cells — is
// still read, and turns into notes on the way in. Songs are written out in
// the form above.

Note :: struct {
	tick:    i32,
	len:     i32,
	pitch:   Pitch,
	vel:     u8, // 1..127
	vel_end: u8, // 0 = stays at vel; otherwise it moves there across the note
	// Inside the note, all optional (0 is "not said"):
	nudge:       f32, // milliseconds late (+) or early (-): a groove finer than a tick
	damp:        f32, // seconds, as an instrument's `damp`; < 0 is no damper (it rings)
	slide:       f32, // starts this many semitones off...
	slide_ticks: i32, // ...and slides to its pitch over this many ticks
	bend:        f32, // moves this many semitones away...
	bend_ticks:  i32, // ...over this many ticks...
	bend_at:     i32, // ...starting this many ticks into the note
}

DEFAULT_VELOCITY :: u8(100)

Track :: struct {
	name:   string,
	inst:   string, // an instrument key; see instrument_file.odin
	notes:  [dynamic]Note,
	volume: f32,
	pan:    f32, // -1 left .. 1 right
	mute:   bool,
	solo:   bool,
	rev:    f32, // how much goes to the song's room: 0 none, 1 all
	// One line, slurred: a note that starts before the last one ends glides
	// into it instead of starting again. `glide` is the slide, in seconds.
	legato: bool,
	glide:  f32,
	// Volume over time, as points: between two it moves in a straight line.
	vols:   [dynamic]Vol_Point,
	// One voice, as an AdLib channel is: a new note stops the last.
	mono:   bool,
	rev2:   f32, // how much goes to the second room (`reverb2`): 0 none
	damp:   f32, // every note's damp=, unless the note says its own
	// The track as a whole, after its notes: two-pole low- and high-pass
	// (Hz, 0 = off), peaks, and a tape echo. A gramophone is one track's worth.
	lp:     f32,
	hp:     f32,
	eqs:    [dynamic]Eq_Band,
	echo:   Echo,
}

// A peak (or, with a negative gain, a notch) at `hz`, `q` wide.
Eq_Band :: struct {
	hz:   f32,
	gain: f32, // dB
	q:    f32,
}

// A tape echo: repeats `ms` apart (or `sync` ticks apart, at the opening
// tempo), each `feedback` of the last, the first at `mix`. The repeats grow
// darker and thinner, as tape does.
Echo :: struct {
	ms:       f32,
	sync:     i32,
	feedback: f32,
	mix:      f32,
}

Vol_Point :: struct {
	tick:  i32,
	level: f32, // times the track's own vol
}

// From `at` on, the song runs at `bpm`; with `glide` it gets there over that
// many ticks, which is how an ending broadens.
Tempo_Change :: struct {
	at:    i32,
	bpm:   f32,
	glide: i32,
}

Song :: struct {
	name:      string,
	tempo:     f32, // quarter notes per minute
	beats:     i32, // time signature, top
	beat_unit: i32, // time signature, bottom
	key:       i32, // sharps (+) / flats (-)
	bars:      i32,
	grid:      i32, // ticks to a cell in the tracker view
	loop:      bool,
	tracks:    [dynamic]Track,
	// Instruments the song carries itself. A tune that needs one particular
	// sound travels with it. See instrument_file.odin.
	own:       Instrument_Set,
	tempos:    [dynamic]Tempo_Change, // after the opening `tempo`, in order
	level:     f32,    // LUFS to master to; LEVEL_NONE leaves it
	level_short: bool, // measured as the loudest 3 s, not integrated
	ceiling:   f32,    // dBFS
	reverb:    Reverb, // mix 0 is a dry song
	// A second room, fed only by tracks that say `rev2=`. Off (mix 0) unless said.
	reverb2:      Reverb,
	reverb2_kind: Room_Kind,
	// What reading it found that a person should know: a note that started
	// after the loop's end, which is wrapped round to the start.
	warnings:  [dynamic]string,
}

// A song's loudness, unless it says otherwise: about where a game's music
// sits, and where composer A's cues were aiming.
DEFAULT_LEVEL :: f32(-16)

song_new :: proc(name: string, tempo: f32 = 100, bars: i32 = 4) -> Song {
	return {
		name = strings.clone(name),
		tempo = tempo,
		beats = 4,
		beat_unit = 4,
		bars = max(bars, 1),
		grid = TPQ / 4, // a sixteenth
		loop = true,
		level = DEFAULT_LEVEL,
		ceiling = DEFAULT_CEILING,
		reverb = DEFAULT_REVERB,
	}
}

song_destroy :: proc(s: ^Song) {
	for &t in s.tracks do track_destroy(&t)
	delete(s.tracks)
	delete(s.name)
	delete(s.tempos)
	for w in s.warnings do delete(w)
	delete(s.warnings)
	instrument_set_destroy(&s.own)
	s^ = {}
}

track_destroy :: proc(t: ^Track) {
	delete(t.notes)
	delete(t.vols)
	delete(t.eqs)
	delete(t.name)
	delete(t.inst)
	t^ = {}
}

song_add_track :: proc(s: ^Song, name: string, inst: string, volume: f32 = 0.3) -> int {
	append(&s.tracks, Track{
		name   = strings.clone(name),
		inst   = strings.clone(inst),
		volume = volume,
		rev    = 1,
	})
	return len(s.tracks) - 1
}

song_remove_track :: proc(s: ^Song, i: int) {
	if i < 0 || i >= len(s.tracks) do return
	track_destroy(&s.tracks[i])
	ordered_remove(&s.tracks, i)
}

track_set_instrument :: proc(t: ^Track, key: string) {
	delete(t.inst)
	t.inst = strings.clone(key)
}

// --- Where the bars fall ---

bar_ticks :: proc(s: ^Song) -> i32 {
	return max(s.beats, 1) * (TPQ * 4 / max(s.beat_unit, 1))
}

beat_ticks :: proc(s: ^Song) -> i32 {
	return TPQ * 4 / max(s.beat_unit, 1)
}

// Seconds to a tick, at this song's tempo.
tick_seconds :: proc(s: ^Song) -> f32 {
	return 60 / (max(s.tempo, 1) * TPQ)
}

// Where the last note of any track ends.
song_end_tick :: proc(s: ^Song) -> i32 {
	end: i32
	for &t in s.tracks do for n in t.notes do end = max(end, n.tick + n.len)
	return end
}

// How long the song is: the bars it says it has. A loop is exactly this long,
// which is what makes it join up.
song_total_ticks :: proc(s: ^Song) -> i32 {
	return max(s.bars, 1) * bar_ticks(s)
}

// Grow the bar count so every note has somewhere to be.
song_grow_bars :: proc(s: ^Song) {
	bt := bar_ticks(s)
	need := (song_end_tick(s) + bt - 1) / bt
	s.bars = max(need, s.bars, 1)
}

// The same, rounded up to a whole page. The sheet turns pages, so it wants
// the last one full; a file being read does not.
song_fit_bars :: proc(s: ^Song, per_page: i32 = 4) {
	song_grow_bars(s)
	s.bars = (s.bars + per_page - 1) / per_page * per_page
}

song_any_solo :: proc(s: ^Song) -> bool {
	for &t in s.tracks do if t.solo do return true
	return false
}

track_audible :: proc(s: ^Song, t: ^Track) -> bool {
	if t.mute do return false
	if song_any_solo(s) do return t.solo
	return true
}

// --- Editing a track ---

track_sort :: proc(t: ^Track) {
	slice.sort_by(t.notes[:], proc(a, b: Note) -> bool {
		if a.tick != b.tick do return a.tick < b.tick
		return pitch_midi(a.pitch) < pitch_midi(b.pitch)
	})
}

// Put a note in, replacing anything at the same SOUNDING pitch it overlaps —
// one instrument cannot play the same string twice at once, and the note
// being replaced is what the person clicking meant. Returns its index.
track_put :: proc(t: ^Track, n: Note) -> int {
	m := pitch_midi(n.pitch)
	for i := len(t.notes) - 1; i >= 0; i -= 1 {
		o := t.notes[i]
		if pitch_midi(o.pitch) != m do continue
		if o.tick < n.tick + n.len && n.tick < o.tick + o.len do ordered_remove(&t.notes, i)
	}
	append(&t.notes, n)
	track_sort(t)
	for o, i in t.notes do if o == n do return i
	return -1
}

// The note on this staff step covering this tick, if there is one. The last
// one wins, because it is the one drawn on top.
track_note_at :: proc(t: ^Track, step: int, tick: i32) -> int {
	for i := len(t.notes) - 1; i >= 0; i -= 1 {
		o := t.notes[i]
		if int(o.pitch.step) == step && o.tick <= tick && tick < o.tick + o.len do return i
	}
	return -1
}

// Any note sounding at this tick, whatever its pitch. The tracker grid has
// one cell per moment rather than one row per pitch, so this is what it asks.
track_note_covering :: proc(t: ^Track, tick: i32) -> int {
	for i := len(t.notes) - 1; i >= 0; i -= 1 {
		o := t.notes[i]
		if o.tick <= tick && tick < o.tick + o.len do return i
	}
	return -1
}

// --- The tracker grid's view of it ---
//
// A cell is `grid` ticks wide, a sixteenth by default. These are what the
// tracker editor works in, so that view stays as simple as it was when a song
// really was nothing but a grid.

song_grid :: proc(s: ^Song) -> i32 {
	return max(s.grid, 1)
}

song_steps :: proc(s: ^Song) -> int {
	return int(song_total_ticks(s) / song_grid(s))
}

step_tick :: proc(s: ^Song, step: int) -> i32 {
	return i32(step) * song_grid(s)
}

REST :: -1
HOLD :: -2 // in the grid: this cell is the note before it, still sounding

// What the tracker should show in one cell: a MIDI note if one starts here,
// HOLD if one is still sounding, REST if nothing is. `off_grid` says the note
// did not start on a cell boundary — it was written on the sheet, or came
// from a MIDI file — so the grid is showing you an approximation.
Cell :: struct {
	note:     int, // MIDI number, REST or HOLD
	index:    int, // which note in the track, or -1
	off_grid: bool,
}

track_cell :: proc(s: ^Song, t: ^Track, step: int) -> Cell {
	g := song_grid(s)
	from := step_tick(s, step)
	// A note starting anywhere inside this cell is shown as starting here.
	for n, i in t.notes {
		if n.tick >= from && n.tick < from + g {
			return {pitch_midi(n.pitch), i, n.tick != from}
		}
	}
	if i := track_note_covering(t, from); i >= 0 do return {HOLD, i, false}
	return {REST, -1, false}
}

// Write a cell: a MIDI note starts one here, REST clears whatever is here,
// HOLD stretches the note before it over this cell.
track_write_cell :: proc(s: ^Song, t: ^Track, step: int, note: int) {
	g := song_grid(s)
	at := step_tick(s, step)

	switch {
	case note == REST:
		// Clear: a note starting here goes; a note running through here is
		// cut short so it stops before this cell.
		for i := len(t.notes) - 1; i >= 0; i -= 1 {
			n := t.notes[i]
			if n.tick >= at && n.tick < at + g {
				ordered_remove(&t.notes, i)
			} else if n.tick < at && n.tick + n.len > at {
				t.notes[i].len = at - n.tick
			}
		}
	case note == HOLD:
		// Stretch whatever was sounding just before this cell over it.
		i := track_note_covering(t, at - 1)
		if i < 0 do return
		if t.notes[i].tick + t.notes[i].len < at + g {
			t.notes[i].len = at + g - t.notes[i].tick
		}
		// And drop anything this now swallows.
		for j := len(t.notes) - 1; j >= 0; j -= 1 {
			if j == i do continue
			n := t.notes[j]
			if n.tick >= at && n.tick < at + g do ordered_remove(&t.notes, j)
		}
	case:
		track_write_cell(s, t, step, REST)
		track_put(t, Note{tick = at, len = g, pitch = pitch_from_midi(note, int(s.key)), vel = DEFAULT_VELOCITY})
	}
	track_sort(t)
}

// "A3", "C#5", "Bb2", "." or "-" — a MIDI note number, REST or HOLD. The
// tracker grid types in these; the sheet uses Pitch directly.
parse_note :: proc(s: string) -> int {
	if s == "-" do return HOLD
	if s == "" || s == "." do return REST
	p, ok := parse_pitch(s)
	if !ok do return REST
	return pitch_midi(p)
}

NOTE_NAMES := [12]string{"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}

note_text :: proc(note: int, allocator := context.temp_allocator) -> string {
	if note == HOLD do return "-"
	if note < 0 do return "."
	return fmt.aprintf("%v%v", NOTE_NAMES[note %% 12], note / 12 - 1, allocator = allocator)
}

note_hz :: proc(note: int) -> f32 {
	return midi_hz(f32(note))
}

// --- File ---

// `insts` is the shared orchestra, so a song's own `instrument ... end`
// blocks can say `based_on violin` and mean the violin everything else uses.
load_song :: proc(path: string, insts: ^Instrument_Set = nil) -> (s: Song, ok: bool) {
	text := read_data_file(path) or_return
	return parse_song(text, insts)
}

parse_song :: proc(text: string, insts: ^Instrument_Set = nil) -> (s: Song, ok: bool) {
	s = song_new("", 100, 4)
	parse_instruments(&s.own, text, "song", insts)

	// The old format was a grid: `steps N`, then a row of cells per track.
	// Both are read; only the new one is written.
	legacy_steps := 0
	legacy_rows := false
	in_instrument := false

	for raw in data_lines(text) {
		l := parse_line(raw)
		switch l.key {
		case "song":
			if len(l.words) > 0 {
				delete(s.name)
				s.name = strings.clone(l.words[0])
			}
			legacy_rows = false
		case "tempo", "bpm":
			if len(l.words) > 0 {
				bpm := max(num_or(l.words[0], 100), 1)
				if at, has := field(l, "at"); has {
					tick, _ := strconv.parse_int(at)
					append(&s.tempos, Tempo_Change{i32(max(tick, 0)), bpm, i32(max(field_int(l, "glide", 0), 0))})
				} else {
					s.tempo = bpm
				}
			}
			legacy_rows = false
		case "level":
			if len(l.words) > 0 {
				s.level = LEVEL_NONE if l.words[0] == "none" else num_or(l.words[0], DEFAULT_LEVEL)
				s.level_short = len(l.words) > 1 && l.words[1] == "short"
			}
		case "ceiling":
			if len(l.words) > 0 do s.ceiling = min(num_or(l.words[0], DEFAULT_CEILING), 0)
		case "reverb":
			s.reverb = parse_reverb(l.words)
		case "reverb2":
			s.reverb2, s.reverb2_kind = parse_reverb2(l.words)
		case "time":
			if len(l.words) > 0 {
				if slash := strings.index_byte(l.words[0], '/'); slash > 0 {
					top, _ := strconv.parse_int(l.words[0][:slash])
					bottom, _ := strconv.parse_int(l.words[0][slash + 1:])
					if top > 0 do s.beats = i32(top)
					if bottom > 0 do s.beat_unit = i32(bottom)
				}
			}
			legacy_rows = false
		case "key":
			if len(l.words) > 0 do s.key = i32(clamp(int(num_or(l.words[0], 0)), -7, 7))
			legacy_rows = false
		case "bars":
			if len(l.words) > 0 do s.bars = max(i32(num_or(l.words[0], 4)), 1)
			legacy_rows = false
		case "grid":
			if len(l.words) > 0 do s.grid = max(i32(num_or(l.words[0], TPQ / 4)), 1)
			legacy_rows = false
		case "loop":
			s.loop = len(l.words) == 0 || l.words[0] == "yes" || l.words[0] == "1" || l.words[0] == "true"
			legacy_rows = false
		case "steps":
			// Old format: this many sixteenths, which is this many bars.
			if len(l.words) > 0 do legacy_steps = int(num_or(l.words[0], 16))
			legacy_rows = false
		case "instrument", "define_instrument":
			// Read already, by parse_instruments; skip the block's body so its
			// lines aren't mistaken for anything else.
			in_instrument = true
			legacy_rows = false
		case "end":
			in_instrument = false
		case "track":
			name := l.words[0] if len(l.words) > 0 else "track"
			// New: `track bass inst=sine vol=0.3`. Old: `track bass sine vol=0.3`.
			key, has_key := field(l, "inst")
			if !has_key do key = l.words[1] if len(l.words) > 1 else "square"
			i := song_add_track(&s, name, key, field_f32(l, "vol", 0.3))
			s.tracks[i].pan = clamp(field_f32(l, "pan", 0), -1, 1)
			s.tracks[i].mute = field_bool(l, "mute")
			s.tracks[i].solo = field_bool(l, "solo")
			s.tracks[i].rev = max(field_f32(l, "rev", 1), 0)
			s.tracks[i].legato = field_bool(l, "legato")
			s.tracks[i].glide = max(field_f32(l, "glide", 0), 0)
			s.tracks[i].mono = field_bool(l, "mono")
			s.tracks[i].rev2 = max(field_f32(l, "rev2", 0), 0)
			s.tracks[i].damp = damp_field(l)
			s.tracks[i].lp = max(field_f32(l, "lp", 0), 0)
			s.tracks[i].hp = max(field_f32(l, "hp", 0), 0)
			legacy_rows = !has_key
		case "eq":
			// A peak on the track above: `eq <Hz> <gain dB> [Q]`.
			if in_instrument || len(s.tracks) == 0 || len(l.words) < 2 do continue
			hz := num_or(l.words[0], 0)
			if hz <= 0 do continue
			q := num_or(l.words[2], 1) if len(l.words) > 2 else 1
			append(&s.tracks[len(s.tracks) - 1].eqs, Eq_Band{hz, clamp(num_or(l.words[1], 0), -30, 30), clamp(q, 0.1, 30)})
		case "echo":
			// A tape echo on the track above: `echo <ms | n/d> [feedback] [mix]`.
			if in_instrument || len(s.tracks) == 0 || len(l.words) < 1 do continue
			s.tracks[len(s.tracks) - 1].echo = parse_echo(l.words)
		case "vol":
			// A volume point on the track above: `vol <tick> <level>`.
			if len(s.tracks) == 0 || len(l.words) < 2 do continue
			tick, _ := strconv.parse_int(l.words[0])
			append(&s.tracks[len(s.tracks) - 1].vols, Vol_Point{i32(max(tick, 0)), max(num_or(l.words[1], 1), 0)})
		case "note":
			if len(s.tracks) == 0 || len(l.words) < 3 do continue
			tick, _ := strconv.parse_int(l.words[0])
			length, _ := strconv.parse_int(l.words[1])
			p, good := parse_pitch(l.words[2])
			if !good do continue
			vel := u8(clamp(field_int(l, "vel", int(DEFAULT_VELOCITY)), 1, 127))
			vel_end := u8(clamp(field_int(l, "vel_end", 0), 0, 127))
			n := Note{
				tick = i32(tick), len = max(i32(length), 1), pitch = p, vel = vel, vel_end = vel_end,
				nudge = clamp(field_f32(l, "nudge", 0), -500, 500),
				damp = damp_field(l),
				bend_at = i32(max(field_int(l, "bend_at", 0), 0)),
			}
			if v, has := field(l, "slide_from"); has do n.slide, n.slide_ticks = semis_at(v)
			if v, has := field(l, "bend"); has do n.bend, n.bend_ticks = semis_at(v)
			append(&s.tracks[len(s.tracks) - 1].notes, n)
		case:
			if in_instrument || !legacy_rows || len(s.tracks) == 0 do continue
			legacy_row(&s, &s.tracks[len(s.tracks) - 1], raw, legacy_steps)
		}
	}

	if legacy_steps > 0 {
		// Sixteenths to bars, rounded up, so nothing is cut off.
		per_bar := bar_ticks(&s) / (TPQ / 4)
		s.bars = max(i32((legacy_steps + int(per_bar) - 1) / int(per_bar)), 1)
	}
	for &t in s.tracks {
		track_sort(&t)
		slice.sort_by(t.vols[:], proc(a, b: Vol_Point) -> bool { return a.tick < b.tick })
	}
	slice.sort_by(s.tempos[:], proc(a, b: Tempo_Change) -> bool { return a.at < b.at })
	// A piece grows to hold its notes. A LOOP does not: it is exactly its
	// bars long, or it stops joining up. A tail running off the end rings on
	// into the start, which is what a loop is; a note that STARTS after the
	// end is wrapped round too, and said, since that is probably a mistake.
	if s.loop && legacy_steps == 0 {
		song_wrap_late_notes(&s)
	} else {
		song_grow_bars(&s)
	}
	if s.name == "" do s.name = strings.clone("untitled")
	return s, true
}

// A looping song's notes that start at or after its end, moved round to the
// start, with a warning each. Returns how many.
song_wrap_late_notes :: proc(s: ^Song) -> int {
	total := song_total_ticks(s)
	moved := 0
	for &t in s.tracks {
		for &n in t.notes {
			if n.tick < total do continue
			append(&s.warnings, fmt.aprintf("track %v: the note at tick %v (%v) starts after the loop ends at %v; it is played at tick %v",
				t.name, n.tick, pitch_text(n.pitch), total, n.tick % total))
			n.tick %= total
			moved += 1
		}
		if moved > 0 do track_sort(&t)
	}
	return moved
}

// How many notes of a looping song run past its end, and so ring on into its
// start. Not a mistake, but worth knowing.
song_tails_wrapping :: proc(s: ^Song) -> int {
	if !s.loop do return 0
	total := song_total_ticks(s)
	n := 0
	for &t in s.tracks do for note in t.notes do if note.tick + note.len > total do n += 1
	return n
}

// `size damp mix [predelay] [width]`, or `none`.
@(private = "file")
parse_reverb :: proc(w: []string) -> Reverb {
	if len(w) == 0 do return DEFAULT_REVERB
	if w[0] == "none" || w[0] == "off" do return {}
	r := DEFAULT_REVERB
	r.size = clamp(num_or(w[0], r.size), 0, 1)
	if len(w) > 1 do r.damp = clamp(num_or(w[1], r.damp), 0, 1)
	if len(w) > 2 do r.mix = max(num_or(w[2], r.mix), 0)
	if len(w) > 3 do r.predelay = clamp(num_or(w[3], r.predelay), 0, 0.5)
	if len(w) > 4 do r.width = clamp(num_or(w[4], r.width), 0, 1)
	return r
}

// `[plate|hall|room] [size] [damp] [mix] [predelay] [width]`, or `none`. A
// kind alone is its preset.
@(private = "file")
parse_reverb2 :: proc(w: []string) -> (Reverb, Room_Kind) {
	if len(w) > 0 && (w[0] == "none" || w[0] == "off") do return {}, .Plate
	kind := Room_Kind.Plate
	rest := w
	if len(w) > 0 {
		switch w[0] {
		case "plate": kind, rest = .Plate, w[1:]
		case "hall":  kind, rest = .Hall, w[1:]
		case "room":  kind, rest = .Room, w[1:]
		}
	}
	r := room_preset(kind)
	if len(rest) > 0 do r.size = clamp(num_or(rest[0], r.size), 0, 1)
	if len(rest) > 1 do r.damp = clamp(num_or(rest[1], r.damp), 0, 1)
	if len(rest) > 2 do r.mix = max(num_or(rest[2], r.mix), 0)
	if len(rest) > 3 do r.predelay = clamp(num_or(rest[3], r.predelay), 0, 0.5)
	if len(rest) > 4 do r.width = clamp(num_or(rest[4], r.width), 0, 1)
	return r, kind
}

// `echo <ms | n/d> [feedback] [mix]`, or `none`.
@(private = "file")
parse_echo :: proc(w: []string) -> Echo {
	if len(w) == 0 || w[0] == "none" || w[0] == "off" do return {}
	e := Echo{feedback = 0.3, mix = 0.3}
	if slash := strings.index_byte(w[0], '/'); slash > 0 {
		top, _ := strconv.parse_int(w[0][:slash])
		bottom, _ := strconv.parse_int(w[0][slash + 1:])
		if top > 0 && bottom > 0 do e.sync = i32(top * 4 * TPQ / bottom)
	} else {
		e.ms = clamp(num_or(strings.trim_suffix(w[0], "ms"), 0), 0, 4000)
	}
	if len(w) > 1 do e.feedback = clamp(num_or(w[1], e.feedback), 0, 0.95)
	if len(w) > 2 do e.mix = clamp(num_or(w[2], e.mix), 0, 2)
	if e.ms <= 0 && e.sync <= 0 do return {}
	return e
}

// `damp=0.3`, or `damp=off` for no damper at all (it rings); 0 if not said.
@(private = "file")
damp_field :: proc(l: Line) -> f32 {
	v, has := field(l, "damp")
	if !has do return 0
	if v == "off" || v == "none" || v == "ring" do return -1
	return max(num_or(v, 0), 0)
}

// "-2@6": semitones, at a number of ticks.
@(private = "file")
semis_at :: proc(v: string) -> (f32, i32) {
	at := strings.index_byte(v, '@')
	if at < 0 do return num_or(v, 0), 0
	ticks, _ := strconv.parse_int(v[at + 1:])
	return clamp(num_or(v[:at], 0), -48, 48), i32(max(ticks, 0))
}

// One row of the old grid format, turned into notes. A run of "-" after a
// note becomes that note's length, which is exactly what it always meant.
@(private = "file")
legacy_row :: proc(s: ^Song, t: ^Track, raw: string, steps: int) {
	cells := strings.fields(raw, context.temp_allocator)
	sixteenth := i32(TPQ / 4)
	for cell, i in cells {
		if steps > 0 && i >= steps do break
		n := parse_note(cell)
		if n < 0 do continue
		held := i32(1)
		for j := i + 1; j < len(cells); j += 1 {
			if parse_note(cells[j]) != HOLD do break
			held += 1
		}
		append(&t.notes, Note{
			tick  = i32(i) * sixteenth,
			len   = held * sixteenth,
			pitch = pitch_from_midi(n, int(s.key)),
			vel   = DEFAULT_VELOCITY,
		})
	}
}

@(private = "file")
num_or :: proc(s: string, fallback: f32) -> f32 {
	if v, ok := strconv.parse_f32(s); ok do return v
	return fallback
}

save_song :: proc(s: ^Song, path: string) -> bool {
	return write_data_file(path, song_text(s))
}

song_text :: proc(s: ^Song, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "# nengine song\nsong %v\n", s.name)
	fmt.sbprintf(&b, "tempo %v\ntime %v/%v\nkey %v\nbars %v\n", s.tempo, s.beats, s.beat_unit, s.key, s.bars)
	for tc in s.tempos {
		fmt.sbprintf(&b, "tempo %v at=%v", tc.bpm, tc.at)
		if tc.glide > 0 do fmt.sbprintf(&b, " glide=%v", tc.glide)
		strings.write_byte(&b, '\n')
	}
	if s.grid != TPQ / 4 do fmt.sbprintf(&b, "grid %v\n", s.grid)
	if !s.loop do fmt.sbprint(&b, "loop no\n")
	if s.level == LEVEL_NONE do fmt.sbprint(&b, "level none\n")
	else if s.level != DEFAULT_LEVEL || s.level_short do fmt.sbprintf(&b, "level %v%v\n", s.level, " short" if s.level_short else "")
	if s.ceiling != DEFAULT_CEILING do fmt.sbprintf(&b, "ceiling %v\n", s.ceiling)
	if s.reverb.mix <= 0 {
		fmt.sbprint(&b, "reverb none\n")
	} else if s.reverb != DEFAULT_REVERB {
		r := s.reverb
		fmt.sbprintf(&b, "reverb %v %v %v %v %v\n", r.size, r.damp, r.mix, r.predelay, r.width)
	}
	if s.reverb2.mix > 0 {
		r := s.reverb2
		kinds := ROOM_KIND_NAMES
		fmt.sbprintf(&b, "reverb2 %v %v %v %v %v %v\n", kinds[s.reverb2_kind], r.size, r.damp, r.mix, r.predelay, r.width)
	}
	for &ins in s.own.list do strings.write_string(&b, instrument_text(&ins))

	for &t in s.tracks {
		fmt.sbprintf(&b, "track %v inst=%v vol=%v", t.name, t.inst, t.volume)
		if t.pan != 0 do fmt.sbprintf(&b, " pan=%v", t.pan)
		if t.rev != 1 do fmt.sbprintf(&b, " rev=%v", t.rev)
		if t.legato do fmt.sbprint(&b, " legato=1")
		if t.glide > 0 do fmt.sbprintf(&b, " glide=%v", t.glide)
		if t.mute do fmt.sbprint(&b, " mute=1")
		if t.solo do fmt.sbprint(&b, " solo=1")
		if t.mono do fmt.sbprint(&b, " mono=1")
		if t.rev2 > 0 do fmt.sbprintf(&b, " rev2=%v", t.rev2)
		write_damp(&b, t.damp)
		if t.lp > 0 do fmt.sbprintf(&b, " lp=%v", t.lp)
		if t.hp > 0 do fmt.sbprintf(&b, " hp=%v", t.hp)
		strings.write_byte(&b, '\n')
		for q in t.eqs do fmt.sbprintf(&b, "eq %v %v %v\n", q.hz, q.gain, q.q)
		if e := t.echo; e.ms > 0 || e.sync > 0 {
			if e.sync > 0 {
				whole := i32(4 * TPQ)
				g := song_gcd(e.sync, whole)
				fmt.sbprintf(&b, "echo %v/%v %v %v\n", e.sync / g, whole / g, e.feedback, e.mix)
			} else {
				fmt.sbprintf(&b, "echo %v %v %v\n", e.ms, e.feedback, e.mix)
			}
		}
		for v in t.vols do fmt.sbprintf(&b, "vol %v %v\n", v.tick, v.level)
		for n in t.notes {
			fmt.sbprintf(&b, "note %v %v %v", n.tick, n.len, pitch_text(n.pitch))
			if n.vel != DEFAULT_VELOCITY do fmt.sbprintf(&b, " vel=%v", n.vel)
			if n.vel_end != 0 do fmt.sbprintf(&b, " vel_end=%v", n.vel_end)
			if n.slide != 0 do fmt.sbprintf(&b, " slide_from=%v@%v", n.slide, n.slide_ticks)
			if n.bend != 0 do fmt.sbprintf(&b, " bend=%v@%v", n.bend, n.bend_ticks)
			if n.bend != 0 && n.bend_at > 0 do fmt.sbprintf(&b, " bend_at=%v", n.bend_at)
			if n.nudge != 0 do fmt.sbprintf(&b, " nudge=%v", n.nudge)
			write_damp(&b, n.damp)
			strings.write_byte(&b, '\n')
		}
	}
	return strings.to_string(b)
}

@(private = "file")
write_damp :: proc(b: ^strings.Builder, damp: f32) {
	if damp < 0 do fmt.sbprint(b, " damp=off")
	else if damp > 0 do fmt.sbprintf(b, " damp=%v", damp)
}

@(private = "file")
song_gcd :: proc(a, b: i32) -> i32 {
	x, y := max(a, 1), max(b, 1)
	for y != 0 do x, y = y, x % y
	return x
}
