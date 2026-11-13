package nengine

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

// Sides: a screen's four borders, and the neighbour you walk straight into
// across each. Every outdoor screen looks the same way (north, up the
// picture), so a room's sides are its compass:
//
//     side north to=inside_path span=384,640
//     side east  to=banda_front span=400,608 name=banda
//     side south to=track span=448,576 gate=g1
//     shut south Padlocked at dusk. One key, on his belt.
//     side west  to=donga span=400,608 arrive=880,560     # a long walk
//
// `span` is the stretch of the side the walk band crosses, measured along it:
// x for north and south, y for east and west, in canvas pixels. Walking off
// the floor there crosses, and she arrives at the matching point of the
// neighbour's opposite side — mapped proportionally across the two spans, a
// step in from its brink — unless the side names a fixed `arrive=` (a long
// walk, with no screen between). `when=` false and the side is not there: the
// floor ends, as anywhere. `gate=` names one of the game's gates (World.gates)
// and while it is shut the side refuses, with its `shut <dir>` line or the
// gate's own words; every side and exit that names the gate shuts with it, in
// every room at once. `name=` is a noun: GO BANDA, as an exit's name is.
//
// Three ways over, as for an edge (edge.odin), and an edge wins wherever both
// could apply — a drop is not a doorway:
//
//   - **the arrow keys**: the step that would leave the floor, inside a span
//     and at its brink, crosses; she walks straight on in the new screen;
//   - **a click** beyond the brink, or on the floor within SIDE_NEAR of it,
//     inside the span: she walks to the brink and crosses on arriving;
//   - **typed**: GO NORTH (go_compass), GO TO <room> (head_for_room), GO
//     <name> (head_for_exit): the same walk to the brink.
//
// The brink at a point along a side is the outermost floor there: the first
// floor met coming in from the canvas border. So the face of a building in
// the middle of the floor is never a side; only the span says where crossing
// is allowed at all.
//
// A person can go off through a side, or come on through one: `obj moore ...
// leaves=east enters=south` walks them off (or on) when their `when=` changes
// in front of the player, a routine's `step moore leave east` walks them off
// for good, and a cutscene's `4.0 margaret leave east` with the next one's
// `cast margaret enter=west` carries her across between two cuts (with
// cross_player for Ada). People never change size: going north, they sink
// behind the brink, over the rise.

Compass :: enum u8 {
	North,
	East,
	South,
	West,
}

COMPASS_WORDS := [Compass]string {
	.North = "north",
	.East  = "east",
	.South = "south",
	.West  = "west",
}

compass_of :: proc(word: string) -> (d: Compass, ok: bool) {
	for name, c in COMPASS_WORDS do if name == word do return c, true
	return .North, false
}

opposite :: proc(d: Compass) -> Compass {
	switch d {
	case .North: return .South
	case .South: return .North
	case .East:  return .West
	case .West:  return .East
	}
	return d
}

// The way out over side `d`, as a unit vector on the canvas.
outward :: proc(d: Compass) -> [2]f32 {
	switch d {
	case .North: return {0, -1}
	case .South: return {0, 1}
	case .East:  return {1, 0}
	case .West:  return {-1, 0}
	}
	return {}
}

// Where `p` is along side `d` (x for north and south, y for east and west),
// and across it.
along :: proc(d: Compass, p: [2]f32) -> f32 {
	return p.x if d == .North || d == .South else p.y
}

@(private = "file")
across :: proc(d: Compass, p: [2]f32) -> f32 {
	return p.y if d == .North || d == .South else p.x
}

Side :: struct {
	dir:         Compass,
	to:          int,    // index into World.scenes; see resolve_exits
	to_name:     string, // the room, by name, as files say it
	span:        [2]f32, // lo, hi along the side
	gate:        string, // "" for none; see World.gates
	name:        string, // a noun for GO; "" for none
	only:        string, // condition; see flags.odin
	hidden:      bool,   // worked out from `only`; see refresh_scene
	closed_text: string, // `shut <dir>`
	// A long walk: she arrives here, not at the matching point.
	arrive:      [2]f32,
	has_arrive:  bool,
}

// A gate: one condition, and every side and exit that names it shut while it
// holds, in every room at once. The game declares them (World.gates) before
// it loads its rooms. `text` is the refusal for a side or exit with no `shut`
// line of its own.
//
//     {name = "g1", shut = "dusk,!main_gate_open", text = "Padlocked at dusk."}
Gate :: struct {
	name: string,
	shut: string, // a condition: `,` is and, `|` is or (flags.odin)
	text: string,
}

// A walk to the brink of a side, to cross on arriving: a click, GO NORTH. It
// rides in Exit_Walk (anim.odin) with the edge's, so whatever calls off one
// calls off the other.
Side_Walk :: struct {
	active: bool,
	side:   int,    // in the current room's sides
	spot:   [2]f32, // the brink, a pixel inside the floor
}

// Somebody who walked off through a side in one cutscene, for the next to
// bring on at the matching point (`cast <name> enter=<dir>`).
Cut_Handoff :: struct {
	name: string, // owned
	dir:  Compass,
	c:    f32,    // where along the side they went
	span: [2]f32, // that side's span; {} for a room with no side there
}

// Canvas pixels, all.
SIDE_REACH :: f32(8)     // a step off the floor this near the brink crosses
SIDE_NEAR :: f32(24)     // a click on the floor this near the brink crosses
SPAN_IN :: f32(12)       // GO <dir> aims this far inside the span's ends
ARRIVE_IN :: f32(24)     // she lands this far in from the neighbour's brink
ARRIVE_LOOK :: f32(64)   // and arrival looks this much further, and along, for a free spot
SIDE_OFFSTAGE :: f32(110) // past an east or west side, out of sight
SINK_OUT :: f32(64)      // how far past a north brink somebody walks, sinking
SINK_DEPTH :: f32(200)   // how far down behind it they are drawn by then: all of them

@(private = "file")
canvas :: proc() -> [2]f32 {
	return {f32(WIDTH) if WIDTH > 0 else 1024, f32(HEIGHT) if HEIGHT > 0 else 640}
}

// --- Gates ---

gate_named :: proc(w: ^World, name: string) -> ^Gate {
	for &g in w.gates do if g.name == name do return &g
	return nil
}

// Is the gate shut now? Worked out when asked, from its one condition, so
// both its sides always agree. A gate nobody declared is open (and loading a
// room that names one fails: resolve_exits).
gate_shut :: proc(w: ^World, name: string) -> bool {
	if name == "" do return false
	g := gate_named(w, name)
	return g != nil && g.shut != "" && condition_met(w, g.shut)
}

// What a shut side says: its own `shut` line, else its gate's.
side_shut_text :: proc(w: ^World, s: ^Side) -> string {
	if s.closed_text != "" do return s.closed_text
	if g := gate_named(w, s.gate); g != nil do return g.text
	return ""
}

// --- Geometry ---

// The brink of side `d` at `c` along it: the outermost floor there, coming
// in from that border, a pixel or so inside. False if there is no floor at
// all along that line. Nothing outside the floor's own bounds is floor, so
// the search starts there rather than at the canvas border.
side_brink :: proc(sc: ^Scene, d: Compass, c: f32) -> (p: [2]f32, ok: bool) {
	if len(sc.walk_area) < 3 do return {}, false
	lo, hi := f32(1e30), f32(-1e30)
	for q in sc.walk_area {
		lo = min(lo, across(d, q))
		hi = max(hi, across(d, q))
	}
	at :: proc(d: Compass, c, t: f32) -> [2]f32 {
		return {c, t} if d == .North || d == .South else {t, c}
	}
	inside :: proc(sc: ^Scene, d: Compass, c, t: f32) -> bool {
		return point_in_polygon(at(d, c, t), sc.walk_area)
	}
	// North and west come in from the low side, south and east from the high.
	step := f32(2) if d == .North || d == .West else -2
	start := lo - 2 if step > 0 else hi + 2
	prev := start
	for t := start; t >= lo - 2 && t <= hi + 2; t += step {
		if !inside(sc, d, c, t) {
			prev = t
			continue
		}
		out, in_ := prev, t
		for _ in 0 ..< 4 {
			mid := (out + in_) / 2
			if inside(sc, d, c, mid) do in_ = mid
			else do out = mid
		}
		// A pixel further in, so the spot is on the floor and not its line.
		for extra in ([3]f32{1, 2, 3}) {
			if tt := in_ + extra * (1 if step > 0 else -1); inside(sc, d, c, tt) do return at(d, c, tt), true
		}
		return at(d, c, in_), true
	}
	return {}, false
}

// Proportionally from one span to another: a third of the way along the
// gate is a third of the way along it on the other side.
span_map :: proc(c: f32, from, to: [2]f32) -> f32 {
	if from[1] - from[0] < 0.5 do return (to[0] + to[1]) / 2
	t := clamp((c - from[0]) / (from[1] - from[0]), 0, 1)
	return to[0] + t * (to[1] - to[0])
}

// How far the floor reaches along side `d`: the span a side with no partner
// is mapped onto.
@(private = "file")
floor_extent :: proc(sc: ^Scene, d: Compass) -> [2]f32 {
	if len(sc.walk_area) == 0 do return {0, along(d, canvas())}
	lo, hi := f32(1e30), f32(-1e30)
	for q in sc.walk_area {
		lo = min(lo, along(d, q))
		hi = max(hi, along(d, q))
	}
	return {lo + 4, hi - 4}
}

// The side in room `to` that `s` (in room `from`) crosses into: facing back,
// leading back, and the same one counting along the side, for a side with
// two openings. nil if the neighbour has none; the room audit's business.
side_partner :: proc(w: ^World, from: int, s: ^Side) -> ^Side {
	if s.to < 0 || s.to >= len(w.scenes) || from < 0 || from >= len(w.scenes) do return nil
	rank := 0
	for o in w.scenes[from].sides {
		if o.dir == s.dir && o.to == s.to && o.span[0] < s.span[0] do rank += 1
	}
	there := &w.scenes[s.to]
	want := opposite(s.dir)
	for &o in there.sides {
		if o.dir != want || o.to != from do continue
		n := 0
		for p in there.sides do if p.dir == want && p.to == from && p.span[0] < o.span[0] do n += 1
		if n == rank do return &o
	}
	return nil
}

// Somewhere she can arrive: on the floor, in nothing solid, nobody standing
// there, no deadly edge, and no open exit to carry her on through.
side_free :: proc(sc: ^Scene, p: [2]f32) -> bool {
	if !point_in_polygon(p, sc.walk_area) || in_a_block(sc, p) do return false
	for o in sc.objects {
		if o.walks && !o.hidden && length(o.pos - p) < BESIDE / 2 do return false
	}
	for e in sc.edges {
		if !e.hidden && e.on_step != nil && len(e.area) >= 3 && point_in_polygon(p, e.area) do return false
	}
	for e in sc.exits {
		if !e.hidden && !e.closed && in_rect(p, e.area) do return false
	}
	return true
}

// Where she lands in `sc`, arriving over its side `d` at `c` along it: a
// step in from the brink, or the nearest free spot along the span and further
// in. Nothing free, and the step in from the brink all the same.
side_arrival :: proc(sc: ^Scene, d: Compass, span: [2]f32, c: f32) -> [2]f32 {
	inward := -outward(d)
	cs := clamp(c, span[0], span[1])
	width := span[1] - span[0]
	for i := 0; ; i += 1 {
		k := f32((i + 1) / 2) * 8 * (1 if i % 2 == 1 else -1) // 0, +8, -8, +16 ...
		if abs(k) > width + 8 do break
		cc := cs + k
		if cc < span[0] || cc > span[1] do continue
		b, ok := side_brink(sc, d, cc)
		if !ok do continue
		for dd := ARRIVE_IN; dd <= ARRIVE_IN + ARRIVE_LOOK; dd += 8 {
			if p := b + inward * dd; side_free(sc, p) do return p
		}
	}
	b, ok := side_brink(sc, d, cs)
	if !ok do return clamp_to_polygon(canvas() / 2, sc.walk_area)
	return clamp_to_polygon(b + inward * ARRIVE_IN, sc.walk_area)
}

// The first side facing `d` that is there now; or, `any`, there or not.
side_facing :: proc(sc: ^Scene, d: Compass, any := false) -> int {
	for s, i in sc.sides do if s.dir == d && !s.hidden do return i
	if any do for s, i in sc.sides do if s.dir == d do return i
	return -1
}

// Walking from `pos` to `next` along `dir`, off the floor: the side she is
// stepping over, or -1. Inside its span, at its brink, and going out of it.
side_ahead :: proc(sc: ^Scene, pos, next, dir: [2]f32) -> int {
	if point_in_polygon(next, sc.walk_area) do return -1
	best, best_d := -1, f32(1e30)
	for s, i in sc.sides {
		if s.hidden do continue
		out := outward(s.dir)
		if dir.x * out.x + dir.y * out.y <= 0.01 do continue
		c := along(s.dir, pos)
		if c < s.span[0] || c > s.span[1] do continue
		b, ok := side_brink(sc, s.dir, c)
		if !ok do continue
		gap := abs(across(s.dir, pos) - across(s.dir, b))
		if gap > SIDE_REACH do continue
		if gap < best_d do best, best_d = i, gap
	}
	return best
}

// A click at `at`: the side it crosses, and the brink to walk to; -1 if it
// is only a click. Beyond the brink, or on the floor near it, in the span;
// not where the brink is painted solid (a tent standing on the edge of the
// floor): that is a click on the tent, and she cannot stand at the brink to
// cross there anyway (click_spot finds her somewhere to stand).
side_for_click :: proc(sc: ^Scene, at: [2]f32) -> (side: int, spot: [2]f32) {
	side = -1
	best := f32(1e30)
	for s, i in sc.sides {
		if s.hidden do continue
		c := along(s.dir, at)
		if c < s.span[0] || c > s.span[1] do continue
		b, ok := side_brink(sc, s.dir, c)
		if !ok || solid_at(sc, b) do continue
		out := outward(s.dir)
		beyond := (at.x - b.x) * out.x + (at.y - b.y) * out.y
		if beyond < -SIDE_NEAR do continue
		if abs(beyond) < best do side, spot, best = i, b, abs(beyond)
	}
	return
}

// Where somebody going off through side `s` at `c` along it leaves the floor,
// and where they are out of sight: off the side for east and west, off the
// bottom for south, and sunk behind the brink for north. `standable`: for
// somebody who walks there round things (a person of the room going off or
// coming on), the nearest brink along the span that is not painted solid,
// as GO NORTH finds one: not one behind a tent standing on the edge, which
// they could not get to.
side_beyond :: proc(sc: ^Scene, s: Side, c: f32, standable := false) -> (brink, beyond: [2]f32, ok: bool) {
	lo, hi := s.span[0] + SPAN_IN, s.span[1] - SPAN_IN
	if lo > hi do lo, hi = (s.span[0] + s.span[1]) / 2, (s.span[0] + s.span[1]) / 2
	brink, ok = side_brink(sc, s.dir, clamp(c, lo, hi))
	if !ok do return
	if standable do brink = brink_free(sc, s.dir, clamp(c, lo, hi), lo, hi, brink)
	size := canvas()
	switch s.dir {
	case .West:  beyond = {-SIDE_OFFSTAGE, brink.y}
	case .East:  beyond = {size.x + SIDE_OFFSTAGE, brink.y}
	case .South: beyond = {brink.x, size.y + SINK_DEPTH}
	case .North: beyond = {brink.x, brink.y - SINK_OUT}
	}
	return brink, beyond, true
}

// --- Crossing ---

// Over side `i` of the current room and into the next, at the matching
// point (or the side's own `arrive=`). `heading` is kept: the arrow keys walk
// straight on into the new screen. A long walk (`arrive=`) drops it: she has
// walked the way round, with no screen between, and arrives standing at its
// fixed point; walking on would carry her off it the way she set out, round
// the corner and on into the next long walk. No gate is asked; see try_side.
cross :: proc(w: ^World, i: int, heading: [2]f32 = {}) {
	from := w.current
	sc := current_scene(w)
	if i < 0 || i >= len(sc.sides) do return
	s := sc.sides[i]
	if s.to < 0 || s.to >= len(w.scenes) do return
	there := &w.scenes[s.to]
	at: [2]f32
	c := along(s.dir, w.player.pos)
	switch {
	case s.has_arrive:
		at = s.arrive
	case:
		if partner := side_partner(w, from, &sc.sides[i]); partner != nil {
			at = side_arrival(there, partner.dir, partner.span, span_map(c, s.span, partner.span))
		} else {
			ext := floor_extent(there, opposite(s.dir))
			at = side_arrival(there, opposite(s.dir), ext, span_map(c, s.span, ext))
		}
	}
	go_to(w, s.to, at)
	face_towards(&w.player, outward(s.dir))
	w.player.heading = {} if s.has_arrive else heading
	w.crossed = s.dir // for the harness to say so (edge.odin's walked_aloud)
	log_route(w, "cross")
	if w.on_arrive != nil do w.on_arrive(w)
}

// Side `i`, if its gate lets her, and the room beyond is not kept from her
// (keep_out.odin): across, or stopped at the brink and told. True if she
// crossed.
try_side :: proc(w: ^World, i: int, heading: [2]f32 = {}) -> bool {
	sc := current_scene(w)
	if i < 0 || i >= len(sc.sides) do return false
	s := &sc.sides[i]
	text, shut := "", false
	if gate_shut(w, s.gate) {
		text, shut = side_shut_text(w, s), true
	} else if k := kept_out(w, s.to); k != nil {
		text, shut = k.text, true
	}
	if shut {
		p := &w.player
		p.heading = {}
		p.moving = false
		face_towards(p, outward(s.dir))
		if text != "" do say(w, text)
		return false
	}
	cross(w, i, heading)
	return true
}

// The game's, between two cutscenes: her across side `d` from wherever she
// stands (a cut may have walked her off the floor), gates or no gates. False
// if the room has no side that way.
cross_player :: proc(w: ^World, d: Compass) -> bool {
	if len(w.scenes) == 0 do return false
	i := side_facing(current_scene(w), d, any = true)
	if i < 0 do return false
	cross(w, i)
	return true
}

@(private)
start_side_walk :: proc(w: ^World, i: int, spot: [2]f32) {
	walk_to(&w.player, spot)
	w.exit_walk.side = {active = true, side = i, spot = spot}
}

// The brink `b` (at `c` along side `d`) painted solid (a trunk at the edge of
// the picture, a tent on it: the room's solid map, priority.odin): the
// nearest along lo..hi that is not. `b` if it is free, or nothing is.
brink_free :: proc(sc: ^Scene, d: Compass, c, lo, hi: f32, b: [2]f32) -> [2]f32 {
	for k := f32(8); solid_at(sc, b) && k <= hi - lo + 8; k += 8 {
		for cc in ([2]f32{c - k, c + k}) {
			if cc < lo || cc > hi do continue
			if bb, good := side_brink(sc, d, cc); good && !solid_at(sc, bb) do return bb
		}
	}
	return b
}

// GO NORTH: to the brink of the side facing `d` whose span is nearest her,
// straight across if she can, and over on arriving. False if there is none.
head_for_side :: proc(w: ^World, d: Compass) -> bool {
	sc := current_scene(w)
	c0 := along(d, w.player.pos)
	best, best_gap := -1, f32(1e30)
	for s, i in sc.sides {
		if s.hidden || s.dir != d do continue
		gap := max(s.span[0] - c0, c0 - s.span[1], 0)
		if gap < best_gap do best, best_gap = i, gap
	}
	if best < 0 do return false
	return head_for_side_at(w, best)
}

// The same, for one side by its place in the room's list.
head_for_side_at :: proc(w: ^World, i: int) -> bool {
	sc := current_scene(w)
	if i < 0 || i >= len(sc.sides) do return false
	s := sc.sides[i]
	lo, hi := s.span[0] + SPAN_IN, s.span[1] - SPAN_IN
	if lo > hi do lo, hi = (s.span[0] + s.span[1]) / 2, (s.span[0] + s.span[1]) / 2
	c := clamp(along(s.dir, w.player.pos), lo, hi)
	b, ok := side_brink(sc, s.dir, c)
	if !ok do return false
	b = brink_free(sc, s.dir, c, lo, hi, b)
	cancel_approach(w)
	w.exit_walk = {}
	start_side_walk(w, i, b)
	return true
}

// Once a frame, after she has moved: arrived at the brink of a side walk, so
// over (or told it is shut). Stopped short, or sent somewhere else, and the
// walk is off. True if she crossed.
side_walk_step :: proc(w: ^World) -> bool {
	sw := &w.exit_walk.side
	if !sw.active do return false
	p := &w.player
	if p.moving {
		if p.target != sw.spot do sw^ = {} // sent elsewhere
		return false
	}
	at := length(p.pos - sw.spot) <= 2
	i := sw.side
	sw^ = {}
	sc := current_scene(w)
	if !at || i < 0 || i >= len(sc.sides) || sc.sides[i].hidden do return false
	return try_side(w, i)
}

// EAST, GO WEST: out by the side that way; with none (a room inside, the boat,
// a far place), by the open exit whose doorway lies furthest that way from the
// middle of the floor, and more that way than off to one side of it.
go_compass :: proc(w: ^World, word: string) -> bool {
	d, ok := compass_of(word)
	if !ok || len(w.scenes) == 0 do return false
	if head_for_side(w, d) do return true
	dir := outward(d)
	sc := current_scene(w)
	mid: [2]f32
	for p in sc.walk_area do mid += p
	if len(sc.walk_area) > 0 do mid /= f32(len(sc.walk_area))
	best, far := "", f32(0)
	for e in sc.exits {
		if e.hidden do continue
		v := [2]f32{e.area.x + e.area.width / 2, e.area.y + e.area.height / 2} - mid
		on, off := v.x * dir.x + v.y * dir.y, abs(v.x * dir.y - v.y * dir.x)
		if on <= off || on <= far do continue
		best, far = e.name, on
	}
	return best != "" && head_for_exit(w, best)
}

// GO TO <room>, from next door: the exit that leads there, else the side.
head_for_room :: proc(w: ^World, room: string) -> bool {
	if len(w.scenes) == 0 do return false
	sc := current_scene(w)
	for e in sc.exits {
		if e.hidden || e.to < 0 || e.to >= len(w.scenes) || w.scenes[e.to].name != room do continue
		return head_for_exit(w, e.name)
	}
	for s, i in sc.sides {
		if s.hidden || s.to < 0 || s.to >= len(w.scenes) || w.scenes[s.to].name != room do continue
		return head_for_side_at(w, i)
	}
	return false
}

// --- People across sides ---

// Off through side `d`: to the brink at their own place along it, and on out
// of sight. They are not a thing while they go (`hidden`); update_people
// walks them and draw_room draws them. False if there is no side that way.
@(private)
person_leave :: proc(sc: ^Scene, o: ^Object, d: Compass) -> bool {
	i := side_facing(sc, d, any = true)
	if i < 0 do return false
	b, beyond, ok := side_beyond(sc, sc.sides[i], along(d, o.actor.pos), standable = true)
	if !ok do return false
	o.going = true
	o.going_from = o.actor.pos
	actor_stop_anim(&o.actor)
	o.actor.pose = ""
	walk_legs(&o.actor, []Leg{{b, false}, {beyond, true}})
	o.actor.sink = b.y if d == .North else 0
	return true
}

// On through side `d`, from out of sight to where they stand.
@(private)
person_enter :: proc(sc: ^Scene, o: ^Object, d: Compass) -> bool {
	i := side_facing(sc, d, any = true)
	if i < 0 do return false
	to := o.actor.pos
	b, beyond, ok := side_beyond(sc, sc.sides[i], along(d, to), standable = true)
	if !ok do return false
	o.coming = true
	o.coming_to = to
	actor_stop_anim(&o.actor)
	o.actor.pos = beyond
	o.pos = beyond
	walk_legs(&o.actor, []Leg{{b, true}, {to, false}})
	o.actor.sink = b.y if d == .North else 0
	return true
}

// A person's `when=` changed in front of her: off through their `leaves=`
// side, or on through their `enters=`. Without one, they come and go as
// they always did, at once.
@(private)
person_moves :: proc(sc: ^Scene, o: ^Object, gone: bool) {
	if gone {
		if o.coming do settle_coming(o)
		if o.going do return
		if d, has := o.leaves.?; has && person_leave(sc, o, d) do return
		person_pop(o)
		return
	}
	if o.going {
		settle_going(o) // back before they had gone: where they were
		return
	}
	if d, has := o.enters.?; has do person_enter(sc, o, d)
}

// Is the person at `i` only changing lines on this screen? Going, while
// another line of the same character is in sight after this refresh; or
// coming, while another was in sight before it. Then it is a swap, at once,
// and nobody walks: `leaves=` and `enters=` are for leaving the screen.
@(private)
person_stays :: proc(w: ^World, sc: ^Scene, i: int, gone: bool, was: []bool) -> bool {
	me := sc.objects[i]
	for o, j in sc.objects {
		if j == i || !o.walks || o.char_name != me.char_name do continue
		if gone {
			if condition_met(w, o.only) && !o.away do return true
		} else if j < len(was) && was[j] {
			return true
		}
	}
	return false
}

// Gone at once (no `leaves=`, or no side that way): gone to the parser now,
// and still in the picture, as they stood, until the next frame that is hers
// (update_people settles a walk with no legs at once, and runs only then). A
// person whose answer spent the turn that took them away says it to her face
// rather than from nowhere (sight.odin).
@(private)
person_pop :: proc(o: ^Object) {
	o.going = true
	o.going_from = o.actor.pos
	o.actor.moving = false
	o.actor.legs_len = 0
}

// A line going up in her room (show_line): whoever is walking on has arrived,
// so nobody speaks from beyond a side, held there for the length of it.
@(private)
people_arrive :: proc(w: ^World) {
	if len(w.scenes) == 0 || w.current < 0 || w.current >= len(w.scenes) do return
	for &o in current_scene(w).objects do if o.coming do settle_coming(&o)
}

@(private)
settle_going :: proc(o: ^Object) {
	o.going = false
	// Walking cleared their pose (person_leave): back to their line's, for
	// whenever they are next in sight.
	o.actor.pose = o.rest_pose
	o.actor.facing = o.rest_facing
	o.actor.facing_left = o.rest_facing == .Left
	o.actor.pos = o.going_from
	o.pos = o.going_from
	o.actor.moving = false
	o.actor.legs_len = 0
	o.actor.straight = false
	o.actor.sink = 0
}

@(private)
settle_coming :: proc(o: ^Object) {
	o.coming = false
	o.actor.pose = o.rest_pose // arrived: sitting, leaning, as their line says
	o.actor.facing = o.rest_facing
	o.actor.facing_left = o.rest_facing == .Left
	o.actor.pos = o.coming_to
	o.pos = o.coming_to
	o.actor.moving = false
	o.actor.legs_len = 0
	o.actor.straight = false
	o.actor.sink = 0
}

// Everybody in a room the player is leaving (or a restore is leaving) put
// where they are going, at once: nobody walks in a room nobody watches.
@(private)
people_settle :: proc(sc: ^Scene) {
	for &o in sc.objects {
		if o.going do settle_going(&o)
		if o.coming do settle_coming(&o)
		// Called back (sight.odin): only ever somebody whose line had gone;
		// the next refresh says again whether it holds.
		if o.held {
			o.held = false
			o.hidden = true
			o.actor.pose = o.rest_pose
		}
	}
}

// --- Cutscenes across sides ---

// A cast member off through side `d` of the cut's room, and where along it,
// for the next cut's `enter=`.
@(private)
cut_leave :: proc(w: ^World, sc: ^Scene, who: string, a: ^Actor, d: Compass) {
	c := along(d, a.pos)
	span: [2]f32
	b, beyond: [2]f32
	ok := false
	if sc != nil {
		if i := side_facing(sc, d, any = true); i >= 0 {
			span = sc.sides[i].span
			b, beyond, ok = side_beyond(sc, sc.sides[i], c)
			if ok do c = along(d, b) // where they really went: inside the span
		}
	}
	if !ok {
		// No side that way: straight off, as an extra comes on.
		size := canvas()
		b = a.pos
		switch d {
		case .West:  beyond = {-SIDE_OFFSTAGE, a.pos.y}
		case .East:  beyond = {size.x + SIDE_OFFSTAGE, a.pos.y}
		case .South: beyond = {a.pos.x, size.y + SINK_DEPTH}
		case .North: beyond = {a.pos.x, a.pos.y - SINK_OUT}
		}
	}
	walk_legs(a, []Leg{{b, true}, {beyond, true}})
	a.straight = true
	a.pose = ""
	actor_stop_anim(a)
	a.sink = b.y if d == .North else 0
	if w == nil do return
	for &h, i in w.cut_handoff do if h.name == who {
		delete(h.name)
		ordered_remove(&w.cut_handoff, i)
		break
	}
	append(&w.cut_handoff, Cut_Handoff{name = strings.clone(who), dir = d, c = c, span = span})
}

// A cast member written `enter=<dir>`: just out of sight beyond that side, at
// the place matching where they went off in the last cut (or their `at=`, or
// the middle of the span), for their first walk to bring them on.
@(private)
cut_enter :: proc(w: ^World, sc: ^Scene, m: Cast_Member, a: ^Actor, d: Compass) {
	i := side_facing(sc, d, any = true)
	if i < 0 do return
	s := sc.sides[i]
	c := (s.span[0] + s.span[1]) / 2
	if !m.keep_place do c = along(d, m.at)
	for h, k in w.cut_handoff {
		if h.name != m.name || h.dir != opposite(d) do continue
		c = span_map(h.c, h.span, s.span) if h.span[1] > h.span[0] else h.c
		delete(h.name)
		ordered_remove(&w.cut_handoff, k)
		break
	}
	b, beyond, ok := side_beyond(sc, s, c)
	if !ok do return
	a.pos = beyond
	a.sink = b.y if d == .North else 0
}

@(private)
clear_cut_handoff :: proc(w: ^World) {
	for h in w.cut_handoff do delete(h.name)
	clear(&w.cut_handoff)
}

// --- The F1 view ---

@(private)
draw_debug_sides :: proc(w: ^World, scene: ^Scene, fs: i32) {
	cyan := rl.Color{80, 230, 230, 255}
	for &s in scene.sides {
		shut := gate_shut(w, s.gate)
		col := rl.GRAY if s.hidden || shut else cyan
		prev: [2]f32
		have := false
		first: [2]f32
		for c := s.span[0]; c <= s.span[1] + 0.01; c += 8 {
			b, ok := side_brink(scene, s.dir, min(c, s.span[1]))
			if !ok {
				have = false
				continue
			}
			if !have && first == {} do first = b
			if have do rl.DrawLineEx(prev, b, 3, col)
			prev, have = b, true
		}
		to := s.to_name if s.to_name != "" else fmt.tprintf("%v", s.to)
		label := fmt.ctprintf("%v> %v%v%v", COMPASS_WORDS[s.dir][:1], to, fmt.tprintf(" [%v]", s.gate) if s.gate != "" else "", " (shut)" if shut else "")
		rl.DrawText(label, i32(first.x) + ui(2), i32(first.y) - ui(12), fs, col)
	}
}
