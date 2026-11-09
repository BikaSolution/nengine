package nengine

import "core:fmt"
import "core:slice"
import "core:strings"

// The story clock: what time it is in the story, as opposed to how long the
// player has been playing.
//
// `World.time` is playtime — seconds at the keyboard, which is what a score
// screen reports. This is the other clock: the hour the fiction has reached.
// In a mystery the two are unrelated and should be. A player can stand still
// at the fire for twenty minutes and the night does not move; they can find
// one thing and it moves four minutes. **Discovery costs time**: walking is
// free, looking is free, finding is not.
//
//     w.clock_start = 19 * 60 + 30   // dinner
//     w.clock_step  = 4              // minutes a tick is worth
//     w.on_clock    = what_the_hour_does
//
//     ne.discover(&w, {id = "the_glasses", tab = "things", text = "..."})
//         // writes it in the notebook, stamps it with the hour, spends a tick
//
// The engine keeps the count and puts it in every save. What an hour *does* —
// the fire burning down, a generator dying at half past ten — is the game's,
// and it lives in `on_clock`, which is called every time the clock moves and
// once when a save is restored. Everything else in the game should read flags
// that `on_clock` sets, so a room can change with the hour in its own file and
// nothing but one procedure has to know what time it is.
//
// **Minutes on this clock are not times of day.** A case that runs from
// teatime to dawn crosses midnight, so the clock counts on past 1440: ten past
// midnight is 1450, not 10. A clock that wrapped would sort the second half of
// the night before the first, in the notebook tab where order is the evidence.
// Turn a minute back into "00:10" with `clock_face`, for a debug bar or a page
// in the book, and never compare two of those strings.

// **A tick need not be worth the same all day.** An afternoon in which twelve
// people want towels moves in quarter hours; a night in which three people are
// dying moves in fours. `clock_paces` says where the step changes:
//
//     w.clock_start = 16 * 60
//     w.clock_step  = 15                              // the afternoon
//     w.clock_paces = {{from = 19 * 60 + 30, step = 4}} // from dinner on
//
// A tick is worth the pace in force at the minute it starts from. Without any
// paces, every tick is `clock_step`.
Clock_Pace :: struct {
	from: int, // a minute on the game's clock
	step: int,
}

// Where the story clock is now, in minutes on the game's own clock.
clock_minute :: proc(w: ^World) -> int {
	if len(w.clock_paces) == 0 do return w.clock_start + w.clock_ticks * w.clock_step
	m := w.clock_start
	for _ in 0 ..< w.clock_ticks do m += step_at(w, m)
	return m
}

// What a tick starting at minute m is worth.
@(private)
step_at :: proc(w: ^World, m: int) -> int {
	step := w.clock_step
	for p in w.clock_paces do if m >= p.from do step = p.step
	return max(step, 1)
}

// Is the story clock in [from, until)? For a window: the one quarter of an
// hour a conversation can be overheard, the hours a host is awake.
clock_between :: proc(w: ^World, from, until: int) -> bool {
	m := clock_minute(w)
	return m >= from && m < until
}

// Spends whatever it takes to reach `minute`, if the clock is not there yet.
// For a scene that takes the time it takes: a talk that runs from twenty past
// to twenty-five to is over at twenty-five to, however early you walked in.
// Returns the ticks it spent.
clock_at_least :: proc(w: ^World, minute: int) -> int {
	if w.clock_turns {
		// Ticks are minutes underneath; a jump is a jump, not so many turns.
		if clock_is_held(w) do return 0
		n := minute - clock_minute(w)
		advance_minutes(w, n)
		return max(n, 0)
	}
	n, m := 0, clock_minute(w)
	for m < minute {
		m += step_at(w, m)
		n += 1
	}
	tick(w, n)
	return n
}

// A minute on the game's clock as a time of day: "23:52", "00:10". Wraps at
// twenty-four hours for the face only — the minute itself never wraps.
clock_face :: proc(minute: int, allocator := context.temp_allocator) -> string {
	m := minute %% (24 * 60) // %% rather than %: a clock may start before midnight and be asked about earlier
	return fmt.aprintf("%02v:%02v", m / 60, m %% 60, allocator = allocator)
}

// **A clock can be held.** A prologue that happens before the hours start to
// matter — a boat, a train, a week in one evening — should not spend them:
// `clock_held` is a condition (flags.odin), and while it holds a tick is
// free. Waiting, finding and asking all go on as usual; the hour does not.
//
//     w.clock_held = "act1"
//
// Because it is a condition on flags, it saves itself and cannot drift.
clock_is_held :: proc(w: ^World) -> bool {
	return w.clock_held != "" && condition_met(w, w.clock_held)
}

// Spends time. Negative is refused: the story does not run backwards, and a
// restore is `set_clock`, not a negative tick. A held clock spends nothing.
tick :: proc(w: ^World, n := 1) {
	if n <= 0 || clock_is_held(w) do return
	w.ticked = true
	if w.clock_turns {
		for _ in 0 ..< n do turn(w)
		light_after_tick(w)
		return
	}
	w.clock_ticks += n
	if w.on_clock != nil do w.on_clock(w)
	light_after_tick(w)
}

// A turn (`World.clock_turns`): the clock runs on, a step at a time, to the
// next moment the world is different — somebody has come or gone, a room
// reads or sounds or is lit otherwise, a story window has opened or shut
// (a flag), something is due to be seen (a beat, an announcement) — and
// stops there. So every tick the player pays for changes somebody, and no
// window is ever stepped over. `clock_turn_max` minutes is as far as one turn
// goes; a turn that gets there without a change is one the game has not
// filled yet, and `!ticks` says so.
@(private)
turn :: proc(w: ^World) {
	before := world_print(w)
	flags_before := true_flags(w)
	limit := w.clock_turn_max if w.clock_turn_max > 0 else 30
	for _ in 0 ..< limit {
		w.clock_ticks += 1
		if w.on_clock != nil do w.on_clock(w)
		if beat_due(w) != nil || announcement_due(w) != nil do return
		if !slice.equal(flags_before, true_flags(w)) do return
		if len(world_diff(before, world_print(w))) > 0 do return
	}
}

// The flags that are on, sorted, to compare.
@(private)
true_flags :: proc(w: ^World) -> []string {
	on := make([dynamic]string, context.temp_allocator)
	for name, set in w.flags {
		// The light flags follow the light, which follows the clock: a sunset
		// is not somebody in the world being different. See latch_light.
		if !set || strings.has_prefix(name, "light_") || strings.has_prefix(name, "award_open_") do continue
		append(&on, name)
	}
	slice.sort(on[:])
	return on[:]
}

// The clock moved on by minutes, not turns: for jumps the story makes
// (clock_at_least) and the harness's `!at`.
@(private)
advance_minutes :: proc(w: ^World, minutes: int) {
	if minutes <= 0 do return
	w.ticked = true
	w.clock_ticks += minutes
	if w.on_clock != nil do w.on_clock(w)
	light_after_tick(w)
}

// Puts the clock somewhere and lets the world catch up with it. For a restore,
// for the harness, and for the start of the game, when `on_clock` has to run
// once so the world looks like the opening hour before anybody sees it.
set_clock :: proc(w: ^World, ticks: int) {
	w.clock_ticks = max(ticks, 0)
	if w.on_clock != nil do w.on_clock(w)
	relight(w) // a jump, not a passing: the light is wherever the clock is
}

// Finding something: a note in the book, stamped with the hour, and a tick off
// the clock. True the first time only — the notebook is idempotent, so the
// clock is too, and finding the shoe four times costs what finding it once did.
//
// An entry that already carries a minute keeps it. Most do not: most things
// are learned *now*. But a witness's "about eleven" is about eleven whenever
// the player hears it, and the Times tab is only worth sorting if those stay
// put.
discover :: proc(w: ^World, e: Entry) -> bool {
	fresh := e
	if _, timed := fresh.minute.?; !timed do fresh.minute = clock_minute(w)
	if !note(w, fresh) do return false
	if !w.ticked do tick(w) // once a command (note may have spent it already)
	return true
}
