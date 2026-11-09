package nengine

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

// Probes: pictures of a room taken from the harness, for checking who is
// drawn in front of what.
//
// Drawing order is the one thing in a room nobody can check by reading the
// file: a table painted into the backdrop has no feet line at all, so whoever
// walks behind it is drawn over it, and only a picture shows that. These
// bangs take the pictures, in the real draw (draw_room), hidden, many to a
// run:
//
//     !stand 400,520 [facing]      put her there, no walking
//     !put cook/2 315,487          move an object or a person (name/n: the nth
//                                  of that name in the file)
//     !show cook/2 | !show *       force one shown, or every non-person
//     !hide cook/2 | !hide people  force one hidden, or every person
//     !snap <name> [debug|marked]  the room as it stands
//     !crowd <name> [debug|marked] [grid] [around] [x,y[:facing=f][:as=char][:pose=p]]...
//                                  her at every point, all in one picture
//     !spots <name> [debug|marked] every person the file holds, at every spot
//                                  it gives them (their line, their routine),
//                                  whatever their when=
//     !strip <a> <b>|around [light=L] [people] [debug] [out=f.png]
//                                  neighbours as one picture, the way they
//                                  meet across a side (side.odin), for
//                                  checking the paint agrees at the seam
//     !depth off|on|check|time|at  the room's depth map (priority.odin)
//     !sheet <path> [cols=N] [scale=F]
//                                  the pictures that follow go on one contact
//                                  sheet, written at `!sheet end` (or the
//                                  next !sheet, or the end of the script)
//
// A crowd is one picture with her standing at every point at once. Each point
// is drawn on its own — the room as drawn with her there — and what she
// changed is copied onto the empty room, farthest first. So every copy of her
// is in front of exactly what the engine would put her in front of, and a
// picture shows forty places at a glance. Points that would overlap go on a
// picture of their own (`name 2/3`).
//
// `grid` is the floor every so often; `around` is behind, in front of and
// either side of every thing in the room with a picture or a block. `as=` puts
// another character's art on her for that point (a cutscene's mark, a ride's
// spot), `pose=` a part of it.
//
// `marked` keeps only that second picture.
//
// `debug` adds a second picture beside it: the floor's outline, blocks in red,
// every thing's feet line (yellow; cyan for depth=back, magenta for front,
// orange for a glow) with its name, and a cross at every point. Without a
// sheet open, <name> is the file a picture is written to; with one, its label.

@(private = "file")
Probe_Tile :: struct {
	image: rl.Image,
	label: string,
}

@(private = "file")
Probe_Sheet :: struct {
	path:  string,
	cols:  int,
	scale: f32,
	tiles: [dynamic]Probe_Tile,
	open:  bool,
}

@(private = "file")
probe_sheet: Probe_Sheet

@(private = "file")
probe_target: rl.RenderTexture2D

// A point a crowd stands somebody on: where, which way, as whom.
Probe_Point :: struct {
	pos:    [2]f32,
	facing: Facing,
	as:     string, // a character's name; "" for her own art
	pose:   string,
}

// How far apart two points must be to share a picture: one figure's width
// and most of its height, so nobody in a crowd covers anybody else.
PROBE_APART :: [2]f32{72, 150}

@(private)
probe_bang :: proc(w: ^World, word, arg: string) -> (reply: string, handled: bool) {
	switch word {
	case "stand", "put", "show", "hide", "snap", "crowd", "spots", "sheet", "strip", "people", "cutsnap", "depth":
	case:
		return "", false
	}
	sc := current_scene(w)
	if word == "people" do return people_here_text(sc), true
	args := strings.fields(arg, context.temp_allocator)
	if word == "depth" do return depth_bang(w, args), true // the depth and solid maps (priority.odin)
	if word == "strip" do return strip_bang(w, args), true
	if word == "cutsnap" do return cutsnap_bang(args), true

	switch word {
	case "stand":
		if len(args) < 1 do return "!stand x,y [facing]", true
		p, ok := parse_vec2(args[0])
		if !ok do return fmt.tprintf("%q is not x,y", args[0]), true
		w.player.pos = p
		w.player.moving = false
		w.player.walking = false
		w.player.heading = {}
		w.player.path_ready = false
		if len(args) > 1 do w.player.facing = parse_facing(args[1])
		return fmt.tprintf("standing at %.0f,%.0f%v", p.x, p.y, "" if point_in_polygon(p, sc.walk_area) else " (off the floor)"), true

	case "put":
		if len(args) < 2 do return "!put <object>[/n] x,y", true
		i := probe_object(sc, args[0])
		if i < 0 do return fmt.tprintf("no %v here", args[0]), true
		p, ok := parse_vec2(args[1])
		if !ok do return fmt.tprintf("%q is not x,y", args[1]), true
		sc.objects[i].pos = p
		sc.objects[i].actor.pos = p
		return fmt.tprintf("%v at %.0f,%.0f", args[0], p.x, p.y), true

	case "show", "hide":
		if len(args) < 1 do return fmt.tprintf("!%v <object>[/n] | * | people", word), true
		hide := word == "hide"
		n := 0
		switch args[0] {
		case "*":
			for &o in sc.objects do if !o.walks {o.hidden = hide; n += 1}
		case "people":
			for &o in sc.objects do if o.walks {o.hidden = hide; n += 1}
		case:
			i := probe_object(sc, args[0])
			if i < 0 do return fmt.tprintf("no %v here", args[0]), true
			sc.objects[i].hidden = hide
			n = 1
		}
		return fmt.tprintf("%v %v", "hidden" if hide else "shown", n), true

	case "sheet":
		probe_sheet_write()
		if len(args) < 1 || args[0] == "end" do return "sheet written", true
		probe_sheet = {path = strings.clone(args[0]), cols = 2, scale = 1, open = true}
		for a in args[1:] {
			if strings.has_prefix(a, "cols=") do probe_sheet.cols = max(1, strconv.parse_int(a[5:]) or_else 2)
			if strings.has_prefix(a, "scale=") do probe_sheet.scale = clamp(strconv.parse_f32(a[6:]) or_else 1, 0.1, 1)
		}
		return fmt.tprintf("sheet %v", args[0]), true
	}

	// The pictures.
	if len(args) < 1 do return fmt.tprintf("!%v <name> [debug] ...", word), true
	name := args[0]
	debug, only_marked := false, false
	points := make([dynamic]Probe_Point, context.temp_allocator)
	for a in args[1:] {
		switch a {
		case "debug":
			debug = true
		case "marked":
			debug, only_marked = true, true
		case "grid":
			probe_grid(sc, &points)
		case "around":
			probe_around(sc, &points)
		case:
			pt, ok := parse_probe_point(a)
			if !ok do return fmt.tprintf("%q is not a point (x,y[:facing=f][:as=char][:pose=p])", a), true
			append(&points, pt)
		}
	}

	switch word {
	case "snap":
		img := probe_render(w, sc, false)
		probe_out(w, sc, img, name, debug, only_marked, nil)
		return fmt.tprintf("snapped %v", name), true

	case "crowd":
		if len(points) == 0 do return "a crowd needs points: grid, around, or x,y", true
		layers := probe_layers(points[:])
		for layer, n in layers {
			img := probe_crowd(w, sc, layer)
			label := name
			if len(layers) > 1 {
				if probe_sheet.open {
					label = fmt.tprintf("%v %v/%v", name, n + 1, len(layers))
				} else {
					// A file each: x.png becomes x.1.png, x.2.png.
					dot := strings.last_index_byte(name, '.')
					stem, ext := name, ".png"
					if dot > 0 do stem, ext = name[:dot], name[dot:]
					label = fmt.tprintf("%v.%v%v", stem, n + 1, ext)
				}
			}
			probe_out(w, sc, img, label, debug, only_marked, layer)
		}
		return fmt.tprintf("%v point(s) in %v picture(s)", len(points), len(layers)), true

	case "spots":
		img, spots := probe_spots(w, sc)
		probe_out(w, sc, img, name, debug, only_marked, spots)
		return fmt.tprintf("%v spot(s)", len(spots)), true
	}
	return "", false
}

// `!strip a b [light=night] [people] [debug] [out=file.png]`, and `!strip a
// around`: neighbours drawn as one picture the way they meet, for checking
// that the paint agrees across a side (side.odin). East and west side by
// side, north above south; rooms that are not neighbours, side by side
// anyway. `around` is a room and its neighbour on every side, in a plus.
// People are left out unless `people`; `debug` draws each floor, each side's
// brink, and, every 64 px of a span, a line from where she leaves to where
// she lands. Into the open sheet, or `out=` (else strip_a_b.png).
@(private = "file")
strip_bang :: proc(w: ^World, args: []string) -> string {
	USAGE :: "!strip <room> <room>|around [light=day|sunset|night|sunrise] [people] [debug] [out=file.png]"
	if len(args) < 2 do return USAGE
	a, found := scene_index(w, args[0])
	if !found do return fmt.tprintf("no room called %q", args[0])
	around := args[1] == "around"
	light := w.light
	people, debug := false, false
	out := ""
	for x in args[2:] {
		switch {
		case x == "people": people = true
		case x == "debug":  debug = true
		case strings.has_prefix(x, "out="): out = x[4:]
		case strings.has_prefix(x, "light="):
			known := false
			for l in Light do if strings.equal_fold(fmt.tprint(l), x[6:]) do light, known = l, true
			if !known do return USAGE
		case: return USAGE
		}
	}
	STEP := [Compass][2]int{.North = {0, -1}, .East = {1, 0}, .South = {0, 1}, .West = {-1, 0}}
	Cell :: struct {
		room: int,
		at:   [2]int,
		side: int, // the side of `a` that leads here; -1 for `a` itself, or no side
	}
	cells := make([dynamic]Cell, context.temp_allocator)
	append(&cells, Cell{a, {0, 0}, -1})
	how := ""
	if around {
		for d in Compass {
			i := side_facing(&w.scenes[a], d, any = true)
			if i < 0 do continue
			to := w.scenes[a].sides[i].to
			if to >= 0 && to < len(w.scenes) do append(&cells, Cell{to, STEP[d], i})
		}
		how = fmt.tprintf("%v neighbour(s)", len(cells) - 1)
	} else {
		b, ok := scene_index(w, args[1])
		if !ok do return fmt.tprintf("no room called %q", args[1])
		cell := Cell{b, {1, 0}, -1}
		for s, i in w.scenes[a].sides do if s.to == b {
			cell.at, cell.side = STEP[s.dir], i
			break
		}
		append(&cells, cell)
		how = "not neighbours"
		if cell.side >= 0 do how = COMPASS_WORDS[w.scenes[a].sides[cell.side].dir]
	}
	lo, hi := [2]int{0, 0}, [2]int{0, 0}
	ch := i32(0)
	for c in cells {
		lo = {min(lo.x, c.at.x), min(lo.y, c.at.y)}
		hi = {max(hi.x, c.at.x), max(hi.y, c.at.y)}
		ch = max(ch, i32(room_height(&w.scenes[c.room])))
	}
	cw := WIDTH
	strip := rl.GenImageColor(i32(hi.x - lo.x + 1) * cw, i32(hi.y - lo.y + 1) * ch, {0, 0, 0, 255})
	origin :: proc(c: Cell, lo: [2]int, cw, ch: i32) -> [2]f32 {
		return {f32(i32(c.at.x - lo.x) * cw), f32(i32(c.at.y - lo.y) * ch)}
	}

	// Each room drawn as if she stood in it, in the one light, nobody about.
	saved_current, saved_light := w.current, w.light
	for c in cells {
		sc := &w.scenes[c.room]
		hid := make([]bool, len(sc.objects), context.temp_allocator)
		for &o, k in sc.objects {
			hid[k] = o.hidden
			if o.walks && !people do o.hidden = true
		}
		w.current, w.light = c.room, light
		img := probe_render(w, sc, false)
		w.current, w.light = saved_current, saved_light
		for &o, k in sc.objects do o.hidden = hid[k]
		at := origin(c, lo, cw, ch)
		rl.ImageDraw(&strip, img, {0, 0, f32(img.width), f32(img.height)}, {at.x, at.y, f32(img.width), f32(img.height)}, rl.WHITE)
		rl.UnloadImage(img)
	}

	if debug {
		line :: proc(img: ^rl.Image, p, q: [2]f32, col: rl.Color) {
			for d in ([3][2]f32{{0, 0}, {1, 0}, {0, 1}}) do rl.ImageDrawLineV(img, p + d, q + d, col)
		}
		for c in cells {
			sc := &w.scenes[c.room]
			at := origin(c, lo, cw, ch)
			n := len(sc.walk_area)
			for k in 0 ..< n do line(&strip, sc.walk_area[k] + at, sc.walk_area[(k + 1) % n] + at, {90, 220, 90, 255})
			for s in sc.sides {
				prev: [2]f32
				have := false
				for v := s.span[0]; v <= s.span[1] + 0.01; v += 8 {
					b, ok := side_brink(sc, s.dir, min(v, s.span[1]))
					if !ok {
						have = false
						continue
					}
					if have do line(&strip, prev + at, b + at, {80, 230, 230, 255})
					prev, have = b, true
				}
			}
		}
		// Where she leaves, and where she lands, across each seam.
		home := &w.scenes[a]
		home_at := origin(cells[0], lo, cw, ch)
		for c in cells[1:] {
			if c.side < 0 do continue
			s := home.sides[c.side]
			partner := side_partner(w, a, &home.sides[c.side])
			there := &w.scenes[c.room]
			there_at := origin(c, lo, cw, ch)
			for step := s.span[0]; step <= s.span[1] + 0.01; step += 64 {
				v := min(step, s.span[1])
				from, ok := side_brink(home, s.dir, v)
				if !ok do continue
				to := s.arrive
				if !s.has_arrive {
					if partner == nil do continue
					to = side_arrival(there, partner.dir, partner.span, span_map(v, s.span, partner.span))
				}
				line(&strip, from + home_at, to + there_at, {250, 220, 80, 255})
				rl.ImageDrawCircleV(&strip, to + there_at, 5, {250, 220, 80, 255})
			}
		}
	}

	name := out if out != "" else fmt.tprintf("strip_%v_%v.png", args[0], args[1])
	size := fmt.tprintf("%vx%v", strip.width, strip.height)
	if probe_sheet.open {
		append(&probe_sheet.tiles, Probe_Tile{strip, strings.clone(name)})
		return fmt.tprintf("strip %v %v (%v), %v, on the sheet", args[0], args[1], how, size)
	}
	wrote := rl.ExportImage(strip, strings.clone_to_cstring(name, context.temp_allocator))
	rl.UnloadImage(strip)
	if !wrote do return fmt.tprintf("could not write %v", name)
	return fmt.tprintf("strip %v %v (%v), %v -> %v", args[0], args[1], how, size, name)
}

// The sheet still open when the script ends is written then.
@(private)
probe_finish :: proc() {
	probe_sheet_write()
	if probe_target.id != 0 {
		rl.UnloadRenderTexture(probe_target)
		probe_target = {}
	}
}

// `cook` is the first object of that name; `cook/3` the third, counting the
// file's lines whatever their when= says.
@(private)
// `!people`: everybody drawn here now, by their lines' order: `name x,y`,
// the pose if any, and `(coming)` or `(going)` while they walk on or off
// through a side. "nobody" if there is nobody.
people_here_text :: proc(sc: ^Scene) -> string {
	b := strings.builder_make(context.temp_allocator)
	for o in sc.objects {
		if !o.walks || (o.hidden && !o.going) do continue
		if strings.builder_len(b) > 0 do strings.write_string(&b, "; ")
		at := o.going_from if o.going else o.coming_to if o.coming else o.actor.pos
		fmt.sbprintf(&b, "%v %.0f,%.0f", o.name, at.x, at.y)
		if o.actor.pose != "" do fmt.sbprintf(&b, " %v", o.actor.pose)
		if o.going do strings.write_string(&b, " (going)")
		if o.coming do strings.write_string(&b, " (coming)")
	}
	if strings.builder_len(b) == 0 do return "nobody"
	return strings.to_string(b)
}

probe_object :: proc(sc: ^Scene, spec: string) -> int {
	name, nth := spec, 1
	if slash := strings.index_byte(spec, '/'); slash > 0 {
		name = spec[:slash]
		nth = strconv.parse_int(spec[slash + 1:]) or_else 1
	}
	seen := 0
	for o, i in sc.objects do if o.name == name {
		seen += 1
		if seen == nth do return i
	}
	return -1
}

// `400,520`, `400,520:facing=left`, `640,560:as=fairbank:pose=sit`.
parse_probe_point :: proc(s: string) -> (pt: Probe_Point, ok: bool) {
	parts := strings.split(s, ":", context.temp_allocator)
	pt.pos = parse_vec2(parts[0]) or_return
	for kv in parts[1:] {
		eq := strings.index_byte(kv, '=')
		if eq <= 0 do return pt, false
		switch kv[:eq] {
		case "facing": pt.facing = parse_facing(kv[eq + 1:])
		case "as":     pt.as = kv[eq + 1:]
		case "pose":   pt.pose = kv[eq + 1:]
		case:          return pt, false
		}
	}
	return pt, true
}

// Points into pictures, so that no two in one picture are within
// PROBE_APART of each other: the first picture that has room, in the order
// given.
probe_layers :: proc(points: []Probe_Point, allocator := context.temp_allocator) -> [][]Probe_Point {
	layers := make([dynamic][dynamic]Probe_Point, allocator)
	next: for p in points {
		for &layer in layers {
			clash := false
			for q in layer {
				d := p.pos - q.pos
				if abs(d.x) < PROBE_APART.x && abs(d.y) < PROBE_APART.y {
					clash = true
					break
				}
			}
			if !clash {
				append(&layer, p)
				continue next
			}
		}
		layer := make([dynamic]Probe_Point, allocator)
		append(&layer, p)
		append(&layers, layer)
	}
	out := make([][]Probe_Point, len(layers), allocator)
	for l, i in layers do out[i] = l[:]
	return out
}

// Somewhere she could stand: on the floor and not in anything's block.
@(private)
probe_standable :: proc(sc: ^Scene, p: [2]f32) -> bool {
	return point_in_polygon(p, sc.walk_area) && !in_a_block(sc, p)
}

// The floor every so often, rows offset by half a step.
@(private = "file")
probe_grid :: proc(sc: ^Scene, points: ^[dynamic]Probe_Point) {
	if len(sc.walk_area) < 3 do return
	lo, hi := sc.walk_area[0], sc.walk_area[0]
	for v in sc.walk_area {
		lo = {min(lo.x, v.x), min(lo.y, v.y)}
		hi = {max(hi.x, v.x), max(hi.y, v.y)}
	}
	STEP :: [2]f32{96, 52}
	row := 0
	for y := lo.y + 10; y <= hi.y; y += STEP.y {
		off := STEP.x / 2 if row % 2 == 1 else 0
		for x := lo.x + 24 + off; x <= hi.x; x += STEP.x {
			if probe_standable(sc, {x, y}) do append(points, Probe_Point{pos = {x, y}})
		}
		row += 1
	}
}

// Behind, in front of and either side of every thing shown with a picture or
// a block: where a mistake in drawing order would show.
@(private = "file")
probe_around :: proc(sc: ^Scene, points: ^[dynamic]Probe_Point) {
	add :: proc(sc: ^Scene, points: ^[dynamic]Probe_Point, p: [2]f32) {
		if !probe_standable(sc, p) do return
		for q in points do if abs(q.pos.x - p.x) < 20 && abs(q.pos.y - p.y) < 14 do return
		append(points, Probe_Point{pos = p})
	}
	for o in sc.objects {
		if o.hidden || o.walks do continue
		x0, x1, front: f32
		back := f32(-1)
		if o.block.kind != .None {
			c := o.pos + o.block.offset
			x0, x1 = c.x - o.block.size.x / 2, c.x + o.block.size.x / 2
			back, front = c.y - o.block.size.y / 2, c.y + o.block.size.y / 2
		} else if o.sprite.texture.id != 0 && !o.glow && o.depth == .Normal {
			half := f32(o.sprite.frame_w) / 2
			x0, x1 = o.pos.x - half, o.pos.x + half
			front = o.pos.y + o.base
			back = front
		} else {
			continue
		}
		cx := (x0 + x1) / 2
		for dy in ([]f32{14, 40, 80}) {
			add(sc, points, {cx, back - dy})
			if x1 - x0 > 120 {
				add(sc, points, {x0 + 30, back - dy})
				add(sc, points, {x1 - 30, back - dy})
			}
		}
		for dy in ([]f32{14, 44}) do add(sc, points, {cx, front + dy})
		mid := (back + front) / 2
		add(sc, points, {x0 - 40, mid})
		add(sc, points, {x1 + 40, mid})
	}
}

// The room as draw_room draws it, read back: canvas size, cropped to the
// picture (the prompt's band is not the room).
@(private = "file")
probe_render :: proc(w: ^World, sc: ^Scene, player: bool) -> rl.Image {
	if probe_target.id == 0 do probe_target = rl.LoadRenderTexture(WIDTH, HEIGHT)
	// The tint's shader and textures are made on first use, and making a
	// render texture inside BeginTextureMode unbinds ours: make them first.
	ride_draw_setup()
	debug := w.debug
	w.debug = false
	rl.BeginTextureMode(probe_target)
	rl.ClearBackground(rl.BLACK)
	draw_room(w, sc, player)
	rl.EndTextureMode()
	w.debug = debug
	return probe_read(sc)
}

@(private = "file")
probe_read :: proc(sc: ^Scene) -> rl.Image {
	img := rl.LoadImageFromTexture(probe_target.texture)
	rl.ImageFlipVertical(&img)
	rl.ImageFormat(&img, .UNCOMPRESSED_R8G8B8A8)
	if h := i32(room_height(sc)); h < img.height do rl.ImageCrop(&img, {0, 0, f32(img.width), f32(h)})
	return img
}

// Whatever `with` has that `base` does not, copied onto `out`.
@(private = "file")
probe_paste :: proc(out, base, with: rl.Image) {
	o := ([^]rl.Color)(out.data)
	b := ([^]rl.Color)(base.data)
	m := ([^]rl.Color)(with.data)
	for i in 0 ..< int(out.width) * int(out.height) {
		if m[i] != b[i] do o[i] = m[i]
	}
}

// Her at every point, farthest first, in one picture.
@(private = "file")
probe_crowd :: proc(w: ^World, sc: ^Scene, points: []Probe_Point) -> rl.Image {
	saved := w.player
	defer w.player = saved
	base := probe_render(w, sc, false)
	defer rl.UnloadImage(base)
	out := rl.ImageCopy(base)
	order := slice.clone(points, context.temp_allocator)
	slice.sort_by(order, proc(a, b: Probe_Point) -> bool {return a.pos.y < b.pos.y})
	for p in order {
		w.player = saved
		w.player.pos = p.pos
		w.player.moving, w.player.walking = false, false
		w.player.facing = p.facing
		w.player.pose = p.pose
		w.player.anim = ""
		if p.as != "" && w.assets != nil {
			if art, found := &w.assets.chars[p.as]; found do w.player.character = art
		}
		img := probe_render(w, sc, true)
		probe_paste(out, base, img)
		rl.UnloadImage(img)
	}
	return out
}

// Every person the room's file holds, at their own line's spot and at every
// place their routine walks them, whatever their when= says; nobody else.
@(private = "file")
probe_spots :: proc(w: ^World, sc: ^Scene) -> (rl.Image, []Probe_Point) {
	Spot :: struct {
		obj: int,
		pos: [2]f32,
	}
	spots := make([dynamic]Spot, context.temp_allocator)
	hidden := make([]bool, len(sc.objects), context.temp_allocator)
	for &o, i in sc.objects {
		hidden[i] = o.hidden
		if !o.walks do continue
		o.hidden = true
		append(&spots, Spot{i, o.pos})
		for st in o.routine.steps do if st.kind == .Walk_To do append(&spots, Spot{i, st.to})
	}
	defer for &o, i in sc.objects do o.hidden = hidden[i]

	base := probe_render(w, sc, false)
	defer rl.UnloadImage(base)
	out := rl.ImageCopy(base)
	slice.sort_by(spots[:], proc(a, b: Spot) -> bool {return a.pos.y < b.pos.y})
	marks := make([]Probe_Point, len(spots), context.temp_allocator)
	for s, n in spots {
		o := &sc.objects[s.obj]
		was := o.pos
		o.pos, o.actor.pos = s.pos, s.pos
		o.hidden = false
		img := probe_render(w, sc, false)
		probe_paste(out, base, img)
		rl.UnloadImage(img)
		o.hidden = true
		o.pos, o.actor.pos = was, was
		marks[n] = {pos = s.pos, as = o.name}
	}
	return out, marks
}

// A picture to its file, or onto the open sheet; with `debug`, its marked
// copy after it.
@(private = "file")
probe_out :: proc(w: ^World, sc: ^Scene, img: rl.Image, name: string, debug, only_marked: bool, points: []Probe_Point) {
	marked: rl.Image
	if debug do marked = probe_marked(w, sc, img, points)
	if probe_sheet.open {
		if !only_marked do append(&probe_sheet.tiles, Probe_Tile{img, strings.clone(name)})
		else do rl.UnloadImage(img)
		if debug do append(&probe_sheet.tiles, Probe_Tile{marked, strings.concatenate({name, " (marked)"}) if !only_marked else strings.clone(name)})
		return
	}
	if !only_marked do rl.ExportImage(img, strings.clone_to_cstring(name, context.temp_allocator))
	rl.UnloadImage(img)
	if debug {
		dot := strings.last_index_byte(name, '.')
		stem := name[:dot] if dot > 0 else name
		rl.ExportImage(marked, strings.clone_to_cstring(fmt.tprintf("%v.marked.png", stem), context.temp_allocator))
		rl.UnloadImage(marked)
	}
}

// The picture with the room's workings drawn faintly over it. Marks for
// reading, not art: lines and labels over a copy.
@(private = "file")
probe_marked :: proc(w: ^World, sc: ^Scene, img: rl.Image, points: []Probe_Point) -> rl.Image {
	tex := rl.LoadTextureFromImage(img)
	defer rl.UnloadTexture(tex)
	if probe_target.id == 0 do probe_target = rl.LoadRenderTexture(WIDTH, HEIGHT)
	rl.BeginTextureMode(probe_target)
	rl.ClearBackground(rl.BLACK)
	rl.DrawTexture(tex, 0, 0, rl.WHITE)

	label :: proc(text: string, x, y: f32, c: rl.Color) {
		t := strings.clone_to_cstring(text, context.temp_allocator)
		rl.DrawText(t, i32(x) + 1, i32(y) + 1, 10, {0, 0, 0, 220})
		rl.DrawText(t, i32(x), i32(y), 10, c)
	}

	area := sc.walk_area
	for i in 0 ..< len(area) do rl.DrawLineEx(area[i], area[(i + 1) % len(area)], 2, {0, 255, 80, 150})
	for e in sc.exits do if !e.hidden do rl.DrawRectangleLinesEx(e.area, 1, {80, 140, 255, 150})
	for o in sc.objects {
		if o.hidden do continue
		if o.block.kind == .Box {
			c := o.pos + o.block.offset
			r := rl.Rectangle{c.x - o.block.size.x / 2, c.y - o.block.size.y / 2, o.block.size.x, o.block.size.y}
			rl.DrawRectangleRec(r, {255, 0, 0, 45})
			rl.DrawRectangleLinesEx(r, 1, {255, 60, 60, 170})
		} else if o.block.kind == .Oval {
			c := o.pos + o.block.offset
			rl.DrawEllipse(i32(c.x), i32(c.y), o.block.size.x / 2, o.block.size.y / 2, {255, 0, 0, 45})
			rl.DrawEllipseLines(i32(c.x), i32(c.y), o.block.size.x / 2, o.block.size.y / 2, {255, 60, 60, 170})
		}
		if o.walks do continue // a person's line is the cross at their feet
		half := f32(o.sprite.frame_w) / 2 if o.sprite.texture.id != 0 else 24
		if o.lit.painted != {} do half = max(half, f32(o.lit.by[room_light(w, sc)].frame_w) / 2)
		if o.sprite.texture.id == 0 && o.lit.painted == {} && o.block.kind == .None do continue
		feet := o.pos.y + o.base
		c := rl.Color{255, 230, 0, 210}
		tag := ""
		switch {
		case o.glow:
			c, tag = {255, 150, 0, 210}, " glow"
		case o.depth == .Back:
			c, tag = {0, 210, 255, 210}, " back"
		case o.depth == .Front:
			c, tag = {255, 0, 255, 210}, " front"
		}
		if o.depth == .Normal {
			rl.DrawLineEx({o.pos.x - half, feet}, {o.pos.x + half, feet}, 2, c)
		} else {
			// Back and front sort by no line: dashes along the picture's foot.
			for x := o.pos.x - half; x < o.pos.x + half; x += 12 do rl.DrawLineEx({x, o.pos.y}, {min(x + 6, o.pos.x + half), o.pos.y}, 2, c)
		}
		if o.base != 0 do rl.DrawLineEx({o.pos.x, o.pos.y}, {o.pos.x, feet}, 1, c)
		based := fmt.tprintf(" base=%v", o.base) if o.base != 0 else ""
		label(fmt.tprintf("%v%v%v", o.name, tag, based), o.pos.x - half, (feet if o.depth == .Normal else o.pos.y) - 12, c)
	}
	for p in points {
		rl.DrawLineEx(p.pos - {7, 0}, p.pos + {7, 0}, 2, rl.WHITE)
		rl.DrawLineEx(p.pos - {0, 7}, p.pos + {0, 7}, 2, rl.WHITE)
		text := fmt.tprintf("%.0f,%.0f", p.pos.x, p.pos.y)
		if p.as != "" do text = fmt.tprintf("%v %v", p.as, text)
		label(text, p.pos.x + 5, p.pos.y + 3, rl.WHITE)
	}
	rl.EndTextureMode()
	return probe_read(sc)
}

// The open sheet, tiled and labelled, to its file.
@(private = "file")
probe_sheet_write :: proc() {
	sh := &probe_sheet
	if !sh.open do return
	defer {
		for t in sh.tiles {
			rl.UnloadImage(t.image)
			delete(t.label)
		}
		delete(sh.tiles)
		delete(sh.path)
		sh^ = {}
	}
	if len(sh.tiles) == 0 do return
	tw, th: i32
	for t in sh.tiles {
		tw = max(tw, i32(f32(t.image.width) * sh.scale))
		th = max(th, i32(f32(t.image.height) * sh.scale))
	}
	GAP :: 8
	cols := i32(min(sh.cols, len(sh.tiles)))
	rows := (i32(len(sh.tiles)) + cols - 1) / cols
	sheet := rl.GenImageColor(cols * tw + (cols + 1) * GAP, rows * th + (rows + 1) * GAP, {36, 36, 40, 255})
	defer rl.UnloadImage(sheet)
	for t, n in sh.tiles {
		x := GAP + i32(n) % cols * (tw + GAP)
		y := GAP + i32(n) / cols * (th + GAP)
		img := rl.ImageCopy(t.image)
		if sh.scale != 1 do rl.ImageResize(&img, i32(f32(img.width) * sh.scale), i32(f32(img.height) * sh.scale))
		rl.ImageDraw(&sheet, img, {0, 0, f32(img.width), f32(img.height)}, {f32(x), f32(y), f32(img.width), f32(img.height)}, rl.WHITE)
		rl.UnloadImage(img)
		text := strings.clone_to_cstring(t.label, context.temp_allocator)
		size := i32(20)
		rl.ImageDrawRectangle(&sheet, x, y, rl.MeasureText(text, size) + 12, size + 6, {0, 0, 0, 200})
		rl.ImageDrawText(&sheet, text, x + 6, y + 3, size, rl.WHITE)
	}
	if !rl.ExportImage(sheet, strings.clone_to_cstring(sh.path, context.temp_allocator)) do fmt.eprintfln("could not write %v", sh.path)
}


// --- `!cutsnap`: a cutscene, looked at part way ---

// `!cutsnap <cut> <secs>...`: when the harness next plays that cutscene out
// (cutscene_aloud), the room is snapped as drawn, with her in it, as its own
// clock passes each of those seconds: <cut>_<secs>.png in the working folder
// (a time past its end, at its last frame). The harness plays a cut in
// steps of a sixtieth of a second, so the pictures are the same however fast
// the machine draws; a --shot of a held cut is not.
@(private = "file")
Probe_Cut :: struct {
	name:  string,
	times: [dynamic]f32,
}

@(private = "file")
probe_cut: Probe_Cut

// The words after `!cutsnap`: the cut's name and the seconds, in order.
parse_cutsnap :: proc(args: []string, allocator := context.allocator) -> (name: string, times: [dynamic]f32, ok: bool) {
	if len(args) < 2 do return "", nil, false
	times = make([dynamic]f32, allocator)
	for a in args[1:] {
		t, good := strconv.parse_f32(a)
		if !good || t < 0 {
			delete(times)
			return "", nil, false
		}
		append(&times, t)
	}
	slice.sort(times[:])
	return args[0], times, true
}

@(private = "file")
cutsnap_bang :: proc(args: []string) -> string {
	name, times, ok := parse_cutsnap(args)
	if !ok do return "!cutsnap <cut> <secs> [secs...]"
	delete(probe_cut.name)
	delete(probe_cut.times)
	probe_cut = {strings.clone(name), times}
	return fmt.tprintf("%v snapped at %v s when it plays", name, args[1:])
}

// After each frame of a cutscene the harness plays out, and once at its end
// (`last`): the snaps of it that are due.
@(private)
probe_cut_frame :: proc(w: ^World, last := false) {
	if w.cut.cut == nil || probe_cut.name != w.cut.cut.name do return
	for len(probe_cut.times) > 0 && (last || w.cut.t >= probe_cut.times[0]) {
		t := probe_cut.times[0]
		ordered_remove(&probe_cut.times, 0)
		if w.cut.scene < 0 || w.cut.scene >= len(w.scenes) do continue
		sc := &w.scenes[w.cut.scene]
		img := probe_render(w, sc, true)
		probe_out(w, sc, img, fmt.tprintf("%v_%v.png", probe_cut.name, t), false, false, nil)
	}
}
