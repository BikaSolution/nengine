package nengine

import "core:testing"

@(private = "file")
tidy :: proc(w: ^World) {
	clear_notebook(w)
	clear_accusations(w)
	clear_flags(w)
	clear_awards(w)
	delete(w.notebook)
	delete(w.accusations)
	for &sc in w.scenes {
		if sc.from_file do free_scene_strings(&sc)
		delete(sc.exits)
		delete(sc.objects)
		delete(sc.said)
		delete(sc.triggers)
		if sc.from_file {
			delete(sc.walk_area)
			delete(sc.scenery)
		}
	}
	delete(w.scenes)
}

// --- Exits by name ---

@(private = "file")
room :: proc(t: ^testing.T, text: string) -> Scene {
	s, ok := parse_scene(text, nil)
	testing.expect(t, ok)
	return s
}

// An index makes the load order load-bearing; a name does not.
@(test)
an_exit_goes_to_a_room_by_its_name :: proc(t: ^testing.T) {
	w: World
	defer tidy(&w)
	append(&w.scenes, room(t, "scene fire_pit\nwalk 0,0 10,0 10,10\nexit office area=0,0,5,5 to=admin arrive=1,1\n"))
	append(&w.scenes, room(t, "scene pool_deck\nwalk 0,0 10,0 10,10\n"))
	append(&w.scenes, room(t, "scene admin\nwalk 0,0 10,0 10,10\nexit back area=0,0,5,5 to=fire_pit arrive=1,1\n"))

	_, ok := resolve_exits(&w)
	testing.expect(t, ok)
	testing.expect_value(t, w.scenes[0].exits[0].to, 2)
	testing.expect_value(t, w.scenes[2].exits[0].to, 0)
}

// The bug this replaced: `to=admin` parsed as 0 and dropped the player in the
// first room, without a word. A room nobody loaded is now an error that says
// which exit and which name.
@(test)
an_exit_to_a_room_nobody_loaded_is_an_error_not_a_wrong_room :: proc(t: ^testing.T) {
	w: World
	defer tidy(&w)
	append(&w.scenes, room(t, "scene fire_pit\nwalk 0,0 10,0 10,10\nexit office area=0,0,5,5 to=admni arrive=1,1\n"))

	problem, ok := resolve_exits(&w)
	testing.expect(t, !ok)
	testing.expect_value(t, problem, "fire_pit: exit office goes to admni, and there is no room called that")
}

@(test)
a_numbered_exit_still_works :: proc(t: ^testing.T) {
	w: World
	defer tidy(&w)
	append(&w.scenes, room(t, "scene a\nwalk 0,0 10,0 10,10\nexit e area=0,0,5,5 to=0 arrive=1,1\n"))
	_, ok := resolve_exits(&w)
	testing.expect(t, ok)
	testing.expect_value(t, w.scenes[0].exits[0].to, 0)
	testing.expect_value(t, w.scenes[0].exits[0].to_name, "")
}

// The room editor saves scene files. It must write a name back as a name, or
// opening a room and pressing save would quietly turn `to=admin` into `to=2`.
@(test)
an_exit_by_name_survives_the_room_editor_saving_it :: proc(t: ^testing.T) {
	s := room(t, "scene fire_pit\nwalk 0,0 10,0 10,10\nexit office area=0,0,5,5 to=admin arrive=1,1\n")
	defer free_scene_strings(&s)
	defer delete(s.exits)
	defer delete(s.walk_area)
	defer delete(s.scenery)
	text := scene_text(&s)
	testing.expect(t, contains(text, "to=admin"), text)
}

@(private = "file")
contains :: proc(hay, needle: string) -> bool {
	for i in 0 ..= len(hay) - len(needle) do if hay[i:i + len(needle)] == needle do return true
	return false
}

// --- Dressings ---

@(test)
a_room_wears_one_dressing_at_a_time :: proc(t: ^testing.T) {
	w: World
	defer tidy(&w)
	dress(&w, "tent", "3")
	testing.expect(t, flag(&w, "tent_3"))
	testing.expect_value(t, dressing(&w, "tent"), "3")

	dress(&w, "tent", "5")
	testing.expect(t, flag(&w, "tent_5"))
	testing.expect(t, !flag(&w, "tent_3"), "putting one on takes the last one off")
	testing.expect_value(t, dressing(&w, "tent"), "5")
}

// Only its own group: dressing the tent must not undress the fire.
@(test)
dressing_one_room_leaves_the_others_alone :: proc(t: ^testing.T) {
	w: World
	defer tidy(&w)
	set_flag(&w, "tents_pitched", true) // shares a prefix, is not in the group
	dress(&w, "fire", "high")
	dress(&w, "tent", "2")
	testing.expect(t, flag(&w, "fire_high"))
	testing.expect(t, flag(&w, "tents_pitched"))
	testing.expect_value(t, dressing(&w, "nothing"), "")
}

// --- Slots ---

@(test)
a_slot_is_one_the_player_owns_or_nothing :: proc(t: ^testing.T) {
	testing.expect_value(t, slot_of("1"), 1)
	testing.expect_value(t, slot_of("8"), 8)
	testing.expect_value(t, slot_of("9"), 0) // past the eight
	testing.expect_value(t, slot_of("0"), 0)
	testing.expect_value(t, slot_of("-1"), 0) // the autosave is not the player's to overwrite
	testing.expect_value(t, slot_of("lamp"), 0)
	testing.expect_value(t, slot_of(""), 0)
}

@(test)
save_with_no_number_asks_which :: proc(t: ^testing.T) {
	w: World
	defer tidy(&w)
	outcome, slot := slot_command(&w, Command{verb = "save"})
	testing.expect_value(t, outcome, Slot_Outcome.No_Slot)
	testing.expect_value(t, slot, 0)
}

// --- Look ---

// Scenery is painted into the backdrop and is not an object, and a LOOK that
// forgot it answered "no such thing" for half of every room.
@(test)
look_finds_scenery_as_well_as_things :: proc(t: ^testing.T) {
	w: World
	defer tidy(&w)
	append(&w.scenes, room(t, "scene r\ndesc A room.\nwalk 0,0 10,0 10,10\nobj lamp pos=5,5\ntext lamp A lamp.\nscenery sky Stars.\n"))
	refresh_world(&w)

	testing.expect(t, look_command(&w, Command{verb = "look"}))
	testing.expect_value(t, message(&w), "A room.")
	testing.expect(t, look_command(&w, Command{verb = "look", noun = "sky"}))
	testing.expect_value(t, message(&w), "Stars.")
	testing.expect(t, look_command(&w, Command{verb = "look", noun = "lamp"}))
	testing.expect(t, !look_command(&w, Command{verb = "look", noun = "piano"}), "the game says this one, in its own voice")
}

// --- The command line ---

@(test)
the_switches_every_game_is_tested_with :: proc(t: ^testing.T) {
	l := launch_flags({"--skip", "--debug", "--shot", "--at", "40", "--script", "look; !tick 3"})
	testing.expect(t, l.skip)
	testing.expect(t, l.debug)
	testing.expect(t, l.shot)
	testing.expect_value(t, l.shot_at, 40)
	testing.expect_value(t, l.script, "look; !tick 3")
	testing.expect(t, !l.menu)

	// A number that is not one leaves the frame where it was.
	bad := launch_flags({"--at", "soon"})
	testing.expect_value(t, bad.shot_at, 24)
}

// --- Starting over ---

@(private = "file", thread_local)
started: int

@(private = "file")
opening :: proc(w: ^World) {
	started += 1
	set_flag(w, "act2", true)
	ask(w, "Who?")
}

// Restart from the death box and Start from the menu are the same path, and
// between them nothing the last game did may survive.
@(test)
a_new_game_forgets_the_last_one :: proc(t: ^testing.T) {
	w := World{clock_start = 100, clock_step = 4}
	defer tidy(&w)
	started = 0

	new_game(&w, opening)
	set_flag(&w, "bodies_found", true)
	award(&w, "the_shoe")
	note(&w, {id = "shoe", tab = "things", text = "One shoe."})
	tick(&w, 30)
	w.dead = true

	new_game(&w, opening)
	testing.expect_value(t, started, 2)
	testing.expect(t, !flag(&w, "bodies_found"))
	testing.expect(t, flag(&w, "act2"), "and the game's own opening is put back")
	testing.expect(t, !has_award(&w, "the_shoe"))
	testing.expect_value(t, notebook_count(&w), 0)
	testing.expect_value(t, w.clock_ticks, 0)
	testing.expect(t, !w.dead)
	// Asked once per game, not once per game played so far.
	testing.expect_value(t, len(w.accusations), 1)
}

// --- The overlay ---

@(private = "file")
stay :: proc(w: ^World, dt: f32) -> bool {return true}

@(test)
an_overlay_is_open_until_it_is_closed :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, !overlay_open(&w))
	open_overlay(&w, {update = stay})
	testing.expect(t, overlay_open(&w))
	close_overlay(&w)
	testing.expect(t, !overlay_open(&w))
}

// --- The harness ---

@(test)
the_harness_can_set_up_a_test_without_the_beats_that_would :: proc(t: ^testing.T) {
	w := World{clock_start = 19 * 60 + 30, clock_step = 4}
	defer tidy(&w)
	append(&w.scenes, room(t, "scene fire_pit\nwalk 0,0 100,0 100,100 0,100\n"))
	append(&w.scenes, room(t, "scene admin\nwalk 200,200 300,200 300,300 200,300\n"))

	run_script(&w, "!flag act3; !flag !act2; !tick 5; !dress tent 3; !note things shoe One shoe.; !room admin")
	testing.expect(t, flag(&w, "act3"))
	testing.expect(t, !flag(&w, "act2"))
	testing.expect_value(t, w.clock_ticks, 5)
	testing.expect_value(t, dressing(&w, "tent"), "3")
	e, got := notebook_entry(&w, "shoe")
	testing.expect(t, got)
	testing.expect_value(t, e.text, "One shoe.")
	testing.expect_value(t, w.current, 1)
	// Standing on the floor, not wherever the last room left her.
	testing.expect_value(t, w.player.pos, [2]f32{250, 250})
}
