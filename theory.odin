package nengine

import "core:fmt"
import "core:math"
import "core:strings"

// As much music theory as a sheet of music needs, and no more.
//
// PITCH IS STORED THE WAY IT IS WRITTEN, not the way it sounds. F#4 and Gb4
// are the same key on a piano and two different notes on paper, and a song
// that comes back from disk with its sharps turned into flats has been
// damaged. `pitch_midi` gives the sounding number whenever something needs to
// hear it.
//
// STEPS count lines and spaces from C0 = 0 — seven to an octave, so C4
// (middle C) is 28 and the octave is step / 7. Every even step is a staff
// line, and that one fact is what lets a single continuous "super-staff" hold
// the treble clef (E4..F5 = steps 30..38), the bass clef (G2..A3 = 18..26)
// and middle C's ledger line (28) between them, with no clef switching at all.

// Ticks to a quarter note. 24 is the smallest number that divides evenly into
// 32nds (3) and every triplet down to the 32nd-triplet (2), which is why a
// tick is the unit and a "step" of the tracker grid is just six of them.
TPQ :: 24

// The piano: A0 to C8. Every instrument's range lies inside this.
STEP_LO :: 5  // A0
STEP_HI :: 56 // C8
STEP_COUNT :: STEP_HI - STEP_LO + 1

Pitch :: struct {
	step:  i8, // diatonic, C0 = 0
	alter: i8, // -1 flat, 0 natural, +1 sharp
}

STEP_SEMIS := [7]int{0, 2, 4, 5, 7, 9, 11}
LETTERS := [7]u8{'C', 'D', 'E', 'F', 'G', 'A', 'B'}

pitch_midi :: proc(p: Pitch) -> int {
	s := int(p.step)
	return (s / 7 + 1) * 12 + STEP_SEMIS[s % 7] + int(p.alter)
}

// Is this step a staff line? (Even steps are lines, odd ones spaces.)
step_is_line :: proc(step: int) -> bool {
	return step % 2 == 0
}

// The ten bold lines of the grand staff: bass G2..A3, treble E4..F5.
step_is_grand_staff :: proc(step: int) -> bool {
	return step_is_line(step) && ((step >= 18 && step <= 26) || (step >= 30 && step <= 38))
}

// "C#4", "Bb3", "E4".
pitch_text :: proc(p: Pitch, allocator := context.temp_allocator) -> string {
	s := int(p.step)
	acc := ""
	switch p.alter {
	case 1:  acc = "#"
	case -1: acc = "b"
	case 2:  acc = "x"
	case -2: acc = "bb"
	}
	return fmt.aprintf("%c%s%d", rune(LETTERS[s % 7]), acc, s / 7, allocator = allocator)
}

// The other way round. Takes C4, C#4, Cb4, Cx4, Cbb4, Cn4, and lower case.
parse_pitch :: proc(s: string) -> (p: Pitch, ok: bool) {
	if len(s) < 2 do return
	letter := s[0]
	if letter >= 'a' && letter <= 'g' do letter -= 32
	idx := -1
	for l, i in LETTERS do if l == letter do idx = i
	if idx < 0 do return
	rest := s[1:]
	alter := 0
	switch {
	case strings.has_prefix(rest, "bb"): alter, rest = -2, rest[2:]
	case strings.has_prefix(rest, "#"):  alter, rest = 1, rest[1:]
	case strings.has_prefix(rest, "x"):  alter, rest = 2, rest[1:]
	case strings.has_prefix(rest, "b"):  alter, rest = -1, rest[1:]
	case strings.has_prefix(rest, "n"):  rest = rest[1:]
	}
	if len(rest) == 0 || len(rest) > 2 do return
	oct := 0
	for c in transmute([]u8)rest {
		if c < '0' || c > '9' do return
		oct = oct * 10 + int(c - '0')
	}
	step := oct * 7 + idx
	if step < 0 || step > 127 do return
	return Pitch{i8(step), i8(alter)}, true
}

// A MIDI number spelled for a key: black keys become sharps in sharp keys and
// in C, flats in flat keys.
pitch_from_midi :: proc(m: int, key: int = 0) -> Pitch {
	oct := m / 12 - 1
	pc := m %% 12
	SHARP := [12][2]int{{0,0},{0,1},{1,0},{1,1},{2,0},{3,0},{3,1},{4,0},{4,1},{5,0},{5,1},{6,0}}
	FLAT  := [12][2]int{{0,0},{1,-1},{1,0},{2,-1},{2,0},{3,0},{4,-1},{4,0},{5,-1},{5,0},{6,-1},{6,0}}
	e := FLAT[pc] if key < 0 else SHARP[pc]
	return Pitch{i8(oct * 7 + e[0]), i8(e[1])}
}

// --- Key signatures ---

// The order sharps and flats are added in, as letter indices (C=0 .. B=6).
SHARP_ORDER := [7]int{3, 0, 4, 1, 5, 2, 6} // F C G D A E B
FLAT_ORDER := [7]int{6, 2, 5, 1, 4, 0, 3}  // B E A D G C F

// What the key signature does to a step: +1, -1 or nothing.
key_alter :: proc(key: int, step: int) -> i8 {
	letter := step %% 7
	if key > 0 {
		for i in 0 ..< min(key, 7) do if SHARP_ORDER[i] == letter do return 1
	} else if key < 0 {
		for i in 0 ..< min(-key, 7) do if FLAT_ORDER[i] == letter do return -1
	}
	return 0
}

KEY_NAMES := [15]string {
	"Cb major", "Gb major", "Db major", "Ab major", "Eb major", "Bb major", "F major",
	"C major",
	"G major", "D major", "A major", "E major", "B major", "F# major", "C# major",
}

key_name :: proc(key: int) -> string {
	return KEY_NAMES[clamp(key, -7, 7) + 7]
}

// --- Note lengths ---

Length :: enum {
	Whole,
	Half,
	Quarter,
	Eighth,
	Sixteenth,
	Thirty_Second,
}

LENGTH_TICKS := [Length]i32 {
	.Whole = 96, .Half = 48, .Quarter = 24,
	.Eighth = 12, .Sixteenth = 6, .Thirty_Second = 3,
}

LENGTH_LABEL := [Length]string {
	.Whole = "1", .Half = "1/2", .Quarter = "1/4",
	.Eighth = "1/8", .Sixteenth = "1/16", .Thirty_Second = "1/32",
}

Length_Mod :: enum {
	None,
	Dotted,
	Triplet,
}

// How long a note of this length lasts, in ticks. A dotted 32nd would be 4.5
// ticks, so it quietly stays a plain 32nd.
note_ticks :: proc(l: Length, m: Length_Mod) -> i32 {
	t := LENGTH_TICKS[l]
	switch m {
	case .None:
	case .Dotted:  if t % 2 == 0 do t = t * 3 / 2
	case .Triplet: t = t * 2 / 3
	}
	return t
}

// The slot a note of this length snaps to: its own length, or for a dotted
// note half its undotted length — a dotted quarter lands on eighths, which is
// where dotted notes actually fall in real music.
snap_ticks :: proc(l: Length, m: Length_Mod) -> i32 {
	t := LENGTH_TICKS[l]
	switch m {
	case .None:
	case .Dotted:  t = max(t / 2, 3)
	case .Triplet: t = t * 2 / 3
	}
	return t
}

// The nearest length to a number of ticks, for showing what an imported note
// is. Exact where it can be, closest where it can't.
ticks_length :: proc(ticks: i32) -> (Length, Length_Mod) {
	best_l, best_m := Length.Quarter, Length_Mod.None
	best := max(i32)
	for l in Length {
		for m in Length_Mod {
			d := abs(note_ticks(l, m) - ticks)
			if d < best {
				best, best_l, best_m = d, l, m
			}
		}
	}
	return best_l, best_m
}

midi_hz :: proc(m: f32) -> f32 {
	return 440 * math.pow(f32(2), (m - 69) / 12)
}
