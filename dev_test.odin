package nengine

import "core:strings"
import "core:testing"

// The developer's TELEPORT and TIMETRAVEL (dev.odin).

@(private = "file")
tidy :: proc(w: ^World) {
	clear_flags(w)
	clear_notebook(w)
	delete(w.notebook)
	for &sc in w.scenes {
		if sc.from_file do free_scene_strings(&sc)
		delete(sc.exits)
		delete(sc.objects)
		delete(sc.said)
		delete(sc.triggers)
		delete(sc.sides)
		if sc.from_file {
			delete(sc.walk_area)
			delete(sc.scenery)
		}
	}
	delete(w.scenes)
}

@(private = "file")
room :: proc(t: ^testing.T, text: string) -> Scene {
	s, ok := parse_scene(text, nil)
	testing.expect(t, ok)
	return s
}

@(private = "file")
DEV_WORDS := [?]Word {
	{.Verb, "look", "l"},
	{.Noun, "gap", "the gap, overlap, nine feet"},
	{.Noun, "officestep", "office step, the office step"},
	{.Noun, "tent6", "tent 6, tent six, sixth tent"},
	{.Noun, "office", "the office"},
}

@(private = "file")
DEV_PLACES := [?]Place_Name {
	{"gap", "fuel_store"},
	{"office", "admin"}, {"office", "office_step"}, {"officestep", "office_step"},
	{"tent6", "tent_row_south"},
	{"kitchen", "kitchen_yard"},
}

// A camp of eight rooms, the game's words for some of them.
@(private = "file")
camp :: proc(t: ^testing.T, w: ^World) {
	w.vocab = DEV_WORDS[:]
	w.dev.places = DEV_PLACES[:]
	for name in ([]string{"fuel_store", "office_step", "admin", "kitchen", "kitchen_yard", "tent_row_south", "pool_deck", "pool_gate"}) {
		append(&w.scenes, room(t, strings.concatenate({"scene ", name, "\nwalk 0,0 400,0 400,300 0,300\n"}, context.temp_allocator)))
	}
}

@(private = "file")
place :: proc(w: ^World, said: string) -> string {
	i, ok, _ := match_place(w, said)
	return w.scenes[i].name if ok else ""
}

// --- Times ---

@(test)
a_time_is_read_however_it_is_written :: proc(t: ^testing.T) {
	Case :: struct {
		said:   string,
		minute: int,
	}
	cases := [?]Case {
		{"20:00", 20 * 60}, {"2000", 20 * 60}, {"20.00", 20 * 60}, {"20h", 20 * 60}, {"20h30", 20 * 60 + 30},
		{"8pm", 20 * 60}, {"8 PM", 20 * 60}, {"8:30pm", 20 * 60 + 30}, {"8.30 p.m.", 20 * 60 + 30}, {"830pm", 20 * 60 + 30},
		{"02:30", 2 * 60 + 30}, {"0230", 2 * 60 + 30}, {"2:30", 2 * 60 + 30}, {"230", 2 * 60 + 30}, {"2am", 2 * 60},
		{"12am", 0}, {"12pm", 12 * 60}, {"midnight", 0}, {"noon", 12 * 60}, {"0", 0}, {"23:59", 23 * 60 + 59}, {"7", 7 * 60},
	}
	for c in cases {
		m, ok := parse_time_of_day(c.said)
		testing.expectf(t, ok && m == c.minute, "%q: got %v %v, want %v", c.said, m, ok, c.minute)
	}
}

@(test)
garbage_is_not_a_time :: proc(t: ^testing.T) {
	for said in ([]string{"", "pm", "24:00", "25:00", "20:60", "20:0", "2:3", "13pm", "0am", "abc", "8xm", "-1", "20:00:00", "12345", "20h3", "eight"}) {
		_, ok := parse_time_of_day(said)
		testing.expectf(t, !ok, "%q read as a time", said)
	}
}

// After midnight is the same night: in a day from four in the afternoon,
// 02:30 is after 23:59 on the game's clock, and ten in the morning is not in it.
@(test)
a_time_goes_on_the_storys_day :: proc(t: ^testing.T) {
	w := World{clock_start = 16 * 60}
	w.dev.day = {16 * 60, 30 * 60 + 40}
	m, ok := day_minute(&w, 2 * 60 + 30)
	testing.expect(t, ok)
	testing.expect_value(t, m, 26 * 60 + 30)
	m, ok = day_minute(&w, 20 * 60)
	testing.expect_value(t, m, 20 * 60)
	m, ok = day_minute(&w, 16 * 60)
	testing.expect_value(t, m, 16 * 60)
	_, ok = day_minute(&w, 10 * 60)
	testing.expect(t, !ok)
	_, ok = day_minute(&w, 6 * 60 + 41)
	testing.expect(t, !ok)
	// No day given: the twenty-four hours from the clock's start.
	v := World{clock_start = 19 * 60 + 30}
	m, ok = day_minute(&v, 10)
	testing.expect(t, ok && m == 24 * 60 + 10)
	m, ok = day_minute(&v, 19 * 60)
	testing.expect(t, ok && m == 43 * 60)
}

// --- Names ---

@(test)
a_place_is_found_by_any_name_for_it :: proc(t: ^testing.T) {
	w: World
	defer tidy(&w)
	camp(t, &w)
	// Exact: the room's own name, with spaces, any case.
	testing.expect_value(t, place(&w, "fuel_store"), "fuel_store")
	testing.expect_value(t, place(&w, "Fuel Store"), "fuel_store")
	testing.expect_value(t, place(&w, "to the FUEL-STORE"), "fuel_store")
	// The game's word, and the vocabulary's synonyms for it.
	testing.expect_value(t, place(&w, "the gap"), "fuel_store")
	testing.expect_value(t, place(&w, "overlap"), "fuel_store")
	testing.expect_value(t, place(&w, "office step"), "office_step")
	testing.expect_value(t, place(&w, "tent six"), "tent_row_south")
	testing.expect_value(t, place(&w, "tent 6"), "tent_row_south")
	// A room's own name beats a word the game gives another room.
	testing.expect_value(t, place(&w, "kitchen"), "kitchen")
	testing.expect_value(t, place(&w, "admin"), "admin")
	// The start of one name, if only one room starts that way.
	testing.expect_value(t, place(&w, "fuel"), "fuel_store")
	testing.expect_value(t, place(&w, "kitchen y"), "kitchen_yard")
	testing.expect_value(t, place(&w, "tent row"), "tent_row_south")
}

@(test)
a_name_for_several_places_or_none_says_which :: proc(t: ^testing.T) {
	w: World
	defer tidy(&w)
	camp(t, &w)
	// A start several rooms share.
	_, ok, why := match_place(&w, "pool")
	testing.expect(t, !ok)
	testing.expectf(t, strings.contains(why, "pool_deck") && strings.contains(why, "pool_gate"), "%v", why)
	// A word of the game's for two rooms.
	_, ok, why = match_place(&w, "the office")
	testing.expect(t, !ok)
	testing.expectf(t, strings.contains(why, "admin") && strings.contains(why, "office_step"), "%v", why)
	// Nothing by that name: the nearest by spelling.
	_, ok, why = match_place(&w, "fule store")
	testing.expect(t, !ok)
	testing.expectf(t, strings.contains(why, "No place") && strings.contains(why, "fuel_store"), "%v", why)
	_, ok, why = match_place(&w, "zebra crossing")
	testing.expect(t, !ok)
	testing.expectf(t, strings.contains(why, "No place called"), "%v", why)
	_, ok, _ = match_place(&w, "")
	testing.expect(t, !ok)
}

// --- The switch ---

@(test)
off_the_commands_are_words_nobody_knows :: proc(t: ^testing.T) {
	w := World{clock_start = 16 * 60, clock_step = 1}
	defer tidy(&w)
	camp(t, &w)
	run_command(&w, "teleport admin")
	testing.expect_value(t, message(&w), "I don't know the word \"teleport\".")
	testing.expect_value(t, w.current, 0)
	run_command(&w, "timetravel 20:00")
	testing.expect_value(t, message(&w), "I don't know the word \"timetravel\".")
	testing.expect_value(t, clock_minute(&w), 16 * 60)
	run_command(&w, "time travel 20:00")
	testing.expect_value(t, message(&w), "I don't know the word \"time\".")
	testing.expect_value(t, clock_minute(&w), 16 * 60)

	w.dev.on = true
	run_command(&w, "teleport admin")
	testing.expect_value(t, current_scene(&w).name, "admin")
	run_command(&w, "TIME TRAVEL 8pm")
	testing.expect_value(t, clock_minute(&w), 20 * 60)
	// And the parser still has everything else.
	run_command(&w, "dance")
	testing.expect_value(t, message(&w), "I don't know the word \"dance\".")
}

// --- TELEPORT ---

@(private = "file")
arrived_count, found_count: int

@(test)
teleporting_in_is_walking_in :: proc(t: ^testing.T) {
	w := World{dev = {on = true}}
	defer tidy(&w)
	defer dev_list_free()
	append(&w.scenes, room(t, "scene path\nwalk 0,0 400,0 400,300 0,300\nexit down area=0,0,20,20 to=deck arrive=300,200\n"))
	append(&w.scenes, room(t, "scene deck\nwalk 0,0 400,0 400,300 0,300\ntrigger find_bodies area=0,0,400,300 action=find_bodies\n"))
	append(&w.scenes, room(t, "scene hut\nwalk 0,0 400,0 400,300 0,300\n"))
	_, ok := resolve_exits(&w)
	testing.expect(t, ok)
	scene_bind_trigger(&w.scenes[1], "find_bodies", proc(w: ^World) {found_count += 1})
	w.on_arrive = proc(w: ^World) {arrived_count += 1}
	arrived_count, found_count = 0, 0

	run_command(&w, "teleport deck")
	testing.expect_value(t, current_scene(&w).name, "deck")
	// At the door's arrival spot, and the room knows she has come.
	testing.expect_value(t, w.player.pos, [2]f32{300, 200})
	testing.expect_value(t, arrived_count, 1)
	testing.expect_value(t, found_count, 1)
	// No door into the hut: the middle of its floor.
	run_command(&w, "teleport hut")
	testing.expect_value(t, current_scene(&w).name, "hut")
	testing.expect_value(t, w.player.pos, [2]f32{200, 150})
	testing.expect_value(t, arrived_count, 2)
	// Where, with nowhere said; a list, and she stays put.
	run_command(&w, "teleport")
	testing.expectf(t, strings.contains(message(&w), "path, deck, hut"), "%v", message(&w))
	testing.expect_value(t, current_scene(&w).name, "hut")
	run_command(&w, "teleport list")
	testing.expectf(t, strings.contains(message(&w), "3 places"), "%v", message(&w))
	run_command(&w, "teleport nowhere")
	testing.expect_value(t, current_scene(&w).name, "hut")
}

// --- TIMETRAVEL ---

@(test)
timetravel_runs_the_clock_on_and_never_back :: proc(t: ^testing.T) {
	w := World{clock_start = 16 * 60, clock_step = 1, dev = {on = true, day = {16 * 60, 30 * 60 + 40}}}
	defer tidy(&w)
	camp(t, &w)
	w.on_clock = proc(w: ^World) {set_flag(w, "dinner", clock_minute(w) >= 19 * 60 + 30)}

	run_command(&w, "timetravel")
	testing.expectf(t, strings.contains(message(&w), "It is 16:00"), "%v", message(&w))
	run_command(&w, "timetravel 20:00")
	testing.expect_value(t, clock_minute(&w), 20 * 60)
	testing.expect(t, flag(&w, "dinner")) // the hour's flags, as it passed
	run_command(&w, "timetravel 02:30")
	testing.expect_value(t, clock_minute(&w), 26 * 60 + 30)
	// Back: refused, and saying so.
	run_command(&w, "timetravel 8pm")
	testing.expect_value(t, clock_minute(&w), 26 * 60 + 30)
	testing.expectf(t, strings.contains(message(&w), "only runs forward") && strings.contains(message(&w), "02:30"), "%v", message(&w))
	run_command(&w, "timetravel 10am")
	testing.expect_value(t, clock_minute(&w), 26 * 60 + 30)
	testing.expectf(t, strings.contains(message(&w), "not in the story's day"), "%v", message(&w))
	run_command(&w, "timetravel soon")
	testing.expectf(t, strings.contains(message(&w), "is not a time"), "%v", message(&w))
}

@(private = "file", thread_local)
unheld_count: int

@(test)
a_held_clock_is_let_go_by_the_game_or_not_at_all :: proc(t: ^testing.T) {
	w := World{clock_start = 16 * 60, clock_step = 1, clock_held = "boat", dev = {on = true}}
	defer tidy(&w)
	camp(t, &w)
	set_flag(&w, "boat", true)
	run_command(&w, "timetravel 20:00")
	testing.expect_value(t, clock_minute(&w), 16 * 60)
	testing.expectf(t, strings.contains(message(&w), "held"), "%v", message(&w))
	unheld_count = 0
	w.dev.unhold = proc(w: ^World) {
		set_flag(w, "boat", false)
		unheld_count += 1
	}
	run_command(&w, "timetravel 20:00")
	testing.expect_value(t, unheld_count, 1)
	testing.expect_value(t, clock_minute(&w), 20 * 60)
}

// --dev on a command line a test passes says so, and switches nothing on: only
// the game's own command line (or NENGINE_DEV) does.
@(test)
the_switch_is_dash_dash_dev :: proc(t: ^testing.T) {
	testing.expect(t, launch_flags({"--skip", "--dev"}).dev)
	testing.expect(t, !launch_flags({"--skip"}).dev)
	w: World
	testing.expect(t, !dev_on(&w))
}
