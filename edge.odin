package nengine

import "core:fmt"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

// Edges: where the floor stops and something else starts that a person can
// still step into. Water off a jetty, a drop off a cliff, a road. A wall is
// the end of the floor and nothing more; an edge is the end of the floor with
// somewhere to go beyond it, and going there is an event of the game's.
//
//     edge water action=drown 716,446 1024,446 1024,640 784,640
//     edge water action=drown when=!flooded 716,446 1024,446 1024,640 784,640
//
// The points are a polygon, as `walk` is, drawn over what lies beyond the
// floor (the painted water), beside it and off it. The floor itself is never
// in it: pathfinding keeps to the floor, so a walk anywhere — a click on the
// jetty, GO TO an exit, an approach to a thing, a cutscene — never steps over.
// Three things do, and only these:
//
//   - **the arrow keys**: walking along a heading, the step that would leave
//     the floor goes over instead of stopping, if the edge is just ahead
//     (within EDGE_REACH of the floor's end, along the heading);
//   - **a click on it**: she walks to the nearest floor, at the brink, and
//     goes over on arriving (`click_walk`); a click anywhere else walks as it
//     always did;
//   - **the game**, for a typed JUMP: `walk_off_edge` walks her to the brink
//     nearest to her and over.
//
// Going over calls the edge's `on_step`, which the game binds by the `action`
// name (`scene_bind_edge`), as a trigger's. She stands at the brink when it
// is called, stopped, facing `dir`; what happens then — a warning line, a
// death — is the game's. An edge with nothing bound, or whose `when=` is
// false, is the end of the floor like any other.

Edge :: struct {
	name:    string,
	area:    [][2]f32, // a polygon off the floor: what lies beyond it
	action:  string,
	only:    string, // condition; see flags.odin
	hidden:  bool,   // worked out from `only`; see refresh_world
	// She has stepped over, from the brink at w.player.pos, going `dir` (a
	// unit vector).
	on_step: proc(w: ^World, e: ^Edge, dir: [2]f32),
}

// How far beyond the floor's end the edge may begin and still be stepped
// into from it: room for the painted brink, between the walk polygon's line
// and where the water starts.
EDGE_REACH :: f32(24)

// A walk to the brink that goes over on arriving: a click on the water, or
// the game's walk_off_edge. It rides in the World's `exit_walk` (anim.odin),
// so whatever calls off a walk to an exit — a click, an arrow, a typed
// command, a room changing, a load — calls this off too; and a walk that
// ends anywhere but the brink, or is sent elsewhere, is off.
Edge_Walk :: struct {
	active: bool,
	edge:   string,
	spot:   [2]f32, // the floor at the brink, where the walk ends
	dir:    [2]f32, // and the way over
}

// Joins an edge's `action=` to the game's proc, as scene_bind_trigger does.
scene_bind_edge :: proc(s: ^Scene, action: string, on_step: proc(w: ^World, e: ^Edge, dir: [2]f32)) {
	for &e in s.edges {
		if e.action == action do e.on_step = on_step
	}
}

// The live edge (bound, and its `when=` true) whose area holds `p`, off the
// floor. nil if none.
edge_at :: proc(scene: ^Scene, p: [2]f32) -> ^Edge {
	if point_in_polygon(p, scene.walk_area) do return nil
	for &e in scene.edges {
		if e.hidden || e.on_step == nil || len(e.area) < 3 do continue
		if point_in_polygon(p, e.area) do return &e
	}
	return nil
}

// The live edge with this name, or nil.
edge_named :: proc(scene: ^Scene, name: string) -> ^Edge {
	for &e in scene.edges {
		if e.name == name && !e.hidden && e.on_step != nil && len(e.area) >= 3 do return &e
	}
	return nil
}

// Walking from `from` along `dir` (a unit vector), off the floor at `next`:
// the edge that lies just ahead, or nil if it is only the end of the floor.
edge_ahead :: proc(scene: ^Scene, next, dir: [2]f32) -> ^Edge {
	if point_in_polygon(next, scene.walk_area) do return nil
	for d := f32(0); d <= EDGE_REACH; d += 2 {
		if e := edge_at(scene, next + dir * d); e != nil do return e
	}
	return nil
}

// Over she goes: stopped at the brink, facing the way, and the game's.
step_off :: proc(w: ^World, e: ^Edge, dir: [2]f32) {
	p := &w.player
	p.heading = {}
	p.moving = false
	w.exit_walk = {}
	cancel_approach(w)
	face_towards(p, dir)
	w.stepped_over = e.name
	if e.on_step != nil do e.on_step(w, e, dir)
}

// One frame of walking along the heading (the arrow keys): on over the
// floor, or over an edge, or stopped at the end of the floor.
walk_heading :: proc(w: ^World, dt: f32) {
	p := &w.player
	if p.heading == {0, 0} do return
	scene := current_scene(w)
	next := p.pos + p.heading * p.speed * dt
	if next != p.pos && !can_step(scene, p.pos, next) {
		dir := p.heading / length(p.heading)
		if e := edge_ahead(scene, next, dir); e != nil {
			step_off(w, e, dir)
			return
		}
		// Not a drop: a side, and across it, walking on (side.odin).
		if i := side_ahead(scene, p.pos, next, dir); i >= 0 {
			try_side(w, i, p.heading)
			return
		}
	}
	actor_follow_heading(p, dt, scene)
}

// A click in the room (not on the menu bar): walk there, as near as the floor
// goes; and if it was on an edge, over it on arriving.
click_walk :: proc(w: ^World, at: [2]f32) {
	cancel_approach(w)
	w.exit_walk = {}
	scene := current_scene(w)
	spot := click_spot(w, scene, at)
	walk_to(&w.player, spot)
	// In a doorway, or on the door above the floor's edge, where the nearest
	// floor is in its doorway: through that door on getting there, and no
	// other on the way (world.odin's check_exits).
	w.door_walk = {}
	for e in scene.exits {
		if e.hidden || !(in_rect(at, e.area) || in_rect(spot, e.area)) do continue
		w.door_walk = {active = true, exit = e.name, spot = spot}
		break
	}
	if e := edge_at(scene, at); e != nil {
		d := at - spot
		if length(d) < 0.01 do return
		w.exit_walk.edge = {active = true, edge = e.name, spot = spot, dir = d / length(d)}
		return
	}
	// Beyond a side's brink, or on the floor near it: there, and across
	// (side.odin). A drop is never a side: the edge has had its turn.
	if i, brink := side_for_click(scene, at); i >= 0 do start_side_walk(w, i, brink)
}

// Where a click at `at` walks her: the floor nearest it; or, on something
// painted solid (a tent's canvas), the nearest floor she can walk to and be
// seen on (stand_spot, priority.odin).
click_spot :: proc(w: ^World, scene: ^Scene, at: [2]f32) -> [2]f32 {
	spot := clamp_to_polygon(at, scene.walk_area)
	s, _, _ := actor_picture(w.player)
	return stand_spot(scene, w.player.pos, at, spot, sprite_bounds(s, w.player.pos))
}

// The game's: walk her to the brink of the named edge nearest to where she
// stands, and over. False if there is no such edge here, live.
walk_off_edge :: proc(w: ^World, name: string) -> bool {
	scene := current_scene(w)
	e := edge_named(scene, name)
	if e == nil do return false
	// The nearest point of the edge's area to her, and the floor beside it.
	best, best_d := e.area[0], f32(1e30)
	j := len(e.area) - 1
	for i in 0 ..< len(e.area) {
		q := closest_on_segment(w.player.pos, e.area[j], e.area[i])
		if d := length_sq(w.player.pos - q); d < best_d do best, best_d = q, d
		j = i
	}
	// A little way in, so the spot is in the water and not on its line.
	toward := best
	if inside, ok := nudge_inside(best, e.area); ok do toward = inside
	click_walk(w, toward)
	return w.exit_walk.edge.active
}

// Once a frame, after she has moved: arrived at the brink of an edge walk,
// so over. Stopped short of it, or walking somewhere else now, and the walk
// is off. True if she went over.
edge_walk_step :: proc(w: ^World) -> bool {
	ew := &w.exit_walk.edge
	if !ew.active do return false
	p := &w.player
	if p.moving {
		if p.target != ew.spot do ew^ = {} // sent elsewhere
		return false
	}
	at_brink := length(p.pos - ew.spot) <= 2
	scene := current_scene(w)
	e := edge_named(scene, ew.edge)
	dir := ew.dir
	ew^ = {}
	if !at_brink || e == nil do return false
	step_off(w, e, dir)
	return true
}

// Someone going in over an edge, drawn down to `line` (a y on the canvas) and
// no further: the rest is under the water, or down the hole. People never
// change size; they go behind the surface instead.
draw_actor_above :: proc(a: Actor, line: f32) {
	if line <= 0 do return
	rl.BeginScissorMode(0, 0, WIDTH, i32(line))
	draw_actor(a)
	rl.EndScissorMode()
}

// The F1 view's: each edge outlined, and named.
@(private)
draw_debug_edges :: proc(scene: ^Scene, fs: i32) {
	c := rl.Color{255, 80, 220, 255}
	for e in scene.edges {
		if len(e.area) < 3 do continue
		col := c if !e.hidden && e.on_step != nil else rl.GRAY
		for i in 0 ..< len(e.area) do rl.DrawLineV(e.area[i], e.area[(i + 1) % len(e.area)], col)
		rl.DrawText(fmt.ctprintf("edge %v", e.name), i32(e.area[0].x) + ui(2), i32(e.area[0].y) + ui(2), fs, col)
	}
}

// --- The harness's (script.odin) ---

// `!click x,y`: a click in the room there, as the mouse's, and the walk
// played out in real steps, undrawn (finish_walk). Says where she got to, and
// whether she went over an edge.
click_bang :: proc(w: ^World, arg: string) -> string {
	at, ok := parse_vec2(arg)
	if !ok do return "!click x,y"
	w.stepped_over = ""
	w.crossed = nil
	w.message_len = 0 // a stale reply is not this walk's
	from := w.current
	click_walk(w, at)
	finish_walk(w)
	return walked_aloud(w, from)
}

// Where a harness walk ended, and what was said there.
@(private)
walked_aloud :: proc(w: ^World, from: int) -> string {
	p := w.player.pos
	got: string
	switch {
	case w.stepped_over != "": got = fmt.tprintf("over the edge %v at %.0f,%.0f", w.stepped_over, p.x, p.y)
	case w.crossed != nil && w.current != from:
		got = fmt.tprintf("crossed %v to %v at %.0f,%.0f", COMPASS_WORDS[w.crossed.?], current_scene(w).name, p.x, p.y)
	case w.current != from:  got = fmt.tprintf("went to %v", current_scene(w).name)
	case:                    got = fmt.tprintf("walked to %.0f,%.0f", p.x, p.y)
	}
	if w.dead do return fmt.tprintf("%v, dead", got)
	if said := message(w); said != "" do return fmt.tprintf("%v | %v", got, said)
	return got
}

// `!arrow right [secs]`: an arrow key tapped once, and the walk along it in
// real steps, undrawn, until she stops at the end of the floor (or goes over
// an edge, or through an exit), or `secs` (10) go by. up, down, left, right,
// and the numpad's diagonals as upleft, upright, downleft, downright.
arrow_bang :: proc(w: ^World, arg: string) -> string {
	name, _, secs_text := strings.partition(arg, " ")
	Dir :: struct {
		name: string,
		dir:  [2]f32,
	}
	DIRS :: [?]Dir {
		{"up", {0, -1}}, {"down", {0, 1}}, {"left", {-1, 0}}, {"right", {1, 0}},
		{"upleft", {-DIAGONAL, -DIAGONAL}}, {"upright", {DIAGONAL, -DIAGONAL}},
		{"downleft", {-DIAGONAL, DIAGONAL}}, {"downright", {DIAGONAL, DIAGONAL}},
	}
	dir: [2]f32
	known := false
	for d in DIRS do if d.name == name do dir, known = d.dir, true
	if !known do return "!arrow up|down|left|right|upleft|upright|downleft|downright [secs]"
	secs := f32(10)
	if v, ok := strconv.parse_f32(secs_text); ok && v > 0 do secs = v
	w.stepped_over = ""
	w.crossed = nil
	w.message_len = 0
	cancel_approach(w)
	w.exit_walk = {}
	p := &w.player
	p.moving = false
	p.heading = dir
	from := w.current
	for _ in 0 ..< int(secs * 60) {
		if p.heading == {0, 0} || w.dead || w.current != from do break
		before := p.pos
		walk_heading(w, 1.0 / 60)
		if w.stepped_over != "" do break
		if !check_triggers(w, before) do check_exits(w)
	}
	p.heading = {}
	return walked_aloud(w, from)
}
