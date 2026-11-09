package nengine

import "core:testing"

// Two scenes joined by a doorway at x 90..100 in each.
@(private = "file")
two_rooms :: proc() -> World {
	w: World
	a := Scene{name = "a"}
	b := Scene{name = "b"}
	append(&a.exits, Exit{name = "door", area = {90, 0, 10, 100}, to = 1, arrive = {95, 50}})
	append(&b.exits, Exit{name = "door", area = {90, 0, 10, 100}, to = 0, arrive = {80, 50}})
	append(&w.scenes, a, b)
	return w
}

@(test)
stepping_into_an_exit_changes_scene :: proc(t: ^testing.T) {
	w := two_rooms()
	defer destroy_world(&w)

	w.player.pos = {89, 50}
	testing.expect(t, !check_exits(&w))
	w.player.pos = {91, 50}
	testing.expect(t, check_exits(&w))
	testing.expect_value(t, w.current, 1)
	testing.expect_value(t, w.player.pos, [2]f32{95, 50})
}

@(test)
a_new_scene_stops_arrow_walking :: proc(t: ^testing.T) {
	w := two_rooms()
	defer destroy_world(&w)
	w.player.heading = {1, 0}
	go_to(&w, 1, {20, 20})
	testing.expect_value(t, w.player.heading, [2]f32{0, 0})
}

@(test)
arriving_inside_an_exit_does_not_bounce_back :: proc(t: ^testing.T) {
	w := two_rooms()
	defer destroy_world(&w)

	// Scene b's arrival point sits inside b's own exit. Standing and walking
	// around in it must not send us straight back to a.
	go_to(&w, 1, {95, 50})
	testing.expect(t, !check_exits(&w))
	w.player.pos += {1, 0}
	testing.expect(t, !check_exits(&w))
	testing.expect_value(t, w.current, 1)

	// Step out and back in: now it works.
	w.player.pos = {50, 50}
	check_exits(&w)
	w.player.pos = {95, 50}
	testing.expect(t, check_exits(&w))
	testing.expect_value(t, w.current, 0)
}

@(test)
a_closed_exit_blocks_and_says_so_once :: proc(t: ^testing.T) {
	w := two_rooms()
	defer destroy_world(&w)
	w.scenes[0].exits[0].closed = true
	w.scenes[0].exits[0].closed_text = "The door is closed."

	w.player.pos = {95, 50}
	testing.expect(t, !check_exits(&w))
	testing.expect_value(t, w.current, 0)
	testing.expect_value(t, message(&w), "The door is closed.")

	// Standing there doesn't repeat it every frame.
	w.message_until = 0
	check_exits(&w)
	testing.expect_value(t, message(&w), "")

	// Opening the door while standing in the doorway doesn't carry you through...
	w.scenes[0].exits[0].closed = false
	testing.expect(t, !check_exits(&w))
	testing.expect_value(t, w.current, 0)

	// ...but deciding to go through it does.
	head_for_exit(&w, "door")
	testing.expect(t, check_exits(&w))
	testing.expect_value(t, w.current, 1)
}

@(test)
heading_for_another_exit_does_not_repeat_closed_text :: proc(t: ^testing.T) {
	w := two_rooms()
	defer destroy_world(&w)
	append(&w.scenes[0].exits, Exit{name = "east", area = {190, 0, 10, 100}, to = 1})
	w.scenes[0].exits[0].closed = true
	w.scenes[0].exits[0].closed_text = "The door is closed."

	w.player.pos = {95, 50} // standing in the shut doorway
	check_exits(&w)
	w.message_until = 0

	head_for_exit(&w, "east") // going somewhere else entirely
	check_exits(&w)
	testing.expect_value(t, message(&w), "")
}

@(test)
head_for_exit_walks_to_it :: proc(t: ^testing.T) {
	w := two_rooms()
	defer destroy_world(&w)
	square := [4][2]f32{{0, 0}, {200, 0}, {200, 100}, {0, 100}}
	w.scenes[0].walk_area = square[:]
	w.player = {pos = {20, 50}, speed = 60}

	testing.expect(t, head_for_exit(&w, "door"))
	testing.expect(t, !head_for_exit(&w, "chimney"))

	for _ in 0 ..< 200 {
		actor_follow_target(&w.player, 1.0 / 60, &w.scenes[w.current])
		if check_exits(&w) do break
	}
	testing.expect_value(t, w.current, 1)
}

@(test)
an_exit_whose_condition_is_false_is_not_there :: proc(t: ^testing.T) {
	w := two_rooms()
	defer destroy_world(&w)
	w.scenes[0].exits[0].only = "day"
	refresh_world(&w)

	w.player.pos = {95, 50}
	testing.expect(t, !check_exits(&w))
	testing.expect(t, !head_for_exit(&w, "door"))

	set_flag(&w, "day")
	w.player.pos = {50, 50}
	check_exits(&w)
	w.player.pos = {95, 50}
	testing.expect(t, check_exits(&w))
	clear_flags(&w)
}
