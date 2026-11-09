package nengine

import "core:strings"
import "core:testing"

// A door is gone through on purpose (world.odin's check_exits): a walk that
// means to (GO TO it, a click in its doorway or on the door), the arrow keys
// into it, or being put in it. A walk to somewhere else passes over its patch.
//
// The yard is the kitchen yard's floor: the kitchen door's patch lies on the
// top walking line, between the bins (west) and the arrival from the leg
// (east), and a shed door further along the same line. The bath house's is
// the step, the stalls' door on the top line east of it, and the east side.

@(private = "file")
YARD :: `scene yard
walk 142,400 832,400 832,384 960,384 960,400 1024,400 1024,624 93,624
exit kitchen area=448,400,64,20 to=kitchen arrive=500,500
exit shed area=640,400,40,20 to=shed arrive=500,500
obj bins pos=177,412 walk_to=268,408
obj crate pos=480,380 walk_to=480,410
obj door pos=660,380 walk_to=660,410
`

@(private = "file")
KITCHEN :: `scene kitchen
walk 0,384 1024,384 1024,624 0,624
`

@(private = "file")
SHED :: `scene shed
walk 0,384 1024,384 1024,624 0,624
`

@(private = "file")
BATH :: `scene bath
walk 87,384 1024,384 1024,624 26,624
side east to=gate span=400,608
exit stalls area=705,384,67,24 to=showers arrive=512,580
`

@(private = "file")
GATE :: `scene gate
walk 0,384 1024,384 1024,624 0,624
side west to=bath span=400,608
`

@(private = "file")
SHOWERS :: `scene showers
walk 0,384 1024,384 1024,624 0,624
`

@(private = "file")
rooms :: proc(t: ^testing.T, texts: ..string) -> World {
	w: World
	for text in texts {
		s, ok := parse_scene(text, nil)
		testing.expect(t, ok)
		append(&w.scenes, s)
	}
	problem, ok := resolve_exits(&w)
	testing.expectf(t, ok, "resolve: %v", problem)
	refresh_world(&w)
	w.player = {pos = {844, 409}, speed = 120} // off the leg, at the yard's east end
	w.time = 1
	return w
}

@(private = "file")
here :: proc(w: ^World) -> string {
	return current_scene(w).name
}

@(test)
a_walk_past_a_door_does_not_go_through_it :: proc(t: ^testing.T) {
	w := rooms(t, YARD, KITCHEN, SHED)
	defer destroy_world(&w)

	// From the leg to the bins along the top line: over the shed's patch and
	// the kitchen's, and on.
	said := click_bang(&w, "268,408")
	testing.expect_value(t, said, "walked to 268,408")
	testing.expect_value(t, here(&w), "yard")

	// And back, to the leg's end.
	said = click_bang(&w, "844,409")
	testing.expect_value(t, said, "walked to 844,409")

	// GO TO the bins: an approach, the same line.
	testing.expect(t, approach_command(&w, current_scene(&w), Command{verb = "go", noun = "bins"}))
	finish_approach(&w)
	testing.expect_value(t, here(&w), "yard")
	testing.expect_value(t, w.player.pos, [2]f32{268, 408})
}

@(test)
a_walk_that_ends_in_a_doorway_stands_in_it :: proc(t: ^testing.T) {
	w := rooms(t, YARD, KITCHEN, SHED)
	defer destroy_world(&w)

	// TAKE the crate, whose spot is in the kitchen's doorway: she goes to
	// it, and stands there.
	testing.expect(t, approach_command(&w, current_scene(&w), Command{verb = "take", noun = "crate"}))
	finish_approach(&w)
	testing.expect_value(t, here(&w), "yard")
	testing.expect_value(t, w.player.pos, [2]f32{480, 410})
	testing.expect(t, !check_exits(&w))
	testing.expect_value(t, here(&w), "yard")

	// The arrow keys from there: she walks out of it, not through it.
	said := arrow_bang(&w, "down 1")
	testing.expect(t, strings.has_prefix(said, "walked to 480,"), said)

	// GO TO the bins and back: still the yard.
	testing.expect_value(t, click_bang(&w, "268,408"), "walked to 268,408")
	testing.expect(t, approach_command(&w, current_scene(&w), Command{verb = "take", noun = "crate"}))
	finish_approach(&w)
	testing.expect_value(t, here(&w), "yard")

	// Deciding to go in, from the doorway: in.
	testing.expect(t, head_for_exit(&w, "kitchen"))
	finish_walk(&w)
	testing.expect_value(t, here(&w), "kitchen")
}

@(test)
clicking_the_door_goes_through_it :: proc(t: ^testing.T) {
	w := rooms(t, YARD, KITCHEN, SHED)
	defer destroy_world(&w)

	// A click in the doorway, from the far side of the shed's patch: through
	// the kitchen's, and not the shed's on the way.
	testing.expect_value(t, click_bang(&w, "480,410"), "went to kitchen")

	// A click on the door itself, above the floor's edge.
	go_to(&w, 0, {844, 409})
	testing.expect_value(t, click_bang(&w, "480,330"), "went to kitchen")

	// From the bins, GO TO the shed: over the kitchen's patch to the shed's.
	go_to(&w, 0, {268, 408})
	testing.expect(t, head_for_exit(&w, "shed"))
	finish_walk(&w)
	testing.expect_value(t, here(&w), "shed")
}

@(test)
the_arrow_keys_into_a_door_go_through_it :: proc(t: ^testing.T) {
	w := rooms(t, YARD, KITCHEN, SHED)
	defer destroy_world(&w)

	// Up from the yard, straight into the kitchen's doorway.
	w.player.pos = {480, 520}
	testing.expect_value(t, arrow_bang(&w, "up"), "went to kitchen")

	// Along the top line from the leg: the first door she walks into is the
	// shed's, and the arrows take her through it, as Sierra's do.
	go_to(&w, 0, {844, 409})
	w.exit_grace = false
	testing.expect_value(t, arrow_bang(&w, "left"), "went to shed")
}

@(test)
going_east_past_a_door_crosses_the_side :: proc(t: ^testing.T) {
	w := rooms(t, BATH, GATE, SHOWERS)
	defer destroy_world(&w)

	// The bath house's step, west of the stalls' door on the top line: GO
	// EAST walks over the door's patch to the east side, and across.
	w.player.pos = {557, 389}
	testing.expect(t, go_compass(&w, "east"))
	finish_walk(&w)
	testing.expect_value(t, here(&w), "gate")

	// GO TO the stalls from the step: in.
	go_to(&w, 0, {557, 389})
	testing.expect(t, head_for_exit(&w, "stalls"))
	finish_walk(&w)
	testing.expect_value(t, here(&w), "showers")
}

@(test)
go_to_a_door_whose_spot_is_in_its_doorway_goes_through :: proc(t: ^testing.T) {
	w := rooms(t, YARD, KITCHEN, SHED)
	defer destroy_world(&w)

	// GO TO the door (the thing): its spot is in the shed's doorway, and in.
	testing.expect(t, approach_command(&w, current_scene(&w), Command{verb = "go", noun = "door"}))
	finish_approach(&w)
	testing.expect_value(t, here(&w), "shed")

	// ENTER it: the same.
	go_to(&w, 0, {268, 408})
	testing.expect(t, approach_command(&w, current_scene(&w), Command{verb = "enter", noun = "door"}))
	finish_approach(&w)
	testing.expect_value(t, here(&w), "shed")

	// KNOCK on it: she goes to it and knocks, and stands in the doorway.
	go_to(&w, 0, {268, 408})
	testing.expect(t, approach_command(&w, current_scene(&w), Command{verb = "knock", noun = "door"}))
	finish_approach(&w)
	testing.expect_value(t, here(&w), "yard")
	testing.expect_value(t, w.player.pos, [2]f32{660, 410})

	// And then GO TO it, from where she stands: in.
	testing.expect(t, approach_command(&w, current_scene(&w), Command{verb = "go", noun = "door"}))
	finish_approach(&w)
	check_exits(&w)
	testing.expect_value(t, here(&w), "shed")
}

@(test)
a_shut_door_walked_past_says_nothing :: proc(t: ^testing.T) {
	w := rooms(t, YARD, KITCHEN, SHED)
	defer destroy_world(&w)
	w.scenes[0].exits[0].closed = true
	w.scenes[0].exits[0].closed_text = strings.clone("Bolted.") // a parsed scene owns its words

	testing.expect_value(t, click_bang(&w, "268,408"), "walked to 268,408")
	// Walked into on purpose: told.
	go_to(&w, 0, {844, 409})
	testing.expect_value(t, click_bang(&w, "480,410"), "walked to 480,410 | Bolted.")
}
