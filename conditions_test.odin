package nengine

import "core:slice"
import "core:testing"

// One room file, five acts. The thing being tested is that a room can change
// without becoming a second copy of the room — because fourteen rooms times
// five acts is seventy files, and changing a doorway in seventy files is how
// a doorway ends up different in three of them.

@(private = "file")
ROOM :: `scene pool_deck
desc Warm, and lit from under the water.
desc when=act3 Two of them. Nobody has touched anything.
desc when=act4 Tape, and a great deal of dust.

obj boiler pos=100,180
text boiler It is still lit.
on boiler look The pilot light has not gone out all night.
on boiler touch You would lose a hand.
on boiler open when=act4 The hatch has been forced.

obj shoe pos=210,180 when=act3
text shoe One shoe, on its side.

obj bodies pos=160,190 when=act3 block=circle:20
text bodies Fairbank and Beatrice, in the water.

obj tape pos=160,190 when=act4
text tape Tape, strung between two chairs.

obj door pos=300,150
on door unlock with=key The lock gives.
on door unlock You have nothing to unlock it with.
on door open action=swing_door

scenery water Flat, and too blue for the hour.
scenery moon when=act3 A thin moon, and no cloud at all.

exit path area=0,150,20,40 to=0 arrive=10,10
exit gap area=300,150,20,40 to=0 arrive=10,10 when=act5
`

@(private = "file")
load :: proc(t: ^testing.T) -> (World, Scene) {
	s, ok := parse_scene(ROOM, nil)
	testing.expect(t, ok)
	w: World
	append(&w.scenes, s)
	refresh_world(&w)
	return w, s
}

@(private = "file")
tidy :: proc(w: ^World) {
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

@(test)
what_is_in_the_room_follows_the_flags :: proc(t: ^testing.T) {
	w, _ := load(t)
	defer tidy(&w)
	scene := &w.scenes[0]

	// Act two: the pool is empty and inviting.
	testing.expect(t, object_here(scene, "boiler") != nil, "the boiler is always here")
	testing.expect(t, object_here(scene, "shoe") == nil, "no shoe yet")
	testing.expect(t, object_here(scene, "bodies") == nil)
	testing.expect(t, !is_here(scene, "moon"), "the moon is act three")

	set_flag(&w, "act3")
	testing.expect(t, object_here(scene, "shoe") != nil, "the shoe is here now")
	testing.expect(t, object_here(scene, "bodies") != nil)
	testing.expect(t, object_here(scene, "tape") == nil, "the tape is act four")
	testing.expect(t, is_here(scene, "moon"))

	// And the act turning takes them away again.
	set_only(&w, "act4", {"act2", "act3", "act4"})
	testing.expect(t, object_here(scene, "shoe") == nil)
	testing.expect(t, object_here(scene, "bodies") == nil)
	testing.expect(t, object_here(scene, "tape") != nil)
	testing.expect(t, !is_here(scene, "moon"))
}

@(test)
the_room_reads_differently_as_the_acts_turn :: proc(t: ^testing.T) {
	w, _ := load(t)
	defer tidy(&w)
	scene := &w.scenes[0]

	testing.expect_value(t, scene_description(&w, scene), "Warm, and lit from under the water.")
	set_flag(&w, "act3")
	testing.expect_value(t, scene_description(&w, scene), "Two of them. Nobody has touched anything.")
	set_only(&w, "act4", {"act3", "act4"})
	testing.expect_value(t, scene_description(&w, scene), "Tape, and a great deal of dust.")
}

@(test)
a_hidden_object_is_not_in_the_way :: proc(t: ^testing.T) {
	w, _ := load(t)
	defer tidy(&w)
	scene := &w.scenes[0]
	delete(scene.walk_area)
	floor := [][2]f32{{0, 0}, {320, 0}, {320, 200}, {0, 200}}
	scene.walk_area = slice.clone(floor) // tidy frees it

	// The bodies block the floor, but only once they are there.
	testing.expect(t, can_step(scene, {160, 120}, {160, 190}), "nothing in the way yet")
	set_flag(&w, "act3")
	testing.expect(t, !can_step(scene, {160, 120}, {160, 190}), "you can't walk through them")
	set_only(&w, "act4", {"act3", "act4"})
	testing.expect(t, can_step(scene, {160, 120}, {160, 190}), "they have been moved")
}

@(test)
an_exit_can_open_late_in_the_story :: proc(t: ^testing.T) {
	w, _ := load(t)
	defer tidy(&w)
	scene := &w.scenes[0]

	testing.expect(t, is_here(scene, "path"))
	testing.expect(t, !is_here(scene, "gap"), "nobody admits the gap exists yet")
	set_flag(&w, "act5")
	testing.expect(t, is_here(scene, "gap"))
}

@(test)
conditions_are_all_of_these_and_none_of_those :: proc(t: ^testing.T) {
	w: World
	defer clear_flags(&w)

	testing.expect(t, condition_met(&w, ""), "no condition is always met")
	testing.expect(t, !condition_met(&w, "act3"))
	set_flag(&w, "act3")
	testing.expect(t, condition_met(&w, "act3"))

	testing.expect(t, condition_met(&w, "act3,!body_moved"))
	set_flag(&w, "body_moved")
	testing.expect(t, !condition_met(&w, "act3,!body_moved"))

	testing.expect(t, !condition_met(&w, "act3,night"), "every term has to hold")
	set_flag(&w, "night")
	testing.expect(t, condition_met(&w, "act3,night"))

	// Turning one off again, rather than deleting it.
	set_flag(&w, "night", false)
	testing.expect(t, !condition_met(&w, "act3,night"))
}

@(test)
an_object_answers_its_own_verbs :: proc(t: ^testing.T) {
	w, _ := load(t)
	defer tidy(&w)
	scene := &w.scenes[0]

	boiler := object_here(scene, "boiler")
	testing.expect(t, boiler != nil)

	look := object_interaction(&w, boiler, Command{verb = "look", noun = "boiler"})
	testing.expect(t, look != nil)
	testing.expect_value(t, look.text, "The pilot light has not gone out all night.")

	touch := object_interaction(&w, boiler, Command{verb = "touch", noun = "boiler"})
	testing.expect(t, touch != nil)
	testing.expect_value(t, touch.text, "You would lose a hand.")

	// A verb nobody wrote an answer for.
	testing.expect(t, object_interaction(&w, boiler, Command{verb = "eat", noun = "boiler"}) == nil)

	// An interaction can be conditional too.
	testing.expect(t, object_interaction(&w, boiler, Command{verb = "open", noun = "boiler"}) == nil)
	set_flag(&w, "act4")
	open := object_interaction(&w, boiler, Command{verb = "open", noun = "boiler"})
	testing.expect(t, open != nil)
	testing.expect_value(t, open.text, "The hatch has been forced.")
}

@(test)
the_specific_answer_beats_the_general_one :: proc(t: ^testing.T) {
	w, _ := load(t)
	defer tidy(&w)
	door := object_here(&w.scenes[0], "door")
	testing.expect(t, door != nil)

	// UNLOCK DOOR WITH KEY finds the one that names the key...
	with_key := object_interaction(&w, door, Command{verb = "unlock", noun = "door", prep = "with", noun2 = "key"})
	testing.expect(t, with_key != nil)
	testing.expect_value(t, with_key.text, "The lock gives.")

	// ...and UNLOCK DOOR on its own finds the one that doesn't, whichever
	// order they happen to be written in.
	bare := object_interaction(&w, door, Command{verb = "unlock", noun = "door"})
	testing.expect(t, bare != nil)
	testing.expect_value(t, bare.text, "You have nothing to unlock it with.")

	// A second noun nobody wrote for falls back to the general answer rather
	// than to nothing at all.
	with_hammer := object_interaction(&w, door, Command{verb = "unlock", noun = "door", noun2 = "hammer"})
	testing.expect(t, with_hammer != nil)
	testing.expect_value(t, with_hammer.text, "You have nothing to unlock it with.")
}

@(test)
an_action_is_bound_to_game_code_by_name :: proc(t: ^testing.T) {
	w, _ := load(t)
	defer tidy(&w)

	swing :: proc(w: ^World, o: ^Object) {}
	scene_bind_action(&w.scenes[0], "swing_door", swing)

	door := object_here(&w.scenes[0], "door")
	open := object_interaction(&w, door, Command{verb = "open", noun = "door"})
	testing.expect(t, open != nil)
	testing.expect(t, open.on_do != nil, "the file said what, the game said how")
}

@(test)
all_of_it_survives_being_written_and_read :: proc(t: ^testing.T) {
	w, _ := load(t)
	defer tidy(&w)

	again, ok := parse_scene(scene_text(&w.scenes[0]), nil)
	testing.expect(t, ok)
	w2: World
	append(&w2.scenes, again)
	defer {
		free_scene_strings(&w2.scenes[0])
		delete(w2.scenes[0].objects)
		delete(w2.scenes[0].exits)
		delete(w2.scenes[0].triggers)
		delete(w2.scenes[0].walk_area)
		delete(w2.scenes[0].scenery)
		delete(w2.scenes[0].said)
		delete(w2.scenes)
		clear_flags(&w2)
	}
	refresh_world(&w2)
	scene := &w2.scenes[0]

	testing.expect_value(t, len(scene.objects), len(w.scenes[0].objects))
	testing.expect_value(t, scene_description(&w2, scene), "Warm, and lit from under the water.")

	// The conditions came back...
	set_flag(&w2, "act3")
	testing.expect(t, object_here(scene, "shoe") != nil)
	testing.expect_value(t, scene_description(&w2, scene), "Two of them. Nobody has touched anything.")

	// ...and so did the interactions, with the field in the middle of the
	// line, which is the part the writer is most likely to get wrong.
	door := object_here(scene, "door")
	testing.expect(t, door != nil)
	with_key := object_interaction(&w2, door, Command{verb = "unlock", noun = "door", noun2 = "key"})
	testing.expect(t, with_key != nil)
	testing.expect_value(t, with_key.text, "The lock gives.")
	testing.expect_value(t, with_key.with, "key")

	// And an object's plain description, which shares the same line shape.
	boiler := object_here(scene, "boiler")
	testing.expect_value(t, boiler.description, "It is still lit.")
}

// A room's sound follows the hour: the last `ambience` line whose condition
// holds. The generator stopping is a flag, and the office goes quiet.
@(test)
the_ambience_follows_the_flags :: proc(t: ^testing.T) {
	text := "scene office\nambience generator_hum\nambience when=generator_off room_quiet\nfootstep step_boards\nwalk 0,0 10,0 10,10\n"
	s, ok := parse_scene(text, nil)
	testing.expect(t, ok)
	w: World
	append(&w.scenes, s)
	defer {
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
	refresh_world(&w)
	testing.expect_value(t, w.scenes[0].ambience_name, "generator_hum")
	testing.expect_value(t, w.scenes[0].step_name, "step_boards")
	set_flag(&w, "generator_off")
	refresh_world(&w)
	testing.expect_value(t, w.scenes[0].ambience_name, "room_quiet")
}
