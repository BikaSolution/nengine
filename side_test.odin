package nengine

import "core:os"
import "core:strings"
import "core:testing"

// Four screens in a square, each floor 400 wide and the band y 100 to 200:
//
//     nw | ne        nw east is `yard`; ne south and se north are gate g1,
//     ---+---        shut at night; ne's own refusal, se's the gate's.
//     sw | se
@(private = "file")
NW :: `scene nw
walk 0,100 400,100 400,200 0,200
side east to=ne span=120,180 name=yard
side south to=sw span=100,300
`
@(private = "file")
NE :: `scene ne
walk 0,100 400,100 400,200 0,200
side west to=nw span=120,180
side south to=se span=100,300 gate=g1
shut south The gate is padlocked.
`
@(private = "file")
SW :: `scene sw
walk 0,100 400,100 400,200 0,200
side north to=nw span=100,300
side east to=se span=120,180
`
@(private = "file")
SE :: `scene se
walk 0,100 400,100 400,200 0,200
side north to=ne span=100,300 gate=g1
side west to=sw span=120,180
`

@(private = "file")
GATES := [?]Gate{{name = "g1", shut = "night", text = "Locked for the night."}}

@(private = "file", thread_local)
arrivals: int

@(private = "file")
counted :: proc(w: ^World) {arrivals += 1}

// Rooms from scene text, joined up and refreshed, the player in the first.
@(private = "file")
world_of :: proc(t: ^testing.T, texts: ..string) -> World {
	w: World
	w.gates = GATES[:]
	for text in texts {
		s, ok := parse_scene(text, nil)
		testing.expect(t, ok)
		append(&w.scenes, s)
	}
	problem, ok := resolve_exits(&w)
	testing.expectf(t, ok, "resolve: %v", problem)
	refresh_world(&w)
	w.player = {pos = {200, 150}, speed = 120}
	w.time = 1
	arrivals = 0
	return w
}

@(private = "file")
square :: proc(t: ^testing.T) -> World {
	return world_of(t, NW, NE, SW, SE)
}

@(private = "file")
here :: proc(w: ^World) -> string {
	return current_scene(w).name
}

@(private = "file")
near_to :: proc(a, b: [2]f32, by: f32 = 3) -> bool {
	return abs(a.x - b.x) <= by && abs(a.y - b.y) <= by
}

// Walks along the heading, as update() does, until she stops or leaves.
@(private = "file")
arrow :: proc(w: ^World, dir: [2]f32) {
	from := w.current
	w.player.heading = dir
	for _ in 0 ..< 600 {
		if w.player.heading == {0, 0} || w.current != from do break
		walk_heading(w, 1.0 / 60)
	}
}

@(test)
a_side_loads_and_writes_back :: proc(t: ^testing.T) {
	w := world_of(t, `scene a
walk 0,100 400,100 400,200 0,200
side south to=b span=300,100 gate=g1 name=gate when=open arrive=10,20
shut south Padlocked.
side east to=b span=120,140
side east to=b span=160,180
`, `scene b
walk 0,100 400,100 400,200 0,200
`)
	defer destroy_world(&w)
	sc := &w.scenes[0]
	testing.expect_value(t, len(sc.sides), 3)
	s := sc.sides[0]
	testing.expect_value(t, s.dir, Compass.South)
	testing.expect_value(t, s.span, [2]f32{100, 300}) // lo first, whichever way written
	testing.expect_value(t, s.to, 1)
	testing.expect_value(t, s.gate, "g1")
	testing.expect_value(t, s.name, "gate")
	testing.expect(t, s.hidden) // `open` is not set
	testing.expect(t, s.has_arrive)
	testing.expect_value(t, s.closed_text, "Padlocked.")
	text := scene_text(sc)
	testing.expect(t, strings.contains(text, "side south to=b span=100,300 gate=g1 name=gate when=open arrive=10,20\nshut south Padlocked.\n"))
	testing.expect(t, strings.contains(text, "side east to=b span=120,140\nside east to=b span=160,180\n"))
}

@(test)
a_side_to_no_room_fails_loudly :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	s, _ := parse_scene("scene a\nside north to=nowhere span=0,10\n", nil)
	append(&w.scenes, s)
	problem, ok := resolve_exits(&w)
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(problem, "side north goes to nowhere"))
}

@(test)
an_undeclared_gate_fails_loudly :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	s, _ := parse_scene("scene a\nside north to=a span=0,10 gate=g9\n", nil)
	append(&w.scenes, s)
	problem, ok := resolve_exits(&w)
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(problem, "names gate g9"))
	// And an exit's, the same.
	w2: World
	defer destroy_world(&w2)
	s2, _ := parse_scene("scene a\nexit out area=0,0,10,10 to=a arrive=5,5 gate=g9\n", nil)
	append(&w2.scenes, s2)
	_, ok2 := resolve_exits(&w2)
	testing.expect(t, !ok2)
}

@(test)
spans_map_in_proportion :: proc(t: ^testing.T) {
	testing.expect_value(t, span_map(100, {100, 300}, {100, 300}), f32(100))
	testing.expect_value(t, span_map(200, {100, 300}, {400, 600}), f32(500))
	testing.expect_value(t, span_map(150, {100, 300}, {0, 80}), f32(20)) // a quarter of the way
	testing.expect_value(t, span_map(50, {100, 300}, {0, 80}), f32(0))   // outside: clamped
	testing.expect_value(t, span_map(900, {100, 300}, {0, 80}), f32(80))
	testing.expect_value(t, span_map(7, {5, 5}, {0, 80}), f32(40))       // nothing to measure by: the middle
}

@(test)
the_brink_is_the_outermost_floor :: proc(t: ^testing.T) {
	// A floor with a notch running up into the picture at x 150..250.
	w := world_of(t, "scene a\nwalk 0,100 150,100 150,40 250,40 250,100 400,100 400,200 0,200\n")
	defer destroy_world(&w)
	s := &w.scenes[0]
	b, ok := side_brink(s, .North, 200)
	testing.expect(t, ok)
	testing.expect(t, b.y > 40 && b.y < 45, "the notch's top is the north brink there")
	b, _ = side_brink(s, .North, 100)
	testing.expect(t, b.y > 100 && b.y < 105)
	b, _ = side_brink(s, .South, 100)
	testing.expect(t, b.y > 195 && b.y < 200)
	b, _ = side_brink(s, .East, 150)
	testing.expect(t, b.x > 395 && b.x < 400)
	b, _ = side_brink(s, .West, 150)
	testing.expect(t, b.x > 0 && b.x < 5)
	testing.expect(t, point_in_polygon(b, s.walk_area))
	_, ok = side_brink(s, .North, 500)
	testing.expect(t, !ok, "no floor along that line")
}

@(test)
the_arrow_keys_cross_a_side :: proc(t: ^testing.T) {
	w := square(t)
	defer destroy_world(&w)
	w.on_arrive = counted
	w.player.pos = {380, 150}
	arrow(&w, {1, 0})
	testing.expect_value(t, here(&w), "ne")
	testing.expect(t, near_to(w.player.pos, {25, 150}), "a step in from ne's west brink, the same y")
	testing.expect_value(t, w.player.facing, Facing.Right)
	testing.expect_value(t, w.player.heading, [2]f32{1, 0}) // walking straight on
	testing.expect_value(t, arrivals, 1)
}

@(test)
outside_the_span_the_floor_just_ends :: proc(t: ^testing.T) {
	w := square(t)
	defer destroy_world(&w)
	w.player.pos = {380, 110}
	arrow(&w, {1, 0})
	testing.expect_value(t, here(&w), "nw")
	testing.expect_value(t, w.player.heading, [2]f32{0, 0})
	testing.expect(t, w.player.pos.x > 395)
}

@(test)
south_lands_at_the_matching_x_facing_on :: proc(t: ^testing.T) {
	w := square(t)
	defer destroy_world(&w)
	w.player.pos = {250, 180}
	arrow(&w, {0, 1})
	testing.expect_value(t, here(&w), "sw")
	testing.expect(t, near_to(w.player.pos, {250, 125}))
	testing.expect_value(t, w.player.facing, Facing.Front)
}

@(test)
a_diagonal_crosses_the_side_it_meets :: proc(t: ^testing.T) {
	w := square(t)
	defer destroy_world(&w)
	w.player.pos = {390, 150}
	arrow(&w, {DIAGONAL, DIAGONAL})
	testing.expect_value(t, here(&w), "ne")
}

@(test)
something_solid_at_the_brink_stops_her :: proc(t: ^testing.T) {
	w := world_of(t, NW + "obj crate pos=390,150 block=box:10,100\n", NE, SW, SE)
	defer destroy_world(&w)
	w.player.pos = {300, 150}
	arrow(&w, {1, 0})
	testing.expect_value(t, here(&w), "nw")
	testing.expect(t, w.player.pos.x < 386)
}

@(private = "file", thread_local)
drowned: int

@(private = "file")
drown :: proc(w: ^World, e: ^Edge, dir: [2]f32) {drowned += 1}

@(test)
a_deadly_edge_wins_over_a_side :: proc(t: ^testing.T) {
	jetty := `scene jetty
walk 0,100 400,100 400,200 0,200
edge water action=drown 402,100 500,100 500,200 402,200
side east to=bank span=100,200
`
	bank := `scene bank
walk 0,100 400,100 400,200 0,200
side west to=jetty span=100,200
`
	{
		w := world_of(t, jetty, bank)
		defer destroy_world(&w)
		scene_bind_edge(&w.scenes[0], "drown", drown)
		refresh_world(&w)
		drowned = 0
		w.player.pos = {380, 150}
		arrow(&w, {1, 0})
		testing.expect_value(t, drowned, 1)
		testing.expect_value(t, here(&w), "jetty")
		// A click out on the water, beyond the side's brink too: the water.
		drowned = 0
		w.player.pos = {300, 150}
		click_walk(&w, {450, 150})
		testing.expect(t, w.exit_walk.edge.active)
		testing.expect(t, !w.exit_walk.side.active)
	}
	{
		// Nothing bound to it: it is not an edge, and the side has her.
		w := world_of(t, jetty, bank)
		defer destroy_world(&w)
		w.player.pos = {380, 150}
		arrow(&w, {1, 0})
		testing.expect_value(t, here(&w), "bank")
	}
}

@(test)
a_click_beyond_the_brink_crosses :: proc(t: ^testing.T) {
	w := square(t)
	defer destroy_world(&w)
	w.player.pos = {100, 150}
	click_walk(&w, {250, 199}) // the south edge of the floor, in the span
	testing.expect(t, w.exit_walk.side.active)
	finish_walk(&w)
	testing.expect_value(t, here(&w), "sw")
	testing.expect(t, near_to(w.player.pos, {250, 125}))
	testing.expect_value(t, w.player.heading, [2]f32{0, 0}) // a click stops when it gets there
}

@(test)
a_click_near_the_border_crosses :: proc(t: ^testing.T) {
	w := square(t)
	defer destroy_world(&w)
	w.player.pos = {100, 150}
	click_walk(&w, {385, 160}) // on the floor, within SIDE_NEAR of the east brink
	finish_walk(&w)
	testing.expect_value(t, here(&w), "ne")
	testing.expect(t, near_to(w.player.pos, {25, 160}))
}

@(test)
a_click_elsewhere_only_walks :: proc(t: ^testing.T) {
	w := square(t)
	defer destroy_world(&w)
	w.player.pos = {100, 150}
	click_walk(&w, {300, 150}) // far from any side
	testing.expect(t, !w.exit_walk.side.active)
	finish_walk(&w)
	testing.expect_value(t, here(&w), "nw")
	click_walk(&w, {399, 110}) // at the east border, but outside the span
	testing.expect(t, !w.exit_walk.side.active)
	finish_walk(&w)
	testing.expect_value(t, here(&w), "nw")
}

@(test)
a_walk_to_the_brink_called_off_does_not_cross :: proc(t: ^testing.T) {
	w := square(t)
	defer destroy_world(&w)
	w.player.pos = {100, 150}
	click_walk(&w, {399, 150})
	testing.expect(t, w.exit_walk.side.active)
	click_walk(&w, {200, 150}) // changed her mind
	testing.expect(t, !w.exit_walk.side.active)
	finish_walk(&w)
	testing.expect_value(t, here(&w), "nw")
	// Sent somewhere else on the way.
	click_walk(&w, {399, 150})
	walk_to(&w.player, {150, 150})
	finish_walk(&w)
	testing.expect_value(t, here(&w), "nw")
}

@(test)
a_shut_gate_refuses_from_both_rooms :: proc(t: ^testing.T) {
	w := square(t)
	defer destroy_world(&w)
	set_flag(&w, "night")
	// From ne: its own line.
	go_to(&w, 1, {200, 150})
	testing.expect(t, go_compass(&w, "south"))
	finish_walk(&w)
	testing.expect_value(t, here(&w), "ne")
	testing.expect_value(t, message(&w), "The gate is padlocked.")
	// From se: no line of its own, so the gate's.
	go_to(&w, 3, {200, 150})
	w.message_len = 0
	arrow(&w, {0, -1})
	testing.expect_value(t, here(&w), "se")
	testing.expect_value(t, message(&w), "Locked for the night.")
	testing.expect_value(t, w.player.heading, [2]f32{0, 0})
	// Day: one condition, and both sides open with it.
	set_flag(&w, "night", false)
	arrow(&w, {0, -1})
	testing.expect_value(t, here(&w), "ne")
}

@(test)
a_gated_exit_is_closed_with_the_gate :: proc(t: ^testing.T) {
	w := world_of(t, "scene a\nwalk 0,100 400,100 400,200 0,200\nexit walk area=380,100,20,100 to=b arrive=50,150 gate=g1\n", "scene b\nwalk 0,100 400,100 400,200 0,200\n")
	defer destroy_world(&w)
	testing.expect(t, !w.scenes[0].exits[0].closed)
	set_flag(&w, "night")
	testing.expect(t, w.scenes[0].exits[0].closed)
	w.player.pos = {390, 150}
	testing.expect(t, !check_exits(&w))
	testing.expect_value(t, message(&w), "Locked for the night.")
	// The file never said closed=true: writing it back does not either.
	testing.expect(t, !strings.contains(scene_text(&w.scenes[0]), "closed=true"))
	testing.expect(t, strings.contains(scene_text(&w.scenes[0]), "gate=g1"))
}

@(test)
a_hidden_side_is_the_end_of_the_floor :: proc(t: ^testing.T) {
	w := world_of(t, NW + "side west to=sw span=100,200 when=dawn\n", NE, SW, SE)
	defer destroy_world(&w)
	w.player.pos = {20, 150}
	arrow(&w, {-1, 0})
	testing.expect_value(t, here(&w), "nw")
	testing.expect_value(t, message(&w), "")
	testing.expect(t, !go_compass(&w, "west"), "no side and no exit that way")
}

@(test)
a_long_walk_arrives_where_it_says :: proc(t: ^testing.T) {
	w := world_of(t, NW + "side west to=sw span=100,200 arrive=300,150\n", NE, SW, SE)
	defer destroy_world(&w)
	w.player.pos = {20, 150}
	arrow(&w, {-1, 0})
	testing.expect_value(t, here(&w), "sw")
	testing.expect_value(t, w.player.pos, [2]f32{300, 150})
	// The arrow key that set out is spent on the walk: she stands where it
	// says, and does not walk on west off it (T4.7, the SW corner into the donga).
	testing.expect_value(t, w.player.heading, [2]f32{0, 0})
}

@(test)
go_north_takes_the_side :: proc(t: ^testing.T) {
	w := square(t)
	defer destroy_world(&w)
	go_to(&w, 2, {50, 150}) // sw, west of the span: she goes in at its near end
	testing.expect(t, go_compass(&w, "north"))
	finish_walk(&w)
	testing.expect_value(t, here(&w), "nw")
	testing.expect(t, near_to(w.player.pos, {100 + SPAN_IN, 174}))
	testing.expect(t, !go_compass(&w, "up"), "not a compass word")
}

@(test)
with_no_side_the_compass_takes_the_exit_that_way :: proc(t: ^testing.T) {
	w := world_of(t, "scene hut\nwalk 0,100 400,100 400,200 0,200\nexit door area=180,190,40,10 to=yard arrive=50,150\nexit back area=180,100,40,10 to=yard arrive=50,150\n", "scene yard\nwalk 0,100 400,100 400,200 0,200\n")
	defer destroy_world(&w)
	testing.expect(t, go_compass(&w, "south"))
	finish_walk(&w)
	testing.expect_value(t, here(&w), "yard")
	testing.expect(t, !go_compass(&w, "east"), "nothing lies east")
}

@(test)
go_to_a_side_by_its_name_or_its_room :: proc(t: ^testing.T) {
	w := square(t)
	defer destroy_world(&w)
	testing.expect(t, head_for_exit(&w, "yard"))
	finish_walk(&w)
	testing.expect_value(t, here(&w), "ne")
	testing.expect(t, head_for_room(&w, "se"), "gated, but it is the way: she walks to it")
	w.exit_walk = {}
	w.player.moving = false
	go_to(&w, 0, {200, 150})
	testing.expect(t, head_for_room(&w, "sw"))
	finish_walk(&w)
	testing.expect_value(t, here(&w), "sw")
	testing.expect(t, !head_for_room(&w, "ne"), "not next door")
}

@(test)
two_spans_on_one_side_pair_in_order :: proc(t: ^testing.T) {
	w := world_of(t, `scene a
walk 0,100 400,100 400,200 0,200
side east to=b span=160,180
side east to=b span=100,120
`, `scene b
walk 0,100 400,100 400,200 0,200
side west to=a span=110,130
side west to=a span=150,170
`)
	defer destroy_world(&w)
	w.player.pos = {380, 170}
	arrow(&w, {1, 0})
	testing.expect_value(t, here(&w), "b")
	testing.expect(t, near_to(w.player.pos, {25, 160}), "the second opening, half way along")
}

@(test)
arrival_moves_off_what_is_in_the_way :: proc(t: ^testing.T) {
	{
		w := world_of(t, NW, NE + "obj crate pos=25,150 block=box:30,30\n", SW, SE)
		defer destroy_world(&w)
		w.player.pos = {380, 150}
		arrow(&w, {1, 0})
		testing.expect_value(t, here(&w), "ne")
		testing.expect(t, !in_a_block(current_scene(&w), w.player.pos))
		testing.expect(t, abs(w.player.pos.y - 150) < 9)
	}
	{
		// Not into a doorway, to be carried straight on through it.
		w := world_of(t, NW, NE + "exit hut area=0,130,60,40 to=sw arrive=50,150\n", SW, SE)
		defer destroy_world(&w)
		w.player.pos = {380, 150}
		arrow(&w, {1, 0})
		testing.expect_value(t, here(&w), "ne")
		testing.expect(t, !in_rect(w.player.pos, current_scene(&w).exits[0].area))
	}
	{
		// Nowhere free at all: a step in all the same.
		w := world_of(t, NW, NE + "obj barn pos=200,150 block=box:500,300\n", SW, SE)
		defer destroy_world(&w)
		w.player.pos = {380, 150}
		arrow(&w, {1, 0})
		testing.expect_value(t, here(&w), "ne")
		testing.expect(t, near_to(w.player.pos, {25, 150}))
	}
}

@(test)
cross_player_crosses_from_wherever_she_stands :: proc(t: ^testing.T) {
	w := square(t)
	defer destroy_world(&w)
	w.player.pos = {510, 140} // walked off the floor by a cutscene
	testing.expect(t, cross_player(&w, .East))
	testing.expect_value(t, here(&w), "ne")
	testing.expect(t, near_to(w.player.pos, {25, 140}))
	testing.expect(t, !cross_player(&w, .North), "ne has no north side")
}

@(test)
or_in_conditions :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	testing.expect(t, !condition_met(&w, "a,b|c"))
	set_flag(&w, "c")
	testing.expect(t, condition_met(&w, "a,b|c"))
	set_flag(&w, "c", false)
	set_flag(&w, "a")
	testing.expect(t, !condition_met(&w, "a,b|c"))
	set_flag(&w, "b")
	testing.expect(t, condition_met(&w, "a,b|c"))
	testing.expect(t, condition_met(&w, "!x|y"))
	testing.expect(t, !condition_met(&w, "x|"), "an empty alternative is no alternative")
	testing.expect(t, condition_met(&w, "a, b"))
}

// A real game's template: the band art y 120 to 195, canvas
// 384 to 624, full width; east and west cross in y 400..608, north and south in
// x 384..640. Partners' spans are equal, so she arrives at the same y, or x.
@(test)
a_real_template_crosses_at_the_same_place :: proc(t: ^testing.T) {
	w := world_of(t, `scene kitchen_yard
walk 0,384 1024,384 1024,624 0,624
side east to=fire_pit span=400,608
`, `scene fire_pit
walk 0,384 1024,384 1024,624 0,624
side west to=kitchen_yard span=400,608
side north to=inside_path span=384,640
`, `scene inside_path
walk 0,384 1024,384 1024,624 0,624
side south to=fire_pit span=384,640
`)
	defer destroy_world(&w)
	w.player.pos = {1000, 500}
	arrow(&w, {1, 0})
	testing.expect_value(t, here(&w), "fire_pit")
	testing.expect(t, near_to(w.player.pos, {25, 500}))
	w.player.heading = {}
	w.player.pos = {500, 400}
	arrow(&w, {0, -1})
	testing.expect_value(t, here(&w), "inside_path")
	testing.expect(t, near_to(w.player.pos, {500, 598}), "a step in from the front line, the same x")
}

// --- People across sides ---

@(private = "file")
YARD :: `scene yard
walk 0,100 400,100 400,200 0,200
side east to=yard span=120,180
side west to=yard span=120,180
side north to=yard span=100,300
obj moore pos=200,150 char=moore when=moore_here enters=west leaves=north
`

@(private = "file")
people_frames :: proc(w: ^World, n := 600) {
	for _ in 0 ..< n do update_people(w, current_scene(w), 1.0 / 60)
}

@(test)
a_person_comes_on_and_goes_off_through_a_side :: proc(t: ^testing.T) {
	w := world_of(t, YARD)
	defer destroy_world(&w)
	sc := current_scene(&w)
	g := &sc.objects[0]
	testing.expect(t, g.hidden)
	set_flag(&w, "moore_here")
	testing.expect(t, !g.hidden)
	testing.expect(t, g.coming)
	testing.expect(t, g.pos.x < 0, "out of sight beyond the west side")
	testing.expect(t, abs(g.pos.y - 150) < 1)
	people_frames(&w)
	testing.expect(t, !g.coming)
	testing.expect(t, near_to(g.pos, {200, 150}))

	set_flag(&w, "moore_here", false)
	testing.expect(t, g.hidden)
	testing.expect(t, g.going)
	testing.expect(t, object_here(sc, "moore") == nil, "going is gone, to the parser")
	testing.expect(t, g.actor.sink > 0, "going north: over the rise")
	people_frames(&w, 30)
	testing.expect(t, g.going)
	people_frames(&w)
	testing.expect(t, !g.going)
	testing.expect(t, near_to(g.pos, {200, 150}), "back where they stood, for whenever they are here again")
}

// The same person on two lines of one screen (sitting, then standing): the
// change is a swap where they are, never a walk off one line and on the other.
@(test)
a_person_changing_lines_here_swaps_and_does_not_walk :: proc(t: ^testing.T) {
	w := world_of(t, `scene yard
walk 0,100 400,100 400,200 0,200
side east to=yard span=120,180
side west to=yard span=120,180
obj moore pos=200,150 char=moore when=here,!up enters=west leaves=east
obj moore pos=260,150 char=moore when=here,up enters=west leaves=east
`)
	defer destroy_world(&w)
	sc := current_scene(&w)
	sit, stand := &sc.objects[0], &sc.objects[1]
	set_flag(&w, "here")
	testing.expect(t, sit.coming, "on through the west side: nobody was here")
	people_frames(&w)
	set_flag(&w, "up")
	testing.expect(t, sit.hidden && !sit.going, "the sitting line goes at once")
	testing.expect(t, !stand.hidden && !stand.coming, "the standing line is there at once")
	testing.expect(t, near_to(stand.pos, {260, 150}))
	set_flag(&w, "here", false)
	testing.expect(t, stand.going, "and off the screen through the east side, for good")
}

@(test)
nobody_walks_off_in_a_room_she_is_not_in :: proc(t: ^testing.T) {
	w := world_of(t, "scene elsewhere\nwalk 0,100 400,100 400,200 0,200\n", YARD)
	defer destroy_world(&w)
	set_flag(&w, "moore_here")
	g := &w.scenes[1].objects[0]
	testing.expect(t, !g.hidden)
	testing.expect(t, !g.coming)
	// Nor on a restore, nor walking in.
	go_to(&w, 1, {100, 150})
	set_flag(&w, "moore_here", false)
	testing.expect(t, g.going)
	go_to(&w, 0, {100, 150})
	testing.expect(t, !g.going, "settled as she left")
	testing.expect(t, near_to(g.pos, {200, 150}))
}

@(test)
a_routine_can_walk_somebody_off_until_the_room_is_entered :: proc(t: ^testing.T) {
	w := world_of(t, `scene yard
walk 0,100 400,100 400,200 0,200
side east to=yard span=120,180
obj cook pos=200,150 char=cook
step cook walk_to 300,150
step cook leave east
`, "scene elsewhere\nwalk 0,100 400,100 400,200 0,200\n")
	defer destroy_world(&w)
	c := &w.scenes[0].objects[0]
	testing.expect_value(t, step_text(c.routine.steps[1], "cook"), "step cook leave east")
	people_frames(&w, 200)
	testing.expect(t, c.away)
	testing.expect(t, c.hidden)
	people_frames(&w, 400)
	testing.expect(t, !c.going)
	testing.expect(t, c.hidden, "away")
	go_to(&w, 1, {100, 150})
	go_to(&w, 0, {100, 150})
	testing.expect(t, !c.away)
	testing.expect(t, !c.hidden, "back for the next visit")
}

@(test)
a_cutscene_hands_somebody_across_a_side :: proc(t: ^testing.T) {
	w := square(t)
	defer destroy_world(&w)
	one, ok1 := parse_cutscene("cut one scene=nw\ncast moore char=moore at=200,150 facing=right\n0.0 moore leave east\n6.0 end\n")
	defer cutscene_destroy(&one)
	two, ok2 := parse_cutscene("cut two scene=ne\ncast moore char=moore enter=west\n0.0 moore walk_to 100,160\n6.0 end\n")
	defer cutscene_destroy(&two)
	testing.expect(t, ok1 && ok2)
	testing.expect_value(t, cue_body_text(one.cues[0]), "moore leave east")
	testing.expect_value(t, cast_text(two.people[0]), "cast moore char=moore enter=west")

	testing.expect(t, start_cutscene(&w, &one))
	skip_cutscene(&w)
	testing.expect_value(t, len(w.cut_handoff), 1)
	h := w.cut_handoff[0]
	testing.expect_value(t, h.dir, Compass.East)
	testing.expect(t, abs(h.c - 150) < 1)

	w.player.pos = {510, 150}
	testing.expect(t, cross_player(&w, .East))
	testing.expect(t, start_cutscene(&w, &two))
	a := w.cut.actors[0]
	testing.expect(t, a.pos.x < 0, "beyond ne's west side")
	testing.expect(t, abs(a.pos.y - 150) < 1, "at the matching y")
	testing.expect_value(t, len(w.cut_handoff), 0)
	skip_cutscene(&w)
}

// --- Saves ---

@(test)
a_save_from_another_version_is_refused :: proc(t: ^testing.T) {
	w := square(t)
	defer destroy_world(&w)
	w.save_version = 12
	s: Save
	save_world(&w, &s, "")
	text := strings.clone(save_text_of(&s))
	defer delete(text)
	save_destroy(&s)
	testing.expect(t, strings.contains(text, "version 12"))

	w.save_version = 13
	go_to(&w, 3, {50, 150})
	testing.expect(t, !load_world(&w, text))
	testing.expect(t, w.old_save)
	testing.expect_value(t, here(&w), "se") // nothing changed
	testing.expect_value(t, w.player.pos, [2]f32{50, 150})

	w.save_version = 12
	testing.expect(t, load_world(&w, text))
	testing.expect(t, !w.old_save)
	testing.expect_value(t, here(&w), "nw")
	// A game that keeps no version loads anything, as it always did.
	w.save_version = 0
	testing.expect(t, load_world(&w, text))
}

@(test)
old_saves_are_listed_as_old_and_never_offered :: proc(t: ^testing.T) {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" do base = "/tmp"
	dir := strings.concatenate({base, "/nengine-side-saves"}, context.temp_allocator)
	os.remove_all(dir)
	defer os.remove_all(dir)
	w := square(t)
	defer destroy_world(&w)
	w.save_name = dir
	w.save_version = 12
	testing.expect(t, save_game(&w, 1))
	testing.expect(t, any_save(&w))
	testing.expect_value(t, newest_save(&w), 1)
	w.save_version = 13
	infos := save_infos(&w)
	defer save_info_destroy(infos)
	testing.expect(t, infos[2].used && infos[2].stale)
	testing.expect_value(t, slot_title_text(infos[2]), "(an older game)")
	testing.expect(t, !any_save(&w))
	testing.expect_value(t, newest_save(&w), 0)
}

// --- The harness ---

@(test)
the_harness_says_she_crossed :: proc(t: ^testing.T) {
	w := square(t)
	defer destroy_world(&w)
	w.player.pos = {380, 150}
	said := arrow_bang(&w, "right")
	testing.expectf(t, strings.has_prefix(said, "crossed east to ne"), "%v", said)
	said = click_bang(&w, "20,150")
	testing.expectf(t, strings.has_prefix(said, "crossed west to nw"), "%v", said)
	said = click_bang(&w, "200,150")
	testing.expectf(t, strings.has_prefix(said, "walked to"), "%v", said)
}


@(test)
a_person_who_walked_off_or_on_keeps_the_pose_of_their_line :: proc(t: ^testing.T) {
	o := Object{name = "moore", walks = true, rest_pose = "post", going = true, going_from = {112, 538}}
	o.actor.pose = "" // walking
	settle_going(&o)
	testing.expect_value(t, o.actor.pose, "post")
	o.coming, o.coming_to = true, {112, 538}
	o.actor.pose = ""
	settle_coming(&o)
	testing.expect_value(t, o.actor.pose, "post")
	testing.expect_value(t, o.actor.pos, [2]f32{112, 538})
}
