package nengine

import "core:testing"

// Elena cleans the banda: she wipes one end, walks to the other, wipes that,
// and goes back. The player can look at her, talk to her, and walk past her
// while she does it, because she is an object like the bar is an object — one
// that happens to move.

@(private = "file")
BANDA :: `scene banda
walk 0,0 640,0 640,640 0,640

obj bar pos=100,400
text bar Zinc, and a great deal of polishing.

obj elena pos=100,470 char=elena speed=100 facing=right when=!elena_gone
text elena She is wiping down the bar, again.
on elena look She looks up, and keeps wiping.
on elena talk_to Evening, miss. You'll want the far tent.
routine elena loop
step elena walk_to 500,470
step elena play cleaning 4
step elena face left
step elena walk_to 100,470
step elena wait 2
`

@(private = "file")
open_banda :: proc(t: ^testing.T) -> World {
	s, ok := parse_scene(BANDA, nil)
	testing.expect(t, ok)
	w: World
	append(&w.scenes, s)
	refresh_world(&w)
	return w
}

@(private = "file")
shut_banda :: proc(w: ^World) {
	for &o in w.scenes[0].objects do routine_destroy(&o.routine)
	free_scene_strings(&w.scenes[0])
	delete(w.scenes[0].objects)
	delete(w.scenes[0].exits)
	delete(w.scenes[0].triggers)
	delete(w.scenes[0].walk_area)
	delete(w.scenes[0].scenery)
	delete(w.scenes[0].said)
	delete(w.scenes)
	clear_flags(w)
}

// Runs the world's clock forward, the way the game loop does.
@(private = "file")
tick :: proc(w: ^World, seconds: f32, step: f32 = 1.0 / 60) {
	for t := f32(0); t < seconds; t += step {
		w.time += step
		update_people(w, &w.scenes[0], step)
	}
}

@(test)
a_person_is_an_object_that_walks :: proc(t: ^testing.T) {
	w := open_banda(t)
	defer shut_banda(&w)
	scene := &w.scenes[0]

	// She is found, described and talked to exactly like the bar is, because
	// there is one kind of thing in a room and she is one of them.
	elena := object_here(scene, "elena")
	testing.expect(t, elena != nil)
	testing.expect(t, elena.walks)
	testing.expect_value(t, elena.char_name, "elena")

	text, ok := describe(scene, "elena")
	testing.expect(t, ok)
	testing.expect_value(t, text, "She is wiping down the bar, again.")

	talk := object_interaction(&w, elena, Command{verb = "talk to", noun = "elena"})
	testing.expect(t, talk != nil)
	testing.expect_value(t, talk.text, "Evening, miss. You'll want the far tent.")

	// And the bar is still just a bar.
	bar := object_here(scene, "bar")
	testing.expect(t, bar != nil)
	testing.expect(t, !bar.walks)
}

@(test)
she_walks_the_routine_and_starts_again :: proc(t: ^testing.T) {
	w := open_banda(t)
	defer shut_banda(&w)
	elena := object_here(&w.scenes[0], "elena")

	testing.expect_value(t, elena.pos.x, f32(100))

	// Step one: walk to the far end. 400 pixels at 100 a second.
	tick(&w, 1)
	testing.expect(t, elena.pos.x > 150, "she has set off")
	testing.expect(t, elena.pos.x < 500, "and has not arrived yet")

	tick(&w, 4)
	testing.expect_value(t, elena.pos.x, f32(500))

	// Step two: wiping, which is standing still in a named pose.
	testing.expect_value(t, elena.actor.pose, "cleaning")
	testing.expect(t, !elena.actor.moving)
	tick(&w, 1)
	testing.expect_value(t, elena.pos.x, f32(500)) // she stays put while she wipes

	// Steps three and four: turn, and walk back.
	tick(&w, 4)
	testing.expect_value(t, elena.actor.pose, "") // a pose lasts for its own step
	testing.expect(t, elena.pos.x < 500, "she is on her way back")

	// Walking back takes four seconds from the ten-second mark, then she
	// waits two; at twelve and a half she is home and standing still.
	tick(&w, 2.5)
	testing.expect_value(t, elena.pos.x, f32(100))

	// And round again, because the routine loops: the wait ends at fourteen.
	tick(&w, 3)
	testing.expect(t, elena.pos.x > 100, "she has set off again")
	testing.expect(t, !elena.routine.done)
}

@(test)
a_routine_that_does_not_loop_stops_at_the_end :: proc(t: ^testing.T) {
	w := open_banda(t)
	defer shut_banda(&w)
	elena := object_here(&w.scenes[0], "elena")
	elena.routine.loop = false

	tick(&w, 30)
	testing.expect(t, elena.routine.done, "she has finished")
	testing.expect_value(t, elena.actor.pose, "") // not left mid-wipe
	where_she_stopped := elena.pos
	tick(&w, 5)
	testing.expect_value(t, elena.pos, where_she_stopped)
}

@(test)
somebody_who_is_not_in_this_act_is_not_in_the_room :: proc(t: ^testing.T) {
	w := open_banda(t)
	defer shut_banda(&w)
	scene := &w.scenes[0]

	tick(&w, 2)
	testing.expect(t, object_here(scene, "elena") != nil)

	// She leaves the story. She is not drawn, not found, and not walking.
	set_flag(&w, "elena_gone")
	testing.expect(t, object_here(scene, "elena") == nil)
	_, ok := describe(scene, "elena")
	testing.expect(t, !ok, "you cannot look at somebody who is not there")

	any := &scene.objects[1]
	tick(&w, 3)
	testing.expect(t, !any.actor.moving, "and she is not pacing about invisibly")

	// When she comes back she starts the routine again rather than resuming
	// half way through wiping a table she has not walked to.
	set_flag(&w, "elena_gone", false)
	testing.expect(t, object_here(scene, "elena") != nil)
	testing.expect_value(t, any.routine.at, 0)
	testing.expect(t, !any.routine.begun)
}

@(test)
a_person_blocks_and_sorts_like_anything_else :: proc(t: ^testing.T) {
	w := open_banda(t)
	defer shut_banda(&w)
	elena := object_here(&w.scenes[0], "elena")

	// `pos` is the field everything else reads — drawing order, blocking,
	// how near the player is — and the actor keeps it up to date as she goes.
	testing.expect_value(t, elena.pos, elena.actor.pos)
	tick(&w, 2)
	testing.expect_value(t, elena.pos, elena.actor.pos)
	testing.expect(t, elena.pos.x > 100)
}

@(test)
a_routine_survives_being_written_and_read :: proc(t: ^testing.T) {
	w := open_banda(t)
	defer shut_banda(&w)

	again, ok := parse_scene(scene_text(&w.scenes[0]), nil)
	testing.expect(t, ok)
	w2: World
	append(&w2.scenes, again)
	defer shut_banda(&w2)
	refresh_world(&w2)

	elena := object_here(&w2.scenes[0], "elena")
	testing.expect(t, elena != nil)
	testing.expect(t, elena.walks)
	testing.expect_value(t, elena.char_name, "elena")
	testing.expect_value(t, elena.actor.speed, f32(100))
	testing.expect_value(t, elena.actor.facing, Facing.Right)
	testing.expect_value(t, elena.only, "!elena_gone")

	testing.expect(t, elena.routine.loop)
	testing.expect_value(t, len(elena.routine.steps), 5)
	testing.expect_value(t, elena.routine.steps[0].kind, Step_Kind.Walk_To)
	testing.expect_value(t, elena.routine.steps[0].to.x, f32(500))
	testing.expect_value(t, elena.routine.steps[1].kind, Step_Kind.Play)
	testing.expect_value(t, elena.routine.steps[1].pose, "cleaning")
	testing.expect_value(t, elena.routine.steps[1].secs, f32(4))
	testing.expect_value(t, elena.routine.steps[2].kind, Step_Kind.Face)
	testing.expect_value(t, elena.routine.steps[2].facing, Facing.Left)
	testing.expect_value(t, elena.routine.steps[4].kind, Step_Kind.Wait)

	// And she still answers her verbs after the round trip.
	talk := object_interaction(&w2, elena, Command{verb = "talk to", noun = "elena"})
	testing.expect(t, talk != nil)
	testing.expect_value(t, talk.text, "Evening, miss. You'll want the far tent.")
}

// A man on a step sits there: `pose=` is the part he holds when nothing else
// asks for one, and a routine that plays a pose gives it back afterwards.
@(private = "file")
STEP :: `scene step
walk 0,0 640,0 640,640 0,640

obj man pos=300,470 char=man pose=sit
routine man loop
step man play drink 1
step man wait 1
`

@(test)
a_person_holds_a_resting_pose :: proc(t: ^testing.T) {
	s, ok := parse_scene(STEP, nil)
	testing.expect(t, ok)
	w: World
	append(&w.scenes, s)
	refresh_world(&w)
	defer {
		for &o in w.scenes[0].objects do routine_destroy(&o.routine)
		free_scene_strings(&w.scenes[0])
		delete(w.scenes[0].objects)
		delete(w.scenes[0].exits)
		delete(w.scenes[0].triggers)
		delete(w.scenes[0].walk_area)
		delete(w.scenes[0].scenery)
		delete(w.scenes[0].said)
		delete(w.scenes)
		clear_flags(&w)
	}
	man := object_here(&w.scenes[0], "man")
	testing.expect(t, man != nil)
	testing.expect_value(t, man.rest_pose, "sit")

	for i := 0; i < 30; i += 1 {
		w.time += 1.0 / 60
		update_people(&w, &w.scenes[0], 1.0 / 60)
	}
	testing.expect_value(t, man.actor.pose, "drink") // the routine's step borrows it
	for i := 0; i < 60; i += 1 {
		w.time += 1.0 / 60
		update_people(&w, &w.scenes[0], 1.0 / 60)
	}
	testing.expect_value(t, man.actor.pose, "sit") // and gives it back
}
