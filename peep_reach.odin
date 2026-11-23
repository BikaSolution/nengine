package nengine

import "core:fmt"
import "core:strings"

// Can play reach every peep window? The harness's `!reach`.
//
// With clock turns (clock.odin) the clock stops only where the world is
// different, and a window's hour coming round is not a difference: it sets no
// flag and moves nobody. So a window whose minutes nothing else in the world
// marks is stepped over by every turn, and its lines are lost to every
// player. `!at` hides that, because a jump can stand on any minute.
//
//     !reach 23:59 at=row     step the clock to 23:59 as play does, standing at the row
//     !reach 06:40 stop=over  ...and stop at the first landing where `over` holds
//     !reach                  what was reached, and what was stepped over
//     !reach clear            start the record again
//
// A step is what play does after a tick: the tick (a turn), then whatever it
// sets off before she has the prompt again (run_on: beats, cuts, rides,
// conversations and the jumps they make). After each step the minute she
// stands on is a landing. With `at=<room>` she is walked back to that room
// after every step, as a player waiting at an aperture would be (walking is
// free). A window is **reached** at a landing in its hours, in a room that has
// its aperture (and its `room`, if it names one), with its `only` true. It is
// **stepped over** when one step goes from before its `from` to its `until` or
// later while its `only` held at one end or the other: no landing in its
// minutes, on a night where it was owed. One that was landed in only while its
// `only` was shut is a branch the route did not take, and not a fault. A window
// that plays during a step is reached at the minute it played (play_window
// marks it): a beat may play one inside a step that lands after its hours.

Reach_Mark :: struct {
	reached:   int,  // the first landing with it open where she stood; -1 none
	over:      bool, // a step went clean over it with its condition met
	over_from: int,  // ...from this minute
	over_to:   int,  // ...to this one
	shut:      int,  // landings in its hours, at its aperture, with its `only` shut
	at_it:     int,  // landings at its aperture, at any hour
	passed:    bool, // the route got to its `until`
}

// Starts the record, or makes sure there is one for every window.
reach_begin :: proc(w: ^World) {
	if len(w.reach) == len(w.peep_windows) do return
	clear(&w.reach)
	for _ in w.peep_windows do append(&w.reach, Reach_Mark{reached = -1})
}

// Is she where this window is heard from: a room with its aperture in it?
@(private)
reach_here :: proc(w: ^World, win: ^Peep_Window) -> bool {
	if len(w.scenes) == 0 do return false
	sc := current_scene(w)
	if win.room != "" && sc.name != win.room do return false
	o := object_here(sc, win.peep)
	return o != nil && o.peep.is
}

// One landing at minute `to`, the step having started at `from` with the
// windows' conditions as `before` said.
reach_land :: proc(w: ^World, from, to: int, before: []bool) {
	reach_begin(w)
	for &win, i in w.peep_windows {
		if win.from == 0 && win.until == 0 do continue // any time: a flag's window, not the clock's
		m := &w.reach[i]
		held := win.only == "" || condition_met(w, win.only)
		if to >= win.until do m.passed = true
		here := reach_here(w, &win)
		if here do m.at_it += 1
		if to >= win.from && to < win.until && here {
			if held {
				if m.reached < 0 do m.reached = to
			} else {
				m.shut += 1
			}
		}
		// Over it, judged where she stands: a route waiting at another
		// aperture may simply not stop where this one's room would.
		was := i < len(before) && before[i]
		if from < win.from && to >= win.until && (held || was) && m.reached < 0 && !m.over && here {
			m.over, m.over_from, m.over_to = true, from, to
		}
	}
}

// One step of play: a tick and all it sets off; then back to `at`, if given.
reach_step :: proc(w: ^World, at: string, stop := "") {
	reach_begin(w)
	before := make([]bool, len(w.peep_windows), context.temp_allocator)
	for &win, i in w.peep_windows do before[i] = win.only == "" || condition_met(w, win.only)
	from := clock_minute(w)
	tick(w)
	run_on(w)
	if at != "" && !w.dead && len(w.scenes) > 0 && current_scene(w).name != at {
		go_to_named(w, at)
		run_on(w)
	}
	// A game that is over (`stop`, the game's word for it) lands nowhere:
	// nothing after it is play.
	if stop == "" || !condition_met(w, stop) do reach_land(w, from, clock_minute(w), before)
	fmt.printfln("  [reach %v -> %v in %v]", clock_face(from), clock_face(clock_minute(w)), current_scene(w).name if len(w.scenes) > 0 else "-")
}

// What became of every window with hours, and how many were stepped over.
reach_report :: proc(w: ^World) -> (report: string, over: int) {
	reach_begin(w)
	b := strings.builder_make(context.temp_allocator)
	reached, other := 0, 0
	for &win, i in w.peep_windows {
		if win.from == 0 && win.until == 0 do continue
		m := w.reach[i]
		hours := fmt.tprintf("%v-%v", clock_face(win.from), clock_face(win.until))
		switch {
		case m.reached >= 0:
			reached += 1
			fmt.sbprintf(&b, "\n    %v at %v, %v: reached at %v", win.name, win.peep, hours, clock_face(m.reached))
		case m.over:
			over += 1
			fmt.sbprintf(&b, "\n    %v at %v, %v: STEPPED OVER, %v -> %v", win.name, win.peep, hours, clock_face(m.over_from), clock_face(m.over_to))
		case:
			other += 1
			why := "stepped past with its condition shut: a branch not taken"
			switch {
			case m.shut > 0:   why = fmt.tprintf("in its hours %v time(s), its condition shut: a branch not taken", m.shut)
			case m.at_it == 0: why = "she was not at its aperture on this route"
			case !m.passed:    why = "not passed: the route ended first"
			}
			fmt.sbprintf(&b, "\n    %v at %v, %v: %v", win.name, win.peep, hours, why)
		}
	}
	head := fmt.tprintf("%v reached, %v stepped over, %v not judged on this route", reached, over, other)
	return strings.concatenate({head, strings.to_string(b)}, context.temp_allocator), over
}

// `!reach [HH:MM] [at=<room>] [stop=<condition>]`, `!reach clear`.
reach_bang :: proc(w: ^World, arg: string) -> string {
	if len(w.peep_windows) == 0 do return "no peep windows"
	if arg == "clear" {
		clear(&w.reach)
		reach_begin(w)
		return "the reach record is clear"
	}
	if arg == "" {
		report, _ := reach_report(w)
		return report
	}
	at, stop, hour := "", "", ""
	rest := arg
	for part in strings.fields_iterator(&rest) {
		switch {
		case strings.has_prefix(part, "at="):   at = part[len("at="):]
		case strings.has_prefix(part, "stop="): stop = part[len("stop="):]
		case hour == "":                        hour = part
		}
	}
	target, _, ok := parse_until(w, fmt.tprintf("until %v x", hour))
	if !ok do return "!reach [HH:MM [at=<room>] [stop=<condition>] | clear]"
	if at != "" && !go_to_named(w, at) do return fmt.tprintf("no room called %q", at)
	run_on(w)
	now := clock_minute(w)
	reach_land(w, now, now, nil) // where she stands now is a landing too
	steps := 0
	stopped := stop != "" && condition_met(w, stop)
	for n := 0; clock_minute(w) < target && !w.dead && !stopped && n < 1000; n += 1 {
		was := clock_minute(w)
		reach_step(w, at, stop)
		steps += 1
		stopped = stop != "" && condition_met(w, stop)
		if clock_minute(w) == was do break // a held clock: nothing to step
	}
	return fmt.tprintf("%v step(s), now %v%v%v", steps, clock_face(clock_minute(w)), " (dead)" if w.dead else "",
		fmt.tprintf(" (stopped: %v)", stop) if stopped else "")
}
