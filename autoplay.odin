package nengine

import "core:fmt"
import "core:strings"

// Autoplay: the game playing itself, in its window, from a script.
//
//     mygame --play walkthrough.script [--speed 4]
//
// Not the harness. The harness (script.odin) runs commands before the window
// opens and settles everything instantly, which is right for tests and wrong
// for watching. Autoplay plays the script the way a person would: from the
// menu's Start (so the intro plays), typing each command at the prompt, with
// real frames — the walking walked, the rides ridden, every line and every
// announcement up long enough to read, and then Enter. `--speed` runs the
// world faster (4 by default): as fast as it can go and still be watched.
//
// The script is the harness's format: one command a line, `#` for comments,
// `until HH:MM <command>` to repeat a real command until the clock reads that.
// Bangs (`!at`, `!room`) are the harness's and are skipped here: a playthrough
// that teleports is not a playthrough.
//
// What it does with what is on the screen, as a reader would:
//
// - A line of a conversation, a peep's line, an epilogue card, an
//   announcement: up for its reading time, then Enter. A choice in a
//   conversation is the next line of the script, typed at the prompt, as the
//   player answers it; so is a timed question, inside its seconds.
// - A cutscene plays at its own pace (at the world's speed); nothing is typed
//   and nothing is pressed until it ends.
// - A ride the script started is the player's: WAIT in it lets the glance
//   run out instead of cutting it short, so the host looks for as long as it
//   looks, and the glances come round as the harness counts them. A ride the
//   story started (a beat's, a scripted one) is watched to its end.
// - A line half typed when something comes up on screen waits, typed, until
//   the screen is hers again, and then goes in. A command run under a
//   conversation or a cutscene would be lost.
// - While a deadline runs (timer.odin), she skims: lines are up for a
//   quarter of their time and she types faster, as a person with seconds on
//   the clock does.
// - When the script runs out, whatever is still coming plays out — the last
//   conversation, its card — and the last screen (a score, an overlay) stays
//   up for the watcher. Nothing more is typed.

Autoplay :: struct {
	lines:     []string,
	at:        int,     // the next line
	until:     int,     // the clock minute an `until` line runs to; -1 when none
	key:       string,  // what is on screen, so we know when it changes
	wait:      f32,     // world seconds before doing anything about it
	typing:    string,  // the command being typed
	typed:     int,
	done:      bool,    // nothing more to do, ever (she died)
	ended:     bool,    // the script has run out: reading on, typing nothing

	// Rides. Whose this one is, and the glances it has shown since the
	// script last typed, so WAIT can be counted as the harness counts it.
	own_ride:  bool,
	was_riding: bool,
	walk_cmd:  bool,    // the last line set off a walk; a ride when it lands is the line's
	asked_ride: bool,   // the last line was RIDE: a ride that begins after it (a line of hers first) is hers
	glances:   int,
	glance:    int,
	glance_t:  f32,
	glance_on: bool,
}

autoplay_new :: proc(script: string) -> (ap: Autoplay) {
	ap.lines = strings.split(script, ";")
	ap.until = -1
	return
}

autoplay_destroy :: proc(ap: ^Autoplay) {
	delete(ap.lines)
	delete(ap.key)
}

// How long a thing stays up, in world seconds: a breath, and a reading speed.
// Racing a deadline, a quarter of it.
@(private = "file")
read_secs :: proc(w: ^World, text: string) -> f32 {
	secs := 1.0 + f32(len(text)) / 22
	return secs * AUTOPLAY_SKIM if racing(w) else secs
}

// Racing a deadline: how much of a line's reading time she gives it, and the
// longest she will look at anything at all.
AUTOPLAY_SKIM :: f32(0.25)
AUTOPLAY_SKIM_MAX :: f32(1.5)

// What holds the screen, as something to compare, and its words. A line of a
// conversation is keyed by when it went up as well as where it is, so the
// first line of the next conversation in the same struct is read too.
@(private = "file")
on_screen :: proc(w: ^World) -> (key, text: string) {
	switch {
	case announcing(w):
		a := w.announcing
		return fmt.tprintf("an:%v", a.name), strings.concatenate({a.title, a.text}, context.temp_allocator)
	case talking(w):
		c := w.talk
		return fmt.tprintf("talk:%p:%v:%v", c, c.at, c.started), c.lines[c.at].text
	case overlay_open(w):
		return "overlay", "                                        " // a look, not a read
	}
	if m := message(w); m != "" do return fmt.tprintf("msg:%v", m), m
	return "", ""
}

// Something on the screen that is not hers to type over: a conversation, an
// announcement, an overlay, a cutscene, the death box.
@(private = "file")
screen_held :: proc(w: ^World) -> bool {
	return announcing(w) || talking(w) || overlay_open(w) || cutting(w) || w.dead
}

// Busy by itself: walking there, going under, coming back, a gesture, or a
// ride the story is giving her.
@(private = "file")
busy :: proc(w: ^World, ap: ^Autoplay) -> bool {
	if approaching(w) || w.player.moving || actor_playing(&w.player) || cutting(w) do return true
	if riding(w) && (w.ride.phase != .Riding || !ap.own_ride) do return true
	return false
}

// Whose ride it is, and the glances that come round by themselves.
@(private = "file")
watch_ride :: proc(w: ^World, ap: ^Autoplay) {
	now := riding(w)
	if now && !ap.was_riding {
		// Begun since the last frame, and not inside a line the script typed
		// (that is marked as it is typed): the line's only if the walk it set
		// off has just landed. Otherwise the story's.
		ap.own_ride = (ap.walk_cmd && !approaching(w)) || ap.asked_ride
		ap.asked_ride = false
		ap.glances, ap.glance_on = 0, false
	}
	if !now {
		ap.own_ride, ap.glance_on = false, false
	}
	if ap.walk_cmd && !approaching(w) do ap.walk_cmd = false
	ap.was_riding = now

	if now && w.ride.phase == .Riding {
		if ap.glance_on && (w.ride.glance != ap.glance || w.ride.t < ap.glance_t) do ap.glances += 1
		ap.glance, ap.glance_t, ap.glance_on = w.ride.glance, w.ride.t, true
	}
}

// Is this line WAIT, as the parser reads it (its synonyms too)?
@(private = "file")
is_wait :: proc(w: ^World, line: string) -> bool {
	cmd, err, _ := parse(line, w.vocab, w.last_noun)
	return err == .None && cmd.verb == "wait" && cmd.noun == ""
}

// Is there a real command left in the script, after any bangs and blanks?
@(private = "file")
lines_left :: proc(ap: ^Autoplay) -> bool {
	for i in ap.at ..< len(ap.lines) {
		line := strings.trim_space(ap.lines[i])
		if line != "" && !strings.has_prefix(line, "!") do return true
	}
	return false
}

// One frame of it, before the world's own update. `dt` is the world's.
autoplay_step :: proc(w: ^World, ap: ^Autoplay, dt: f32) {
	if ap.done do return
	if w.dead {
		fmt.println("autoplay: she died, and the script stops here")
		ap.done = true
		return
	}
	watch_ride(w, ap)
	hurry := racing(w)
	if hurry do ap.wait = min(ap.wait, AUTOPLAY_SKIM_MAX)

	// Typing: a few letters a frame, then a beat, then Enter — unless the
	// screen has been taken while she typed, and then the line waits.
	if ap.typing != "" && !screen_held(w) && !(riding(w) && w.ride.phase != .Riding) && !(riding(w) && !ap.own_ride) {
		ap.wait -= dt
		if ap.wait > 0 do return
		if ap.typed < len(ap.typing) {
			ap.typed += 1
			w.input_len = copy(w.input[:], ap.typing[:ap.typed])
			if hurry do ap.wait = 0.02 if ap.typed < len(ap.typing) else 0.15
			else do ap.wait = 0.05 if ap.typed < len(ap.typing) else 0.5
			return
		}
		w.last_len = copy(w.last_input[:], w.input[:w.input_len])
		w.input_len = 0
		ap.typing, ap.typed = "", 0
		was := riding(w)
		typed := string(w.last_input[:w.last_len])
		if c, err, _ := parse(typed, w.vocab, w.last_noun); err == .None do ap.asked_ride = c.verb == "ride"
		else do ap.asked_ride = false
		run_command(w, typed)
		if !was && riding(w) do ap.own_ride = true
		ap.was_riding = riding(w)
		ap.walk_cmd = approaching(w)
		ap.glances, ap.glance_on = 0, false
		return
	}

	// Something new on screen: give it its time.
	key, text := on_screen(w)
	if key != ap.key {
		delete(ap.key)
		ap.key = strings.clone(key)
		ap.wait = read_secs(w, text) if key != "" else 0.3
		return
	}
	ap.wait -= dt
	if ap.wait > 0 do return

	// Read: press on. An announcement holds even a cutscene, and is closed
	// as it would be; a cutscene is left to play, and a conversation under
	// one waits for it.
	switch {
	case announcing(w):
		close_announcement(w)
		return
	case cutting(w):
		return
	case talking(w):
		advance_conversation(w)
		return
	case overlay_open(w):
		// The last screen stays up for the watcher: the score, after the
		// last line of the script.
		if !lines_left(ap) && ap.typing == "" {
			if !ap.ended do fmt.println("autoplay: the end of the script")
			ap.ended = true
			return
		}
		close_overlay(w)
		return
	}
	if busy(w, ap) do return
	if ap.typing != "" do return // half typed: it goes in when the screen is hers

	// The next command.
	for ap.at < len(ap.lines) {
		line := strings.trim_space(ap.lines[ap.at])
		if line == "" || strings.has_prefix(line, "!") {
			if line != "" do fmt.printfln("autoplay: skipping %v (a harness bang)", line)
			ap.at += 1
			continue
		}
		if target, cmd, is_until := parse_until(w, line); is_until {
			if ap.until < 0 do ap.until = target
			if clock_minute(w) < ap.until {
				ap.typing = cmd
				return
			}
			ap.until = -1
			ap.at += 1
			continue
		}
		// WAIT in her own ride: the glance runs out by itself, as long as
		// the host looks. One that has already come round while she read
		// is the one this WAIT was for.
		if riding(w) && ap.own_ride && w.ride.phase == .Riding && !hurry && is_wait(w, line) {
			if ap.glances > 0 {
				ap.glances -= 1
				ap.at += 1
				continue
			}
			return
		}
		ap.typing = line
		ap.at += 1
		return
	}
	if !ap.ended do fmt.println("autoplay: the end of the script")
	ap.ended = true
}

// --- In the harness ---

// `!autoplay <file> [snaps=<folder>]`: the script played as --play plays it,
// in the harness, with nothing drawn and no clock on the wall: autoplay_step
// and update, a sixtieth of a second at a time, which is what --play does at
// any --speed between two draws (launch.odin). Every line read for its time
// and then Enter, every walk walked, people on their routines and walking on
// and off. What real frames do that the harness's settled commands hide,
// without a window: everybody she speaks to, and every line a person says to
// her face, is checked to be in sight (sight.odin), and the ghosts are
// listed, each with a picture of the frame if `snaps=` names a folder. From
// where the game is, as the script expects it (`!intro` first, for a
// playthrough from the menu's Start).
autoplay_bang :: proc(w: ^World, arg: string) -> string {
	args := strings.fields(arg, context.temp_allocator)
	if len(args) == 0 do return "!autoplay <file> [snaps=<folder>]"
	snaps := ""
	for a in args[1:] do if strings.has_prefix(a, "snaps=") do snaps = a[len("snaps="):]
	script, ok := read_script_file(args[0])
	if !ok do return fmt.tprintf("!autoplay: cannot read %q", args[0])
	defer delete(script)
	ap := autoplay_new(script)
	defer autoplay_destroy(&ap)
	sight_watch_reset()
	sight_watch.on = true
	sight_watch.snaps = snaps
	defer sight_watch.on = false
	dt := f32(1.0 / 60)
	seen: rawptr
	seen_at, frames := -1, 0
	seen_started := f32(-1)
	for !ap.ended && !ap.done && frames < AUTOPLAY_HARNESS_FRAMES {
		autoplay_step(w, &ap, dt)
		update(w, dt)
		frames += 1
		if talking(w) {
			c := w.talk
			if rawptr(c) != seen || c.at != seen_at || c.started != seen_started {
				seen, seen_at, seen_started = c, c.at, c.started
				sight_check_line(w, c.lines[c.at])
			}
		}
	}
	end := "the end of the script" if ap.ended else "she died" if ap.done else "out of time"
	return fmt.tprintf("%v world seconds, %v: %v at %v; %v", frames / 60, end, current_scene(w).name,
		clock_face(clock_minute(w)), sight_report())
}

// The longest a harness autoplay runs: six hours of the world's seconds.
AUTOPLAY_HARNESS_FRAMES :: 60 * 60 * 60 * 6
