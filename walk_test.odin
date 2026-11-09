package nengine

import "core:testing"

// Run with: just test

@(private = "file")
square := [4][2]f32{{0, 0}, {100, 0}, {100, 100}, {0, 100}}

// A "U": two legs joined at the bottom, with a gap between them at the top.
@(private = "file")
u_shape := [8][2]f32{{0, 0}, {30, 0}, {30, 70}, {70, 70}, {70, 0}, {100, 0}, {100, 100}, {0, 100}}

@(test)
inside_and_outside :: proc(t: ^testing.T) {
	testing.expect(t, point_in_polygon({50, 50}, square[:]))
	testing.expect(t, !point_in_polygon({150, 50}, square[:]))
	testing.expect(t, !point_in_polygon({50, 30}, u_shape[:]), "the gap in the U is outside")
	testing.expect(t, point_in_polygon({15, 30}, u_shape[:]), "a leg of the U is inside")
}

@(test)
clamp_lands_inside_near_the_click :: proc(t: ^testing.T) {
	p := clamp_to_polygon({150, 50}, square[:])
	testing.expect(t, point_in_polygon(p, square[:]))
	testing.expectf(t, p.x > 97 && abs(p.y - 50) < 2, "got %v", p)

	inside := [2]f32{40, 40}
	testing.expect_value(t, clamp_to_polygon(inside, square[:]), inside)
}

@(test)
actor_arrives :: proc(t: ^testing.T) {
	floor_square := Scene{walk_area = square[:]}
	a := Actor{pos = {10, 10}, speed = 50}
	walk_to(&a, {90, 90})
	arrived := false
	for _ in 0 ..< 200 {
		if actor_follow_target(&a, 1.0 / 60, &floor_square) {
			arrived = true
			break
		}
	}
	testing.expect(t, arrived)
	testing.expect_value(t, a.pos, [2]f32{90, 90})
}

@(test)
zero_time_step_does_not_cancel_the_walk :: proc(t: ^testing.T) {
	floor_square := Scene{walk_area = square[:]}
	// The first frame of a game has dt = 0. That used to count as "blocked".
	a := Actor{pos = {10, 10}, speed = 50}
	walk_to(&a, {90, 90})
	actor_follow_target(&a, 0, &floor_square)
	testing.expect(t, a.moving)
}

@(test)
arrow_walking_keeps_going_until_the_edge :: proc(t: ^testing.T) {
	floor_square := Scene{walk_area = square[:]}
	a := Actor{pos = {50, 50}, speed = 60, heading = {1, 0}}
	for _ in 0 ..< 30 do actor_follow_heading(&a, 1.0 / 60, &floor_square)
	testing.expect(t, a.pos.x > 75, "still walking with nothing pressed")
	testing.expect(t, a.heading != {0, 0})

	for _ in 0 ..< 200 do actor_follow_heading(&a, 1.0 / 60, &floor_square)
	testing.expect(t, a.pos.x < 100 && a.pos.x > 98, "stopped at the edge")
	testing.expect_value(t, a.heading, [2]f32{0, 0})
}

@(test)
clicking_cancels_arrow_walking :: proc(t: ^testing.T) {
	a := Actor{pos = {50, 50}, speed = 60, heading = {1, 0}}
	walk_to(&a, {10, 10})
	testing.expect_value(t, a.heading, [2]f32{0, 0})
	testing.expect(t, a.moving)
}

@(test)
actor_goes_round_the_gap :: proc(t: ^testing.T) {
	floor_u_shape := Scene{walk_area = u_shape[:]}
	// From the left leg straight across to the right leg: the gap is in the
	// way, so the walk goes round it, and never leaves the floor doing so.
	a := Actor{pos = {15, 30}, speed = 50}
	walk_to(&a, {85, 30})
	for _ in 0 ..< 60 * 20 {
		actor_follow_target(&a, 1.0 / 60, &floor_u_shape)
		testing.expect(t, point_in_polygon(a.pos, u_shape[:]), "never left the walk area")
		if !a.moving do break
	}
	testing.expect_value(t, a.pos, [2]f32{85, 30})
}

// --- Solid things and reach ---

@(private = "file")
room_with_a_cat :: proc() -> Scene {
	s := Scene{walk_area = square[:]}
	append(&s.objects, Object {
		name  = "cat",
		pos   = {50, 50},
		block = circle(20),         // 20 wide, 10 deep
		reach = box(40, 30),        // anywhere round it
	})
	return s
}

@(test)
you_cannot_walk_through_something_solid :: proc(t: ^testing.T) {
	s := room_with_a_cat()
	defer delete(s.objects)

	a := Actor{pos = {20, 50}, speed = 60, heading = {1, 0}}
	for _ in 0 ..< 120 do actor_follow_heading(&a, 1.0 / 60, &s)
	testing.expect(t, a.pos.x < 41, "stopped at the cat")
	testing.expect_value(t, a.heading, [2]f32{0, 0})

	// Going round is fine: well above it.
	b := Actor{pos = {20, 30}, speed = 60, heading = {1, 0}}
	for _ in 0 ..< 60 do actor_follow_heading(&b, 1.0 / 60, &s)
	testing.expect(t, b.pos.x > 70, "walked past above the cat")
}

@(test)
starting_inside_something_solid_you_can_still_leave :: proc(t: ^testing.T) {
	s := room_with_a_cat()
	defer delete(s.objects)
	testing.expect(t, can_step(&s, {50, 50}, {51, 50}))
	testing.expect(t, !can_step(&s, {30, 50}, {45, 50}))
}

@(test)
near_means_anywhere_in_reach :: proc(t: ^testing.T) {
	s := room_with_a_cat()
	defer delete(s.objects)
	w: World
	cat := &s.objects[0]
	for spot in ([4][2]f32{{32, 50}, {68, 50}, {50, 36}, {50, 64}}) {
		w.player.pos = spot
		testing.expectf(t, near(&w, cat), "near from %v", spot)
	}
	w.player.pos = {90, 90}
	testing.expect(t, !near(&w, cat))
}

@(test)
diagonal_walking_is_not_faster :: proc(t: ^testing.T) {
	s := Scene{walk_area = square[:]}
	a := Actor{pos = {10, 10}, speed = 60, heading = {DIAGONAL, DIAGONAL}}
	for _ in 0 ..< 60 do actor_follow_heading(&a, 1.0 / 60, &s)
	testing.expect(t, abs(length(a.pos - {10, 10}) - 60) < 1, "60 pixels in a second, as straight")
}

// A U-shaped floor: from the bottom of one leg to the bottom of the other the
// straight line crosses the gap, so the way goes up, across and down.
@(test)
the_way_goes_round_the_corners :: proc(t: ^testing.T) {
	u := [][2]f32{{0, 0}, {100, 0}, {100, 100}, {70, 100}, {70, 30}, {30, 30}, {30, 100}, {0, 100}}
	out: [16][2]f32
	n := find_path({15, 90}, {85, 90}, u, out[:])
	testing.expect(t, n >= 3, "round two corners, then there")
	testing.expect_value(t, out[n - 1], [2]f32{85, 90})
	prev := [2]f32{15, 90}
	for i in 0 ..< n {
		testing.expect(t, segment_in_polygon(prev, out[i], u), "every leg stays on the floor")
		prev = out[i]
	}
	// A straight walk is one step.
	testing.expect_value(t, find_path({10, 10}, {90, 10}, u, out[:]), 1)
}

// An actor given a target across the gap gets there by walking.
@(test)
an_actor_walks_round_the_gap :: proc(t: ^testing.T) {
	u := [][2]f32{{0, 0}, {100, 0}, {100, 100}, {70, 100}, {70, 30}, {30, 30}, {30, 100}, {0, 100}}
	scene := Scene{walk_area = u}
	a := Actor{pos = {15, 90}, speed = 60}
	walk_to(&a, {85, 90})
	arrived := false
	for _ in 0 ..< 60 * 20 {
		if actor_follow_target(&a, 1.0 / 60, &scene) {
			arrived = true
			break
		}
	}
	testing.expect(t, arrived)
	testing.expect_value(t, a.pos, [2]f32{85, 90})
}

// A table in the middle of the floor: the way goes round it, not through.
@(test)
the_way_goes_round_the_table :: proc(t: ^testing.T) {
	floor := [][2]f32{{0, 0}, {200, 0}, {200, 100}, {0, 100}}
	scene := Scene{walk_area = floor}
	append(&scene.objects, Object{name = "table", pos = {100, 50}, block = box(60, 40)})
	defer delete(scene.objects)
	a := Actor{pos = {40, 50}, speed = 60}
	walk_to(&a, {160, 50})
	arrived := false
	for _ in 0 ..< 60 * 20 {
		if actor_follow_target(&a, 1.0 / 60, &scene) {
			arrived = true
			break
		}
		testing.expect(t, !in_shape(scene.objects[0].block, scene.objects[0].pos, a.pos), "never through the table")
	}
	testing.expect(t, arrived)
}

// A spot just clear of a block, reached in one long frame: the step that
// would land in the block is shortened up to its edge, and she arrives,
// as she would in many short frames.
@(test)
a_long_step_stops_at_the_edge_and_still_arrives :: proc(t: ^testing.T) {
	s := room_with_a_cat()
	defer delete(s.objects)
	// The cat's block is 20 wide and 10 deep round 50,50: its lower edge is
	// y 55. A spot one pixel below it, approached from straight below.
	a := Actor{pos = {50, 95}, speed = 600}
	walk_to(&a, {50, 56})
	arrived := false
	for _ in 0 ..< 20 do if actor_follow_target(&a, 1.0 / 6, &s) { arrived = true; break }
	testing.expect(t, arrived, "a hundred pixels a step, and still there")
	testing.expect_value(t, a.pos, [2]f32{50, 56})
}
