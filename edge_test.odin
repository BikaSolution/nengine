package nengine

import "core:strings"
import "core:testing"

// A jetty 400 wide and 200 deep, the river under it, and a ditch to the right
// that is only there when it has flooded.
@(private = "file")
JETTY :: `scene jetty
walk 0,0 400,0 400,200 0,200
edge water action=drown 0,210 400,210 400,300 0,300
edge ditch action=fall when=flooded 410,0 500,0 500,200 410,200
edge bare action=nothing 0,-100 400,-100 400,-10 0,-10
`

// Per test: the tests run side by side, a thread each.
@(private = "file", thread_local)
stepped: int
@(private = "file", thread_local)
stepped_dir: [2]f32
@(private = "file", thread_local)
stepped_edge: string

@(private = "file")
went_over :: proc(w: ^World, e: ^Edge, dir: [2]f32) {
	stepped += 1
	stepped_dir = dir
	stepped_edge = e.name
}

@(private = "file")
jetty :: proc(t: ^testing.T) -> World {
	w: World
	s, ok := parse_scene(JETTY, nil)
	testing.expect(t, ok)
	append(&w.scenes, s)
	scene_bind_edge(&w.scenes[0], "drown", went_over)
	scene_bind_edge(&w.scenes[0], "fall", went_over)
	// "nothing" is bound to nothing: the end of the floor, like any other.
	refresh_world(&w)
	w.player = {pos = {200, 150}, speed = 120}
	stepped, stepped_dir, stepped_edge = 0, {}, ""
	return w
}

// Walks along the heading for up to ten seconds, as update() does.
@(private = "file")
arrow :: proc(w: ^World, dir: [2]f32) {
	w.player.heading = dir
	for _ in 0 ..< 600 {
		if w.player.heading == {0, 0} do break
		walk_heading(w, 1.0 / 60)
	}
}

@(test)
an_edge_loads_and_writes_back :: proc(t: ^testing.T) {
	w := jetty(t)
	defer destroy_world(&w)
	sc := &w.scenes[0]
	testing.expect_value(t, len(sc.edges), 3)
	water := sc.edges[0]
	testing.expect_value(t, water.name, "water")
	testing.expect_value(t, water.action, "drown")
	testing.expect_value(t, len(water.area), 4)
	testing.expect_value(t, water.area[1], [2]f32{400, 210})
	testing.expect_value(t, sc.edges[1].only, "flooded")
	testing.expect(t, sc.edges[1].hidden) // not flooded
	testing.expect(t, !water.hidden)

	text := scene_text(sc)
	testing.expect(t, strings.contains(text, "edge water action=drown 0,210 400,210 400,300 0,300\n"))
	testing.expect(t, strings.contains(text, "edge ditch action=fall when=flooded 410,0 500,0 500,200 410,200\n"))
}

@(test)
the_arrow_keys_go_over_an_edge :: proc(t: ^testing.T) {
	w := jetty(t)
	defer destroy_world(&w)

	arrow(&w, {0, 1}) // down, off the jetty
	testing.expect_value(t, stepped, 1)
	testing.expect_value(t, stepped_edge, "water")
	testing.expect_value(t, stepped_dir, [2]f32{0, 1})
	// At the brink, on the floor, stopped, facing the water.
	testing.expect(t, point_in_polygon(w.player.pos, w.scenes[0].walk_area))
	testing.expect(t, w.player.pos.y > 196)
	testing.expect_value(t, w.player.heading, [2]f32{})
	testing.expect_value(t, w.player.facing, Facing.Front)
}

@(test)
the_arrow_keys_stop_at_the_plain_end_of_the_floor :: proc(t: ^testing.T) {
	w := jetty(t)
	defer destroy_world(&w)

	// Up: an edge there, but bound to nothing.
	arrow(&w, {0, -1})
	testing.expect_value(t, stepped, 0)
	testing.expect(t, w.player.pos.y < 4)

	// Right: the ditch, but it has not flooded.
	w.player.pos = {200, 100}
	arrow(&w, {1, 0})
	testing.expect_value(t, stepped, 0)
	testing.expect(t, w.player.pos.x > 396)

	// Flooded: ten pixels off the floor, inside EDGE_REACH, and over.
	set_flag(&w, "flooded", true)
	refresh_world(&w)
	arrow(&w, {1, 0})
	testing.expect_value(t, stepped, 1)
	testing.expect_value(t, stepped_edge, "ditch")
}

@(test)
a_click_on_the_water_walks_to_the_brink_and_over :: proc(t: ^testing.T) {
	w := jetty(t)
	defer destroy_world(&w)

	click_walk(&w, {100, 260})
	testing.expect(t, w.player.moving)
	testing.expect_value(t, stepped, 0) // not yet: she is still walking
	finish_walk(&w)
	testing.expect_value(t, stepped, 1)
	testing.expect_value(t, stepped_edge, "water")
	testing.expect(t, abs(w.player.pos.x - 100) < 2 && w.player.pos.y > 196)
	testing.expect(t, stepped_dir.y > 0.99)
}

@(test)
a_click_on_the_floor_never_goes_over :: proc(t: ^testing.T) {
	w := jetty(t)
	defer destroy_world(&w)

	// Right at the brink, on the floor.
	click_walk(&w, {100, 199})
	finish_walk(&w)
	testing.expect_value(t, w.player.pos, [2]f32{100, 199})
	// Between the floor and the water: nothing there, so as near as the floor goes.
	click_walk(&w, {300, 205})
	finish_walk(&w)
	// Off the floor where there is no edge bound: the old click.
	click_walk(&w, {200, -50})
	finish_walk(&w)
	testing.expect(t, w.player.pos.y < 2)
	testing.expect_value(t, stepped, 0)
}

@(test)
walking_somewhere_else_calls_it_off :: proc(t: ^testing.T) {
	w := jetty(t)
	defer destroy_world(&w)

	click_walk(&w, {100, 260})
	walk_to(&w.player, {300, 100}) // changed her mind: GO TO, an approach
	finish_walk(&w)
	testing.expect_value(t, w.player.pos, [2]f32{300, 100})
	testing.expect_value(t, stepped, 0)

	// And an arrow, part-way there.
	click_walk(&w, {100, 260})
	w.exit_walk = {} // what the arrow keys do to a walk
	finish_walk(&w)
	testing.expect_value(t, stepped, 0)

	// And so does stopping short of the brink.
	w.player.pos = {100, 100}
	click_walk(&w, {100, 260})
	w.player.moving = false
	testing.expect(t, !edge_walk_step(&w))
	testing.expect(t, !w.exit_walk.edge.active)
	testing.expect_value(t, stepped, 0)
}

@(test)
the_game_can_walk_her_off :: proc(t: ^testing.T) {
	w := jetty(t)
	defer destroy_world(&w)

	w.player.pos = {50, 50}
	testing.expect(t, walk_off_edge(&w, "water"))
	finish_walk(&w)
	testing.expect_value(t, stepped, 1)
	testing.expect(t, abs(w.player.pos.x - 50) < 6 && w.player.pos.y > 196)

	// Not an edge that is not there: hidden, or unknown.
	testing.expect(t, !walk_off_edge(&w, "ditch"))
	testing.expect(t, !walk_off_edge(&w, "lake"))
	testing.expect(t, !walk_off_edge(&w, "bare"))
}
