package nengine

import "core:fmt"
import "core:strconv"
import "core:strings"

// Score, and how long it took.
//
// A mystery is scored on what the player worked out, so the points are on the
// clues: found the field book, read the boiler log, noticed that one of them
// was never wet. The game declares every award once, so that "45 of 250" can
// be shown from the first minute, and then awards them by name as they
// happen.
//
//     AWARDS := [?]ne.Award {
//         {"field_book", "Fairbank's field book",  10, 0, 0},
//         {"photograph", "The 1948 photograph",    15, 0, 0},
//         {"boiler_log", "The boiler was lit at 23:40", 20, 23*60, 25*60},
//     }
//     w.awards = AWARDS[:]
//
//     ne.award(&w, "field_book")     // when it is found
//     ne.score(&w)                   // 10
//     ne.score_text(&w)              // "10 of 45"
//
// Awarding is idempotent: finding the same clue twice is worth what finding
// it once was. That is the whole reason awards have names rather than the
// game adding numbers to a counter, because a counter that a player can feed
// by looking at a thing repeatedly is not a score.
//
// An award also sets a flag of the same name, so a clue can change the world
// as well as the score without the game saying it twice — `when=field_book`
// on anything in a room.

Award :: struct {
	name:   string, // what the game calls it: "field_book"
	text:   string, // what to show at the end: "Fairbank's field book"
	points: int,
	// When it could be had, on the story clock: from, and until it was gone.
	// 0 is "from the start" and "for good". The end of a game is where this
	// earns its keep: a missed list that says *when* each thing was lost is
	// the argument for playing again.
	from:   int,
	until:  int,
	// A condition: an award of one branch (the third death is Percy's, or
	// Pickett's). Until it has held at least once in this game, the award is
	// neither earned nor missed: the other branch's is not a thing she lost.
	only:   string,
}

// The flag that remembers an award's `only` held at some point.
@(private)
award_open_flag :: proc(name: string) -> string {
	return fmt.tprintf("award_open_%v", name)
}

// Whenever the flags change: notes each award whose `only` holds, once, for
// good. Written straight into the flags (not set_flag, which would come back
// here), and saved with them.
@(private)
note_open_awards :: proc(w: ^World) {
	for a in w.awards {
		if a.only == "" || !condition_met(w, a.only) do continue
		key := award_open_flag(a.name)
		if key in w.flags do continue
		if w.flags == nil do w.flags = make(map[string]bool)
		w.flags[strings.clone(key)] = true
	}
}

// An award that has been earned, and when.
Earned :: struct {
	using award: Award,
	at:          f32, // playtime, in seconds, when it happened
	minute:      int, // and the story clock, when there is one
}

// Gives the award, if it hasn't been given already. True the first time only,
// so a game can say something the first time and stay quiet afterwards:
//
//     if ne.award(w, "field_book") do ne.say(w, "Found it. (+10)")
award :: proc(w: ^World, name: string) -> bool {
	if name == "" || has_award(w, name) do return false
	if w.earned == nil do w.earned = make(map[string]f32)
	w.earned[strings.clone(name)] = w.time
	if w.earned_minute == nil do w.earned_minute = make(map[string]int)
	w.earned_minute[strings.clone(name)] = clock_minute(w)
	// A clue almost always changes the room as well as the score, so it sets
	// a flag of its own name too. One call, one fact about the world.
	set_flag(w, name, true)
	return true
}

has_award :: proc(w: ^World, name: string) -> bool {
	_, got := w.earned[name]
	return got
}

// Takes one back. For the rare case of a clue that turns out to be wrong —
// and for tests, which need to be able to start again.
unaward :: proc(w: ^World, name: string) {
	if !has_award(w, name) do return
	// delete_key hands back the key it removed, which is the copy this made
	// when it was awarded, so it is ours to free.
	key, _ := delete_key(&w.earned, name)
	delete(key)
	mkey, _ := delete_key(&w.earned_minute, name)
	delete(mkey)
	set_flag(w, name, false)
}

clear_awards :: proc(w: ^World) {
	for name in w.earned do delete(name)
	delete(w.earned)
	w.earned = nil
	for name in w.earned_minute do delete(name)
	delete(w.earned_minute)
	w.earned_minute = nil
}

// What the player has scored.
score :: proc(w: ^World) -> int {
	total := 0
	for a in w.awards do if has_award(w, a.name) do total += a.points
	return total
}

// What there is to score. Known from the start, because the awards are
// declared rather than discovered.
score_max :: proc(w: ^World) -> int {
	total := 0
	for a in w.awards do total += a.points
	return total
}

// "45 of 250". What a status line or a SCORE command shows.
score_text :: proc(w: ^World, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%v of %v", score(w), score_max(w), allocator = allocator)
}

// --- The end of the game ---

// What the player found, in the order they found it. For the ending, which is
// where a score stops being a number and becomes a list of what you worked
// out.
awards_earned :: proc(w: ^World, allocator := context.temp_allocator) -> []Earned {
	out := make([dynamic]Earned, allocator)
	for a in w.awards {
		if at, got := w.earned[a.name]; got do append(&out, Earned{a, at, w.earned_minute[a.name]})
	}
	// By when they happened, which is the order the player lived them in.
	for i in 1 ..< len(out) {
		v := out[i]
		j := i - 1
		for j >= 0 && out[j].at > v.at {
			out[j + 1] = out[j]
			j -= 1
		}
		out[j + 1] = v
	}
	return out[:]
}

// What the player walked past, in the order it was there to be had. The
// other half of an ending worth reading — and with each award's `until`, the
// hour it was lost.
awards_missed :: proc(w: ^World, allocator := context.temp_allocator) -> []Award {
	out := make([dynamic]Award, allocator)
	note_open_awards(w)
	for a in w.awards {
		if has_award(w, a.name) do continue
		if a.only != "" && !flag(w, award_open_flag(a.name)) do continue // the other branch's
		append(&out, a)
	}
	// Stable, so awards available at the same hour keep the declared order.
	for i in 1 ..< len(out) {
		v := out[i]
		j := i - 1
		for j >= 0 && out[j].from > v.from {
			out[j + 1] = out[j]
			j -= 1
		}
		out[j + 1] = v
	}
	return out[:]
}

// --- How long it took ---
//
// `World.time` is the play clock: it runs while the game is being played and
// not while a menu is up, it goes into every save, and it comes back with
// one. Everything else that needs a clock — animations, routines, how long a
// message stays up — reads the same one, so there is only ever one answer to
// "when".

playtime :: proc(w: ^World) -> f32 {
	return w.time
}

// "1h 23m", "4m 12s", "38s". Rounded the way somebody would say it rather
// than to the second, because nobody reads a play time to the second.
playtime_text :: proc(seconds: f32, allocator := context.temp_allocator) -> string {
	secs := int(max(seconds, 0))
	h, m, s := secs / 3600, (secs / 60) % 60, secs % 60
	switch {
	case h > 0: return fmt.aprintf("%vh %vm", h, m, allocator = allocator)
	case m > 0: return fmt.aprintf("%vm %vs", m, s, allocator = allocator)
	case:       return fmt.aprintf("%vs", s, allocator = allocator)
	}
}

// --- Saving ---
//
// The earned awards go in as `name:when` pairs, so restoring a save restores
// the score and the moment each piece of it happened. The declaration is the
// game's and does not need saving; only what was found does.

@(private)
earned_text :: proc(w: ^World, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	// In the declared order, so a save file doesn't churn on a hash table.
	first := true
	for a in w.awards {
		at, got := w.earned[a.name]
		if !got do continue
		if !first do strings.write_byte(&b, ',')
		fmt.sbprintf(&b, "%v:%.2f:%v", a.name, at, w.earned_minute[a.name])
		first = false
	}
	return strings.to_string(b)
}

@(private)
set_earned_text :: proc(w: ^World, text: string) {
	clear_awards(w)
	rest := text
	for pair in strings.split_iterator(&rest, ",") {
		item := strings.trim_space(pair)
		if item == "" do continue
		// name:playtime:minute — older saves have no minute, and older still
		// no playtime.
		parts := strings.split(item, ":", context.temp_allocator)
		name := parts[0]
		at, minute := f32(0), 0
		if len(parts) > 1 {
			if v, ok := strconv.parse_f32(parts[1]); ok do at = v
		}
		if len(parts) > 2 {
			if v, ok := strconv.parse_int(parts[2]); ok do minute = v
		}
		if w.earned == nil do w.earned = make(map[string]f32)
		w.earned[strings.clone(name)] = at
		if w.earned_minute == nil do w.earned_minute = make(map[string]int)
		w.earned_minute[strings.clone(name)] = minute
	}
}
