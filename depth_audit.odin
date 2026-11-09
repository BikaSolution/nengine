package nengine

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

// The in-front-and-behind audit (a standing rule for every room): `!depth
// audit` in the harness, `just depth-audit <room>...` from the shell. It draws
// her all over the room's floor, in the real draw, and walks her about it, and
// lists what is wrong:
//
//   behind    a room painted with no depth map: nobody can be behind anything
//             painted in it (NO-MAP)
//   in front  somewhere on the floor she vanishes, hidden by what is painted
//             (VANISHES: floor behind a thing, where she cannot be seen; the
//             floor or the solid map is wrong there); or a thing drawn over her
//             where the room's depth says she stands in front of it (OVER: a
//             depth sprite's one feet line wrong for part of it, or a prop
//             with no depth of its own)
//   solid     a walk that steps onto taken floor or into somebody (THROUGH:
//             the engine's own guarantee, checked); a room with no solid map
//             (NO-SOLID)
//   people    somebody standing where the way to a door, a side or a thing's
//             spot goes, so that it cannot be reached past them (BLOCKS)
//
// Each finding is one line, `FAULT <kind> <x,y> <words>`, and a count at the
// end. The findings are the room as it stands at that moment of the story:
// run it at the hours that matter.

@(private = "file")
Audit_Finding :: struct {
	kind:  string,
	at:    [2]f32,
	words: string,
}

@(private)
depth_audit :: proc(w: ^World) -> string {
	sc := current_scene(w)
	found := make([dynamic]Audit_Finding, context.temp_allocator)
	add :: proc(f: ^[dynamic]Audit_Finding, kind: string, at: [2]f32, words: string) {
		append(f, Audit_Finding{kind, at, words})
	}
	if len(sc.walk_area) < 3 do return fmt.tprintf("%v: no floor, nothing to audit", sc.name)
	painted := sc.background.texture.id != 0
	if painted && sc.depth_map.w <= 0 do add(&found, "NO-MAP", {}, "painted with no depth map: nobody can be behind anything painted in it")
	if painted && sc.solid_map.w <= 0 do add(&found, "NO-SOLID", {}, "no solid map: only the walk polygon and the blocks keep her out of what is painted")

	// The floor, every 24 px: free of blocks and taken floor.
	pts := make([dynamic][2]f32, context.temp_allocator)
	for y := f32(12); y < room_height(sc); y += 24 {
		for x := f32(12); x < f32(WIDTH); x += 24 {
			p := [2]f32{x, y}
			if !point_in_polygon(p, sc.walk_area) || solid_at(sc, p) do continue
			blocked := false
			for o in sc.objects do if !o.hidden && o.block.kind != .None && in_shape(o.block, o.pos, p) do blocked = true
			if !blocked do append(&pts, p)
		}
	}

	saved := w.player
	defer w.player = saved
	was := depth_maps_off
	defer depth_maps_off = was

	// In front: her at each point, drawn both ways.
	if painted {
		depth_maps_off = true
		empty_off := depth_probe_render(w, sc, false)
		defer rl.UnloadImage(empty_off)
		depth_maps_off = false
		empty_on := depth_probe_render(w, sc, false)
		defer rl.UnloadImage(empty_on)
		e0 := ([^]rl.Color)(empty_off.data)
		e1 := ([^]rl.Color)(empty_on.data)
		live: Depth_Map
		if sc.depth_map.w > 0 do live = scene_depth_now(sc)^
		for p in pts {
			w.player.pos = p
			w.player.moving = false
			w.player.walking = false
			w.player.facing = .Front
			s, _, _ := actor_picture(w.player)
			box := sprite_bounds(s, p)
			depth_maps_off = true
			whole := depth_probe_render(w, sc, true)
			depth_maps_off = false
			masked := depth_probe_render(w, sc, true)
			a := ([^]rl.Color)(whole.data)
			b := ([^]rl.Color)(masked.data)
			her, shown, over := 0, 0, 0
			for y in max(int(box.y), 0) ..< min(int(box.y + box.height), int(whole.height)) {
				for x in max(int(box.x), 0) ..< min(int(box.x + box.width), int(whole.width)) {
					i := y * int(whole.width) + x
					if a[i] == e0[i] do continue
					her += 1
					if b[i] != e1[i] {
						shown += 1
						continue
					}
					if live.w > 0 && !depth_hides(live, sc.map_scale, {f32(x) + 0.5, f32(y) + 0.5}, p.y) do over += 1
				}
			}
			rl.UnloadImage(whole)
			rl.UnloadImage(masked)
			if her == 0 do continue
			if shown * 10 <= her {
				add(&found, "VANISHES", p, "she stands here and cannot be seen: floor behind something painted (the walk polygon or the solid map is wrong here)")
			} else if over * 4 >= her {
				add(&found, "OVER", p, fmt.tprintf("%v drawn over her where the depth map says she is in front of it", audit_over_whom(sc, box, p.y)))
			}
		}
	}

	// Solid: walks every which way, none onto taken floor or into anybody.
	if len(pts) >= 2 {
		onto, into := 0, 0
		first: [2]f32
		for k in 0 ..< 120 {
			from := pts[(k * 7919) % len(pts)]
			to := pts[(k * 104729 + 13) % len(pts)]
			if from == to do continue
			w.player.pos = from
			w.player.moving = false
			walk_to(&w.player, to)
			for _ in 0 ..< 60 * 20 {
				if !w.player.moving do break
				before := w.player.pos
				people_frame_scene(sc, &w.player)
				actor_follow_target(&w.player, 1.0 / 60, sc)
				if solid_at(sc, w.player.pos) && !solid_at(sc, before) {
					onto += 1
					first = w.player.pos
				}
				sc.mover = .Player
				if people_in_way(sc, w.player.pos, before) {
					into += 1
					first = w.player.pos
				}
				sc.mover = .None
			}
		}
		if onto > 0 do add(&found, "THROUGH", first, fmt.tprintf("%v step(s) onto taken floor in 120 walks", onto))
		if into > 0 do add(&found, "THROUGH", first, fmt.tprintf("%v step(s) into somebody in 120 walks", into))
	}

	// People: somebody on the only way to a door, a side or a thing.
	audit_people(w, sc, &found)

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%v: %v finding(s), %v floor points", sc.name, len(found), len(pts))
	for f in found {
		if f.at == {} do fmt.sbprintf(&b, "\n    FAULT %v %v", f.kind, f.words)
		else do fmt.sbprintf(&b, "\n    FAULT %v %.0f,%.0f %v", f.kind, f.at.x, f.at.y, f.words)
	}
	return strings.to_string(b)
}

// The people's frame for one room, without a world: her there.
@(private)
people_frame_scene :: proc(sc: ^Scene, me: ^Actor) {
	the_player = me
	sc.player_in = true
	sc.player_pos = me.pos
}

// Which still thing at depth=normal, drawn after her, covers her box most.
@(private = "file")
audit_over_whom :: proc(sc: ^Scene, box: rl.Rectangle, feet: f32) -> string {
	best, best_a := "a thing", f32(0)
	for &o in sc.objects {
		if o.hidden || o.walks || o.depth != .Normal || o.sprite.texture.id == 0 do continue
		y := own_depth_line(&o) if o.own_depth != nil else o.pos.y + o.base
		if y < feet do continue
		r, _ := sprite_grid_box(o.sprite, o.pos)
		x0, y0 := max(r.x, box.x), max(r.y, box.y)
		x1, y1 := min(r.x + r.width, box.x + box.width), min(r.y + r.height, box.y + box.height)
		if x1 <= x0 || y1 <= y0 do continue
		if a := (x1 - x0) * (y1 - y0); a > best_a {
			best, best_a = fmt.tprintf("%v (sprite %v, feet %.0f%v)", o.name, o.sprite_name, y, ", no depth of its own" if o.own_depth == nil else ""), a
		}
	}
	return best
}

// Reachability over the floor on an 8 px grid (polygon, blocks, taken floor),
// with and without the people standing about: a door, a side's brink or a
// thing's spot reachable without somebody and not with them is blocked by
// them.
@(private = "file")
audit_people :: proc(w: ^World, sc: ^Scene, found: ^[dynamic]Audit_Finding) {
	people := make([dynamic]int, context.temp_allocator)
	for &o, i in sc.objects do if o.walks && !o.hidden && !o.going && !o.coming do append(&people, i)
	if len(people) == 0 do return
	G :: f32(8)
	gw, gh := int(f32(WIDTH) / G), int(room_height(sc) / G)
	cell_of :: proc(p: [2]f32, gw, gh: int) -> int {
		return clamp(int(p.y / 8), 0, gh - 1) * gw + clamp(int(p.x / 8), 0, gw - 1)
	}
	reach :: proc(sc: ^Scene, gw, gh: int, from: [2]f32, without: int) -> []bool {
		seen := make([]bool, gw * gh, context.temp_allocator)
		free :: proc(sc: ^Scene, c, gw: int, without: int) -> bool {
			p := [2]f32{f32(c % gw) * 8 + 4, f32(c / gw) * 8 + 4}
			if !point_in_polygon(p, sc.walk_area) || solid_at(sc, p) do return false
			for o, i in sc.objects {
				if o.hidden do continue
				if o.block.kind != .None && in_shape(o.block, o.pos, p) do return false
				if o.walks && !o.going && !o.coming && i != without && in_shape(person_foot(o.actor), o.actor.pos, p) do return false
			}
			return true
		}
		start := cell_of(from, gw, gh)
		queue := make([dynamic]int, context.temp_allocator)
		append(&queue, start)
		seen[start] = true
		for head := 0; head < len(queue); head += 1 {
			c := queue[head]
			cx, cy := c % gw, c / gw
			for d in ([4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
				nx, ny := cx + d.x, cy + d.y
				if nx < 0 || ny < 0 || nx >= gw || ny >= gh do continue
				n := ny * gw + nx
				if seen[n] || !free(sc, n, gw, without) do continue
				seen[n] = true
				append(&queue, n)
			}
		}
		return seen
	}
	// Where the ways go: each open exit's spot, each side's brink along its
	// span, each thing's walk_to.
	Goal :: struct {
		at:   [2]f32,
		what: string,
	}
	goals := make([dynamic]Goal, context.temp_allocator)
	for e in sc.exits do if !e.hidden do append(&goals, Goal{clamp_to_polygon(rect_center(e.area), sc.walk_area), fmt.tprintf("exit %v", e.name)})
	for s in sc.sides {
		if s.hidden do continue
		for c := s.span[0]; c <= s.span[1]; c += 32 {
			if b, ok := side_brink(sc, s.dir, c); ok do append(&goals, Goal{b, fmt.tprintf("side %v", COMPASS_WORDS[s.dir])})
		}
	}
	for o in sc.objects do if !o.hidden && !o.walks && o.walk_to != {} do append(&goals, Goal{o.walk_to, fmt.tprintf("%v's spot", o.name)})
	// From the biggest piece of the floor: the middle of it, as she arrives.
	mid: [2]f32
	for p in sc.walk_area do mid += p
	mid = clamp_to_polygon(mid / f32(len(sc.walk_area)), sc.walk_area)
	all := reach(sc, gw, gh, mid, -2)   // with everybody
	for i in people {
		got := reach(sc, gw, gh, mid, i)
		said := make(map[string]bool, allocator = context.temp_allocator)
		for g in goals {
			c := cell_of(g.at, gw, gh)
			if got[c] && !all[c] && !said[g.what] {
				said[g.what] = true
				o := sc.objects[i]
				append(found, Audit_Finding{"BLOCKS", o.actor.pos, fmt.tprintf("%v stands in the only way to %v", o.name, g.what)})
			}
		}
	}
}


// --- One case replayed (the regressions) ---
//
// `!depth case walk x,y`: the floor at a point that must not be stood on (the
// inside of a tent, a crate, a gate's leaf). Can she stand there; a click
// there from where she stands, as near as the floor goes; and an arrow key
// held toward it from up to 120 px off, in whichever of the eight ways points
// at it, until she stops. Each must keep her off it (CASE_NEAR).
//
// `!depth case front|behind x,y x0,y0,x1,y1 [out=f.png]`: her standing at a
// point, facing front, and how much of her inside the box (a thing's) the room
// hides, in the real draw: her whole picture (everything else hidden, the
// maps off) against what shows of her (everything, as drawn). front: a thing
// nearer than her feet must hide some of her; behind: one farther back must
// not. The verdict is the caller's.
// out= writes the room with her in it and the hidden part of her in magenta.

CASE_NEAR :: f32(1.5) // px: a walk that ends or passes this near the point stood on it (the floor taken round it stops her at its edge)

@(private)
depth_case :: proc(w: ^World, args: []string) -> string {
	USAGE :: "!depth case walk x,y | front|behind x,y x0,y0,x1,y1 [out=f.png]"
	sc := current_scene(w)
	if len(args) < 2 do return USAGE
	p, ok := parse_vec2(args[1])
	if !ok do return USAGE
	saved := w.player
	defer w.player = saved
	switch args[0] {
	case "walk":
		why := "free"
		if !point_in_polygon(p, sc.walk_area) do why = "off the floor"
		else if solid_at(sc, p) do why = "taken"
		else if in_a_block(sc, p) do why = "a block"
		else {
			for o in sc.objects do if o.walks && !o.hidden && in_shape(person_foot(o.actor), o.actor.pos, p) do why = "somebody"
		}
		people_frame_scene(sc, &w.player)
		// A click, from where she stands.
		start := w.player.pos
		w.player.moving = false
		walk_to(&w.player, click_spot(w, sc, p))
		click_near := length(w.player.pos - p)
		for _ in 0 ..< 60 * 30 {
			if !w.player.moving do break
			actor_follow_target(&w.player, 1.0 / 60, sc)
			sc.player_pos = w.player.pos
			click_near = min(click_near, length(w.player.pos - p))
		}
		click_end := w.player.pos
		// An arrow at it: the nearest of the eight ways from where the click
		// stopped, from the farthest free point on that line up to 120 px off.
		d := p - click_end
		if length(d) < 1 do d = p - start
		ang := math.atan2(d.y, d.x)
		k := int(math.round(ang / (math.PI / 4)))
		dir := [2]f32{math.cos(f32(k) * math.PI / 4), math.sin(f32(k) * math.PI / 4)}
		from := p
		found := false
		for back := f32(120); back >= 12; back -= 4 {
			q := p - dir * back
			if point_in_polygon(q, sc.walk_area) && !solid_at(sc, q) && !in_a_block(sc, q) {
				from, found = q, true
				break
			}
		}
		arrow_near := f32(-1)
		arrow_end := from
		if found {
			w.player.pos = from
			w.player.moving = false
			w.player.heading = dir
			sc.player_pos = from
			arrow_near = length(from - p)
			for _ in 0 ..< 60 * 6 {
				if w.player.heading == {} do break
				actor_follow_heading(&w.player, 1.0 / 60, sc)
				sc.player_pos = w.player.pos
				arrow_near = min(arrow_near, length(w.player.pos - p))
				if length(w.player.pos - from) > 260 do break
			}
			arrow_end = w.player.pos
			w.player.heading = {}
		}
		pass := why != "free" && click_near > CASE_NEAR && (arrow_near < 0 || arrow_near > CASE_NEAR)
		arrow := "no free floor to come from" if !found else fmt.tprintf("from %.0f,%.0f stopped at %.0f,%.0f, %.0f px off at nearest", from.x, from.y, arrow_end.x, arrow_end.y, arrow_near)
		return fmt.tprintf("case walk %.0f,%.0f: %v; stand %v; click stopped at %.0f,%.0f, %.0f px off at nearest; arrow %v", p.x, p.y, "PASS" if pass else "FAIL", why, click_end.x, click_end.y, click_near, arrow)

	case "front", "behind":
		if len(args) < 3 do return USAGE
		b := [4]f32{}
		{
			parts := strings.split(args[2], ",", context.temp_allocator)
			if len(parts) != 4 do return USAGE
			for s, i in parts do b[i] = strconv.parse_f32(s) or_else 0
		}
		out := ""
		for a in args[3:] do if strings.has_prefix(a, "out=") do out = a[4:]
		was := depth_maps_off
		defer depth_maps_off = was
		w.player.pos = p
		w.player.moving, w.player.walking = false, false
		w.player.facing = .Front
		w.player.heading = {}
		// Her whole picture: everything else hidden, the maps off.
		hidden := make([]bool, len(sc.objects), context.temp_allocator)
		for &o, i in sc.objects {
			hidden[i] = o.hidden
			o.hidden = true
		}
		depth_maps_off = true
		bare := depth_probe_render(w, sc, false)
		alone := depth_probe_render(w, sc, true)
		for &o, i in sc.objects do o.hidden = hidden[i]
		depth_maps_off = false
		room := depth_probe_render(w, sc, false)
		with := depth_probe_render(w, sc, true)
		defer {
			rl.UnloadImage(bare)
			rl.UnloadImage(alone)
			rl.UnloadImage(room)
			rl.UnloadImage(with)
		}
		c0 := ([^]rl.Color)(bare.data)
		c1 := ([^]rl.Color)(alone.data)
		c2 := ([^]rl.Color)(room.data)
		c3 := ([^]rl.Color)(with.data)
		W := int(with.width)
		her, gone := 0, 0
		for y in max(int(b[1]), 0) ..< min(int(b[3]), int(with.height)) {
			for x in max(int(b[0]), 0) ..< min(int(b[2]), W) {
				i := y * W + x
				if c1[i] == c0[i] do continue
				her += 1
				if c3[i] == c2[i] do gone += 1
			}
		}
		if out != "" {
			img := rl.ImageCopy(with)
			c := ([^]rl.Color)(img.data)
			for i in 0 ..< W * int(with.height) {
				if c1[i] != c0[i] && c3[i] == c2[i] do c[i] = {255, 0, 255, 255}
			}
			rl.ExportImage(img, strings.clone_to_cstring(out, context.temp_allocator))
			rl.UnloadImage(img)
		}
		f := f32(gone) / f32(max(her, 1))
		return fmt.tprintf("case %v %.0f,%.0f: her %v px in the box, %v hidden (%.2f)", args[0], p.x, p.y, her, gone, f)
	}
	return USAGE
}
