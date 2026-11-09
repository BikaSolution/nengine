package nengine

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

// The developer's two cheats, typed at the prompt like any command:
//
//     TELEPORT fuel store      to that screen, standing on its floor where
//                              she would come in, as if she had walked in
//     TIMETRAVEL 20:00         the clock on to then, the world with it
//
// They are not there for a player. With the dev switch off — and it is off
// unless asked for — the words are not in any vocabulary, and typing them gets
// the parser's answer to a word it does not know, whatever the game says to
// that. The switch is `--dev` on the command line or `NENGINE_DEV=1` in the
// environment (launch.odin), or `World.dev.on` for a test. With it on they
// work in the harness too: `--dev --script 'teleport the gap; timetravel 8pm'`.
//
// **TELEPORT <place>** takes a room's name (`fuel_store`), the name with
// spaces ("fuel store"), or any word the game gives for it in `dev.places`
// with every synonym the vocabulary has for that word ("the gap", "tent six").
// Case and spacing do not matter, a leading "the" or "to" is dropped, and the
// start of a name is enough if only one room starts that way. A name that is
// several rooms, or none, lists the near ones. TELEPORT on its own, or
// TELEPORT LIST, lists them all, a page at a time.
//
// She arrives the way a player would: at a door's arrival spot if some door
// leads in, else a step in over a side (the south one first: she walks in
// facing north), else the nearest free spot to the middle of the floor. Then
// the room reacts as to anybody walking in: the game's `on_arrive`, and a
// trigger over the whole floor (a body on a deck). Beats due there play in
// the frames after, as always.
//
// **TIMETRAVEL <time>** takes 20:00, 2000, 20.00, 20h, 20h30, 8pm, 8:30pm,
// noon or midnight. A time is put on the story's day (`dev.day`, minutes on
// the game's clock; by default the twenty-four hours from `clock_start`), so
// 02:30 in a day that starts at four in the afternoon is the night's, after
// 23:59. The clock then runs on to it as the harness's `!at` does
// (clock_at_least): people go to their lines, the hour's flags are set, and
// beats due play in the frames after.
//
// **The clock only runs forward**, here as everywhere (clock.odin's `tick`).
// A time already gone is refused, saying so; it is never quietly taken to be
// tomorrow's, which is what `!at` does. A held clock (a prologue) is let go by
// the game's `dev.unhold`, if it has one, and refused if not.

// What a game tells the developer's commands about itself.
Dev :: struct {
	on:     bool,         // the switch, for a test; a game leaves it to --dev and NENGINE_DEV
	places: []Place_Name, // the game's other words for its rooms
	day:    [2]int,       // the story's day, from and until, on the game's clock; {} for 24h from clock_start
	unhold: proc(w: ^World), // let a held clock run (skip the prologue); nil refuses
}

// A word the player could use for a room: a vocabulary noun, which brings its
// synonyms, or any phrase. One word may name several rooms, as GO TO's may.
Place_Name :: struct {
	noun, room: string,
}

DEV_ENV :: "NENGINE_DEV"

// --dev, or NENGINE_DEV, on this run's own command line (launch_flags).
@(private)
launch_dev: bool

dev_env :: proc() -> bool {
	v := os.get_env(DEV_ENV, context.temp_allocator)
	return v != "" && v != "0"
}

// Are the developer's commands there?
dev_on :: proc(w: ^World) -> bool {
	return w.dev.on || launch_dev
}

// A line typed at the prompt, if it is TELEPORT or TIMETRAVEL and the switch
// is on. False, and the line goes to the parser, otherwise.
@(private)
dev_command :: proc(w: ^World, line: string) -> bool {
	if !dev_on(w) do return false
	said := strings.trim_space(line)
	verb, rest := said, ""
	if sp := strings.index_any(said, " \t"); sp >= 0 do verb, rest = said[:sp], strings.trim_space(said[sp + 1:])
	verb = strings.to_lower(verb, context.temp_allocator)
	if verb == "time" {
		// TIME TRAVEL, as two words.
		v2, r2 := rest, ""
		if sp := strings.index_any(rest, " \t"); sp >= 0 do v2, r2 = rest[:sp], strings.trim_space(rest[sp + 1:])
		if !strings.equal_fold(v2, "travel") do return false
		verb, rest = "timetravel", r2
	}
	switch verb {
	case "teleport":
		log_route(w, "dev:teleport")
		dev_teleport(w, rest)
		return true
	case "timetravel":
		log_route(w, "dev:timetravel")
		say(w, dev_timetravel(w, rest))
		return true
	}
	return false
}

// --- TELEPORT ---

@(private = "file")
dev_teleport :: proc(w: ^World, arg: string) {
	if len(w.scenes) == 0 {
		say(w, "[dev] There are no rooms.")
		return
	}
	if riding(w) {
		say(w, "[dev] Not while riding: GET UP first.")
		return
	}
	if arg == "" || strings.equal_fold(arg, "list") {
		place_list(w)
		return
	}
	i, ok, why := match_place(w, arg)
	if !ok {
		say(w, why)
		return
	}
	// Said first: whatever the room says to her walking in comes after, and
	// is what stays up. A room the story keeps her out of at this hour
	// (keep_out.odin) lets the developer in, and says so.
	if kept_out(w, i) != nil {
		say(w, fmt.tprintf("[dev] Teleported to %v. The story keeps her out of it now; TELEPORT lets her through, and she stays until she leaves.", w.scenes[i].name))
	} else {
		say(w, fmt.tprintf("[dev] Teleported to %v.", w.scenes[i].name))
	}
	teleport(w, i)
}

// To room i, standing where she would come in, and the room told she has, as
// it would be by a door: `on_arrive`, and a trigger over the whole floor.
teleport :: proc(w: ^World, i: int) {
	if i < 0 || i >= len(w.scenes) do return
	w.pending = "" // a question asked in the last room goes unanswered
	go_to(w, i, w.player.pos) // its people and its sides' gates are worked out now
	keep_out_let_through(w, i) // a kept room lets the developer in (keep_out.odin)
	p, facing, has_facing := arrival_spot(w, i)
	w.player.pos = p
	if has_facing do face_towards(&w.player, facing)
	if w.on_arrive != nil do w.on_arrive(w)
	check_triggers(w, w.player.pos)
}

// Where somebody coming into room i would stand: a door's arrival spot, a step
// in over a side (the south first), or the nearest free spot to the middle of
// the floor. With the way she would face, for a side.
arrival_spot :: proc(w: ^World, i: int) -> (p: [2]f32, facing: [2]f32, has_facing: bool) {
	sc := &w.scenes[i]
	for &other, j in w.scenes {
		if j == i do continue
		for e in other.exits do if e.to == i && on_free_floor(sc, e.arrive) do return e.arrive, {}, false
	}
	for pass in 0 ..< 2 {
		for s in sc.sides {
			if s.hidden || (pass == 0) != (s.dir == .South) do continue
			at := s.arrive if s.has_arrive else side_arrival(sc, s.dir, s.span, (s.span[0] + s.span[1]) / 2)
			if side_free(sc, at) do return at, -outward(s.dir), true
		}
	}
	mid := [2]f32{}
	for pt in sc.walk_area do mid += pt
	if len(sc.walk_area) > 0 do mid /= f32(len(sc.walk_area))
	if len(sc.walk_area) < 3 do return mid, {}, false
	mid = clamp_to_polygon(mid, sc.walk_area)
	// Rings out from the middle until a spot is free.
	for r := f32(0); r <= 640; r += 8 {
		steps := max(1, int(r / 4))
		for k in 0 ..< steps {
			a := f32(k) / f32(steps) * 6.2831853
			q := mid + r * [2]f32{math.cos(a), math.sin(a)}
			if side_free(sc, q) do return q, {}, false
		}
	}
	return mid, {}, false
}

@(private = "file")
on_free_floor :: proc(sc: ^Scene, p: [2]f32) -> bool {
	if len(sc.walk_area) < 3 do return true
	return point_in_polygon(p, sc.walk_area) && !in_a_block(sc, p)
}

// A room, by any name for it. Not ok: `why` says so, with the near ones.
match_place :: proc(w: ^World, said: string) -> (room: int, ok: bool, why: string) {
	want := place_key(said)
	if want == "" do return 0, false, "[dev] Teleport where? TELEPORT LIST names them."
	// The room's own name first: "kitchen" is the kitchen, whatever else
	// a word of the game's calls a kitchen.
	for sc, i in w.scenes do if place_key(sc.name) == want do return i, true, ""
	exact := make([dynamic]Place_Hit, context.temp_allocator)
	starts := make([dynamic]Place_Hit, context.temp_allocator)
	id_starts := make([dynamic]Place_Hit, context.temp_allocator)
	for sc, i in w.scenes {
		if strings.has_prefix(place_key(sc.name), want) do add_hit(&id_starts, i, sc.name)
		for name in place_names(w, sc.name) {
			k := place_key(name)
			if k == want do add_hit(&exact, i, name)
			else if strings.has_prefix(k, want) do add_hit(&starts, i, name)
		}
	}
	switch {
	case len(exact) == 1:
		return exact[0].room, true, ""
	case len(exact) > 1:
		return 0, false, fmt.tprintf("[dev] \"%v\" is more than one place: %v.", said, hit_list(w, exact[:]))
	case len(id_starts) == 1:
		// The start of one room's own name, though a word of the game's for
		// another starts the same way: "kitchen y" is the kitchen yard.
		return id_starts[0].room, true, ""
	case len(starts) == 1:
		return starts[0].room, true, ""
	case len(starts) > 1:
		return 0, false, fmt.tprintf("[dev] \"%v\" could be %v.", said, hit_list(w, starts[:]))
	}
	// Nothing: the nearest by spelling, or that contain it.
	near := make([dynamic]Place_Hit, context.temp_allocator)
	for sc, i in w.scenes {
		best, best_name := 1 << 30, ""
		for name in place_names(w, sc.name) {
			k := place_key(name)
			d := strings.levenshtein_distance(k, want, context.temp_allocator)
			if strings.contains(k, want) do d = 0
			if d < best do best, best_name = d, name
		}
		if best <= max(2, len(want) / 3) do append(&near, Place_Hit{i, best_name, best})
	}
	slice.sort_by(near[:], proc(a, b: Place_Hit) -> bool {return a.dist < b.dist})
	if len(near) > 6 do resize(&near, 6)
	if len(near) == 0 do return 0, false, fmt.tprintf("[dev] No place called \"%v\". TELEPORT LIST names them.", said)
	return 0, false, fmt.tprintf("[dev] No place called \"%v\". Nearest: %v.", said, hit_list(w, near[:]))
}

@(private = "file")
Place_Hit :: struct {
	room: int,
	name: string, // the name it matched by
	dist: int,
}

// Once per room: the first name it matched by is the one shown.
@(private = "file")
add_hit :: proc(hits: ^[dynamic]Place_Hit, room: int, name: string) {
	for h in hits do if h.room == room do return
	append(hits, Place_Hit{room = room, name = name})
}

@(private = "file")
hit_list :: proc(w: ^World, hits: []Place_Hit) -> string {
	b := strings.builder_make(context.temp_allocator)
	for h, n in hits {
		if n > 0 do strings.write_string(&b, ", ")
		id := w.scenes[h.room].name
		strings.write_string(&b, id)
		if place_key(h.name) != place_key(id) do fmt.sbprintf(&b, " (%v)", h.name)
	}
	return strings.to_string(b)
}

// Every name room `id` answers to: its own, with spaces, and the game's words
// for it with each of their synonyms in the vocabulary.
place_names :: proc(w: ^World, id: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	append(&out, id)
	spaced, _ := strings.replace_all(id, "_", " ", context.temp_allocator)
	if spaced != id do append(&out, spaced)
	for p in w.dev.places {
		if p.room != id do continue
		append(&out, p.noun)
		for v in w.vocab {
			if v.kind != .Noun || v.name != p.noun do continue
			rest := v.synonyms
			for s in strings.split_iterator(&rest, ",") do if t := strings.trim_space(s); t != "" do append(&out, t)
		}
	}
	return out[:]
}

// A name as matching sees it: lower case, letters and digits only, a leading
// "the", "to", "a" or "an" dropped. "To the Fuel-Store" is "fuelstore", and so
// are fuel_store and FUEL STORE.
place_key :: proc(s: string) -> string {
	words := split_words(s)
	for len(words) > 1 {
		switch words[0] {
		case "the", "to", "a", "an":
			words = words[1:]
			continue
		}
		break
	}
	return strings.concatenate(words, context.temp_allocator)
}

// Every room, a page at a time (a message box holds 600 letters, and a
// game has more rooms than that): a conversation of the engine's, Enter for
// the next page.
@(private = "file")
dev_list: struct {
	talk:  Conversation,
	lines: [dynamic]Talk_Line,
	pages: [dynamic]string,
}

@(private = "file")
DEV_PAGE :: 360

// The pages, gone: for a test's tidy. A game never needs to.
@(private)
dev_list_free :: proc() {
	for p in dev_list.pages do delete(p)
	delete(dev_list.pages)
	delete(dev_list.lines)
	dev_list.pages, dev_list.lines = {}, {}
}

@(private = "file")
place_list :: proc(w: ^World) {
	for p in dev_list.pages do delete(p)
	clear(&dev_list.pages)
	clear(&dev_list.lines)
	b := strings.builder_make(context.temp_allocator)
	page_names := make([dynamic]string, context.temp_allocator)
	pages := make([dynamic][]string, context.temp_allocator)
	used := 0
	for sc in w.scenes {
		if used > 0 && used + len(sc.name) + 2 > DEV_PAGE {
			append(&pages, page_names[:])
			page_names = make([dynamic]string, context.temp_allocator)
			used = 0
		}
		append(&page_names, sc.name)
		used += len(sc.name) + 2
	}
	if len(page_names) > 0 do append(&pages, page_names[:])
	for names, n in pages {
		strings.builder_reset(&b)
		fmt.sbprintf(&b, "[dev] %v places", len(w.scenes))
		if len(pages) > 1 do fmt.sbprintf(&b, " (%v of %v)", n + 1, len(pages))
		strings.write_string(&b, ": ")
		for name, k in names do fmt.sbprintf(&b, "%v%v", "" if k == 0 else ", ", name)
		strings.write_string(&b, ".")
		if n == len(pages) - 1 do strings.write_string(&b, " TELEPORT <place>: a name, its start, or the game's words for it.")
		append(&dev_list.pages, strings.clone(strings.to_string(b)))
	}
	for p in dev_list.pages do append(&dev_list.lines, Talk_Line{text = p})
	begin_conversation(w, &dev_list.talk, dev_list.lines[:])
}

// --- TIMETRAVEL ---

DEV_TIME_USAGE :: "TIMETRAVEL <time>: 20:00, 2000, 20.00, 20h, 8pm, 8:30pm. After midnight is the same night; the clock only runs forward."

// What TIMETRAVEL did, or why not, in so many words.
@(private)
dev_timetravel :: proc(w: ^World, arg: string) -> string {
	if arg == "" do return fmt.tprintf("[dev] It is %v. %v", clock_face(clock_minute(w)), DEV_TIME_USAGE)
	tod, ok := parse_time_of_day(arg)
	if !ok do return fmt.tprintf("[dev] \"%v\" is not a time. %v", arg, DEV_TIME_USAGE)
	target, in_day := day_minute(w, tod)
	if !in_day {
		from, until := story_day(w)
		return fmt.tprintf("[dev] %v is not in the story's day, %v to %v.", clock_face(tod), clock_face(from), clock_face(until))
	}
	unheld := false
	if clock_is_held(w) {
		if w.dev.unhold == nil do return fmt.tprintf("[dev] The clock is held (%v), and nothing here lets it go.", w.clock_held)
		w.dev.unhold(w)
		unheld = true
		if clock_is_held(w) do return fmt.tprintf("[dev] The clock is held (%v), and stays held.", w.clock_held)
	}
	now := clock_minute(w)
	skipped := " The prologue is skipped." if unheld else ""
	if target < now {
		return fmt.tprintf("[dev] It is %v, and %v has gone: the clock only runs forward. TIMETRAVEL to a later time, or start again.%v",
			clock_face(now), clock_face(target), skipped)
	}
	if target == now do return fmt.tprintf("[dev] It is %v already.%v", clock_face(now), skipped)
	clock_at_least(w, target)
	return fmt.tprintf("[dev] %v to %v.%v", clock_face(now), clock_face(clock_minute(w)), skipped)
}

// The story's day, on the game's clock: `dev.day`, or the twenty-four hours
// from `clock_start`.
story_day :: proc(w: ^World) -> (from, until: int) {
	if w.dev.day != {} do return w.dev.day[0], w.dev.day[1]
	return w.clock_start, w.clock_start + 24 * 60 - 1
}

// A time of day (0 to 1439) as a minute on the game's clock, in the story's
// day: in a day from 16:00, 02:30 is 1590. False if the day does not hold it.
day_minute :: proc(w: ^World, tod: int) -> (minute: int, ok: bool) {
	from, until := story_day(w)
	m := tod
	for m < from do m += 24 * 60
	return m, m <= until
}

// "20:00", "2000", "20.00", "20h", "20h30", "8pm", "8:30 pm", "8.30p.m.",
// "noon", "midnight": minutes after midnight, 0 to 1439.
parse_time_of_day :: proc(text: string) -> (minute: int, ok: bool) {
	s := strings.to_lower(text, context.temp_allocator)
	s, _ = strings.remove_all(s, " ", context.temp_allocator)
	s, _ = strings.replace_all(s, "a.m.", "am", context.temp_allocator)
	s, _ = strings.replace_all(s, "p.m.", "pm", context.temp_allocator)
	switch s {
	case "midnight": return 0, true
	case "noon", "midday": return 12 * 60, true
	}
	half := 0 // 0 none, 1 am, 2 pm
	if strings.has_suffix(s, "am") do half, s = 1, s[:len(s) - 2]
	else if strings.has_suffix(s, "pm") do half, s = 2, s[:len(s) - 2]
	if strings.has_suffix(s, "h") do s = s[:len(s) - 1] // 20h
	if s == "" do return
	hs, ms := s, ""
	if sep := strings.index_any(s, ":.h"); sep >= 0 {
		hs, ms = s[:sep], s[sep + 1:]
		if len(ms) != 2 || !all_digits(ms) do return
	} else if len(s) >= 3 {
		// 2000, 830: the last two are the minutes.
		hs, ms = s[:len(s) - 2], s[len(s) - 2:]
	}
	if len(hs) == 0 || len(hs) > 2 || !all_digits(hs) || (ms != "" && !all_digits(ms)) do return
	h, _ := strconv.parse_int(hs)
	m := 0
	if ms != "" do m, _ = strconv.parse_int(ms)
	if m > 59 do return
	switch half {
	case 0:
		if h > 23 do return
	case:
		if h < 1 || h > 12 do return
		h %= 12
		if half == 2 do h += 12
	}
	return h * 60 + m, true
}

@(private = "file")
all_digits :: proc(s: string) -> bool {
	for c in transmute([]u8)s do if c < '0' || c > '9' do return false
	return true
}
