package nengine

import "core:testing"
import rl "vendor:raylib"

// The depth (priority) and solid (control) maps: priority.odin. Without a
// window, so the shader's sums are checked here through depth_hides, which
// is the same sum (and `!depth check` holds the GPU to it in the harness).

// A room 40 art px wide and 30 high at 3.2: a wall across it whose foot is
// at canvas y 200, standing from art row 20 up to row 10, and nothing else.
@(private = "file")
WALL_DEPTH :: `depth wall
size 40 30
.*40
.*40
.*40
.*40
.*40
.*40
.*40
.*40
.*40
.*40
.*10 200*20 .*10
.*10 200*20 .*10
.*10 200*20 .*10
.*10 200*20 .*10
.*10 200*20 .*10
.*10 200*20 .*10
.*10 200*20 .*10
.*10 200*20 .*10
.*10 200*20 .*10
.*10 200*20 .*10
.*40
.*40
.*40
.*40
.*40
.*40
.*40
.*40
.*40
.*40
`

@(test)
a_depth_map_reads_and_writes_back_the_same :: proc(t: ^testing.T) {
	m, ok := parse_depth_map(WALL_DEPTH, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, m.w, 40)
	testing.expect_value(t, m.h, 30)
	testing.expect_value(t, m.feet[10 * 40 + 10], 200)
	testing.expect_value(t, m.feet[10 * 40 + 9], DEPTH_NONE)
	testing.expect_value(t, m.lo, 200)
	testing.expect_value(t, m.hi, 200)
	again, ok2 := parse_depth_map(depth_map_text(m, "wall"), context.temp_allocator)
	testing.expect(t, ok2)
	testing.expect_value(t, len(again.feet), len(m.feet))
	for v, i in m.feet do if again.feet[i] != v {
		testing.expectf(t, false, "pixel %v: %v, then %v", i, v, again.feet[i])
		break
	}
	// A row too long, a row short, a bad number: not a map.
	_, bad := parse_depth_map("depth x\nsize 2 1\n.*3\n", context.temp_allocator)
	testing.expect(t, !bad)
	_, bad = parse_depth_map("depth x\nsize 2 2\n.*2\n", context.temp_allocator)
	testing.expect(t, !bad)
	_, bad = parse_depth_map("depth x\nsize 2 1\nfoo*2\n", context.temp_allocator)
	testing.expect(t, !bad)
}

@(test)
whoever_stands_behind_the_wall_is_hidden_by_it_and_whoever_stands_in_front_is_not :: proc(t: ^testing.T) {
	m, _ := parse_depth_map(WALL_DEPTH, context.temp_allocator)
	scale := f32(3.2)
	// A pixel on the wall (art 15,15: canvas 48..51, 48..51).
	on_wall := [2]f32{49.5, 49.5}
	testing.expect(t, depth_hides(m, scale, on_wall, 150))  // feet above its foot: behind it
	testing.expect(t, depth_hides(m, scale, on_wall, 199.9))
	testing.expect(t, !depth_hides(m, scale, on_wall, 200)) // on its line: in front (a tie is hers)
	testing.expect(t, !depth_hides(m, scale, on_wall, 260)) // in front
	// Off the wall nothing hides anybody.
	testing.expect(t, !depth_hides(m, scale, {10, 10}, 0))
	testing.expect(t, !depth_hides(m, scale, {20, 49.5}, 0))
	// Off the map, nothing.
	testing.expect(t, !depth_hides(m, scale, {-5, 49.5}, 0))
	testing.expect(t, !depth_hides(m, scale, {500, 49.5}, 0))
}

@(test)
the_art_pixel_under_a_canvas_pixel_is_the_backdrops :: proc(t: ^testing.T) {
	// art_at is the inverse of the backdrop's own blow-up (art_edge): canvas
	// column c shows the art pixel whose columns hold it, at every scale.
	for scale in ([?]f32{3.2, 1, 2, 3, 4, 2.5}) {
		for c in i32(0) ..< 1100 {
			a := art_at(f32(c) + 0.5, scale)
			if !(art_edge(a, scale) <= c && c < art_edge(a + 1, scale)) {
				testing.expectf(t, false, "scale %v: canvas %v is art %v, which covers %v..%v", scale, c, a, art_edge(a, scale), art_edge(a + 1, scale))
				return
			}
		}
	}
}

@(test)
the_tiles_say_no_only_when_nothing_could_hide :: proc(t: ^testing.T) {
	m, _ := parse_depth_map(WALL_DEPTH, context.temp_allocator)
	scale := f32(3.2)
	// Against every pixel: wherever depth_hides says yes, the tiles never said no.
	rects := [?]rl.Rectangle{{0, 0, 20, 20}, {30, 30, 40, 40}, {60, 20, 10, 80}, {0, 0, 128, 96}, {100, 60, 20, 20}}
	for r in rects {
		for feet in ([?]f32{0, 150, 199, 200, 300}) {
			any := false
			for y := r.y; y < r.y + r.height; y += 1 do for x := r.x; x < r.x + r.width; x += 1 {
				if depth_hides(m, scale, {x + 0.5, y + 0.5}, feet) do any = true
			}
			could := depth_could_hide(m, scale, r, feet)
			if any && !could do testing.expectf(t, false, "%v at feet %v: hidden somewhere, and the tiles said no", r, feet)
		}
	}
	testing.expect(t, !depth_could_hide(m, scale, {0, 0, 128, 96}, 200))
	testing.expect(t, depth_could_hide(m, scale, {40, 40, 10, 10}, 100))
}

// A floor 300 x 200 canvas px at scale 1, and a solid band across it at
// y 90..110 with a gap at x 200..240.
@(private = "file")
banded_room :: proc() -> Scene {
	floor := [?][2]f32{{0, 0}, {300, 0}, {300, 200}, {0, 200}}
	area := make([][2]f32, 4, context.temp_allocator)
	copy(area, floor[:])
	m := Solid_Map{w = 300, h = 200, taken = make([]bool, 300 * 200, context.temp_allocator)}
	for y in 90 ..< 110 do for x in 0 ..< 300 do if x < 200 || x >= 240 do m.taken[y * 300 + x] = true
	return Scene{walk_area = area, solid_map = m, map_scale = 1}
}

@(test)
the_solid_map_stops_a_step_and_a_straight_line :: proc(t: ^testing.T) {
	s := banded_room()
	testing.expect(t, solid_at(&s, {50, 100}))
	testing.expect(t, !solid_at(&s, {220, 100}))
	testing.expect(t, !solid_at(&s, {50, 50}))
	testing.expect(t, !can_step(&s, {50, 88}, {50, 91}))
	testing.expect(t, can_step(&s, {220, 88}, {220, 91}))
	// Out of it is always allowed: nobody put down inside is stuck.
	testing.expect(t, can_step(&s, {50, 100}, {50, 101}))
	testing.expect(t, !line_clear(&s, {50, 50}, {50, 150}))
	testing.expect(t, line_clear(&s, {220, 50}, {220, 150}))
	testing.expect(t, in_a_block(&s, {50, 100}))
}

@(test)
a_walk_goes_round_what_is_painted_solid :: proc(t: ^testing.T) {
	s := banded_room()
	// From above the band to below it, straight down at x 50: round by the gap.
	a := Actor{pos = {50, 50}, speed = 200}
	walk_to(&a, {50, 160})
	arrived := false
	for _ in 0 ..< 2000 {
		if actor_follow_target(&a, 1.0 / 60, &s) {
			arrived = true
			break
		}
		if solid_at(&s, a.pos) {
			testing.expectf(t, false, "she walked into the band at %v", a.pos)
			return
		}
	}
	testing.expect(t, arrived)
	testing.expect_value(t, a.pos, [2]f32{50, 160})
	// The way went through the gap.
	path: [16][2]f32
	n := scene_path(&s, {50, 50}, {50, 160}, path[:])
	testing.expect(t, n >= 2)
	through := false
	for p in path[:n] do if p.x >= 195 && p.x <= 245 do through = true
	testing.expect(t, through)
}

@(test)
a_click_into_the_solid_stops_at_its_edge :: proc(t: ^testing.T) {
	s := banded_room()
	a := Actor{pos = {50, 50}, speed = 200}
	walk_to(&a, {50, 100}) // the middle of the band
	for _ in 0 ..< 2000 {
		actor_follow_target(&a, 1.0 / 60, &s)
		if !a.moving do break
		if solid_at(&s, a.pos) {
			testing.expectf(t, false, "she walked into the band at %v", a.pos)
			return
		}
	}
	testing.expect(t, !a.moving)
	testing.expect(t, a.pos.y < 90 && a.pos.y > 80, "stopped just short of the band")
	testing.expect(t, abs(a.pos.x - 50) < 8)
	// With the gap shut, a walk across is no walk at all: she gets as far as the band.
	for y in 90 ..< 110 do for x in 200 ..< 240 do s.solid_map.taken[y * 300 + x] = true
	b := Actor{pos = {50, 50}, speed = 200}
	walk_to(&b, {50, 160})
	for _ in 0 ..< 2000 {
		actor_follow_target(&b, 1.0 / 60, &s)
		if !b.moving do break
	}
	testing.expect(t, !b.moving)
	testing.expect(t, b.pos.y < 90)
}

@(test)
with_no_maps_nothing_changes :: proc(t: ^testing.T) {
	floor := [?][2]f32{{0, 0}, {300, 0}, {300, 200}, {0, 200}}
	s := Scene{walk_area = floor[:]}
	// Nothing is solid, nothing hides, and the way is the polygon's own.
	for y := f32(0); y < 200; y += 7 do for x := f32(0); x < 300; x += 7 do testing.expect(t, !solid_at(&s, {x, y}))
	testing.expect(t, !depth_hides(s.depth_map, 3.2, {10, 10}, 0))
	testing.expect(t, !depth_could_hide(s.depth_map, 3.2, {0, 0, 300, 200}, 0))
	a, b: [16][2]f32
	na := scene_path(&s, {10, 10}, {290, 190}, a[:])
	nb := find_path({10, 10}, {290, 190}, floor[:], b[:])
	testing.expect_value(t, na, nb)
	for i in 0 ..< na do testing.expect_value(t, a[i], b[i])
	// A room without the files: attaching finds none, and keeps none.
	assets: Assets
	scene_attach_maps(&s, &assets)
	testing.expect_value(t, s.solid_map.w, 0)
	testing.expect_value(t, s.depth_map.w, 0)
}

@(test)
a_room_takes_its_maps_by_its_backdrops_name_and_clears_its_doors :: proc(t: ^testing.T) {
	assets: Assets
	assets.depths = make(map[string]Depth_Map, allocator = context.temp_allocator)
	assets.solids = make(map[string]Solid_Map, allocator = context.temp_allocator)
	d, _ := parse_depth_map(WALL_DEPTH, context.temp_allocator)
	assets.depths["wall"] = d
	solid := Solid_Map{w = 40, h = 30, taken = make([]bool, 40 * 30, context.temp_allocator)}
	for &v in solid.taken do v = true
	assets.solids["wall"] = solid
	s := Scene{background_name = "wall", background = Sprite{frame_w = 128, frame_h = 96, w = 40, h = 30, scale = 3.2}}
	append(&s.exits, Exit{name = "door", area = {60, 60, 20, 20}})
	append(&s.objects, Object{name = "chest", walk_to = {30, 80}})
	defer delete(s.exits)
	defer delete(s.objects)
	scene_attach_maps(&s, &assets)
	defer scene_maps_destroy(&s)
	testing.expect_value(t, s.map_scale, f32(3.2))
	testing.expect_value(t, s.depth_map.w, 40)
	testing.expect(t, solid_at(&s, {10, 10}))
	testing.expect(t, !solid_at(&s, {70, 70}), "the door's patch is floor")
	testing.expect(t, !solid_at(&s, {30.5, 80.5}), "so is the chest's walk_to")
	testing.expect(t, assets.solids["wall"].taken[(70 / 3) + 40 * (70 / 3)], "and the asset's own map is untouched")
	// `solid_map none`: no map at all.
	n := Scene{background_name = "wall", background = s.background, solid_named = true, solid_name = "none"}
	scene_attach_maps(&n, &assets)
	testing.expect_value(t, n.solid_map.w, 0)
	testing.expect_value(t, n.depth_map.w, 40)
}

@(test)
a_thing_with_its_own_depth_is_stamped_in_while_it_is_shown :: proc(t: ^testing.T) {
	room, _ := parse_depth_map(WALL_DEPTH, context.temp_allocator)
	// A post 2 art px wide and 6 high, its feet at its own pos (0), its top
	// leaning back (-10): one art px = 3.2 canvas px.
	own, _ := parse_depth_map("depth post\nsize 2 6\n-10*2\n-8*2\n-6*2\n-4*2\n-2*2\n0*2\n", context.temp_allocator)
	s := Scene{depth_map = room, map_scale = 3.2}
	post := Object{name = "post", pos = {32, 80}, sprite = Sprite{frame_w = 6, frame_h = 19, frames = 1, w = 2, h = 6, scale = 3.2}, own_depth = &own}
	append(&s.objects, post)
	defer delete(s.objects)
	defer scene_maps_destroy(&s)
	testing.expect_value(t, own_depth_line(&s.objects[0]), f32(70))
	m := scene_depth_now(&s)
	_, art := sprite_grid_box(post.sprite, post.pos)
	testing.expect_value(t, m.feet[(art.y + 5) * m.w + art.x], 80)
	testing.expect_value(t, m.feet[art.y * m.w + art.x + 1], 70)
	testing.expect(t, depth_hides(m^, 3.2, {f32(art_edge(art.x, 3.2)) + 1, f32(art_edge(art.y + 5, 3.2)) + 1}, 75))
	// Hidden, it is gone from the map again.
	s.objects[0].hidden = true
	m = scene_depth_now(&s)
	testing.expect_value(t, m.feet[(art.y + 5) * m.w + art.x], room.feet[(art.y + 5) * m.w + art.x])
}

// A floor 300 x 200 at scale 1 whose top edge is a side north, and a tent
// standing on that edge: its floor taken from x 60 to 240, from the brink
// down to y 100 (the strip behind it closed in the map, as a kit closes it).
@(private = "file")
tent_on_the_edge :: proc() -> Scene {
	floor := [?][2]f32{{0, 0}, {300, 0}, {300, 200}, {0, 200}}
	area := make([][2]f32, 4, context.temp_allocator)
	copy(area, floor[:])
	m := Solid_Map{w = 300, h = 200, taken = make([]bool, 300 * 200, context.temp_allocator)}
	for y in 0 ..< 100 do for x in 60 ..< 240 do m.taken[y * 300 + x] = true
	s := Scene{walk_area = area, solid_map = m, map_scale = 1}
	append(&s.sides, Side{dir = .North, span = {0, 300}})
	return s
}

@(test)
a_side_behind_a_tent_carves_no_lane_along_the_strip_behind_it :: proc(t: ^testing.T) {
	s := tent_on_the_edge()
	defer delete(s.sides)
	scene_maps_clear(&s)
	// The side is a way across beside the tent; the brinks behind it stay
	// taken, and no lane runs along the edge from them.
	for x := f32(64); x < 236; x += 8 do testing.expectf(t, solid_at(&s, {x, 2}), "the strip behind the tent was opened at %v,2", x)
	testing.expect(t, !solid_at(&s, {20, 2}))
	// The whole side painted over (a gate the model has shut): a lane from
	// every brink, as before, so she can cross anywhere along it.
	for y in 0 ..< 20 do for x in 0 ..< 300 do s.solid_map.taken[y * 300 + x] = true
	scene_maps_clear(&s)
	for c := f32(0); c <= 300; c += 16 {
		if b, ok := side_brink(&s, .North, min(c, 300)); ok do testing.expectf(t, !solid_at(&s, b), "the brink at %v is still taken", c)
	}
}

@(test)
a_click_beyond_a_brink_painted_solid_is_a_click_not_a_crossing :: proc(t: ^testing.T) {
	s := tent_on_the_edge()
	defer delete(s.sides)
	i, _ := side_for_click(&s, {150, -10})
	testing.expect_value(t, i, -1)
	j, _ := side_for_click(&s, {20, -10})
	testing.expect_value(t, j, 0)
	// Somebody of the room going off north from in front of the tent goes
	// at a brink they can stand on, beside it, not behind it.
	b, beyond, ok := side_beyond(&s, s.sides[0], 150, standable = true)
	testing.expect(t, ok && !solid_at(&s, b) && (b.x < 60 || b.x >= 240))
	testing.expect_value(t, beyond.x, b.x)
	b2, _, _ := side_beyond(&s, s.sides[0], 150)
	testing.expect_value(t, b2.x, f32(150))
}

// A tent standing on a floor 300 x 200 at scale 1, seen from the south: its
// floor taken from x 100 to 200 and y 60 to 130, its canvas painted from the
// top of the picture down to its foot (feet line 130), and behind it a strip
// of free floor, y 40 to 60, where only her head would show above it.
@(private = "file")
tent_with_a_strip :: proc() -> Scene {
	floor := [?][2]f32{{0, 40}, {300, 40}, {300, 200}, {0, 200}}
	area := make([][2]f32, 4, context.temp_allocator)
	copy(area, floor[:])
	m := Solid_Map{w = 300, h = 200, taken = make([]bool, 300 * 200, context.temp_allocator)}
	for y in 60 ..< 130 do for x in 100 ..< 200 do m.taken[y * 300 + x] = true
	d := Depth_Map{w = 300, h = 200, feet = make([]i16, 300 * 200, context.temp_allocator)}
	for &f in d.feet do f = DEPTH_NONE
	for y in 0 ..< 130 do for x in 100 ..< 200 do d.feet[y * 300 + x] = 130
	return Scene{walk_area = area, solid_map = m, depth_map = d, map_scale = 1}
}

@(test)
a_click_on_a_tent_stops_where_she_is_seen :: proc(t: ^testing.T) {
	s := tent_with_a_strip()
	from := [2]f32{150, 180}
	box := rl.Rectangle{from.x - 20, from.y - 40, 40, 40}
	// The strip is floor she could reach, and nearer the click than the front.
	testing.expect(t, !solid_at(&s, {150, 55}) && point_in_polygon({150, 55}, s.walk_area))
	// On the canvas: round to the camera side, at its foot.
	p := stand_spot(&s, from, {150, 100}, {150, 100}, box)
	testing.expectf(t, p.y > 130 && p.y < 136 && abs(p.x - 150) < 2, "a click on the canvas stopped at %v", p)
	// Somewhere with nothing painted to aim by (the floor taken under a
	// thing not drawn there): still not the strip, where she is hidden, but
	// the nearest spot where she is seen.
	for y in 56 ..< 130 do for x in 100 ..< 200 do s.depth_map.feet[y * 300 + x] = DEPTH_NONE
	q := stand_spot(&s, from, {150, 62}, {150, 62}, box)
	testing.expectf(t, !(q.y < 60 && q.x > 90 && q.x < 210), "a click into the tent stopped behind it, at %v", q)
	b := rl.Rectangle{q.x - 20, q.y - 40, 40, 40}
	testing.expect(t, stand_hidden(s.depth_map, 1, b, q.y) <= STAND_HIDDEN)
	// Free floor is its own spot, seen or not; and no solid map, no change.
	testing.expect_value(t, stand_spot(&s, from, {150, 50}, {150, 50}, box), [2]f32{150, 50})
	n := Scene{walk_area = s.walk_area}
	testing.expect_value(t, stand_spot(&n, from, {150, 100}, {150, 100}, box), [2]f32{150, 100})
}

// People are solid (priority.odin): a floor 300 x 200 at scale 1 with
// somebody standing in the middle of it.
@(private = "file")
room_with_somebody :: proc() -> Scene {
	floor := [?][2]f32{{0, 0}, {300, 0}, {300, 200}, {0, 200}}
	area := make([][2]f32, 4, context.temp_allocator)
	copy(area, floor[:])
	s := Scene{walk_area = area}
	append(&s.objects, Object{name = "cook", walks = true, pos = {150, 100}, actor = Actor{pos = {150, 100}, npc = true, speed = 200}})
	return s
}

@(test)
a_walk_goes_round_somebody_standing :: proc(t: ^testing.T) {
	s := room_with_somebody()
	defer delete(s.objects)
	me := Actor{pos = {60, 100}, speed = 200}
	the_player = &me
	defer the_player = nil
	foot := person_foot(s.objects[0].actor)
	walk_to(&me, {240, 100})
	arrived := false
	for _ in 0 ..< 2000 {
		if actor_follow_target(&me, 1.0 / 60, &s) {
			arrived = true
			break
		}
		if in_shape(foot, {150, 100}, me.pos) {
			testing.expectf(t, false, "she walked through the cook at %v", me.pos)
			return
		}
	}
	testing.expect(t, arrived)
	testing.expect_value(t, me.pos, [2]f32{240, 100})
}

@(test)
a_click_on_somebodys_feet_stops_beside_them :: proc(t: ^testing.T) {
	s := room_with_somebody()
	defer delete(s.objects)
	me := Actor{pos = {60, 100}, speed = 200}
	the_player = &me
	defer the_player = nil
	foot := person_foot(s.objects[0].actor)
	walk_to(&me, {150, 100})
	for _ in 0 ..< 2000 {
		actor_follow_target(&me, 1.0 / 60, &s)
		if !me.moving do break
		testing.expect(t, !in_shape(foot, {150, 100}, me.pos), "never inside the cook")
	}
	testing.expect(t, !me.moving)
	testing.expect(t, !in_shape(foot, {150, 100}, me.pos))
	testing.expect(t, length(me.pos - {150, 100}) < foot.size.x / 2 + 12, "stopped at the cook's side")
}

@(test)
somebody_walking_goes_round_her :: proc(t: ^testing.T) {
	s := room_with_somebody()
	defer delete(s.objects)
	me := Actor{pos = {150, 100}, speed = 200}
	the_player = &me
	defer the_player = nil
	s.player_in, s.player_pos = true, me.pos
	foot := person_foot(me)
	cook := &s.objects[0].actor
	cook.pos = {40, 100}
	walk_to(cook, {260, 100})
	arrived := false
	for _ in 0 ..< 2000 {
		if actor_follow_target(cook, 1.0 / 60, &s) {
			arrived = true
			break
		}
		if in_shape(foot, me.pos, cook.pos) {
			testing.expectf(t, false, "the cook walked through her at %v", cook.pos)
			return
		}
	}
	testing.expectf(t, arrived, "the cook stopped at %v (moving %v, way %v of %v)", cook.pos, cook.moving, cook.path[:cook.path_len], cook.path_len)
	// Somebody of a cutscene (no npc, not her) is not stopped by anyone.
	s.mover = .None
	testing.expect(t, !people_in_way(&s, me.pos, {0, 0}))
}
