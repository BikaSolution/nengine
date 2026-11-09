package nengine

import "core:testing"

@(private = "file") triggered: int

@(private = "file")
room_with_a_trap :: proc() -> World {
	w: World
	s := Scene{name = "room"}
	append(&s.triggers, Trigger{area = {100, 0, 50, 100}, on_enter = proc(w: ^World) { triggered += 1 }})
	append(&w.scenes, s)
	return w
}

@(test)
a_trigger_fires_on_stepping_in_not_on_standing_there :: proc(t: ^testing.T) {
	w := room_with_a_trap()
	defer destroy_world(&w)
	triggered = 0

	w.player.pos = {90, 50}
	testing.expect(t, !check_triggers(&w, {80, 50}))

	w.player.pos = {105, 50}
	testing.expect(t, check_triggers(&w, {90, 50}))
	testing.expect_value(t, triggered, 1)

	w.player.pos = {110, 50}
	testing.expect(t, !check_triggers(&w, {105, 50}))
	testing.expect_value(t, triggered, 1)
}

// A death that takes one second.
@(private = "file")
one_second_death :: Death {
	reason = "Very sudden.",
	update = proc(w: ^World, t, last: f32) -> bool { return t >= 1 },
}

@(test)
dying_stops_the_player_then_opens_the_box :: proc(t: ^testing.T) {
	w := room_with_a_trap()
	defer destroy_world(&w)
	w.player = {pos = {10, 10}, heading = {1, 0}}
	walk_to(&w.player, {50, 50})

	die(&w, one_second_death)
	testing.expect(t, w.dead)
	testing.expect(t, !w.player.moving)
	testing.expect_value(t, w.player.heading, [2]f32{0, 0})

	for _ in 0 ..< 30 do advance_death(&w, 1.0 / 60)
	testing.expect(t, !w.death_box, "still playing after half a second")

	for _ in 0 ..< 40 do advance_death(&w, 1.0 / 60)
	testing.expect(t, w.death_box, "the box is up after a second")
	testing.expect_value(t, w.death_pick, Death_Choice.Restart)
}

@(test)
the_buttons :: proc(t: ^testing.T) {
	w: World
	death_choose(&w, .Restore)
	testing.expect(t, !w.restart && !w.quit, "restore does nothing yet")
	death_choose(&w, .Restart)
	testing.expect(t, w.restart)
	death_choose(&w, .Quit)
	testing.expect(t, w.quit)
	// Nothing has been saved in this test's world, so Restore is unavailable.
	testing.expect(t, !death_choice_ready(&w, .Restore))
}

@(test)
clearing_the_world_is_a_fresh_start :: proc(t: ^testing.T) {
	w := room_with_a_trap()
	defer destroy_world(&w)
	die(&w, one_second_death)
	w.restart = true
	say(&w, "Old news.")

	clear_world(&w)
	testing.expect_value(t, len(w.scenes), 0)
	testing.expect(t, !w.dead && !w.death_box && !w.restart)
	testing.expect_value(t, message(&w), "")
}

@(test)
just_passed_fires_once :: proc(t: ^testing.T) {
	// Add up time the way the engine does, rounding errors and all.
	count := 0
	now: f32
	for _ in 0 ..< 120 {
		last := now
		now += 1.0 / 60
		if just_passed(now, last, 0.5) do count += 1
	}
	testing.expect_value(t, count, 1)
}

// A death that names its restore point goes back there, not to the newest
// save: the autosave on the way into the trap does not win. And a point can
// stand her somewhere other than where she was when it was made.
@(test)
a_death_goes_back_to_its_own_restore_point :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	append(&w.scenes, Scene{name = "gate"})
	append(&w.scenes, Scene{name = "path"})
	w.save_name = test_tmp("nengine-restore-point-test")
	defer remove_test_saves(&w)

	// At the gate, the moment that matters: the point.
	w.current = 0
	w.player.pos = {100, 100}
	set_flag(&w, "warned")
	testing.expect(t, restore_point(&w, "the warning"))
	testing.expect(t, has_restore_point(&w, "the warning"))

	// Then on, and an autosave on the way into the path: the newest save.
	set_flag(&w, "lamp_left")
	w.current = 1
	w.player.pos = {300, 300}
	testing.expect(t, autosave(&w, "the path"))

	die(&w, Death{reason = "Six hundred feet.", restore = "the warning"})
	testing.expect(t, death_choice_ready(&w, .Restore))
	death_choose(&w, .Restore)
	testing.expect(t, !w.dead, "restoring is how you stop being dead")
	testing.expect_value(t, current_scene(&w).name, "gate")
	testing.expect_value(t, w.player.pos.x, f32(100))
	testing.expect(t, flag(&w, "warned"))
	testing.expect(t, !flag(&w, "lamp_left"), "the point is from before")

	// Made on the path, but standing at the gate.
	w.current = 1
	w.player.pos = {300, 300}
	testing.expect(t, restore_point(&w, "the gate", "gate", {120, 140}))
	die(&w, Death{reason = "Again.", restore = "the gate"})
	death_choose(&w, .Restore)
	testing.expect_value(t, current_scene(&w).name, "gate")
	testing.expect_value(t, w.player.pos.y, f32(140))

	// A point never made: the newest save, as before.
	die(&w, Death{reason = "Elsewhere.", restore = "never made"})
	death_choose(&w, .Restore)
	testing.expect_value(t, current_scene(&w).name, "path")

	// A new game forgets them.
	reset_story(&w)
	testing.expect(t, !has_restore_point(&w, "the warning"))
}

@(private = "file")
remove_test_saves :: proc(w: ^World) {
	for slot in ([]int{AUTOSAVE, AUTOSAVE_PREVIOUS}) do save_delete(w, slot)
}
