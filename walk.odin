package nengine

import "core:math"

// A walk area is a polygon: a list of points joined in order, the last one
// joined back to the first. Any shape works, including concave ones, but not
// shapes with holes in them. Characters keep their feet inside it, and walk
// round its corners to get where they are going (`find_path`), so a floor can
// be a half-moon, a U round a pool, or a path that bends, and a click across
// the notch still gets there.

point_in_polygon :: proc(p: [2]f32, poly: [][2]f32) -> bool {
	// Cast a ray to the right of p and count how many edges it crosses.
	// Odd means inside.
	inside := false
	j := len(poly) - 1
	for i in 0 ..< len(poly) {
		a, b := poly[i], poly[j]
		if (a.y > p.y) != (b.y > p.y) {
			cross_x := a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y)
			if p.x < cross_x do inside = !inside
		}
		j = i
	}
	return inside
}

// The nearest point inside the polygon. Points already inside come back unchanged.
// Used so that clicking on a wall walks you as close to it as you can get.
clamp_to_polygon :: proc(p: [2]f32, poly: [][2]f32) -> [2]f32 {
	if point_in_polygon(p, poly) do return p

	best := p
	best_dist := f32(1e30)
	j := len(poly) - 1
	for i in 0 ..< len(poly) {
		q := closest_on_segment(p, poly[j], poly[i])
		if d := length_sq(p - q); d < best_dist {
			best, best_dist = q, d
		}
		j = i
	}

	// A point exactly on an edge could count as either side, so step one
	// pixel in whichever direction lands properly inside.
	nudges := [8][2]f32{{0, -1}, {0, 1}, {-1, 0}, {1, 0}, {-1, -1}, {1, -1}, {-1, 1}, {1, 1}}
	for n in nudges {
		if point_in_polygon(best + n, poly) do return best + n
	}
	return best
}

@(private)
closest_on_segment :: proc(p, a, b: [2]f32) -> [2]f32 {
	ab := b - a
	len_sq := length_sq(ab)
	if len_sq == 0 do return a
	t := clamp(dot(p - a, ab) / len_sq, 0, 1)
	return a + ab * t
}

@(private) dot       :: proc(a, b: [2]f32) -> f32 { return a.x * b.x + a.y * b.y }
@(private) length_sq :: proc(v: [2]f32) -> f32 { return dot(v, v) }
@(private) length    :: proc(v: [2]f32) -> f32 { return math.sqrt(dot(v, v)) }

// Does a straight walk from a to b stay on the floor the whole way?
segment_in_polygon :: proc(a, b: [2]f32, poly: [][2]f32) -> bool {
	d := b - a
	n := max(int(length(d) / 2), 1)
	for i in 0 ..= n {
		if !point_in_polygon(a + d * (f32(i) / f32(n)), poly) do return false
	}
	return true
}

// The corners to walk round, from `from` to `to`, inside the polygon: the
// shortest way through its corners (each nudged a few pixels onto the floor),
// written into `out`, ending with `to`. Returns how many, or 0 when `to`
// cannot be reached, in which case a walker goes as far as it can in a line.
find_path :: proc(from, to: [2]f32, poly: [][2]f32, out: [][2]f32) -> int {
	scene := Scene{walk_area = poly}
	return scene_path(&scene, from, to, out)
}

// The same, in a room: round the corners of its floor and round anything
// solid standing on it (an object's `block`), not through them.
scene_path :: proc(scene: ^Scene, from, to: [2]f32, out: [][2]f32) -> int {
	if len(out) == 0 do return 0
	if line_clear(scene, from, to) {
		out[0] = to
		return 1
	}
	MAX :: 128
	nodes: [MAX + 2][2]f32
	count := 0
	nodes[count] = from
	count += 1
	add :: proc(scene: ^Scene, nodes: ^[MAX + 2][2]f32, count: ^int, p: [2]f32) {
		if count^ >= MAX || !point_in_polygon(p, scene.walk_area) || in_a_block(scene, p) do return
		nodes[count^] = p
		count^ += 1
	}
	for v in scene.walk_area {
		if inside, ok := nudge_inside(v, scene.walk_area); ok do add(scene, &nodes, &count, inside)
	}
	// Round the people standing about (priority.odin), as round anything solid.
	round := make([dynamic][2]f32, context.temp_allocator)
	people_corners(scene, &round)
	for p in round do add(scene, &nodes, &count, p)
	// Round each solid thing: its corners, stood a little off.
	MARGIN :: f32(6)
	for o in scene.objects {
		if o.hidden || o.block.kind == .None do continue
		c := o.pos + o.block.offset
		h := o.block.size / 2 + MARGIN
		switch o.block.kind {
		case .Box:
			for d in ([4][2]f32{{-1, -1}, {1, -1}, {1, 1}, {-1, 1}}) do add(scene, &nodes, &count, c + d * h)
		case .Oval:
			for i in 0 ..< 8 {
				a := f32(i) * math.PI / 4
				add(scene, &nodes, &count, c + {math.cos(a) * h.x, math.sin(a) * h.y})
			}
		case .None:
		}
	}
	goal := count
	nodes[count] = to
	count += 1

	// Dijkstra over the corners that can see each other.
	dist: [MAX + 2]f32
	prev: [MAX + 2]int
	done: [MAX + 2]bool
	for i in 0 ..< count {
		dist[i] = 1e30
		prev[i] = -1
	}
	dist[0] = 0
	for {
		u := -1
		for i in 0 ..< count do if !done[i] && dist[i] < 1e29 && (u < 0 || dist[i] < dist[u]) do u = i
		if u < 0 || u == goal do break
		done[u] = true
		for v in 0 ..< count {
			if done[v] || v == u do continue
			d := dist[u] + length(nodes[v] - nodes[u])
			if d < dist[v] && line_clear(scene, nodes[u], nodes[v]) {
				dist[v] = d
				prev[v] = u
			}
		}
	}
	if prev[goal] < 0 {
		// A room with a solid map: the floor's corners do not go round what is
		// painted solid, so round it over its pixels instead (priority.odin).
		// Not for a spot off the floor (over a side's brink, onto an edge): that
		// is a walk as far as a line goes, as it always was.
		if scene.solid_map.w > 0 && !solid_maps_off && point_in_polygon(to, scene.walk_area) do return scene_path_grid(scene, from, to, out)
		return 0
	}

	back: [MAX + 2]int
	n := 0
	for at := goal; at > 0; at = prev[at] {
		back[n] = at
		n += 1
	}
	n = min(n, len(out))
	for i in 0 ..< n do out[i] = nodes[back[n - 1 - i]]
	return n
}

// Can feet walk straight from a to b: on the floor, through nothing solid?
// Something solid that a starts inside does not count: stepping out of it is
// always allowed, as in can_step.
@(private)
line_clear :: proc(scene: ^Scene, a, b: [2]f32) -> bool {
	d := b - a
	n := max(int(length(d) / 2), 1)
	for i in 0 ..= n {
		p := a + d * (f32(i) / f32(n))
		// Where a walker already stands is not in question, even on the edge.
		if i > 0 && !point_in_polygon(p, scene.walk_area) do return false
		for o in scene.objects {
			if o.hidden || o.block.kind == .None do continue
			if in_shape(o.block, o.pos, p) && !in_shape(o.block, o.pos, a) do return false
		}
		if i > 0 && solid_at(scene, p) && !solid_at(scene, a) do return false
		if i > 0 && people_in_way(scene, p, a) do return false
	}
	return true
}

@(private)
in_a_block :: proc(scene: ^Scene, p: [2]f32) -> bool {
	for o in scene.objects {
		if !o.hidden && o.block.kind != .None && in_shape(o.block, o.pos, p) do return true
	}
	// Painted floor that is taken, and people (priority.odin).
	return solid_at(scene, p) || people_in_way(scene, p, {1e9, 1e9})
}

// A corner of the floor, moved a few pixels onto it: somewhere to stand.
@(private)
nudge_inside :: proc(v: [2]f32, poly: [][2]f32) -> ([2]f32, bool) {
	R :: f32(4)
	dirs := [8][2]f32{{1, 1}, {-1, 1}, {1, -1}, {-1, -1}, {0, 1}, {0, -1}, {1, 0}, {-1, 0}}
	for d in dirs {
		p := v + d * R
		if point_in_polygon(p, poly) do return p, true
	}
	return v, false
}
