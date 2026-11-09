package ui

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

// Every key, click and wheel turn the tools read comes through here, never
// straight from raylib. Two reasons, and both are about being able to check a
// tool without sitting in front of it:
//
// **Replay.** `--events` hands the host a script of input — `30 move 400 300`,
// `31 click left`, `40 wheel -3` — and from then on this is the only input
// there is. The tools cannot tell it from a person, which is the point: a
// screenshot taken after the script is a picture of what a person doing that
// would have seen, scroll bars, hovers, modal questions and all.
//
// **Questions.** While a modal question is up (leaving with unsaved changes,
// say) the editor underneath still draws, but it reads no input at all — so a
// click on "keep editing" doesn't also paint a pixel under the button.
//
// The script format is documented in tools/README.md, and `parse_events` is
// the authority on it.

// --- The script ---

Event_Kind :: enum {
	Move,     // move X Y
	Down,     // down left|right|middle — pressed and held
	Up,       // up left|right|middle
	Click,    // click [left] — down this frame, up the next
	Wheel,    // wheel N — positive is away from you, as raylib has it
	Key,      // key NAME — down this frame, up the next; ctrl+shift+NAME holds those too
	Hold,     // hold NAME — down until `let NAME`
	Let,      // let NAME
	Type,     // type some text — characters, as a text field reads them
	Drop,     // drop PATH — a file dropped on the window
	Shot,     // shot PATH — a picture of this frame, once it is drawn
	Quit,     // quit
}

Input_Event :: struct {
	frame:  int,
	kind:   Event_Kind,
	pos:    [2]f32,
	button: rl.MouseButton,
	key:    rl.KeyboardKey,
	mods:   bit_set[Mod],
	amount: f32,
	text:   string, // Type, Drop, Shot: a slice of the script, which is kept
}

Mod :: enum {
	Ctrl,
	Shift,
	Alt,
}

// `30 move 400 300`, one to a line or separated by `;`. `#` starts a comment.
// A frame of `+N` is N after the line before, so a script can be written as
// a sequence of steps without adding it all up by hand. Returns false and a
// message naming the line for anything it doesn't understand: a script that
// half-ran because of a typo is worse than one that refused to start.
parse_events :: proc(script: string, out: ^[dynamic]Input_Event) -> (ok: bool, problem: string) {
	last := 0
	rest := script
	n := 0
	for raw_line in strings.split_lines_iterator(&rest) {
		line_rest := raw_line
		for part in strings.split_iterator(&line_rest, ";") {
			n += 1
			line := part
			if hash := strings.index_byte(line, '#'); hash >= 0 do line = line[:hash]
			line = strings.trim_space(line)
			if line == "" do continue

			words := strings.fields(line, context.temp_allocator)
			if len(words) < 2 do return false, fmt.tprintf("event %v (%q): want a frame and a verb", n, line)

			ev: Input_Event
			at := words[0]
			relative := strings.has_prefix(at, "+")
			f, good := strconv.parse_int(strings.trim_prefix(at, "+"))
			if !good || f < 0 do return false, fmt.tprintf("event %v (%q): %q is not a frame", n, line, at)
			ev.frame = last + f if relative else f
			last = ev.frame

			verb := strings.to_lower(words[1], context.temp_allocator)
			args := words[2:]
			// What follows the verb, as typed: `type a b` types "a b".
			tail := strings.trim_space(line[strings.index(line, words[1]) + len(words[1]):])

			switch verb {
			case "move":
				if len(args) != 2 do return false, fmt.tprintf("event %v (%q): move X Y", n, line)
				x, xo := strconv.parse_f32(args[0])
				y, yo := strconv.parse_f32(args[1])
				if !xo || !yo do return false, fmt.tprintf("event %v (%q): move X Y", n, line)
				ev.kind, ev.pos = .Move, {x, y}
			case "click", "down", "up":
				name := args[0] if len(args) > 0 else "left"
				b, bok := button_named(name)
				if !bok do return false, fmt.tprintf("event %v (%q): %q is not left, right or middle", n, line, name)
				ev.kind = .Click if verb == "click" else (.Down if verb == "down" else .Up)
				ev.button = b
			case "wheel":
				if len(args) != 1 do return false, fmt.tprintf("event %v (%q): wheel N", n, line)
				v, vok := strconv.parse_f32(args[0])
				if !vok do return false, fmt.tprintf("event %v (%q): wheel N", n, line)
				ev.kind, ev.amount = .Wheel, v
			case "key", "hold", "let":
				if len(args) != 1 do return false, fmt.tprintf("event %v (%q): %v NAME", n, line, verb)
				k, mods, kok := key_named(args[0])
				if !kok do return false, fmt.tprintf("event %v (%q): no key called %q", n, line, args[0])
				ev.kind = .Key if verb == "key" else (.Hold if verb == "hold" else .Let)
				ev.key, ev.mods = k, mods
			case "type":
				if tail == "" do return false, fmt.tprintf("event %v (%q): type what?", n, line)
				ev.kind, ev.text = .Type, tail
			case "drop":
				if tail == "" do return false, fmt.tprintf("event %v (%q): drop PATH", n, line)
				ev.kind, ev.text = .Drop, tail
			case "shot":
				if tail == "" do return false, fmt.tprintf("event %v (%q): shot PATH", n, line)
				ev.kind, ev.text = .Shot, tail
			case "quit":
				ev.kind = .Quit
			case:
				return false, fmt.tprintf("event %v (%q): no verb %q", n, line, verb)
			}
			append(out, ev)
		}
	}
	return true, ""
}

@(private = "file")
button_named :: proc(name: string) -> (rl.MouseButton, bool) {
	switch strings.to_lower(name, context.temp_allocator) {
	case "left", "l", "1":   return .LEFT, true
	case "right", "r", "2":  return .RIGHT, true
	case "middle", "m", "3": return .MIDDLE, true
	}
	return .LEFT, false
}

// `ESCAPE`, `a`, `ctrl+s`, `shift+KEY_N`, `ctrl+shift+z`. Names are raylib's,
// with or without `KEY_`, in any case; the modifiers are pressed along with
// it. A single digit or letter is that key.
key_named :: proc(spec: string) -> (key: rl.KeyboardKey, mods: bit_set[Mod], ok: bool) {
	parts := strings.split(spec, "+", context.temp_allocator)
	for p, i in parts {
		low := strings.to_lower(p, context.temp_allocator)
		if i < len(parts) - 1 {
			switch low {
			case "ctrl", "control": mods += {.Ctrl}
			case "shift":           mods += {.Shift}
			case "alt":             mods += {.Alt}
			case:                   return {}, {}, false
			}
			continue
		}
		name := strings.to_upper(strings.trim_prefix(strings.trim_prefix(p, "KEY_"), "key_"), context.temp_allocator)
		switch name {
		case "CTRL", "CONTROL": name = "LEFT_CONTROL" // `hold ctrl`
		case "SHIFT": name = "LEFT_SHIFT"
		case "ALT":   name = "LEFT_ALT"
		case "ESC":   name = "ESCAPE"
		case "RETURN": name = "ENTER"
		case "DEL":   name = "DELETE"
		case "BKSP":  name = "BACKSPACE"
		case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
			names := [10]string{"ZERO", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE"}
			name = names[name[0] - '0']
		case "[": name = "LEFT_BRACKET"
		case "]": name = "RIGHT_BRACKET"
		case "-": name = "MINUS"
		case "=": name = "EQUAL"
		case ",": name = "COMMA"
		case ".": name = "PERIOD"
		}
		for k in rl.KeyboardKey {
			if fmt.tprintf("%v", k) == name do return k, mods, k != .KEY_NULL
		}
		return {}, {}, false
	}
	return {}, {}, false
}

// --- The state the tools read ---

@(private = "file")
MAX_KEYS :: 512

@(private = "file")
Replay :: struct {
	on:       bool,
	events:   [dynamic]Input_Event,
	script:   string, // owned; events slice into it
	next:     int, // first event not yet applied
	frame:    int,
	mouse:    [2]f32,
	before:   [2]f32, // where it was last frame, for the delta
	down:     [3]bool,
	pressed:  [3]bool,
	released: [3]bool,
	release:  [3]bool, // a click lets go on the frame after
	keys:     [MAX_KEYS]bool,
	hit:      [MAX_KEYS]bool, // went down this frame
	lift:     [MAX_KEYS]bool, // went up this frame
	key_up:   [dynamic]rl.KeyboardKey, // `key` events, let go next frame
	wheel:    f32,
	chars:    [dynamic]rune,
	drops:    [dynamic]string,
	shots:    [dynamic]string,
	quit:     bool,
	last:     int, // frame of the last event
}

@(private = "file")
replay: Replay

// While a question is up, the tools see no input. The question itself reads
// with `blocked` lowered for the length of its own turn.
@(private = "file")
blocked: bool

// After an editor hands back to the browser in the middle of a frame, the
// keys that sent it there must not count again: Esc that left an editor would
// otherwise also quit the browser it lands in, on the same frame.
@(private = "file")
swallowed: bool

// After a question is answered with a click, the button may still be down on
// the next frame. Until it comes up, it doesn't count as down.
@(private = "file")
held_off: bool

// The host's count of frames, for anything that must know whether something
// happened this frame or an earlier one.
@(private = "file")
frame_count: int

@(private)
input_frame :: proc() -> int {
	return frame_count
}

// Loads a script and switches real input off for good. `source` is a file if
// there is one by that name, otherwise the script itself (so `--events "30
// click left; 31 quit"` works on the command line).
events_load :: proc(source: string) -> bool {
	text: string
	if os.is_file(source) {
		data, err := os.read_entire_file(source, context.allocator)
		if err != nil {
			fmt.eprintfln("--events: could not read %v", source)
			return false
		}
		text = string(data)
	} else {
		text = strings.clone(source)
	}
	ok, problem := parse_events(text, &replay.events)
	if !ok {
		if !strings.contains_any(source, " ;\n") {
			fmt.eprintfln("--events: there is no file %v (and it isn't a script)", source)
		} else {
			fmt.eprintfln("--events: %v", problem)
		}
		delete(text)
		clear(&replay.events)
		return false
	}
	replay.script = text
	replay.on = true
	for e in replay.events do replay.last = max(replay.last, e.frame)
	// The script is a timeline whatever order it was written in.
	for i in 1 ..< len(replay.events) {
		for j := i; j > 0 && replay.events[j - 1].frame > replay.events[j].frame; j -= 1 {
			replay.events[j - 1], replay.events[j] = replay.events[j], replay.events[j - 1]
		}
	}
	return true
}

events_destroy :: proc() {
	delete(replay.events)
	delete(replay.script)
	delete(replay.key_up)
	delete(replay.chars)
	delete(replay.drops)
	delete(replay.shots)
	replay = {}
}

// True when input comes from a script rather than from a person.
replaying :: proc() -> bool {
	return replay.on
}

// The host calls this at the start of frame `n` (counting from 1), before the
// program's own frame: whatever the script says happens now, happens.
input_begin :: proc(n: int) {
	frame_count = n
	swallowed = false
	if held_off {
		up := true
		for b in ([?]rl.MouseButton{.LEFT, .RIGHT, .MIDDLE}) {
			if replay.on ? replay.down[int(b)] : rl.IsMouseButtonDown(b) do up = false
		}
		if up do held_off = false
	}
	if !replay.on do return
	r := &replay
	r.frame = n
	r.before = r.mouse
	r.pressed, r.released = {}, {}
	r.hit, r.lift = {}, {}
	r.wheel = 0
	clear(&r.chars)
	clear(&r.drops)
	clear(&r.shots)

	// Last frame's clicks and key taps let go now.
	for b in 0 ..< 3 do if r.release[b] {
		r.release[b] = false
		r.down[b] = false
		r.released[b] = true
	}
	for k in r.key_up {
		set_key(r, k, false)
	}
	clear(&r.key_up)

	for r.next < len(r.events) && r.events[r.next].frame <= n {
		e := r.events[r.next]
		r.next += 1
		b := int(e.button)
		switch e.kind {
		case .Move:
			r.mouse = e.pos
		case .Down:
			if !r.down[b] do r.pressed[b] = true
			r.down[b] = true
		case .Up:
			if r.down[b] do r.released[b] = true
			r.down[b] = false
		case .Click:
			r.pressed[b], r.down[b], r.release[b] = true, true, true
		case .Wheel:
			r.wheel += e.amount
		case .Key, .Hold:
			held := [Mod]bool {
				.Ctrl  = r.keys[int(rl.KeyboardKey.LEFT_CONTROL)],
				.Shift = r.keys[int(rl.KeyboardKey.LEFT_SHIFT)],
				.Alt   = r.keys[int(rl.KeyboardKey.LEFT_ALT)],
			}
			if .Ctrl in e.mods do set_key(r, .LEFT_CONTROL, true)
			if .Shift in e.mods do set_key(r, .LEFT_SHIFT, true)
			if .Alt in e.mods do set_key(r, .LEFT_ALT, true)
			set_key(r, e.key, true)
			// A tap lets go next frame — of the modifiers too, unless they
			// were already held by a `hold`.
			if e.kind == .Key {
				append(&r.key_up, e.key)
				if .Ctrl in e.mods && !held[.Ctrl] do append(&r.key_up, rl.KeyboardKey.LEFT_CONTROL)
				if .Shift in e.mods && !held[.Shift] do append(&r.key_up, rl.KeyboardKey.LEFT_SHIFT)
				if .Alt in e.mods && !held[.Alt] do append(&r.key_up, rl.KeyboardKey.LEFT_ALT)
			}
		case .Let:
			set_key(r, e.key, false)
			if .Ctrl in e.mods do set_key(r, .LEFT_CONTROL, false)
			if .Shift in e.mods do set_key(r, .LEFT_SHIFT, false)
			if .Alt in e.mods do set_key(r, .LEFT_ALT, false)
		case .Type:
			for ch in e.text do append(&r.chars, ch)
		case .Drop:
			append(&r.drops, e.text)
		case .Shot:
			append(&r.shots, e.text)
		case .Quit:
			r.quit = true
		}
	}
	// Characters come out of the front of the queue, as raylib's do.
	if len(r.chars) > 1 {
		for i in 0 ..< len(r.chars) / 2 {
			j := len(r.chars) - 1 - i
			r.chars[i], r.chars[j] = r.chars[j], r.chars[i]
		}
	}
}

@(private = "file")
set_key :: proc(r: ^Replay, k: rl.KeyboardKey, down: bool) {
	i := int(k)
	if i <= 0 || i >= MAX_KEYS do return
	if down && !r.keys[i] do r.hit[i] = true
	if !down && r.keys[i] do r.lift[i] = true
	r.keys[i] = down
}

// The pictures the script asked for on this frame, to be taken once it is
// drawn; and whether it asked to stop.
replay_shots :: proc() -> []string {
	return replay.shots[:]
}

replay_quit :: proc() -> bool {
	return replay.quit
}

// The frame of the script's last event: a script without a `quit` stops a
// little after it, so a hidden run never waits on a line nobody wrote.
replay_last_frame :: proc() -> int {
	return replay.last
}

// Drops everything pressed this frame, for the rest of the frame.
input_swallow :: proc() {
	swallowed = true
}

// --- What the tools call ---

@(private)
NOWHERE :: [2]f32{-100000, -100000}

mouse :: proc() -> rl.Vector2 {
	if blocked do return NOWHERE
	if replay.on do return replay.mouse
	return rl.GetMousePosition()
}

mouse_delta :: proc() -> rl.Vector2 {
	if blocked do return {}
	if replay.on do return replay.mouse - replay.before
	return rl.GetMouseDelta()
}

mouse_pressed :: proc(b: rl.MouseButton) -> bool {
	if blocked || swallowed do return false
	if replay.on do return int(b) < 3 && replay.pressed[int(b)]
	return rl.IsMouseButtonPressed(b)
}

mouse_down :: proc(b: rl.MouseButton) -> bool {
	if blocked || held_off do return false
	if replay.on do return int(b) < 3 && replay.down[int(b)]
	return rl.IsMouseButtonDown(b)
}

mouse_released :: proc(b: rl.MouseButton) -> bool {
	if blocked do return false
	if replay.on do return int(b) < 3 && replay.released[int(b)]
	return rl.IsMouseButtonReleased(b)
}

wheel :: proc() -> f32 {
	if blocked || swallowed do return 0
	if replay.on do return replay.wheel
	return rl.GetMouseWheelMove()
}

key_pressed :: proc(k: rl.KeyboardKey) -> bool {
	if blocked || swallowed do return false
	if replay.on do return int(k) > 0 && int(k) < MAX_KEYS && replay.hit[int(k)]
	return rl.IsKeyPressed(k)
}

key_down :: proc(k: rl.KeyboardKey) -> bool {
	if blocked do return false
	if replay.on do return int(k) > 0 && int(k) < MAX_KEYS && replay.keys[int(k)]
	return rl.IsKeyDown(k)
}

key_released :: proc(k: rl.KeyboardKey) -> bool {
	if blocked do return false
	if replay.on do return int(k) > 0 && int(k) < MAX_KEYS && replay.lift[int(k)]
	return rl.IsKeyReleased(k)
}

// Held down long enough to repeat. A script never repeats: it says what it
// presses, frame by frame.
key_repeat :: proc(k: rl.KeyboardKey) -> bool {
	if blocked || swallowed || replay.on do return false
	return rl.IsKeyPressedRepeat(k)
}

// The next character typed this frame, or 0.
char_pressed :: proc() -> rune {
	if blocked || swallowed do return 0
	if replay.on {
		if len(replay.chars) == 0 do return 0
		return pop(&replay.chars)
	}
	return rl.GetCharPressed()
}

// Files dropped on the window this frame. The paths are good for this frame.
dropped_files :: proc() -> []string {
	if blocked || swallowed do return nil
	if replay.on do return replay.drops[:]
	if !rl.IsFileDropped() do return nil
	list := rl.LoadDroppedFiles()
	defer rl.UnloadDroppedFiles(list)
	out := make([]string, int(list.count), context.temp_allocator)
	for i in 0 ..< int(list.count) do out[i] = strings.clone(string(list.paths[i]), context.temp_allocator)
	return out
}

// Seconds since the start. Under a script it is the frame count at sixty a
// second, so a caret's blink, a double click and a playhead come out the same
// on every run and a screenshot can be compared with the last one.
now :: proc() -> f64 {
	if replay.on do return f64(replay.frame) / 60
	return rl.GetTime()
}

@(private)
input_hold_off_mouse :: proc() {
	held_off = true
}

// For the question box: input as it really is, whatever is blocked.
@(private)
input_block :: proc(on: bool) {
	blocked = on
}
