package nengine

import "core:testing"

// A 400x300 room with a door at the top. Its spot is just in front of it and
// its ring is 240 across.
@(private = "file")
door_room :: proc() -> World {
	w: World
	@(static) words := [?]Word{{.Noun, "door", ""}, {.Noun, "cat", ""}, {.Noun, "lamp", ""}}
	w.vocab = vocab_join(words[:], context.temp_allocator)
	@(static) floor := [4][2]f32{{0, 0}, {400, 0}, {400, 300}, {0, 300}}
	sc := Scene{name = "hall", walk_area = floor[:]}
	door := Object{name = "door", description = "A door.", pos = {300, 60}, walk_to = {300, 100}}
	door.reach = {kind = .Box, size = {240, 240}}
	append(&door.on, Interaction{verb = "open", text = "It opens."})
	append(&sc.objects, door)
	append(&w.scenes, sc)
	w.player = {pos = {220, 150}, speed = 120}
	return w
}

// Scenes built in code keep their own interactions; destroy_world frees only
// what a scene file allocated.
@(private = "file")
done :: proc(w: ^World) {
	for &s in w.scenes do for &o in s.objects do delete(o.on)
	destroy_world(w)
}

@(test)
doing_something_walks_to_the_spot_first :: proc(t: ^testing.T) {
	w := door_room()
	defer done(&w)

	run_command(&w, "open door")
	testing.expect(t, approaching(&w))
	testing.expect_value(t, message(&w), "") // not yet: she is still walking

	finish_approach(&w)
	testing.expect(t, !approaching(&w))
	testing.expect_value(t, w.player.pos, [2]f32{300, 100})
	testing.expect_value(t, message(&w), "It opens.")
	testing.expect_value(t, w.player.facing, Facing.Back) // the door is above her
}

@(test)
looking_does_not_walk :: proc(t: ^testing.T) {
	w := door_room()
	defer done(&w)

	run_command(&w, "look at door")
	testing.expect(t, !approaching(&w))
	testing.expect_value(t, w.player.pos, [2]f32{220, 150})
	testing.expect_value(t, message(&w), "A door.")
}

@(test)
outside_the_ring_is_too_far :: proc(t: ^testing.T) {
	w := door_room()
	defer done(&w)
	w.player.pos = {40, 280}

	run_command(&w, "open door")
	testing.expect(t, !approaching(&w))
	testing.expect_value(t, w.player.pos, [2]f32{40, 280})
	testing.expect_value(t, message(&w), "You're not close enough.")

	// And the game can say it in its own voice.
	w.on_out_of_reach = proc(w: ^World, o: ^Object, why: Out_Of_Reach) -> bool {
		say(w, "Not from here.")
		return true
	}
	run_command(&w, "open door")
	testing.expect_value(t, message(&w), "Not from here.")
}

@(test)
no_spot_means_do_it_where_you_stand :: proc(t: ^testing.T) {
	w := door_room()
	defer done(&w)
	w.scenes[0].objects[0].walk_to = {}

	run_command(&w, "open door")
	testing.expect(t, !approaching(&w))
	testing.expect_value(t, message(&w), "It opens.")
}

@(test)
something_in_the_way_is_said :: proc(t: ^testing.T) {
	w := door_room()
	defer done(&w)
	w.player.pos = {300, 250}
	w.scenes[0].objects[0].reach = {} // the whole room is in reach
	// A wall across the room between her and the door.
	append(&w.scenes[0].objects, Object{name = "wall", pos = {200, 180}, block = {kind = .Box, size = {400, 20}}})

	run_command(&w, "open door")
	testing.expect(t, approaching(&w))
	finish_approach(&w)
	testing.expect(t, !approaching(&w))
	testing.expect_value(t, message(&w), "You can't get there from here.")
}

@(test)
changing_rooms_calls_it_off :: proc(t: ^testing.T) {
	w := door_room()
	defer done(&w)
	append(&w.scenes, Scene{name = "yard"})

	run_command(&w, "open door")
	go_to(&w, 1, {10, 10})
	testing.expect(t, !approaching(&w))
}

@(test)
going_to_a_thing_walks_there_and_does_nothing_else :: proc(t: ^testing.T) {
	w := door_room()
	defer done(&w)

	run_command(&w, "walk to the door")
	testing.expect(t, approaching(&w))
	finish_approach(&w)
	testing.expect_value(t, w.player.pos, [2]f32{300, 100})
	testing.expect_value(t, message(&w), "")
}

@(test)
a_person_is_approached_from_the_side_you_are_on :: proc(t: ^testing.T) {
	w := door_room()
	defer done(&w)
	cat := Object{name = "cat", pos = {200, 200}, walks = true}
	cat.actor.pos = cat.pos
	append(&cat.on, Interaction{verb = "talk to", text = "Miaow."})
	append(&w.scenes[0].objects, cat)
	w.player.pos = {60, 200}

	run_command(&w, "talk to the cat")
	finish_approach(&w)
	testing.expect_value(t, w.player.pos, [2]f32{200 - BESIDE, 200})
	testing.expect_value(t, w.player.facing, Facing.Right)
	testing.expect_value(t, message(&w), "Miaow.")
}

@(test)
asking_about_a_thing_does_not_walk_to_it :: proc(t: ^testing.T) {
	w := door_room()
	defer done(&w)
	run_command(&w, "ask cat about door") // no cat here; the door is a topic
	testing.expect(t, !approaching(&w))
	testing.expect_value(t, w.player.pos, [2]f32{220, 150})
}

@(test)
leave_walks_out_by_the_only_exit_or_the_one_named_out :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	@(static) floor := [4][2]f32{{0, 0}, {400, 0}, {400, 300}, {0, 300}}
	tent := Scene{name = "tent", walk_area = floor[:]}
	append(&tent.exits, Exit{name = "flap", area = {0, 200, 40, 60}, to = 1, arrive = {10, 10}})
	hut := Scene{name = "hut", walk_area = floor[:]}
	append(&hut.exits, Exit{name = "window", area = {360, 0, 40, 40}, to = 0, arrive = {10, 10}})
	append(&hut.exits, Exit{name = "out", area = {0, 200, 40, 60}, to = 0, arrive = {10, 10}})
	append(&w.scenes, tent, hut)
	w.vocab = vocab_join(nil, context.temp_allocator)
	w.player = {pos = {200, 150}, speed = 120}

	run_command(&w, "leave") // the tent's only way out, whatever it is called
	testing.expect(t, w.player.moving)
	finish_walk(&w)
	testing.expect_value(t, w.current, 1)

	w.player.pos = {200, 150}
	run_command(&w, "go out") // two ways out of the hut: the one called out
	finish_walk(&w)
	testing.expect_value(t, w.current, 0)
}

@(test)
the_harness_fires_a_whole_floor_trigger_on_walking_in :: proc(t: ^testing.T) {
	// Out of the tent by its flap, onto a deck with a trigger over the whole
	// floor: play fires it on the first frame there, and so must the harness,
	// though its walk stops the moment the room changes.
	w: World
	defer destroy_world(&w)
	@(static) floor := [4][2]f32{{0, 0}, {400, 0}, {400, 300}, {0, 300}}
	tent := Scene{name = "tent", walk_area = floor[:]}
	append(&tent.exits, Exit{name = "flap", area = {0, 200, 40, 60}, to = 1, arrive = {200, 150}})
	deck := Scene{name = "deck", walk_area = floor[:]}
	append(&deck.triggers, Trigger{name = "find_bodies", area = {0, 0, 400, 300}, on_enter = proc(w: ^World) {
		(^int)(w.user)^ += 1
	}})
	append(&w.scenes, tent, deck)
	w.vocab = vocab_join(nil, context.temp_allocator)
	w.player = {pos = {200, 150}, speed = 120}
	fired := 0
	w.user = &fired

	run_script(&w, "leave")
	testing.expect_value(t, w.current, 1)
	testing.expect_value(t, fired, 1)
	run_script(&w, "look; leave") // the deck has no way out: she stays, and it does not fire again
	testing.expect_value(t, fired, 1)
}

// Stopped short of the spot beside a person (somebody crossing the floor got
// in the way): a step or two off is near enough to talk; across the room is not.
@(test)
a_person_a_step_away_is_near_enough :: proc(t: ^testing.T) {
	w := door_room()
	defer done(&w)
	cat := Object{name = "cat", pos = {200, 200}, walks = true}
	cat.actor.pos = cat.pos
	append(&cat.on, Interaction{verb = "talk to", text = "Miaow."})
	append(&w.scenes[0].objects, cat)

	w.player.pos = {60, 200}
	run_command(&w, "talk to the cat")
	testing.expect(t, approaching(&w))
	w.player.pos = {120, 200} // stopped 80 short, with nowhere further to go
	w.player.moving = false
	approach_step(&w, false)
	testing.expect_value(t, message(&w), "Miaow.")

	w.message_until = 0
	w.player.pos = {20, 200}
	run_command(&w, "talk to the cat")
	w.player.pos = {20, 280} // stopped 190 away
	w.player.moving = false
	approach_step(&w, false)
	testing.expect(t, message(&w) != "Miaow.")
}

// Stopped far short by somebody crossing the floor: she sets off again rather
// than giving up, and gets there once they have passed.
@(test)
stopped_short_she_sets_off_again :: proc(t: ^testing.T) {
	w := door_room()
	defer done(&w)
	cat := Object{name = "cat", pos = {300, 200}, walks = true}
	cat.actor.pos = cat.pos
	append(&cat.on, Interaction{verb = "talk to", text = "Miaow."})
	append(&w.scenes[0].objects, cat)

	w.player.pos = {20, 280}
	run_command(&w, "talk to the cat")
	w.player.moving = false // stopped: somebody stepped in front of her
	approach_step(&w, false)
	testing.expect(t, approaching(&w), "not given up")
	testing.expect(t, w.player.moving, "off again")
	finish_approach(&w)
	testing.expect_value(t, message(&w), "Miaow.")
}

// Three bushes, one `text` line written under the second: LOOK AT BUSH says it.
@(test)
things_of_one_name_share_their_words :: proc(t: ^testing.T) {
	w := door_room()
	defer done(&w)
	@(static) words := [?]Word{{.Noun, "door", ""}, {.Noun, "bush", ""}}
	w.vocab = vocab_join(words[:], context.temp_allocator)
	append(&w.scenes[0].objects, Object{name = "bush", pos = {50, 50}})
	append(&w.scenes[0].objects, Object{name = "bush", pos = {90, 50}, description = "Sickle bush, and the wind in it."})
	run_command(&w, "look at bush")
	testing.expect_value(t, message(&w), "Sickle bush, and the wind in it.")
}
