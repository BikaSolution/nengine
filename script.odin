package nengine

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

// The test harness: commands typed for you, before the window opens, with
// every reply printed. It is the only way to check a parser change, a room or
// a line of dialogue without sitting at the prompt typing, and it is what
// `just smoke` drives.
//
//     just game --skip --script "look; !room admin; look at the chest; !tick 40"
//
// A line starting `!` is the harness talking to the game rather than the
// player talking to the protagonist. Those are not in the vocabulary, cannot
// be typed at the prompt, and never reach a player — --script does not either.
// The engine's own:
//
//     !room <name>          go there, standing in the middle of the floor
//     !tick [n]             spend n ticks of the story clock (default 1)
//     !clock                what hour it is
//     !secs <n>             let n seconds of real time pass, for a timer
//     !restore              the death box's Restore: its restore point, or the newest save
//     !click x,y            a click in the room, as the mouse's, walked out: on
//                           the floor, or the brink of an edge and over (edge.odin)
//     !arrow <dir> [secs]   an arrow key tapped, walked until she stops, goes
//                           over an edge or out: up, down, left, right, upleft...
//     !sides                the room's sides: where each goes, its span and
//                           brink, its gate, its partner (side_harness.odin)
//     !cross <dir> [at=c] [by=go|arrow|click]
//                           across a side, walked out: as GO NORTH, the arrow
//                           key, or a click just beyond the brink
//     !strip <a> <b>|around neighbours drawn as one picture (probe.odin)
//     !at HH:MM             spend ticks until the clock reads that, next time
//                           it does — the first tick at or after it
//     !flag <name>          turn a flag on; `!flag !name` turns it off
//     !dress <group> <n>    wear dressing n of a room worn several ways
//     !note <tab> <id> [@minute] <text...>
//                           write an entry, for testing a notebook before the
//                           beat that writes it exists. `@1450` stamps it at a
//                           minute on the game's clock rather than now
//     !book [tab]           print the notebook, or one tab of it, as text
//     !ride                 who is being ridden and what it is looking at, and
//                           where the body was left
//     !ride <host>          go under and stay in the handover, for a --shot
//     !leave <n>            the next conversation the harness reads, it leaves
//                           (Escape) on its nth line: a peep left part-way
//     !typing <words>       leave words in the typing line, unsent: a --shot
//                           of the prompt with a command half typed
//     !hold <words>         the next conversation the harness reads, it stops
//                           on the first line with these words in it (or on
//                           the nth line, for a number) and leaves it up, for
//                           a --shot of a line; a cutscene, it leaves to play
//                           in the frames after the script (`--at` picks the
//                           moment); an announcement, it leaves up. Nothing
//                           runs on past it: the script's last line
//     !passer [window] [left|right] [at=F]
//                           somebody going past a window here: now, walking
//                           (`--at` picks the moment), or held F of the way
//                           across; `!passer ?` what is coming, `!passer
//                           chance=1` every room, `seed=N` the dice
//     !cuts                 every cutscene loaded: how long, where, who
//     !cut <name>           play one, here, as play_cutscene would
//     !bar [hover <item> | <item> [row] | off]
//                           the menu bar held down for a shot, an item picked
//                           out, or an item run as a click would (menubar.odin)
//     !screen [<n> | hover <n> | esc]
//                           the screen the bar opened, as text; row n clicked,
//                           or under the pointer; Esc (screens.odin)
//     !hint [2|3|list|try|check|coverage]
//                           the hint at a grade and the entry it is; what
//                           could be done; its answer tried in a copy of the
//                           game; a walk's check; the table against the
//                           awards (hint.odin)
//     !status               how she is getting on, as the hint screen says it
//     !title [at=F] [about] [load [n]]
//                           the title screen instead of play, for a --shot:
//                           its dusk held F of the way to night (0 to 1), its
//                           About page up, its Load screen up and row n (from
//                           1) picked, which goes into the save, printing
//                           where she is (menu.odin, launch.odin)
//     !autoplay <file> [snaps=<folder>]
//                           the script played in real frames, as --play
//                           plays it, undrawn; and every ghost: somebody
//                           spoken to, or speaking to her, out of sight
//                           (autoplay.odin, sight.odin)
//     !stand !put !show !hide !snap !crowd !spots !sheet
//                           pictures of the room for checking who is drawn in
//                           front of what (probe.odin)
//
// A cutscene plays out at once: `[cutscene <name>]`, every line it says as a
// conversation's lines are printed, and `[end <name>]`.
//
// Anything else starting `!` goes to `on_bang`, which is the game's.

// A game's own harness command. `reply` is printed after it; `handled` false
// means the harness does not know the word, and it says so.
Bang :: proc(w: ^World, word, arg: string) -> (reply: string, handled: bool)

run_script :: proc(w: ^World, script: string, on_bang: Bang = nil) {
	if script != "" do log_ready(w)
	// The same dice every run, so a script's passers are the same every run.
	if script != "" do passer_seed(w, PASSER_SCRIPT_SEED)
	// A game may open on a conversation, before anything is typed.
	if script != "" && talking(w) {
		fmt.println("> (the game opens)")
		print_conversation(w)
	}
	rest := script
	for line in strings.split_iterator(&rest, ";") {
		said := strings.trim_space(line)
		if said == "" do continue
		// `until 23:45 wait`: the command, again and again, until the clock
		// reads that. Real play, spelled shorter — no bang, no jump.
		if target, cmd, is_until := parse_until(w, said); is_until {
			for n := 0; clock_minute(w) < target && !w.dead && n < 1000; n += 1 {
				script_line(w, cmd, on_bang)
			}
			continue
		}
		script_line(w, said, on_bang)
	}
	probe_finish() // a contact sheet still open is written now (probe.odin)
}

// `until HH:MM <command>`: the minute on the story clock it runs to (the next
// time the clock reads it, as `!at`), and the command. False if it is not one.
parse_until :: proc(w: ^World, line: string) -> (target: int, cmd: string, ok: bool) {
	if !strings.has_prefix(line, "until ") do return
	rest := strings.trim_space(line[len("until "):])
	sp := strings.index_byte(rest, ' ')
	if sp < 0 do return
	at, command := rest[:sp], strings.trim_space(rest[sp + 1:])
	colon := strings.index_byte(at, ':')
	if colon < 0 do return
	h, ok_h := strconv.parse_int(at[:colon])
	m, ok_m := strconv.parse_int(at[colon + 1:])
	if !ok_h || !ok_m || command == "" do return
	// The next time the clock reads it — but a time only just gone is
	// already here, not tomorrow: `until 23:00` at 23:05 does nothing rather
	// than wait a whole day. Twelve hours behind is the line: `until 00:30`
	// at 23:00 is tonight.
	target = h * 60 + m
	now := clock_minute(w)
	for target + 12 * 60 < now do target += 24 * 60
	return target, command, true
}

// A script from a file: one line each, `#` for a comment. What `--script
// @path` reads, and what `--play` plays.
read_script_file :: proc(path: string, allocator := context.allocator) -> (script: string, ok: bool) {
	text := read_data_file(path) or_return
	b := strings.builder_make(allocator)
	for raw in strings.split_lines_iterator(&text) {
		line := strings.trim_space(raw)
		if hash := strings.index_byte(line, '#'); hash >= 0 do line = strings.trim_space(line[:hash])
		if line == "" do continue
		if strings.builder_len(b) > 0 do strings.write_byte(&b, ';')
		strings.write_string(&b, line)
	}
	return strings.to_string(b), true
}

// One line of a script, as the harness does it: a bang, or a command typed
// at the prompt and everything it sets going. Package-wide for the hint's
// try (hint.odin), which types the answer in a copy of the game.
@(private)
script_line :: proc(w: ^World, said: string, on_bang: Bang) {
	{
		// Each line is a row of the play log, ended when the line is
		// (playlog.odin); a bang's row is what it set going.
		defer log_end(w)
		if strings.has_prefix(said, "!") {
			log_begin(w, said)
			log_route(w, "harness")
			fmt.printfln("> %v  (%v)", said, bang(w, said[1:], on_bang))
			// `!room` walks in, as far as the room knows, and a room may
			// answer that with a conversation.
			run_on(w)
			if !w.script_held do sight_settle(w) // as the frames after it would (sight.odin)
			return
		}
		fmt.printfln("> %v", said)
		// A player closes the notebook before typing at the prompt, and the
		// prompt cannot be reached while it is open; the harness does the same.
		if overlay_open(w) do close_overlay(w)
		// And a command that says nothing must print nothing — not whatever the
		// last one said. A harness that can show a stale reply is lying.
		w.message_len = 0
		room_before := w.current
		run_command(w, said)
		// A command that sent the player walking runs when they arrive, so the
		// harness walks them there — the real steps, undrawn — and says where
		// they ended up. That is also the only scripted check on walking.
		if approaching(w) {
			p := finish_approach(w)
			fmt.printfln("  [walked to %.0f,%.0f]", p.x, p.y)
		} else if w.player.moving {
			// GO TO an exit: the same, and it may end in another room.
			from := w.current
			p := finish_walk(w)
			if w.current != from do fmt.printfln("  [went to %v]", current_scene(w).name)
			else do fmt.printfln("  [walked to %.0f,%.0f]", p.x, p.y)
		}
		// A gesture is not waited for either: it ends, and what it was for
		// happens. See anim.odin.
		// An exit gone through as a climb changes the room at the end of it,
		// and may start another part on the far side; the harness ends both.
		for _ in 0 ..< 4 {
			part := finish_player_anim(w)
			if part == "" do break
			fmt.printfln("  [played %v]", part)
			if w.current != room_before {
				fmt.printfln("  [went to %v]", current_scene(w).name)
				room_before = w.current
			}
		}
		// A room walked (or climbed) into: its first frame fires a trigger
		// over the whole floor, as play does. finish_walk stops the moment
		// the room changes, before any frame there, so the harness does it.
		// Whatever it says is read out below, as part of this command's reply.
		if arrival_due(w) do check_triggers(w, w.player.pos)
		// A conversation waits for Enter, line by line. The harness reads them
		// all out and presses on, and prints whatever is said after the last.
		// At an aperture: which window, then its lines, then the catch if
		// there was one. See peep.odin.
		if w.peeping.active && !w.peeping.announced {
			w.peeping.announced = true
			fmt.printfln("  [peep %v: %v]", w.peeping.object, w.peep_windows[w.peeping.window].name)
		}
		w.peep_caught_by = ""
		talked := talking(w) && print_conversation(w)
		if w.peep_caught_by != "" {
			fmt.printfln("  [caught by %v at line %v]", w.peep_caught_by, w.peep_caught_at)
			w.peep_caught_by = ""
		}
		reply := message(w)
		switch {
		case talked && reply == "":
		case reply == "" && cutting(w): // it is read out below
		case reply != "":
			fmt.printfln("  %v", reply)
		case overlay_open(w):
			fmt.printfln("  [an overlay is open]")
		case:
			fmt.printfln("  [nothing said]")
		}
		if riding(w) do settle_ride_aloud(w)
		// Then whatever that set going, as the frames after it would: a beat
		// the hour has brought on, a ride it started, a conversation at the
		// end of the ride — until nothing more is happening by itself.
		run_on(w)
		// And once the screen is hers: whoever was called into sight to
		// speak, or gone and kept in the picture, gone (sight.odin).
		if !w.script_held do sight_settle(w)
	}
}

// Whatever a command set going, as the frames after it would: a beat the hour
// has brought on, a ride it started, the conversation at the end of the ride
// — until nothing more is happening by itself.
//
// A ride the player started waits for her WAITs and her GET UP, as it would
// at the prompt. A ride that started by itself on the way (a beat, the end of
// a conversation: a scripted ride) goes round once, as its frames would take
// it, and she comes back: in play it ends itself, and a harness that left her
// in it would answer every later line as a passenger.
@(private = "file")
run_on :: proc(w: ^World) {
	ours := riding(w) // under already: the command's own ride
	// A line `!hold` left up stays up: nothing runs on past it.
	for moved := true; moved && !w.script_held; {
		moved = true
		if !riding(w) do ours = false
		switch {
		case w.script_hold != "" && (announcing(w) || open_announcement(w)):
			// `!hold` and an announcement: it stays up, as a conversation's
			// line would.
			delete(w.script_hold)
			w.script_hold = ""
			w.script_held = true
			fmt.printfln("  [announcement held] %v", w.announcing.title)
		case announce_aloud(w):
		case cutting(w) && w.script_hold != "":
			// `!hold` and a cutscene: it plays in the frames after the
			// script, on its own clock, and `--at` picks the moment.
			delete(w.script_hold)
			w.script_hold = ""
			w.script_held = true
			fmt.println("  [the cutscene is left to play]")
		case cutting(w):
			fmt.print(cutscene_aloud(w))
		case talking(w):
			print_conversation(w)
		case riding(w) && w.ride.phase != .Riding:
			settle_ride_aloud(w)
		case riding(w) && !ours:
			play_ride_out(w)
		case play_beats(w):
			fmt.println("  [a beat]")
		case keep_out_aloud(w):
			// A room the story has just shut on her: out of it, as the
			// frames would walk her (keep_out.odin).
		case arrival_due(w):
			// In a new room by some other way (a conversation that ends
			// somewhere else, a restore): its first frame, as above.
			before := strings.clone(message(w), context.temp_allocator)
			check_triggers(w, w.player.pos)
			if m := message(w); m != "" && m != before && !talking(w) do fmt.printfln("  %v", m)
		case w.dead && !w.death_box:
			// No frames to play the death out in: say it, and stop there.
			fmt.printfln("  [dead: %v]", w.death.reason)
			w.death_box = true
		case w.passer.phase == .Waiting && !w.passer.forced:
			// Somebody the room rolled for goes past now, as a walk is
			// finished at once (passer.odin). Seen, and nothing more.
			if said, ok := passer_walk_out(w); ok do fmt.printfln("  %v", said)
		case:
			moved = false
		}
	}
}

// Just come into a room whose first frame has not run: update() would call
// check_triggers on it now, and a trigger over the whole floor would fire.
// Not while something else holds the frame first — a conversation, a ride, a
// death, a gesture or a climb still being played — as update() returns
// before it gets there; that frame comes later.
@(private = "file")
arrival_due :: proc(w: ^World) -> bool {
	if !w.fresh_room || w.dead || overlay_open(w) || announcing(w) || talking(w) || riding(w) || cutting(w) do return false
	return !actor_playing(&w.player) && !w.exit_walk.active
}

// Every line of the conversation that is up, then on to the end of it. True
// if there was anything to print.
@(private = "file")
print_conversation :: proc(w: ^World) -> bool {
	any := false
	read := 0
	for talking(w) {
		c := w.talk
		line := c.lines[c.at]
		who := line.who.name if line.who != nil else ""
		if line.card {
			fmt.printfln("  [card] %v", line.text)
		} else if who != "" {
			fmt.printfln("  %v: %v", who, line.text)
		} else {
			fmt.printfln("  %v", line.text)
		}
		any = true
		read += 1
		// `!hold`: this line stays up, and the harness reads no further.
		if w.script_hold != "" && hold_here(w.script_hold, read, line) {
			delete(w.script_hold)
			w.script_hold = ""
			w.script_held = true
			fmt.printfln("  [held at line %v]", read)
			return any
		}
		// `!leave n`: Escape on the nth line, as a player who stepped away.
		if w.script_leave_after > 0 && read == w.script_leave_after {
			w.script_leave_after = 0
			fmt.printfln("  [left after %v line(s)]", read)
			skip_conversation(w)
			announce_aloud(w)
			continue
		}
		advance_conversation(w)
		// The next frame would show an announcement before the next line: a
		// conversation that ends by starting another, with something found
		// in between.
		announce_aloud(w)
	}
	return any
}

// Is this the line `!hold` asked for: the nth, or the first with the words in
// it (in its text or its speaker's name, either case)?
hold_here :: proc(hold: string, read: int, line: Talk_Line) -> bool {
	if n, is_number := strconv.parse_int(hold); is_number do return read == n
	want := strings.to_lower(hold, context.temp_allocator)
	if strings.contains(strings.to_lower(line.text, context.temp_allocator), want) do return true
	return line.who != nil && strings.contains(strings.to_lower(line.who.name, context.temp_allocator), want)
}

// An announcement, if one is due or up: read out and pressed on from, as a
// player would. True if there was one.
@(private = "file")
announce_aloud :: proc(w: ^World) -> bool {
	if !open_announcement(w) && !announcing(w) do return false
	a := w.announcing
	fmt.printfln("  [announcement] %v — %v", a.title, a.text)
	close_announcement(w)
	return true
}

// A scripted ride, as its frames would play it: each glance in turn, read
// out, until one breaks off or the host has looked round once; then back.
@(private = "file")
play_ride_out :: proc(w: ^World) {
	h := ride_host(w)
	host := h.name
	for _ in 0 ..< len(h.attention) {
		if !riding(w) || w.ride.phase != .Riding do break
		g := h.attention[w.ride.glance]
		if g.leaves do break
		before := strings.clone(message(w), context.temp_allocator)
		begin_glance(w, next_glance(w, h, w.ride.glance))
		if g := ride_glance(w); g != nil do fmt.printfln("  [through the %v: %v]", host, g.look)
		if m := message(w); m != "" && m != before do fmt.printfln("  %v", m)
	}
	come_back(w)
}

// Going under and coming back take frames, and the harness has none: finish
// the handover, and say where that left things — which glance, or where the
// body is.
@(private = "file")
settle_ride_aloud :: proc(w: ^World) {
	before := strings.clone(message(w), context.temp_allocator)
	host := ride_host(w).name
	settle_ride(w)
	if g := ride_glance(w); g != nil {
		fmt.printfln("  [through the %v: %v]", host, g.look)
	} else if room, pos, ok := ride_body(w); ok && !riding(w) {
		fmt.printfln("  [back: %v at %.0f,%.0f]", room, pos.x, pos.y)
	}
	// A ride that ends in a conversation: run_on reads that out, line by line.
	if m := message(w); m != "" && m != before && !talking(w) do fmt.printfln("  %v", m)
}

@(private)
bang :: proc(w: ^World, line: string, on_bang: Bang) -> string {
	word, arg := line, ""
	if sp := strings.index_byte(line, ' '); sp >= 0 {
		word, arg = line[:sp], strings.trim_space(line[sp + 1:])
	}

	switch word {
	case "title":
		// !title [at=F] [about] [load [n]] — the title screen for a --shot,
		// its dusk held F of the way to night, its About page up, its Load
		// screen up and row n picked (launch.odin).
		return title_bang(arg)
	case "room":
		// !room on its own: where she is, and when.
		if arg == "" do return fmt.tprintf("%v at %.0f,%.0f, %v", current_scene(w).name, w.player.pos.x, w.player.pos.y, clock_face(clock_minute(w)))
		if !go_to_named(w, arg) do return fmt.tprintf("no room called %q", arg)
		p := w.player.pos
		// Kept from her now (keep_out.odin): the harness is let in, and says so.
		if w.keep_out_let == arg do return fmt.tprintf("%v at %.0f,%.0f (kept out now: let through)", arg, p.x, p.y)
		return fmt.tprintf("%v at %.0f,%.0f", arg, p.x, p.y)

	case "tick":
		n := 1
		if arg != "" {
			v, ok := strconv.parse_int(arg)
			if !ok do return fmt.tprintf("%q is not a number of ticks", arg)
			n = v
		}
		tick(w, n)
		return fmt.tprintf("%v, %v ticks", clock_face(clock_minute(w)), w.clock_ticks)

	case "clock":
		return fmt.tprintf("%v, %v ticks", clock_face(clock_minute(w)), w.clock_ticks)

	case "sound":
		// What she can hear: the ambience, the loops here, the music, the
		// bed, and the sounds played since the last !sound (audio.odin).
		return sound_report(w)

	case "node":
		// !node A2.GT.SPEECH [tag]: plays a dialogue node, as the game would.
		id, tag := arg, ""
		if sp := strings.index_byte(arg, ' '); sp >= 0 do id, tag = arg[:sp], strings.trim_space(arg[sp + 1:])
		if !play_node(w, id, tag = tag) do return fmt.tprintf("no node %v", id)
		return fmt.tprintf("playing %v", id) // its lines follow, as any conversation's do

	case "cuts":
		// Every cutscene loaded, by the name play_cutscene knows it by.
		if w.assets == nil || len(w.assets.cuts) == 0 do return "no cutscenes"
		names := make([dynamic]string, context.temp_allocator)
		for name in w.assets.cuts do append(&names, name)
		slice.sort(names[:])
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, "%v cutscene(s)", len(names))
		for name in names {
			c := &w.assets.cuts[name]
			lines := 0
			for q in c.cues do if q.action == .Say || q.action == .Think || q.action == .Narrate do lines += 1
			fmt.sbprintf(&b, "\n    %v: %.0fs in %v, %v cast, %v cue(s), %v line(s)", name, cutscene_length(c),
				c.scene if c.scene != "" else "(any room)", len(c.people), len(c.cues), lines)
		}
		return strings.to_string(b)

	case "cut":
		// !cut the_cow: plays it here, as the game would. Its lines follow.
		if !play_cutscene(w, arg) do return fmt.tprintf("no cutscene %v", arg)
		return fmt.tprintf("playing %v", arg)

	case "typing":
		// !typing look at the nail: words left in the typing line, unsent, for
		// a --shot of the prompt with something in it.
		w.input_len = copy(w.input[:], arg)
		return fmt.tprintf("%q in the typing line", string(w.input[:w.input_len]))

	case "bar":
		// !bar, !bar hover save, !bar save 3: the menu bar (menubar.odin).
		return bar_bang(w, arg)

	case "screen":
		// !screen, !screen 3, !screen hover 3, !screen esc (screens.odin).
		return screen_bang(w, arg)

	case "hint":
		// !hint, !hint 2, !hint 3, !hint list, !hint try, !hint check,
		// !hint coverage (hint.odin).
		return hint_bang(w, arg, on_bang)

	case "status":
		// !status: how she is getting on, as the hint screen says it.
		return status_report(w)

	case "hold":
		// !hold Odu: the next conversation read out stops on the line that
		// says it, and stays up for the frames after the script.
		if arg == "" do return "hold on which line?"
		if w.script_hold != "" do delete(w.script_hold)
		w.script_hold = strings.clone(arg)
		w.script_held = false
		return fmt.tprintf("the next conversation is held at %q", arg)

	case "leave":
		// !leave 2: the next conversation read out is left on its second line.
		n, ok := strconv.parse_int(arg)
		if !ok || n < 1 do return fmt.tprintf("%q is not a line to leave on", arg)
		w.script_leave_after = n
		return fmt.tprintf("the next conversation is left on line %v", n)

	case "peeps":
		// Every window: where, when, whether its hour is now, whether heard.
		// See peep.odin.
		if len(w.peep_windows) == 0 do return "no peep windows"
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, "%v window(s)", len(w.peep_windows))
		for &win in w.peep_windows {
			when_ := "any time" if win.from == 0 && win.until == 0 else fmt.tprintf("%v-%v", clock_face(win.from), clock_face(win.until))
			state := "heard" if flag(w, peep_heard_flag(&win)) else ("open now" if peep_window_open(w, &win) else "")
			fmt.sbprintf(&b, "\n    %v at %v, %v%v", win.name, win.peep, when_, fmt.tprintf(" (%v)", state) if state != "" else "")
		}
		return strings.to_string(b)

	case "ticks":
		// !ticks 06:40 — step the clock a tick at a time to that hour and say
		// what each tick changed in the world, or that it changed nothing.
		target, _, ok := parse_until(w, fmt.tprintf("until %v x", arg))
		if !ok do return "!ticks HH:MM"
		empty, total := 0, 0
		for n := 0; clock_minute(w) < target && !w.dead && n < 1000; n += 1 {
			before := world_print(w)
			flags := true_flags(w)
			from := clock_face(clock_minute(w))
			tick(w)
			run_on(w)
			changed := make([dynamic]string, context.temp_allocator)
			append(&changed, ..world_diff(before, world_print(w)))
			// Something that happened to her is a change too: a beat played,
			// a body announced (their flags are their names).
			for f in world_diff(flags, true_flags(w)) {
				name := f[2:]
				for b in w.beats do if b.name == name do append(&changed, strings.concatenate({"! ", name}, context.temp_allocator))
				for a in w.announcements do if a.name == name do append(&changed, strings.concatenate({"! ", name}, context.temp_allocator))
			}
			total += 1
			if len(changed) == 0 {
				empty += 1
				// Why it stopped, if not for something to see: a window that
				// opened or shut, or as far as a turn goes.
				why := world_diff(flags, true_flags(w))
				fmt.printfln("  [tick %v -> %v] NOTHING CHANGED  %v", from, clock_face(clock_minute(w)),
					strings.join(why, " ", context.temp_allocator) if len(why) > 0 else "(as far as a turn goes)")
			} else {
				fmt.printfln("  [tick %v -> %v] %v change(s)", from, clock_face(clock_minute(w)), len(changed))
				for c in changed do fmt.printfln("      %v", c)
			}
		}
		return fmt.tprintf("%v ticks, %v changed nothing", total, empty)

	case "light":
		// !light night — show the room in that light, whatever the clock
		// says, for looking at a painting. With no word, the light it is.
		if arg == "" {
			return fmt.tprintf("seen: %v, now: %v", w.light, light_now(w))
		}
		for l in Light {
			if strings.equal_fold(fmt.tprint(l), arg) {
				latch_light(w, l)
				return fmt.tprintf("%v, as painted", l)
			}
		}
		return "!light day|sunset|night|sunrise"

	case "restore":
		// The death box's Restore: the newest save there is.
		if !w.dead do return "not dead"
		if point := w.death.restore; has_restore_point(w, point) {
			death_choose(w, .Restore)
			return fmt.tprintf("restored %q: %v at %v", point, current_scene(w).name, clock_face(clock_minute(w)))
		}
		slot := newest_save(w)
		if slot == 0 do return "nothing to restore"
		death_choose(w, .Restore)
		return fmt.tprintf("restored slot %v: %v at %v", slot, current_scene(w).name, clock_face(clock_minute(w)))

	case "click":
		return click_bang(w, arg) // edge.odin
	case "arrow":
		return arrow_bang(w, arg) // edge.odin
	case "sides":
		return sides_bang(w) // side_harness.odin
	case "cross":
		return cross_bang(w, arg) // side_harness.odin

	case "type":
		// !type show ledger to edmund — the command as typed, and nothing
		// settled: no walk finished, no conversation read. With !frames, for
		// seeing what real frames do that the harness's instant walks hide.
		run_command(w, arg)
		return fmt.tprintf("typed %v", arg)

	case "autoplay":
		return autoplay_bang(w, arg) // autoplay.odin: the script in real frames, and who was in sight
	case "frames":
		// !frames 5 — five seconds of the real loop, sixty frames a second:
		// people walk their routines, she walks hers, beats wait their turn.
		// Prints where she ended up and what is on the screen.
		// `!frames 5 x10`: each frame ten times as long, as `--play --speed 10`
		// without its small steps would have it.
		secs, _, speed := strings.partition(arg, " x")
		n, ok := strconv.parse_f32(secs)
		if !ok do return "!frames <seconds> [x<speed>]"
		k, has_k := strconv.parse_f32(speed)
		if !has_k || k <= 0 do k = 1
		for _ in 0 ..< int(n * 60 / k) do update(w, k / 60)
		return fmt.tprintf("%v s: %v at %v,%v%v%v | %v", n, current_scene(w).name, int(w.player.pos.x), int(w.player.pos.y),
			" walking" if w.player.moving else "", " approaching" if approaching(w) else "", message(w))

	case "secs":
		// !secs 30 — let real time pass, for a timer, since the harness has none.
		n, ok := strconv.parse_f32(arg)
		if !ok do return "!secs <seconds>"
		w.time += n
		run_timers(w)
		return fmt.tprintf("%v seconds on", n)

	case "passer":
		// !passer [window] [left|right] [at=0.5]: somebody across a window
		// here, now, or held part of the way across for a --shot; `!passer ?`
		// says what is coming; chance= and seed= change the dice (passer.odin).
		return passer_bang(w, arg)

	case "at":
		// !at 22:40 — spend ticks until the clock reads that, the next time it
		// does. After midnight is the same night: `!at 00:10` from 23:00 is
		// 1450, not 10.
		colon := strings.index_byte(arg, ':')
		if colon < 0 do return "!at HH:MM"
		h, ok_h := strconv.parse_int(arg[:colon])
		mm, ok_m := strconv.parse_int(arg[colon + 1:])
		if !ok_h || !ok_m do return "!at HH:MM"
		target := h * 60 + mm
		for target < clock_minute(w) do target += 24 * 60
		clock_at_least(w, target)
		return fmt.tprintf("%v, %v ticks", clock_face(clock_minute(w)), w.clock_ticks)

	case "flag":
		if arg == "" do return "which flag?"
		off := strings.has_prefix(arg, "!")
		name := arg[1:] if off else arg
		set_flag(w, name, !off)
		return fmt.tprintf("%v %v", name, "off" if off else "on")

	case "dress":
		sp := strings.index_byte(arg, ' ')
		if sp < 0 do return "!dress <group> <which>"
		group, which := arg[:sp], strings.trim_space(arg[sp + 1:])
		dress(w, group, which)
		return fmt.tprintf("%v wearing %v", group, dressing(w, group))

	case "note":
		// !note <tab> <id> [@minute] <text...>
		//
		// The minute is optional and is a raw minute on the game's clock —
		// `@1450`, not `@00:10`, because the clock runs past midnight and
		// "00:10" does not say which night. Without one, the entry is stamped
		// now. With one, a Times page can be filled out of order, which is the
		// only way to see sorting it do anything.
		parts := strings.split_n(arg, " ", 3, context.temp_allocator)
		if len(parts) < 3 do return "!note <tab> <id> [@minute] <text>"
		e := Entry{tab = parts[0], id = parts[1], text = parts[2], minute = clock_minute(w)}
		if strings.has_prefix(e.text, "@") {
			sp := strings.index_byte(e.text, ' ')
			if sp > 1 {
				if m, ok := strconv.parse_int(e.text[1:sp]); ok {
					e.minute = m
					e.text = strings.trim_space(e.text[sp + 1:])
				}
			}
		}
		written := note(w, e)
		return fmt.tprintf("%v %v", parts[1], "written" if written else "already there")

	case "book":
		// The notebook as text: every page, or one. The frontend draws it, and
		// a picture cannot be grepped, so this is how a test reads it.
		b := strings.builder_make(context.temp_allocator)
		for e in notebook_entries(w, arg, .Found) {
			fmt.sbprintf(&b, "\n    %v · %v", e.tab, e.text)
			if notebook_dogeared(w, e.id) do strings.write_string(&b, "  [dog-ear]")
			for sh in e.shown do fmt.sbprintf(&b, "\n        shown to %v: %v", sh.who, sh.text)
		}
		n := notebook_count(w, arg)
		return fmt.tprintf("%v entr%v%v", n, "y" if n == 1 else "ies", strings.to_string(b))

	case "ride":
		// With a host: go under and stay between, so a --shot can catch the
		// handover (`--at` picks how far into it). The harness settles a typed
		// RIDE at once; this is the only way to see the part in between.
		if arg != "" do return fmt.tprintf("%v", ride(w, arg))
		body := "no body left anywhere"
		if room, pos, ok := ride_body(w); ok do body = fmt.tprintf("body in %v at %.0f,%.0f", room, pos.x, pos.y)
		if g := ride_glance(w); g != nil do return fmt.tprintf("riding the %v, looking at %v; %v", ride_host(w).name, g.look, body)
		if riding(w) do return fmt.tprintf("between, with the %v; %v", ride_host(w).name, body)
		return fmt.tprintf("not riding; %v", body)
	}

	// Pictures of the room, for checking drawing order (probe.odin).
	if reply, handled := probe_bang(w, word, arg); handled do return reply
	if on_bang != nil {
		if reply, handled := on_bang(w, word, arg); handled do return reply
	}
	// The accusation, as it stands, for a game that does not print its own:
	// every question, the name given and the proof attached.
	if word == "page" {
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, "%v question(s)", len(w.accusations))
		for a, i in w.accusations {
			fmt.sbprintf(&b, "\n    %v. %v %v, %v", i + 1, a.question, a.name if a.name != "" else "(nobody)", a.support if a.support != "" else "(nothing attached)")
		}
		return strings.to_string(b)
	}
	return fmt.tprintf("the harness does not know !%v", word)
}

// Goes to a room by name, standing in the middle of its floor, and calls
// on_arrive as if they had walked in. For the harness and for anything that
// jumps the player somewhere without walking — and it
// stands them *on* the floor, because a player left where they were in the
// last room is usually outside this one's, and then nothing behaves.
go_to_named :: proc(w: ^World, name: string) -> bool {
	i, ok := scene_index(w, name)
	if !ok do return false
	sc := &w.scenes[i]
	mid := [2]f32{}
	for pt in sc.walk_area do mid += pt
	if len(sc.walk_area) > 0 do mid /= f32(len(sc.walk_area))
	// A U or a half-moon has its middle off the floor: stand on the nearest bit.
	if len(sc.walk_area) >= 3 do mid = clamp_to_polygon(mid, sc.walk_area)
	go_to(w, i, mid)
	keep_out_let_through(w, i) // the harness's jump goes where the story keeps her out (keep_out.odin)
	// The harness's jump stands in for walking in, so the room reacts as if
	// the player had: on_arrive, and a trigger over the whole floor.
	if w.on_arrive != nil do w.on_arrive(w)
	check_triggers(w, w.player.pos)
	return true
}
