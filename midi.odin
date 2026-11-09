package nengine

import "core:fmt"
import "core:os"
import "core:strings"

// Standard MIDI File import.
//
// The practical way to get real music into the engine. Thousands of public
// domain pieces exist as .mid, notation software exports it, and it means a
// tune can be written somewhere else and finished here on the sheet.
//
// What happens to a file:
//   * ticks are rescaled from the file's own resolution to TPQ, and snapped
//     to whichever is nearer of the 32nd grid (3 ticks) and the triplet grid
//     (4 ticks), so both survive;
//   * one track per (MIDI track, channel), its instrument chosen from the
//     General MIDI program number; channel 10 is split into drum tracks;
//   * a note outside its instrument's range is moved by octaves until it
//     fits, and counted, so the import can say how much it had to cheat;
//   * the first tempo, time signature and key signature win. A song here has
//     one tempo — a piece that slows down will need doing by hand.

Midi_Report :: struct {
	notes:      int,
	tracks:     int,
	transposed: int,
	problem:    string, // set when nothing could be read
}

midi_import_file :: proc(path: string, out: ^Song, insts: ^Instrument_Set = nil) -> Midi_Report {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil do return {problem = fmt.aprintf("could not read %v", path)}
	defer delete(data)
	title := path
	if i := strings.last_index_any(title, "/\\"); i >= 0 do title = title[i + 1:]
	if i := strings.last_index_byte(title, '.'); i > 0 do title = title[:i]
	return midi_import(data, out, title, insts)
}

midi_import :: proc(data: []u8, out: ^Song, title: string, insts: ^Instrument_Set = nil) -> Midi_Report {
	rep: Midi_Report
	if len(data) < 14 || string(data[:4]) != "MThd" {
		return {problem = strings.clone("not a MIDI file — no MThd header")}
	}
	r := Reader{data = data, pos = 4}
	header_len := int(be(&r, 4))
	_ = be(&r, 2) // format 0, 1 or 2; we treat them all the same way
	track_count := int(be(&r, 2))
	division := int(be(&r, 2))
	r.pos = 8 + header_len
	if division & 0x8000 != 0 || division == 0 {
		return {problem = strings.clone("SMPTE-timed MIDI files are not supported")}
	}

	tempo_us := -1
	ts_top, ts_bottom := 4, 4
	key := 0
	have_ts, have_key := false, false
	programs: [16]int
	have_program: [16]bool

	groups := make([dynamic]Midi_Group, context.temp_allocator)

	for ti in 0 ..< track_count {
		if r.pos + 8 > len(data) do break
		id := string(data[r.pos:r.pos + 4])
		r.pos += 4
		length := int(be(&r, 4))
		track_end := min(r.pos + length, len(data))
		if id != "MTrk" {
			r.pos = track_end
			continue
		}

		track_name := ""
		time: u32
		status: u8
		// Notes being held down: when they started, and how hard.
		on_start: [16][128]i64
		on_vel: [16][128]u8
		for c in 0 ..< 16 do for k in 0 ..< 128 do on_start[c][k] = -1

		for r.pos < track_end && !r.bad {
			time += varlen(&r)
			b := data[r.pos] if r.pos < len(data) else 0
			// Running status: a byte under 0x80 means "same event as last time".
			if b & 0x80 != 0 {
				status = b
				r.pos += 1
			}
			switch {
			case status == 0xFF:
				kind := next(&r)
				meta_len := int(varlen(&r))
				start := r.pos
				switch kind {
				case 0x03:
					if start + meta_len <= len(data) do track_name = string(data[start:start + meta_len])
				case 0x51:
					if tempo_us < 0 do tempo_us = int(be(&r, 3))
				case 0x58:
					if !have_ts && meta_len >= 2 {
						ts_top = int(data[start])
						ts_bottom = 1 << data[start + 1]
						have_ts = true
					}
				case 0x59:
					if !have_key && meta_len >= 1 {
						key = int(i8(data[start]))
						have_key = true
					}
				}
				r.pos = start + meta_len
			case status == 0xF0 || status == 0xF7:
				r.pos += int(varlen(&r))
			case:
				ch := int(status & 0x0f)
				switch status & 0xf0 {
				case 0x80, 0x90:
					k := next(&r) & 0x7f
					vel := next(&r)
					// A note-on with no velocity is a note-off; that is how
					// running status lets a long phrase be one status byte.
					if status & 0xf0 == 0x90 && vel > 0 {
						if on_start[ch][k] >= 0 {
							// Struck again while still held: end the old one here.
							g := midi_group(&groups, ti, ch)
							append(&g.notes, Midi_Note{u32(on_start[ch][k]), time, k, on_vel[ch][k]})
						}
						on_start[ch][k] = i64(time)
						on_vel[ch][k] = vel
					} else if on_start[ch][k] >= 0 {
						g := midi_group(&groups, ti, ch)
						append(&g.notes, Midi_Note{u32(on_start[ch][k]), time, k, on_vel[ch][k]})
						on_start[ch][k] = -1
					}
				case 0xA0, 0xB0, 0xE0: r.pos += 2
				case 0xC0:
					p := int(next(&r))
					if !have_program[ch] {
						programs[ch] = p
						have_program[ch] = true
					}
				case 0xD0: r.pos += 1
				case:      r.pos += 1 // corrupt: step on rather than spin
				}
			}
		}
		for &g in groups do if g.track == ti && g.name == "" do g.name = track_name
		r.pos = track_end
	}

	// --- Build the song ---

	s := song_new(title, 120, 1)
	if tempo_us > 0 do s.tempo = f32(int(60_000_000.0 / f64(tempo_us) + 0.5))
	if ts_bottom == 2 || ts_bottom == 4 || ts_bottom == 8 || ts_bottom == 16 {
		s.beats, s.beat_unit = i32(clamp(ts_top, 1, 16)), i32(ts_bottom)
	}
	s.key = i32(clamp(key, -7, 7))
	s.loop = false // a piece of music ends; it doesn't go round

	for &g in groups {
		if len(g.notes) == 0 do continue

		if g.channel == 9 {
			// Channel 10 is the drum kit: the note number picks the drum, not
			// the pitch. One track per kind of drum, each at a pitch that
			// suits it, because our drums are pitched instruments.
			Kit :: struct { inst: string, note: int }
			kit := [3]Kit{{"bass_drum", 36}, {"snare", 67}, {"cymbal", 84}}
			at := [3]int{-1, -1, -1}
			for n in g.notes {
				k := 1 // anything unrecognised is a snare
				switch n.key {
				case 35, 36:                                  k = 0
				case 42, 44, 46, 49, 51, 52, 53, 55, 57, 59:  k = 2
				}
				if at[k] < 0 do at[k] = song_add_track(&s, kit[k].inst, kit[k].inst, 0.5)
				m := kit[k].note
				// Toms and the rest of the kit: lower and darker than a snare.
				if k == 1 && n.key != 38 && n.key != 40 do m = clamp(int(n.key) + 14, 55, 79)
				add_midi_note(&s, &s.tracks[at[k]], n, division, m, &rep)
			}
			continue
		}

		key_name := gm_instrument(programs[g.channel])
		ins := instrument_get(insts, key_name)
		name := g.name if g.name != "" else ins.name
		ti := song_add_track(&s, name, key_name, 0.5)
		t := &s.tracks[ti]
		for n in g.notes {
			m := int(n.key)
			if m < ins.lo || m > ins.hi {
				for m < ins.lo do m += 12
				for m > ins.hi do m -= 12
				rep.transposed += 1
			}
			add_midi_note(&s, t, n, division, m, &rep)
		}
	}

	for &t in s.tracks do track_sort(&t)
	rep.tracks = len(s.tracks)
	if rep.notes == 0 {
		song_destroy(&s)
		return {problem = strings.clone("there are no notes in it")}
	}
	song_fit_bars(&s)
	song_destroy(out)
	out^ = s
	return rep
}

// --- The bits and pieces ---

@(private = "file")
Midi_Note :: struct {
	start, end: u32,
	key:        u8,
	vel:        u8,
}

@(private = "file")
Midi_Group :: struct {
	track, channel: int,
	name:           string,
	notes:          [dynamic]Midi_Note,
}

@(private = "file")
midi_group :: proc(groups: ^[dynamic]Midi_Group, track, channel: int) -> ^Midi_Group {
	for &g in groups do if g.track == track && g.channel == channel do return &g
	append(groups, Midi_Group{track = track, channel = channel, notes = make([dynamic]Midi_Note, context.temp_allocator)})
	return &groups[len(groups) - 1]
}

@(private = "file")
add_midi_note :: proc(s: ^Song, t: ^Track, n: Midi_Note, division, midi: int, rep: ^Midi_Report) {
	start := midi_tick(n.start, division)
	length := max(midi_tick(n.end, division) - start, 3)
	append(&t.notes, Note{tick = start, len = length, pitch = pitch_from_midi(midi, int(s.key)), vel = max(n.vel, 1)})
	rep.notes += 1
}

// The file's own resolution to ours, snapped to whichever grid it is nearer:
// 3 ticks (a 32nd) or 4 (a 32nd-triplet). Human playing lands between them,
// and rounding to one grid alone turns every triplet into a limp.
@(private = "file")
midi_tick :: proc(t: u32, division: int) -> i32 {
	exact := f64(t) * TPQ / f64(division)
	a := i32(exact / 3 + 0.5) * 3
	b := i32(exact / 4 + 0.5) * 4
	return a if abs(f64(a) - exact) <= abs(f64(b) - exact) else b
}

@(private = "file")
Reader :: struct {
	data: []u8,
	pos:  int,
	bad:  bool,
}

@(private = "file")
next :: proc(r: ^Reader) -> u8 {
	if r.pos >= len(r.data) {
		r.bad = true
		return 0
	}
	r.pos += 1
	return r.data[r.pos - 1]
}

// MIDI numbers are big-endian.
@(private = "file")
be :: proc(r: ^Reader, n: int) -> u32 {
	v: u32
	for _ in 0 ..< n do v = v << 8 | u32(next(r))
	return v
}

// A variable-length quantity: seven bits a byte, the top bit saying "more".
@(private = "file")
varlen :: proc(r: ^Reader) -> u32 {
	v: u32
	for _ in 0 ..< 4 {
		b := next(r)
		v = v << 7 | u32(b & 0x7f)
		if b & 0x80 == 0 do break
	}
	return v
}

// A General MIDI program number to the nearest instrument we have. Anything
// unrecognised becomes a pulse lead, which is honest: you can hear that it
// needs changing.
gm_instrument :: proc(program: int) -> string {
	switch program {
	case 0 ..= 5:   return "piano"
	case 6, 7:      return "harpsichord"
	case 8:         return "celesta"
	case 9 ..= 11:  return "glockenspiel"
	case 12, 13:    return "xylophone"
	case 14:        return "glockenspiel"
	case 15:        return "xylophone"
	case 16 ..= 23: return "pipe_organ"
	case 24 ..= 31: return "harp"
	case 32 ..= 39: return "contrabass"
	case 40:        return "violin"
	case 41:        return "viola"
	case 42:        return "cello"
	case 43:        return "contrabass"
	case 44, 45, 48, 49, 50, 51: return "strings"
	case 46:        return "harp"
	case 47:        return "timpani"
	case 52 ..= 54: return "choir"
	case 55 ..= 56, 59: return "trumpet"
	case 57:        return "trombone"
	case 58:        return "tuba"
	case 60 ..= 63: return "horn"
	case 64, 65:    return "clarinet"
	case 66, 67:    return "bassoon"
	case 68:        return "oboe"
	case 69:        return "oboe"
	case 70:        return "bassoon"
	case 71:        return "clarinet"
	case 72:        return "piccolo"
	case 73 ..= 79: return "flute_orch"
	case 80, 81:    return "square_lead"
	case 87:        return "triangle_bass"
	case 112:       return "glockenspiel"
	case 113 ..= 119: return "snare"
	}
	return "pulse_lead"
}
