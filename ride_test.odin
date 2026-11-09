package nengine

import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
LOOKS := [?]Glance {
	{look = "beam", secs = 3, at = {100, 100}, line = "Along the beam."},
	{look = "moth", secs = 4, at = {300, 120}},
	{look = "yard", room = "yard", secs = 2, at = {50, 50}, line = "Outside."},
}

@(private = "file")
SHY := [?]Glance{{look = "lamp", secs = 1}, {look = "shout", secs = 1, leaves = true}}

@(private = "file")
HOSTS := [?]Host {
	{name = "cat", attention = LOOKS[:]},
	{name = "owl", from = 20 * 60, until = 28 * 60, attention = LOOKS[:]},
	{name = "moth", attention = SHY[:]},
	{name = "ghost", anywhere = true, only = "haunted", attention = LOOKS[:]},
}

// How each world's rides ended, kept on the world (w.user) and not in a
// global: the tests run side by side.
@(private = "file")
Ended :: struct {
	host:      string,
	broke_off: bool,
	count:     int,
}

@(private = "file")
ended_of :: proc(w: ^World) -> ^Ended {
	return cast(^Ended)w.user
}

@(private = "file")
cat_house :: proc() -> World {
	w: World
	w.vocab = vocab_join({{.Noun, "cat", ""}, {.Noun, "owl", ""}, {.Noun, "moth", ""}, {.Noun, "face", ""}}, context.temp_allocator)
	w.hosts = HOSTS[:]
	w.clock_start, w.clock_step = 19 * 60 + 30, 4
	w.on_ride_end = proc(w: ^World, h: ^Host, broke_off: bool) {
		e := ended_of(w)
		e^ = {h.name, broke_off, e.count + 1}
	}
	house := Scene{name = "house"}
	for name in ([]string{"cat", "owl", "moth"}) do append(&house.objects, Object{name = name})
	append(&w.scenes, house, Scene{name = "yard"})
	w.player.pos = {200, 400}
	w.user = new(Ended)
	return w
}

@(private = "file")
done :: proc(w: ^World) {
	free(ended_of(w))
	destroy_world(w)
}

@(test)
a_host_must_be_known_here_and_awake :: proc(t: ^testing.T) {
	w := cat_house()
	defer done(&w)

	testing.expect_value(t, ride(&w, "dog"), Ride_Outcome.Unknown)
	testing.expect_value(t, ride(&w, "owl"), Ride_Outcome.Not_Now) // 19:30, and it wakes at 20:00
	testing.expect_value(t, ride(&w, "ghost"), Ride_Outcome.Not_Now) // not haunted
	w.current = 1
	testing.expect_value(t, ride(&w, "cat"), Ride_Outcome.Not_Here)
	w.current = 0

	tick(&w, 8) // 20:02
	testing.expect_value(t, ride(&w, "owl"), Ride_Outcome.Started)
	testing.expect_value(t, ride(&w, "cat"), Ride_Outcome.Already)
}

@(test)
going_under_then_the_loop :: proc(t: ^testing.T) {
	w := cat_house()
	defer done(&w)

	testing.expect_value(t, ride(&w, "cat"), Ride_Outcome.Started)
	testing.expect(t, riding(&w))
	testing.expect(t, ride_glance(&w) == nil) // still going under

	update_ride(&w, GOING_SECS)
	testing.expect_value(t, ride_glance(&w).look, "beam")
	testing.expect_value(t, message(&w), "Along the beam.")

	update_ride(&w, 3)
	testing.expect_value(t, ride_glance(&w).look, "moth")
	update_ride(&w, 4)
	testing.expect_value(t, ride_glance(&w).look, "yard")
	testing.expect_value(t, w.ride.cam_room, 1) // a cut into the other room
	update_ride(&w, 2)
	testing.expect_value(t, ride_glance(&w).look, "beam") // round again

	// Its line was said the first time round, and is not said again.
	w.message_len = 0
	update_ride(&w, 3)
	update_ride(&w, 4)
	update_ride(&w, 2)
	testing.expect_value(t, message(&w), "")
}

@(test)
wait_moves_on_and_standing_comes_back :: proc(t: ^testing.T) {
	w := cat_house()
	defer done(&w)
	ride(&w, "cat")
	settle_ride(&w)

	run_command(&w, "wait")
	testing.expect_value(t, ride_glance(&w).look, "moth")
	run_command(&w, "stand up")
	testing.expect_value(t, w.ride.phase, Ride_Phase.Coming)
	update_ride(&w, COMING_SECS)
	testing.expect(t, !riding(&w))
	testing.expect_value(t, ended_of(&w).host, "cat")
	testing.expect(t, !ended_of(&w).broke_off)

	room, pos, ok := ride_body(&w)
	testing.expect(t, ok)
	testing.expect_value(t, room, "house")
	testing.expect_value(t, pos, [2]f32{200, 400})
}

@(test)
a_host_can_break_off :: proc(t: ^testing.T) {
	w := cat_house()
	defer done(&w)
	ride(&w, "moth")
	settle_ride(&w)
	update_ride(&w, 1) // the lamp
	update_ride(&w, 1) // the shout: over
	testing.expect_value(t, w.ride.phase, Ride_Phase.Coming)
	settle_ride(&w)
	testing.expect_value(t, ended_of(&w).count, 1)
	testing.expect(t, ended_of(&w).broke_off)
}

@(test)
anything_else_while_riding_is_the_games :: proc(t: ^testing.T) {
	w := cat_house()
	defer done(&w)
	ride(&w, "cat")
	settle_ride(&w)

	run_command(&w, "take moth")
	testing.expect_value(t, message(&w), "You can only wait, or come back.")

	w.on_ride_command = proc(w: ^World, cmd: Command) -> bool {
		if cmd.noun != "face" do return false
		say(w, "It doesn't know what a face is.")
		return true
	}
	run_command(&w, "look at face")
	testing.expect_value(t, message(&w), "It doesn't know what a face is.")
	run_command(&w, "look")
	testing.expect_value(t, message(&w), "Along the beam.")
	testing.expect(t, riding(&w)) // none of that ended it
}

@(test)
tones_stay_in_the_palette :: proc(t: ^testing.T) {
	greys := palette_map_tones({0, 8, 7, 15})
	testing.expect_value(t, greys[0], 0)   // black stays black
	testing.expect_value(t, greys[15], 15) // white stays white
	testing.expect_value(t, greys[7], 7)
	for m in greys do testing.expect(t, m == 0 || m == 8 || m == 7 || m == 15)

	// A keener eye: everything lighter, nothing outside its tones.
	keen := palette_map_tones({0, 1, 8, 7, 15}, 2.2)
	testing.expect_value(t, keen[8], 7) // dark grey, seen by a night animal, is light
	testing.expect_value(t, keen[0], 0) // and black is still black
	testing.expect_value(t, palette_map_same()[9], 9)
}

@(test)
where_the_body_was_left_is_saved :: proc(t: ^testing.T) {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" do base = "/tmp"
	dir := strings.concatenate({base, "/nengine-save-ride"}, context.temp_allocator)
	os.remove_all(dir)
	defer os.remove_all(dir)

	w := cat_house()
	defer done(&w)
	w.save_name = dir
	ride(&w, "cat")
	settle_ride(&w)
	come_back(&w)
	settle_ride(&w)
	testing.expect(t, save_game(&w, 1))

	w.ride = {}
	testing.expect(t, load_game(&w, 1))
	room, pos, ok := ride_body(&w)
	testing.expect(t, ok)
	testing.expect_value(t, room, "house")
	testing.expect_value(t, pos, [2]f32{200, 400})
}

// The same animal in two rooms, looking at two things: each declaration with
// a room is only that room's, and the first one here is the one ridden.
@(test)
a_host_with_a_room_lives_only_there :: proc(t: ^testing.T) {
	w := cat_house()
	defer done(&w)
	barn := [?]Host {
		{name = "cat", room = "yard", attention = SHY[:]},
		{name = "cat", room = "house", attention = LOOKS[:]},
	}
	w.hosts = barn[:]
	testing.expect_value(t, ride(&w, "cat"), Ride_Outcome.Started)
	testing.expect_value(t, ride_host(&w), &w.hosts[1])
	w.ride = {}

	// In the yard, with a cat in it, the yard's.
	append(&w.scenes[1].objects, Object{name = "cat"})
	w.current = 1
	testing.expect_value(t, ride(&w, "cat"), Ride_Outcome.Started)
	testing.expect_value(t, ride_host(&w), &w.hosts[0])
}

@(private = "file")
OVERHEAD := [?]Glance{{look = "above", room = "aerial", secs = 3, at = {512, 300}, line = "The camp, from above."}}

@(private = "file")
KITES := [?]Host{{name = "kite", attention = OVERHEAD[:]}}

@(test)
a_host_in_a_room_with_no_floor_is_ridden :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	w.vocab = vocab_join({{.Noun, "kite", ""}}, context.temp_allocator)
	w.hosts = KITES[:]
	deck := Scene{name = "deck"}
	append(&deck.objects, Object{name = "kite"})
	append(&w.scenes, deck, Scene{name = "aerial"}) // no walk line at all
	testing.expect_value(t, ride(&w, "kite"), Ride_Outcome.Started)
	update_ride(&w, GOING_SECS)
	testing.expect_value(t, ride_glance(&w).look, "above")
	testing.expect_value(t, w.ride.cam_room, 1)
	testing.expect_value(t, message(&w), "The camp, from above.")
}

@(test)
the_harness_plays_out_a_ride_nobody_typed :: proc(t: ^testing.T) {
	// A beat sends her under: a scripted ride. In play its frames take it
	// round and it ends itself; the harness, which has no frames, does the
	// same, and does not leave her answering every later line as a passenger.
	w := cat_house()
	defer done(&w)
	set_flag(&w, "haunted")
	beats := []Beat{{name = "possessed", until = 48 * 60, on_play = proc(w: ^World) {ride(w, "ghost")}}}
	w.beats = beats
	run_script(&w, "!clock")
	testing.expect(t, !riding(&w))
	testing.expect_value(t, ended_of(&w).host, "ghost")
	testing.expect_value(t, ended_of(&w).count, 1)
	clear_flags(&w)
}

@(test)
the_harness_leaves_her_own_ride_to_her :: proc(t: ^testing.T) {
	// Under already when the line ends (the command's own ride): she stays
	// there until she WAITs or gets up, as at the prompt.
	w := cat_house()
	defer done(&w)
	ride(&w, "cat")
	run_script(&w, "!clock")
	testing.expect(t, riding(&w))
	testing.expect_value(t, ended_of(&w).count, 0)
}
