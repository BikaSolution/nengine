package nengine

import "core:container/priority_queue"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

// Sierra's two hidden screens, for a painted room.
//
// SCI drew every room three times: the picture you see, a PRIORITY screen and
// a CONTROL screen. The priority screen said, for every pixel, how near the
// camera the thing painted there stands; a person was drawn behind any pixel
// nearer than their own feet. The control screen said where the floor was
// blocked. A table painted into the backdrop then hides whoever walks behind
// it and stops whoever walks into it, with no object, no `base` and no `block`
// in the scene file at all. These are the two, as files beside the backdrop:
//
//     tent_row.sprite     the picture (and .sunset, .night, .sunrise)
//     tent_row.depth      DEPTH: per art pixel, the feet line of what is seen there
//     tent_row.solid      SOLID: per art pixel, whether the floor there is taken
//
// Both are optional and both are found by name: a scene whose `bg` is
// tent_row takes tent_row.depth and tent_row.solid if they are there. A
// scene can name others, or none (`depth_map none`, `solid_map none`). One
// depth map serves all four lights: the paintings differ, the room does not.
// With neither file a room is drawn and walked exactly as it was before.
//
// **Depth.** Each art pixel holds a canvas y: the line on the floor where the
// surface seen at that pixel stands, which is the line a person standing just
// as near would have their feet on. A wall's every pixel holds the line along
// its foot; a roof's, the line straight below it; the ground holds nothing
// (it hides nobody). Drawing a person, or any thing at depth=normal, every
// pixel of theirs over a depth deeper down the screen than their feet (a
// larger y: nearer the camera) is not drawn, so the backdrop shows through
// there, and they are behind the wall. A tie is theirs: feet on the line
// are in front of it. Things at depth=back and depth=front, somebody passing
// a window outside, and a thing marked `whole=true` are never hidden.
//
// The test is done by the GPU, in the shader each draw already goes through
// (plain, tinted for the light, or through a ride's camera): the vertex
// shader passes the canvas position, and the fragment shader looks the depth
// up at the art pixel the backdrop has there and discards. depth_hides is the
// same sum on the CPU, for the tools and the tests.
//
// **A thing with depth of its own.** A sprite can have its own `.depth`
// (tent_row_gate_open.depth beside tent_row_gate_open.sprite): the same rows,
// one per art pixel of a frame, each the feet line of that pixel measured from
// the thing's own `pos` (so it moves with it). A long thing seen at an angle
// — a fence, a godown at 35°, a tent turned 22° — is then one thing that is
// in front of a person at one end and behind them at the other. Such a thing
// is drawn whole (it is the nearest thing at its own pixels: the art tool cut
// it so), at the farthest line it has, and stamped into the room's depth
// while it is shown, so everybody else is hidden by its pixels as they are by
// the backdrop's. Hidden, it is unstamped. Its `base` is not used.
//
// **Solid.** Each art pixel is free or taken. A taken pixel is floor nobody
// steps onto: walking stops at it, paths go round it (a grid search, pulled
// tight, instead of the polygon's corners), a click on it walks her to the
// nearest floor she can reach and be seen on (stand_spot). It adds to the walk polygon and to the objects' `block`s;
// it replaces neither. Stepping out of it is always allowed, as with a block,
// so nobody put down inside one is stuck. An exit's patch and every thing's
// walk_to (a few pixels round it) are cleared out of it when the room loads,
// so a door is still a door and every interaction point can be stood on.
//
// **The files.** Text, one line per art row, top first, run-length coded:
// `v*n` is n pixels of v, a bare `v` one. In a .depth file `.` is nothing (no
// feet line) and a number is a canvas y; in a .solid file `.` is free floor
// and `X` is taken (not `#`: a line starting with one is a comment). A header gives the size:
//
//     depth tent_row               solid tent_row
//     size 320 200                 size 320 200
//     .*320                        .*320
//     .*57 412*30 .*233            .*120 X*36 .*164
//
// A game's art tools write them from their own model of the room, where
// the floor line of every pixel is known exactly; a hand can fix one in a text editor.

// A depth map, per art pixel of a backdrop or of one frame of a sprite.
Depth_Map :: struct {
	w, h:    i32,
	feet:    []i16,          // canvas y; DEPTH_NONE where nothing stands
	tiles:   []i16,          // the deepest feet in each DEPTH_TILE square, for a quick no
	tw, th:  i32,
	texture: rl.Texture2D,   // feet as two bytes (r low, g high) for the shader; 0 without a window
	lo, hi:  i16,            // the shallowest and deepest feet in it; lo > hi when empty
}

// A solid map, per art pixel of a backdrop.
Solid_Map :: struct {
	w, h:  i32,
	taken: []bool,
}

DEPTH_NONE :: min(i16)
@(private) DEPTH_TILE :: i32(8)

// How far round a walk_to the solid map is cleared when a room loads.
@(private) SOLID_CLEAR :: f32(8)

// --- The files ---

// A depth map from a .depth file's text. Relative maps (a sprite's) may hold
// negative numbers.
parse_depth_map :: proc(text: string, allocator := context.allocator) -> (m: Depth_Map, ok: bool) {
	rows, w, h := map_rows(text, "depth") or_return
	m.w, m.h = w, h
	m.feet = make([]i16, int(w) * int(h), allocator)
	for &v in m.feet do v = DEPTH_NONE
	for line, y in rows {
		x := 0
		row := line
		for tok in strings.fields_iterator(&row) {
			val, n := tok, 1
			if star := strings.index_byte(tok, '*'); star >= 0 {
				val = tok[:star]
				n = strconv.parse_int(tok[star + 1:]) or_return
			}
			v := DEPTH_NONE
			if val != "." {
				i := strconv.parse_int(val) or_return
				v = i16(clamp(i, int(min(i16)) + 1, int(max(i16))))
			}
			for _ in 0 ..< n {
				if x >= int(w) do return {}, false
				m.feet[y * int(w) + x] = v
				x += 1
			}
		}
	}
	depth_map_summarise(&m, allocator)
	return m, true
}

// A solid map from a .solid file's text.
parse_solid_map :: proc(text: string, allocator := context.allocator) -> (m: Solid_Map, ok: bool) {
	rows, w, h := map_rows(text, "solid") or_return
	m.w, m.h = w, h
	m.taken = make([]bool, int(w) * int(h), allocator)
	for line, y in rows {
		x := 0
		row := line
		for tok in strings.fields_iterator(&row) {
			val, n := tok, 1
			if star := strings.index_byte(tok, '*'); star >= 0 {
				val = tok[:star]
				n = strconv.parse_int(tok[star + 1:]) or_return
			} else if len(tok) > 1 && strings.count(tok, tok[:1]) == len(tok) {
				// A row written out longhand, `....XXX..`, a picture of the floor.
				val, n = tok[:1], len(tok)
			}
			if val != "." && val != "X" do return {}, false
			for _ in 0 ..< n {
				if x >= int(w) do return {}, false
				m.taken[y * int(w) + x] = val == "X"
				x += 1
			}
		}
	}
	return m, true
}

// The header and the data rows of either file: `<kind> <name>`, `size w h`,
// then exactly h rows.
@(private = "file")
map_rows :: proc(text, kind: string) -> (rows: []string, w, h: i32, ok: bool) {
	lines := data_lines(text)
	out := make([dynamic]string, context.temp_allocator)
	for line in lines {
		l := parse_line(line)
		switch {
		case l.key == kind:
		case l.key == "size" && len(l.words) == 2:
			w = i32(strconv.parse_int(l.words[0]) or_return)
			h = i32(strconv.parse_int(l.words[1]) or_return)
		case:
			append(&out, line)
		}
	}
	if w <= 0 || h <= 0 || len(out) != int(h) do return nil, 0, 0, false
	return out[:], w, h, true
}

// A depth map as file text.
depth_map_text :: proc(m: Depth_Map, name: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "depth %v\nsize %v %v\n", name, m.w, m.h)
	for y in 0 ..< m.h {
		run_v, run_n := DEPTH_NONE, 0
		first := true
		flush :: proc(b: ^strings.Builder, v: i16, n: int, first: ^bool) {
			if n == 0 do return
			if !first^ do strings.write_byte(b, ' ')
			first^ = false
			if v == DEPTH_NONE do strings.write_byte(b, '.')
			else do fmt.sbprintf(b, "%v", v)
			if n > 1 do fmt.sbprintf(b, "*%v", n)
		}
		for x in 0 ..< m.w {
			v := m.feet[y * m.w + x]
			if v == run_v || run_n == 0 {
				run_v = v
				run_n += 1
				continue
			}
			flush(&b, run_v, run_n, &first)
			run_v, run_n = v, 1
		}
		flush(&b, run_v, run_n, &first)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// The deepest feet in each tile, and the range: worked out once.
@(private)
depth_map_summarise :: proc(m: ^Depth_Map, allocator := context.allocator) {
	m.tw = (m.w + DEPTH_TILE - 1) / DEPTH_TILE
	m.th = (m.h + DEPTH_TILE - 1) / DEPTH_TILE
	if m.tiles == nil do m.tiles = make([]i16, int(m.tw) * int(m.th), allocator)
	for &t in m.tiles do t = DEPTH_NONE
	m.lo, m.hi = max(i16), min(i16)
	for y in 0 ..< m.h {
		for x in 0 ..< m.w {
			v := m.feet[y * m.w + x]
			if v == DEPTH_NONE do continue
			t := &m.tiles[(y / DEPTH_TILE) * m.tw + x / DEPTH_TILE]
			t^ = max(t^, v)
			m.lo = min(m.lo, v)
			m.hi = max(m.hi, v)
		}
	}
}

depth_map_destroy :: proc(m: ^Depth_Map) {
	if m.texture.id != 0 do rl.UnloadTexture(m.texture)
	delete(m.feet)
	delete(m.tiles)
	m^ = {}
}

solid_map_destroy :: proc(m: ^Solid_Map) {
	delete(m.taken)
	m^ = {}
}

// The map's texture for the shader, made (or brought up to date) now. Needs a
// window; without one it stays 0 and nothing is masked.
@(private)
depth_map_upload :: proc(m: ^Depth_Map) {
	if !rl.IsWindowReady() || m.w <= 0 do return
	px := make([]rl.Color, int(m.w) * int(m.h), context.temp_allocator)
	for v, i in m.feet {
		u := u16(max(v, 0)) if v != DEPTH_NONE else 0
		px[i] = {u8(u & 255), u8(u >> 8), 0, 255}
	}
	if m.texture.id == 0 {
		img := rl.Image{data = raw_data(px), width = m.w, height = m.h, mipmaps = 1, format = .UNCOMPRESSED_R8G8B8A8}
		m.texture = rl.LoadTextureFromImage(img)
		rl.SetTextureFilter(m.texture, .POINT)
		return
	}
	rl.UpdateTexture(m.texture, raw_data(px))
}

// --- Asking them ---

// The art pixel the backdrop shows at canvas column (or row) c: the one
// round(a*scale) put there, as sprite_source and the `up` shader find it.
art_at :: proc(c: f32, scale: f32) -> i32 {
	return i32(math.ceil((math.floor(c) + 0.5) / scale)) - 1
}

// The feet line of what the backdrop shows at canvas point p, or DEPTH_NONE.
depth_at :: proc(m: Depth_Map, scale: f32, p: [2]f32) -> i16 {
	if m.w <= 0 do return DEPTH_NONE
	x, y := art_at(p.x, scale), art_at(p.y, scale)
	if x < 0 || y < 0 || x >= m.w || y >= m.h do return DEPTH_NONE
	return m.feet[y * m.w + x]
}

// Is a pixel at canvas point p, of somebody whose feet are on `feet`, behind
// what is painted there? What the shader decides, on the CPU.
depth_hides :: proc(m: Depth_Map, scale: f32, p: [2]f32, feet: f32) -> bool {
	d := depth_at(m, scale, p)
	return d != DEPTH_NONE && f32(d) > feet
}

// Could anything in this canvas rectangle hide somebody with these feet? A
// quick no from the tiles, so most draws skip the mask's shader.
depth_could_hide :: proc(m: Depth_Map, scale: f32, r: rl.Rectangle, feet: f32) -> bool {
	if m.w <= 0 || m.hi == min(i16) || f32(m.hi) <= feet do return false
	x0 := max(art_at(r.x, scale), 0) / DEPTH_TILE
	y0 := max(art_at(r.y, scale), 0) / DEPTH_TILE
	x1 := min(art_at(r.x + r.width, scale), m.w - 1) / DEPTH_TILE
	y1 := min(art_at(r.y + r.height, scale), m.h - 1) / DEPTH_TILE
	for ty in y0 ..= y1 {
		for tx in x0 ..= x1 {
			if t := m.tiles[ty * m.tw + tx]; t != DEPTH_NONE && f32(t) > feet do return true
		}
	}
	return false
}

// Is the floor at canvas point p taken?
solid_at :: proc(sc: ^Scene, p: [2]f32) -> bool {
	m := sc.solid_map
	if m.w <= 0 || sc.map_scale <= 0 || solid_maps_off do return false
	x, y := art_at(p.x, sc.map_scale), art_at(p.y, sc.map_scale)
	if x < 0 || y < 0 || x >= m.w || y >= m.h do return false
	return m.taken[y * m.w + x]
}

// --- A room's maps ---

// Joins a room to its maps once it has loaded: the backdrop's own by name, or
// those its file names; the scale they are at (the backdrop's); and the
// solid map cleared at its exits and every walk_to (scene_maps_clear).
scene_attach_maps :: proc(s: ^Scene, assets: ^Assets) {
	if assets == nil do return
	// NENGINE_NO_MAPS=1: every room as it was before the maps, for a before-and-after.
	if os.get_env("NENGINE_NO_MAPS", context.temp_allocator) != "" do return
	_, _, scale := sprite_native(s.background)
	if s.background.texture.id == 0 && s.background.frame_w == 0 do scale = 1
	s.map_scale = scale
	depth_name := s.depth_name if s.depth_named else s.background_name
	solid_name := s.solid_name if s.solid_named else s.background_name
	if depth_name != "" && depth_name != "none" {
		if m, found := assets.depths[depth_name]; found do s.depth_map = m
	}
	if solid_name != "" && solid_name != "none" {
		if m, found := assets.solids[solid_name]; found {
			s.solid_map = {m.w, m.h, make([]bool, len(m.taken))}
			copy(s.solid_map.taken, m.taken)
			s.owns_solid = true
		}
	}
	for &o in s.objects {
		if o.sprite_name == "" do continue
		if m, found := &assets.depths[o.sprite_name]; found do o.own_depth = m
	}
	scene_maps_clear(s)
}

// Clears the solid map where somebody must be able to stand: in every exit's
// patch, and round every walk_to, whatever their when=; and from each a lane
// to the nearest free floor (solid_carve), so a door painted into a wall or a
// walk_to at a counter is never an island inside what is taken round it. A
// side is a way across if any of it is: a brink on free floor is a pocket
// joined to the floor as a spot is, and lanes are carved from the painted-over
// brinks only when the whole side is painted over (a gate the model has shut,
// a rail along the edge of the picture), from each, as before. Not while any
// of it is open: a side running behind a tent would carve a lane along the
// strip behind it, floor she stands on hidden, closed in the map on purpose.
scene_maps_clear :: proc(s: ^Scene) {
	m := &s.solid_map
	if m.w <= 0 || s.map_scale <= 0 do return
	clear_rect :: proc(m: ^Solid_Map, scale: f32, r: rl.Rectangle) {
		x0, y0 := max(art_at(r.x, scale), 0), max(art_at(r.y, scale), 0)
		x1, y1 := min(art_at(r.x + r.width, scale), m.w - 1), min(art_at(r.y + r.height, scale), m.h - 1)
		for y in y0 ..= y1 do for x in x0 ..= x1 do m.taken[y * m.w + x] = false
	}
	for e in s.exits do clear_rect(m, s.map_scale, e.area)
	for o in s.objects {
		if o.walk_to == {} do continue
		r := SOLID_CLEAR
		clear_rect(m, s.map_scale, {o.walk_to.x - r, o.walk_to.y - r / 2, 2 * r, r})
	}
	main := solid_main_floor(s)
	for e in s.exits do solid_carve(s, main, rect_center(e.area))
	for o in s.objects do if o.walk_to != {} do solid_carve(s, main, o.walk_to)
	// Every side's brink, every 16 px along its span.
	for sd in s.sides {
		brinks := make([dynamic][2]f32, context.temp_allocator)
		open := false
		for c := sd.span[0]; c <= sd.span[1] + 0.01; c += 16 {
			b, ok := side_brink(s, sd.dir, min(c, sd.span[1]))
			if !ok do continue
			append(&brinks, b)
			if !solid_at(s, b) {
				open = true
				solid_carve(s, main, b)
			}
		}
		if !open do for b in brinks do solid_carve(s, main, b)
	}
}

// The free floor's biggest piece (on the polygon, not taken): where she can
// walk. A lane is carved to it, not to a pocket cut off beside a door.
@(private)
solid_main_floor :: proc(s: ^Scene) -> []bool {
	m := &s.solid_map
	W, H := int(m.w), int(m.h)
	free := make([]bool, W * H, context.temp_allocator)
	for c in 0 ..< W * H {
		x, y := i32(c % W), i32(c / W)
		p := [2]f32{f32(art_edge(x, s.map_scale) + art_edge(x + 1, s.map_scale)) / 2, f32(art_edge(y, s.map_scale) + art_edge(y + 1, s.map_scale)) / 2}
		free[c] = !m.taken[c] && point_in_polygon(p, s.walk_area)
	}
	label := make([]i32, W * H, context.temp_allocator)
	best, best_n := i32(0), 0
	queue := make([dynamic]int, 0, 1024, context.temp_allocator)
	next := i32(0)
	for c in 0 ..< W * H {
		if !free[c] || label[c] != 0 do continue
		next += 1
		label[c] = next
		clear(&queue)
		append(&queue, c)
		for head := 0; head < len(queue); head += 1 {
			u := queue[head]
			ux, uy := u % W, u / W
			for d in ([4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
				nx, ny := ux + d.x, uy + d.y
				if nx < 0 || ny < 0 || nx >= W || ny >= H do continue
				n := ny * W + nx
				if free[n] && label[n] == 0 {
					label[n] = next
					append(&queue, n)
				}
			}
		}
		if len(queue) > best_n do best, best_n = next, len(queue)
	}
	out := make([]bool, W * H, context.temp_allocator)
	for c in 0 ..< W * H do out[c] = best != 0 && label[c] == best
	return out
}

// From a spot (or from whichever of several is nearest), the shortest way to
// the main free floor (solid_main_floor), cleared three art pixels wide:
// taken floor on the way is freed.
@(private)
solid_carve :: proc(s: ^Scene, main: []bool, from: ..[2]f32) {
	m := &s.solid_map
	W, H := int(m.w), int(m.h)
	centre :: proc(c, W: int, scale: f32) -> [2]f32 {
		x, y := i32(c % W), i32(c / W)
		return {f32(art_edge(x, scale) + art_edge(x + 1, scale)) / 2, f32(art_edge(y, scale) + art_edge(y + 1, scale)) / 2}
	}
	prev := make([]i32, W * H, context.temp_allocator)
	for &p in prev do p = -2
	queue := make([dynamic]int, 0, 256, context.temp_allocator)
	for f in from {
		sx := clamp(int(art_at(f.x, s.map_scale)), 0, W - 1)
		sy := clamp(int(art_at(f.y, s.map_scale)), 0, H - 1)
		start := sy * W + sx
		if prev[start] != -2 do continue
		prev[start] = -1
		append(&queue, start)
	}
	found := -1
	for head := 0; head < len(queue) && head < 20000; head += 1 {
		c := queue[head]
		if main[c] {
			found = c
			break
		}
		cx, cy := c % W, c / W
		// Over the floor: once on the polygon a lane stays on it (one off it is
		// walked by nobody); from a spot off it (a door below the floor's edge)
		// it may cross off the floor to reach it.
		on := point_in_polygon(centre(c, W, s.map_scale), s.walk_area)
		for d in ([4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
			nx, ny := cx + d.x, cy + d.y
			if nx < 0 || ny < 0 || nx >= W || ny >= H do continue
			n := ny * W + nx
			if prev[n] != -2 do continue
			if on && !point_in_polygon(centre(n, W, s.map_scale), s.walk_area) do continue
			prev[n] = i32(c)
			append(&queue, n)
		}
	}
	if found < 0 do return
	for c := found; c >= 0; c = int(prev[c]) {
		cx, cy := c % W, c / W
		for j in -1 ..= 1 do for i in -1 ..= 1 {
			x, y := cx + i, cy + j
			if x >= 0 && y >= 0 && x < W && y < H do m.taken[y * W + x] = false
		}
	}
}

// Frees what a room owns of its maps (the stamped depth, a cleared solid map).
scene_maps_destroy :: proc(s: ^Scene) {
	if s.owns_solid do solid_map_destroy(&s.solid_map)
	depth_map_destroy(&s.depth_live)
	delete(s.depth_stamped)
	s.solid_map = {}
	s.owns_solid = false
	s.depth_stamped = nil
}

// The farthest feet line a thing with its own depth has, on the canvas: the
// line it is drawn at.
own_depth_line :: proc(o: ^Object) -> f32 {
	if o.own_depth == nil || o.own_depth.lo > o.own_depth.hi do return o.pos.y + o.base
	return o.pos.y + f32(o.own_depth.lo)
}

// The room's depth as it stands now: the backdrop's, with every thing that
// has depth of its own and is shown stamped in, farthest first. Remade only
// when what is shown changes.
@(private)
scene_depth_now :: proc(sc: ^Scene) -> ^Depth_Map {
	any_own := false
	for &o in sc.objects do if o.own_depth != nil {
		any_own = true
		break
	}
	if !any_own || sc.depth_map.w <= 0 do return &sc.depth_map
	// What is stamped: which things, where. The same as last time, the same map.
	key := make([dynamic][3]f32, context.temp_allocator)
	for &o, i in sc.objects {
		if o.own_depth == nil || o.hidden do continue
		append(&key, [3]f32{f32(i), o.pos.x, o.pos.y})
	}
	same := sc.depth_live.w > 0 && len(key) == len(sc.depth_stamped)
	if same do for k, i in key do if k != sc.depth_stamped[i] {
		same = false
		break
	}
	if same do return &sc.depth_live

	m := &sc.depth_live
	base := sc.depth_map
	if m.w != base.w || m.h != base.h {
		depth_map_destroy(m)
		m.w, m.h = base.w, base.h
		m.feet = make([]i16, len(base.feet))
	}
	copy(m.feet, base.feet)
	order := make([dynamic]int, context.temp_allocator)
	for k in key do append(&order, int(k[0]))
	for a in 1 ..< len(order) {
		for b := a; b > 0 && own_depth_line(&sc.objects[order[b]]) < own_depth_line(&sc.objects[order[b - 1]]); b -= 1 {
			order[b], order[b - 1] = order[b - 1], order[b]
		}
	}
	for i in order do depth_stamp(m, sc.map_scale, &sc.objects[i])
	depth_map_summarise(m)
	depth_map_upload(m)
	delete(sc.depth_stamped)
	sc.depth_stamped = make([][3]f32, len(key))
	copy(sc.depth_stamped, key[:])
	return m
}

// One thing's own depth into the room's, at the art pixels it is drawn on
// (draw_sprite_on_grid): the feet of every pixel it paints, and nothing (no
// feet) where it paints a pixel with none. Its sprite must be at the
// backdrop's scale; at any other it is not stamped.
@(private)
depth_stamp :: proc(m: ^Depth_Map, scale: f32, o: ^Object) {
	own := o.own_depth
	sw, sh, sscale := sprite_native(o.sprite)
	if own == nil || own.w != sw || own.h != sh || abs(sscale - scale) > 0.001 do return
	_, art := sprite_grid_box(o.sprite, o.pos)
	for j in 0 ..< own.h {
		y := art.y + j
		if y < 0 || y >= m.h do continue
		for i in 0 ..< own.w {
			x := art.x + i
			if x < 0 || x >= m.w do continue
			v := own.feet[j * own.w + i]
			if v == DEPTH_NONE do continue
			m.feet[y * m.w + x] = i16(clamp(f32(v) + o.pos.y, 0, f32(max(i16))))
		}
	}
}

// --- The mask, while one thing is drawn ---

@(private)
Depth_Mask :: struct {
	on:      bool,
	texture: rl.Texture2D,
	feet:    f32,
	scale:   f32,
}

@(private) depth_mask: Depth_Mask

// Set (by a test, or the harness's `!depth off`) to draw as if no room had a
// depth map: the picture before.
depth_maps_off: bool

// The same for the solid maps (`!depth solid off`): walked as if no room had one.
solid_maps_off: bool

// Everything drawn until depth_mask_end is hidden behind the map's pixels
// deeper than `feet`.
@(private)
depth_mask_begin :: proc(m: ^Depth_Map, scale, feet: f32) {
	if m == nil || m.texture.id == 0 || depth_maps_off do return
	depth_mask = {true, m.texture, feet, scale}
}

@(private)
depth_mask_end :: proc() {
	depth_mask = {}
}

// The vertex shader every masked draw goes through: raylib's own, and the
// canvas position (before any camera) for the fragment shader to look up.
@(private)
DEPTH_VS :: `#version 330
in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec4 vertexColor;
uniform mat4 mvp;
out vec2 fragTexCoord;
out vec4 fragColor;
out vec2 fragCanvas;
void main() {
	fragTexCoord = vertexTexCoord;
	fragColor = vertexColor;
	fragCanvas = vertexPosition.xy;
	gl_Position = mvp * vec4(vertexPosition, 1.0);
}`

// What is added to a fragment shader to mask it: depth_at and depth_hides.
@(private)
DEPTH_GLSL :: `
in vec2 fragCanvas;
uniform sampler2D depthMap;
uniform float depthFeet;
uniform float depthScale;
bool depth_hides() {
	ivec2 size = textureSize(depthMap, 0);
	vec2 c = floor(fragCanvas);
	ivec2 a = ivec2(ceil((c + 0.5) / depthScale) - 1.0);
	if (a.x < 0 || a.y < 0 || a.x >= size.x || a.y >= size.y) return false;
	vec4 d = texelFetch(depthMap, a, 0);
	float feet = floor(d.r * 255.0 + 0.5) + 256.0 * floor(d.g * 255.0 + 0.5);
	return feet > 0.0 && feet > depthFeet;
}
`

// raylib's own fragment shader, which a plain draw goes through.
@(private)
PLAIN_FS :: `#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
uniform sampler2D texture0;
uniform vec4 colDiffuse;
out vec4 finalColor;
void main() {
	finalColor = texture(texture0, fragTexCoord) * colDiffuse * fragColor;
}`

@(private)
Depth_Shader :: enum {
	Plain, // a plain draw
	Tint,  // through the light's palette map (begin_tint)
	Up,    // through the `up` shader: a camera, or a size not its own
}

@(private = "file") depth_shaders: [Depth_Shader]rl.Shader

// A fragment shader with the mask in it: its uniforms after its output, and
// the test first thing in main.
@(private)
depth_masked_source :: proc(fs: string) -> cstring {
	s, _ := strings.replace(fs, "out vec4 finalColor;", "out vec4 finalColor;\n" + DEPTH_GLSL, 1, context.temp_allocator)
	s, _ = strings.replace(s, "void main() {", "void main() {\n\tif (depth_hides()) discard;", 1, context.temp_allocator)
	return strings.clone_to_cstring(s, context.temp_allocator)
}

@(private)
depth_shader :: proc(which: Depth_Shader) -> rl.Shader {
	if depth_shaders[which].id != 0 do return depth_shaders[which]
	fs: string
	switch which {
	case .Plain: fs = PLAIN_FS
	case .Tint:  fs = RIDE_SHADER
	case .Up:    fs = SPRITE_UP_SHADER
	}
	depth_shaders[which] = rl.LoadShaderFromMemory(DEPTH_VS, depth_masked_source(fs))
	return depth_shaders[which]
}

// The mask's own uniforms, on a masked shader already begun (BeginShaderMode
// draws what was waiting, and with it the textures bound for it, so the map
// is bound after).
@(private)
depth_mask_uniforms :: proc(s: rl.Shader) {
	feet, scale := depth_mask.feet, depth_mask.scale
	rl.SetShaderValue(s, rl.GetShaderLocation(s, "depthFeet"), &feet, .FLOAT)
	rl.SetShaderValue(s, rl.GetShaderLocation(s, "depthScale"), &scale, .FLOAT)
	rl.SetShaderValueTexture(s, rl.GetShaderLocation(s, "depthMap"), depth_mask.texture)
}

// Around a draw that would otherwise use no shader of its own: the mask's
// plain one, while a mask is on and no tint or camera has a shader going.
@(private)
depth_plain_begin :: proc() -> bool {
	if !depth_mask.on || tint_on || sprite_camera do return false
	s := depth_shader(.Plain)
	rl.BeginShaderMode(s)
	depth_mask_uniforms(s)
	return true
}

@(private)
depth_plain_end :: proc(began: bool) {
	if began do rl.EndShaderMode()
}

@(private)
depth_draw_shutdown :: proc() {
	for &s in depth_shaders {
		if s.id != 0 do rl.UnloadShader(s)
		s = {}
	}
}

// --- Where a click on what is painted solid takes her ---

// At most this much of her hidden where a click on something solid leaves her,
// as stand_hidden reckons it: a little under half, for her picture's box
// being only a box (half of her, drawn, is about 0.4 of it).
STAND_HIDDEN :: f32(0.4)

// Where a click at `at` walks her, `spot` being the floor nearest it (the
// walk polygon's). On floor that is free, or in a room with no solid map,
// `spot` itself. On floor that is taken (the canvas of a tent, the foot of a
// wall) or in a thing's block: the nearest free floor she can walk to from
// `from` and be seen on, no more than STAND_HIDDEN of her behind what is
// painted; with nowhere like that, the nearest she can walk to. Nearest to
// the foot of what was clicked: the floor line the depth map holds at `at`,
// so a click on a tent's canvas brings her round to its camera side, not to
// a strip of floor behind it where only her head shows. `box` is her picture
// standing at `from` (sprite_bounds), carried to each spot to ask how much of
// her it hides.
stand_spot :: proc(sc: ^Scene, from, at, spot: [2]f32, box: rl.Rectangle) -> [2]f32 {
	m := sc.solid_map
	scale := sc.map_scale
	if m.w <= 0 || scale <= 0 || solid_maps_off || len(sc.walk_area) < 3 do return spot
	taken := solid_at(sc, spot)
	for o in sc.objects do if !o.hidden && o.block.kind != .None && in_shape(o.block, o.pos, spot) do taken = true
	if !taken do return spot

	live: Depth_Map
	if sc.depth_map.w > 0 && !depth_maps_off do live = scene_depth_now(sc)^
	aim := spot
	if d := depth_at(live, scale, at); d != DEPTH_NONE && f32(d) > at.y {
		aim = clamp_to_polygon({at.x, f32(d)}, sc.walk_area)
	}

	// Every cell she can walk to from where she stands (eight ways, no
	// corner of anything taken cut), as scene_path_grid walks them.
	W, H := int(m.w), int(m.h)
	centre :: proc(c, W: int, scale: f32) -> [2]f32 {
		x, y := i32(c % W), i32(c / W)
		return {f32(art_edge(x, scale) + art_edge(x + 1, scale)) / 2, f32(art_edge(y, scale) + art_edge(y + 1, scale)) / 2}
	}
	state := make([]u8, W * H, context.temp_allocator) // 0 not asked, 1 floor, 2 not
	seen := make([]bool, W * H, context.temp_allocator)
	free_cell :: proc(sc: ^Scene, state: []u8, c, W: int, scale: f32) -> bool {
		if state[c] == 0 {
			p := centre(c, W, scale)
			state[c] = 1 if !sc.solid_map.taken[c] && point_in_polygon(p, sc.walk_area) && !in_a_block(sc, p) else 2
		}
		return state[c] == 1
	}
	sx := clamp(int(art_at(from.x, scale)), 0, W - 1)
	sy := clamp(int(art_at(from.y, scale)), 0, H - 1)
	start := sy * W + sx
	Spot :: struct {
		d: f32,
		c: int,
	}
	reached := make([dynamic]Spot, 0, 4096, context.temp_allocator)
	queue := make([dynamic]int, 0, 4096, context.temp_allocator)
	if free_cell(sc, state, start, W, scale) do append(&reached, Spot{length(centre(start, W, scale) - aim), start})
	seen[start] = true
	append(&queue, start)
	for head := 0; head < len(queue); head += 1 {
		u := queue[head]
		ux, uy := u % W, u / W
		for st in ([8][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {-1, 1}, {1, -1}, {-1, -1}}) {
			vx, vy := ux + st.x, uy + st.y
			if vx < 0 || vy < 0 || vx >= W || vy >= H do continue
			v := vy * W + vx
			if seen[v] || !free_cell(sc, state, v, W, scale) do continue
			if st.x != 0 && st.y != 0 && (!free_cell(sc, state, uy * W + vx, W, scale) || !free_cell(sc, state, vy * W + ux, W, scale)) do continue
			seen[v] = true
			append(&queue, v)
			append(&reached, Spot{length(centre(v, W, scale) - aim), v})
		}
	}
	if len(reached) == 0 do return spot
	slice.sort_by(reached[:], proc(a, b: Spot) -> bool {return a.d < b.d})
	if live.w <= 0 do return centre(reached[0].c, W, scale)
	off := [2]f32{box.x, box.y} - from
	for r in reached {
		p := centre(r.c, W, scale)
		if stand_hidden(live, scale, {p.x + off.x, p.y + off.y, box.width, box.height}, p.y) <= STAND_HIDDEN do return p
	}
	return centre(reached[0].c, W, scale)
}

// How much of somebody whose picture fills `box`, feet on `feet`, the depth
// map hides: the share of the art pixels down the middle half of the box
// (where a person standing is; the box's sides are mostly air) whose line is
// nearer the camera than their feet.
stand_hidden :: proc(m: Depth_Map, scale: f32, box: rl.Rectangle, feet: f32) -> f32 {
	if m.w <= 0 do return 0
	x0, x1 := art_at(box.x + box.width / 4, scale), art_at(box.x + box.width * 3 / 4, scale)
	y0, y1 := art_at(box.y, scale), art_at(box.y + box.height - 0.5, scale)
	all, hid := 0, 0
	for y in max(y0, 0) ..= min(y1, m.h - 1) {
		for x in max(x0, 0) ..= min(x1, m.w - 1) {
			all += 1
			if d := m.feet[y * m.w + x]; d != DEPTH_NONE && f32(d) > feet do hid += 1
		}
	}
	return f32(hid) / f32(max(all, 1))
}

// --- Walking round a solid map ---

// The way from `from` to `to` over a room with a solid map: a search over its
// art pixels (on the floor, not taken, in no block), pulled tight into as few
// straight legs as see each other (line_clear). Ends with `to`, always, as
// scene_path's ways do: if `to` cannot be reached, the way goes to the
// nearest spot that can, and on from there as far as a line goes.
@(private)
scene_path_grid :: proc(scene: ^Scene, from, to: [2]f32, out: [][2]f32) -> int {
	m := scene.solid_map
	scale := scene.map_scale
	W, H := int(m.w), int(m.h)
	cell :: proc(p: [2]f32, scale: f32, W, H: int) -> int {
		x := clamp(int(art_at(p.x, scale)), 0, W - 1)
		y := clamp(int(art_at(p.y, scale)), 0, H - 1)
		return y * W + x
	}
	centre :: proc(c, W: int, scale: f32) -> [2]f32 {
		x, y := i32(c % W), i32(c / W)
		return {f32(art_edge(x, scale) + art_edge(x + 1, scale)) / 2, f32(art_edge(y, scale) + art_edge(y + 1, scale)) / 2}
	}
	start, goal := cell(from, scale, W, H), cell(to, scale, W, H)
	// 0 not asked yet, 1 floor, 2 not
	state := make([]u8, W * H, context.temp_allocator)
	free_cell :: proc(scene: ^Scene, state: []u8, c, W: int, scale: f32) -> bool {
		if state[c] == 0 {
			p := centre(c, W, scale)
			ok := !scene.solid_map.taken[c] && point_in_polygon(p, scene.walk_area) && !in_a_block(scene, p)
			state[c] = 1 if ok else 2
		}
		return state[c] == 1
	}
	dist := make([]f32, W * H, context.temp_allocator)
	prev := make([]i32, W * H, context.temp_allocator)
	for i in 0 ..< W * H {
		dist[i] = 1e30
		prev[i] = -1
	}
	Node :: struct {
		f: f32,
		c: int,
	}
	q: priority_queue.Priority_Queue(Node)
	priority_queue.init(&q, proc(a, b: Node) -> bool {return a.f < b.f}, priority_queue.default_swap_proc(Node), 1024, context.temp_allocator)
	gx, gy := goal % W, goal / W
	h :: proc(c, gx, gy, W: int, scale: f32) -> f32 {
		dx, dy := f32(abs(c % W - gx)), f32(abs(c / W - gy))
		return (max(dx, dy) + (math.SQRT_TWO - 1) * min(dx, dy)) * scale
	}
	dist[start] = 0
	priority_queue.push(&q, Node{h(start, gx, gy, W, scale), start})
	best, best_d := start, length(centre(start, W, scale) - to)
	steps := [8][3]int{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {1, 1, 1}, {-1, 1, 1}, {1, -1, 1}, {-1, -1, 1}}
	for priority_queue.len(q) > 0 {
		n := priority_queue.pop(&q)
		u := n.c
		if n.f > dist[u] + h(u, gx, gy, W, scale) + 0.001 do continue
		if u == goal do break
		if d := length(centre(u, W, scale) - to); d < best_d do best, best_d = u, d
		// Near the goal, a straight leg will do: a doorway up a notch of the
		// floor too narrow for the grid's own cells.
		if length(centre(u, W, scale) - to) < 48 && line_clear(scene, centre(u, W, scale), to) {
			best, best_d = u, 0
			break
		}
		ux, uy := u % W, u / W
		for s in steps {
			vx, vy := ux + s[0], uy + s[1]
			if vx < 0 || vy < 0 || vx >= W || vy >= H do continue
			v := vy * W + vx
			if !free_cell(scene, state, v, W, scale) do continue
			// No cutting a corner of something taken.
			if s[2] == 1 && (!free_cell(scene, state, uy * W + vx, W, scale) || !free_cell(scene, state, vy * W + ux, W, scale)) do continue
			nd := dist[u] + (math.SQRT_TWO if s[2] == 1 else 1) * scale
			if nd < dist[v] {
				dist[v] = nd
				prev[v] = i32(u)
				priority_queue.push(&q, Node{nd + h(v, gx, gy, W, scale), v})
			}
		}
	}
	end := goal if (prev[goal] >= 0 || goal == start) && best_d > 0 else best
	// The cells, from the start's to the end's.
	cells := make([dynamic]int, context.temp_allocator)
	for c := end; c >= 0; c = int(prev[c]) {
		append(&cells, c)
		if c == start do break
	}
	pts := make([dynamic][2]f32, context.temp_allocator)
	for i := len(cells) - 1; i >= 0; i -= 1 do append(&pts, centre(cells[i], W, scale))
	if len(pts) > 0 do pts[0] = from
	append(&pts, to)
	// Pulled tight: from each corner, on to the last point it can see.
	legs := make([dynamic][2]f32, context.temp_allocator)
	at := 0
	for at < len(pts) - 1 {
		k := at + 1
		for k + 1 < len(pts) && line_clear(scene, pts[at], pts[k + 1]) do k += 1
		append(&legs, pts[k])
		at = k
	}
	n := min(len(legs), len(out))
	for i in 0 ..< n do out[i] = legs[i]
	if n > 0 do out[n - 1] = to // a way too long to hold ends where it was going all the same
	return n
}

// --- Loading, and the mask for one person or thing ---

// A .depth or .solid file into the table, under its name. A depth map gets
// its texture now (with a window), for the shader.
@(private)
assets_load_map :: proc(a: ^Assets, path, file_name: string) -> bool {
	text, ok := read_data_file(path)
	if !ok do return false
	name := asset_name(file_name)
	if strings.has_suffix(file_name, ".depth") {
		m, good := parse_depth_map(text)
		if !good {
			fmt.eprintfln("%v: not a depth map", path)
			return false
		}
		depth_map_upload(&m)
		if a.depths == nil do a.depths = make(map[string]Depth_Map)
		if old, had := &a.depths[name]; had {
			depth_map_destroy(old)
			a.depths[name] = m
			return true
		}
		a.depths[strings.clone(name)] = m
		return true
	}
	m, good := parse_solid_map(text)
	if !good {
		fmt.eprintfln("%v: not a solid map", path)
		return false
	}
	if a.solids == nil do a.solids = make(map[string]Solid_Map)
	if old, had := &a.solids[name]; had {
		solid_map_destroy(old)
		a.solids[name] = m
		return true
	}
	a.solids[strings.clone(name)] = m
	return true
}

// Set while a tint's shader is going (begin_tint): a masked draw then goes
// through the tint's masked twin, not the plain one.
@(private) tint_on: bool

// The mask on for a person about to be drawn with their feet on `feet`, if
// anything near them in the map could hide any of them.
@(private)
depth_mask_actor :: proc(m: ^Depth_Map, scale: f32, a: Actor, feet: f32) {
	if m == nil do return
	s, _, _ := actor_picture(a)
	r := sprite_bounds(s, a.pos)
	r = {r.x - 4, r.y - 4, r.width + 8, r.height + 8}
	if depth_could_hide(m^, scale, r, feet) do depth_mask_begin(m, scale, feet)
}

// The same for a still thing at depth=normal, at pos on the backdrop's grid.
@(private)
depth_mask_sprite :: proc(m: ^Depth_Map, scale: f32, s: Sprite, pos: [2]f32, feet: f32) {
	if m == nil do return
	r, _ := sprite_grid_box(s, pos)
	if depth_could_hide(m^, scale, r, feet) do depth_mask_begin(m, scale, feet)
}

// --- The harness's (script.odin, probe.odin) ---
//
//     !depth off | on          draw as if no room had a depth map, or as it has
//     !depth check [x,y ...]   her at each point (default: every 40 px of the
//                              floor), drawn by the GPU and checked pixel by
//                              pixel against depth_hides: what is drawn of her
//                              is exactly what the CPU says shows
//     !depth time [n]          the room drawn n times (default 200), with the
//                              depth map and without: ms a frame
//     !depth at x,y            the feet line and the floor at a point
//     !depth solid off | on    walk as if no room had a solid map, or as it has
//     !depth walk x,y          walk her there from where she stands, in real
//                              steps, undrawn: where she got, how many corners,
//                              and how many steps were on taken floor
//     !depth audit             the in-front-and-behind audit of the room as it
//                              stands (depth_audit.odin): what is wrong, a line each
//     !depth sweep [n]         n walks (default 200) between floor points every
//                              which way, with the solid maps off and on: how
//                              many went over taken floor, and how many got there

@(private = "file") depth_probe_target: rl.RenderTexture2D

@(private)
depth_probe_render :: proc(w: ^World, sc: ^Scene, player: bool) -> rl.Image {
	if depth_probe_target.id == 0 do depth_probe_target = rl.LoadRenderTexture(WIDTH, HEIGHT)
	ride_draw_setup()
	debug := w.debug
	w.debug = false
	rl.BeginTextureMode(depth_probe_target)
	rl.ClearBackground(rl.BLACK)
	draw_room(w, sc, player)
	rl.EndTextureMode()
	w.debug = debug
	img := rl.LoadImageFromTexture(depth_probe_target.texture)
	rl.ImageFlipVertical(&img)
	rl.ImageFormat(&img, .UNCOMPRESSED_R8G8B8A8)
	return img
}

@(private)
depth_bang :: proc(w: ^World, args: []string) -> string {
	sc := current_scene(w)
	people_frame(w)
	if len(args) == 0 do return "!depth off|on|check [x,y...]|time [n]|at x,y"
	switch args[0] {
	case "off":
		depth_maps_off = true
		return "depth maps off: drawn as before them"
	case "on":
		depth_maps_off = false
		return "depth maps on"
	case "audit":
		return depth_audit(w)
	case "case":
		return depth_case(w, args[1:])
	case "solid":
		solid_maps_off = len(args) > 1 && args[1] == "off"
		return "solid maps off: walked as before them" if solid_maps_off else "solid maps on"
	case "walk":
		if len(args) < 2 do return "!depth walk x,y"
		to, ok := parse_vec2(args[1])
		if !ok do return "!depth walk x,y"
		was := solid_maps_off
		solid_maps_off = false
		started_in := solid_at(sc, w.player.pos)
		solid_maps_off = was
		walk_to(&w.player, to)
		on_taken, steps, corners := 0, 0, 0
		for _ in 0 ..< 60 * 30 {
			if !w.player.moving do break
			actor_follow_target(&w.player, 1.0 / 60, sc)
			if steps == 0 do corners = w.player.path_len
			steps += 1
			solid_maps_off = false
			if solid_at(sc, w.player.pos) && !started_in do on_taken += 1
			solid_maps_off = was
		}
		p := w.player.pos
		return fmt.tprintf("%v: walked to %.0f,%.0f by %v leg(s), %v step(s), %v on taken floor", sc.name, p.x, p.y, corners, steps, on_taken)
	case "sweep":
		if sc.solid_map.w <= 0 do return fmt.tprintf("%v has no solid map", sc.name)
		n := 200
		if len(args) > 1 do n = strconv.parse_int(args[1]) or_else 200
		// Floor points, free in the map, on a fixed scatter (no randomness: the
		// same walks every run).
		pts := make([dynamic][2]f32, context.temp_allocator)
		for y := f32(6); y < room_height(sc); y += 9 {
			for x := f32(5); x < f32(WIDTH); x += 13 {
				p := [2]f32{x, y}
				if point_in_polygon(p, sc.walk_area) && !in_a_block(sc, p) do append(&pts, p)
			}
		}
		if len(pts) < 2 do return fmt.tprintf("%v: no floor", sc.name)
		saved := w.player
		defer w.player = saved
		was := solid_maps_off
		defer solid_maps_off = was
		over, got: [2]int
		for off in 0 ..< 2 {
			for k in 0 ..< n {
				a := pts[(k * 7919) % len(pts)]
				b := pts[(k * 104729 + 13) % len(pts)]
				if a == b do continue
				w.player.pos = a
				w.player.moving = false
				solid_maps_off = off == 0
				walk_to(&w.player, b)
				went := false
				for _ in 0 ..< 60 * 30 {
					if !w.player.moving do break
					actor_follow_target(&w.player, 1.0 / 60, sc)
					solid_maps_off = false
					if solid_at(sc, w.player.pos) do went = true
					solid_maps_off = off == 0
				}
				if went do over[off] += 1
				if length(w.player.pos - b) < 1 do got[off] += 1
			}
		}
		return fmt.tprintf("%v: %v walks; without the solid map %v went over taken floor (%v got there); with it %v (%v got there)", sc.name, n, over[0], got[0], over[1], got[1])
	case "at":
		if len(args) < 2 do return "!depth at x,y"
		p, ok := parse_vec2(args[1])
		if !ok do return "!depth at x,y"
		d := depth_at(sc.depth_map, sc.map_scale, p)
		return fmt.tprintf("%v at %.0f,%.0f: feet line %v; floor %v", sc.name, p.x, p.y, "none" if d == DEPTH_NONE else fmt.tprint(d), "taken" if solid_at(sc, p) else "free")
	case "time":
		n := 200
		if len(args) > 1 do n = strconv.parse_int(args[1]) or_else 200
		time_it :: proc(w: ^World, sc: ^Scene, n: int) -> f64 {
			img := depth_probe_render(w, sc, true) // warm
			rl.UnloadImage(img)
			t0 := rl.GetTime()
			for _ in 0 ..< n {
				rl.BeginTextureMode(depth_probe_target)
				rl.ClearBackground(rl.BLACK)
				draw_room(w, sc, true)
				rl.EndTextureMode()
			}
			img = rl.LoadImageFromTexture(depth_probe_target.texture) // waits for the GPU
			rl.UnloadImage(img)
			return (rl.GetTime() - t0) * 1000 / f64(n)
		}
		was := depth_maps_off
		depth_maps_off = false
		on := time_it(w, sc, n)
		depth_maps_off = true
		off := time_it(w, sc, n)
		depth_maps_off = was
		return fmt.tprintf("%v: %.3f ms a room drawn with its depth map, %.3f without (%v draws each)", sc.name, on, off, n)
	case "check":
		if sc.depth_map.w <= 0 do return fmt.tprintf("%v has no depth map", sc.name)
		points := make([dynamic][2]f32, context.temp_allocator)
		for a in args[1:] do if p, ok := parse_vec2(a); ok do append(&points, p)
		if len(points) == 0 {
			for y := f32(20); y < room_height(sc); y += 40 {
				for x := f32(20); x < f32(WIDTH); x += 40 {
					if point_in_polygon({x, y}, sc.walk_area) do append(&points, [2]f32{x, y})
				}
			}
		}
		saved := w.player
		defer w.player = saved
		was := depth_maps_off
		defer depth_maps_off = was
		// The room without her, both ways; her, both ways. Her pixels are
		// where she changes the room drawn without the maps (and inside her
		// own box); each must show her, or (where depth_hides says she is
		// behind it) the room as drawn with the maps.
		depth_maps_off = true
		empty_off := depth_probe_render(w, sc, false)
		defer rl.UnloadImage(empty_off)
		depth_maps_off = false
		empty_on := depth_probe_render(w, sc, false)
		defer rl.UnloadImage(empty_on)
		e0 := ([^]rl.Color)(empty_off.data)
		e1 := ([^]rl.Color)(empty_on.data)
		live := scene_depth_now(sc)^
		checked, hidden, wrong := 0, 0, 0
		first := ""
		for p in points {
			w.player.pos = p
			w.player.moving = false
			w.player.walking = false
			s, _, _ := actor_picture(w.player)
			box := sprite_bounds(s, p)
			depth_maps_off = true
			whole := depth_probe_render(w, sc, true)
			depth_maps_off = false
			masked := depth_probe_render(w, sc, true)
			a := ([^]rl.Color)(whole.data)
			b := ([^]rl.Color)(masked.data)
			for y in max(int(box.y) - 2, 0) ..< min(int(box.y + box.height) + 2, int(whole.height)) {
				for x in max(int(box.x) - 2, 0) ..< min(int(box.x + box.width) + 2, int(whole.width)) {
					i := y * int(whole.width) + x
					if a[i] == e0[i] do continue // not her
					checked += 1
					hides := depth_hides(live, sc.map_scale, {f32(x) + 0.5, f32(y) + 0.5}, p.y)
					want := e1[i] if hides else a[i]
					if hides do hidden += 1
					if b[i] != want {
						wrong += 1
						if first == "" do first = fmt.tprintf("; first at %v,%v (her feet %.0f,%.0f, hides %v)", x, y, p.x, p.y, hides)
					}
				}
			}
			rl.UnloadImage(whole)
			rl.UnloadImage(masked)
		}
		return fmt.tprintf("%v: %v points, %v pixels of her, %v hidden by the map, %v drawn otherwise than depth_hides says%v", sc.name, len(points), checked, hidden, wrong, first)
	}
	return "!depth off|on|check [x,y...]|time [n]|at x,y|solid off|on|walk x,y"
}

// --- People are solid ---
//
// Nobody walks through anybody. Every person in a room (an object that walks,
// shown, not walking off or on through a side) stands on an oval round their
// feet, sized to their picture (PERSON_FOOT of its width; wider sitting), and
// Ada's steps, straight lines and paths go round it as round a block: a
// click on somebody's feet stops at the edge, TALK TO stops beside them as it
// always did (BESIDE is wider than the oval). The people in turn go round her:
// a walking person's step into her oval is not taken, and their way is worked
// out again (actor_follow_target, up to WAY_AGAIN times); one walking off or on
// through a side waits a moment (PERSON_WAIT) for her to move and then goes on.
// They do not stop each other, and a cutscene's people are not stopped at all.
// Somebody standing in an exit's patch (a doorway) stops nobody: the door is
// still a door. The same rule as a block: an oval she is already inside does
// not count, so nobody is ever stuck.

PERSON_FOOT :: f32(0.55)      // of the picture's width, across; the oval is 0.4 of that deep
PERSON_FOOT_MIN :: f32(20)
PERSON_SIT :: f32(1.4)        // wider sitting: the chair
PERSON_WAIT :: f32(1.5)       // seconds somebody coming or going through a side waits for her

// Who is walking, for what stops them.
Mover :: enum u8 {
	None,   // a cutscene's people, the called: as before, people stop nothing
	Player, // her: stopped by everybody
	Npc,    // a person of the room: stopped by her only
}

// The actor that is her, set by the world each frame (update).
@(private, thread_local) the_player: ^Actor // per thread: the tests run side by side

// The oval round somebody's feet.
person_foot :: proc(a: Actor) -> Shape {
	s, _, _ := actor_picture(a)
	w := max(f32(s.frame_w) * PERSON_FOOT, PERSON_FOOT_MIN)
	if strings.contains(a.pose, "sit") || strings.contains(a.pose, "desk") do w *= PERSON_SIT
	return {.Oval, {w, w * 0.4}, {}}
}

// Is p inside somebody's oval, for whoever is walking now in this room
// (scene.mover)? An oval holding `from` does not count, nor anybody standing in
// an exit's patch.
people_in_way :: proc(scene: ^Scene, p, from: [2]f32) -> bool {
	switch scene.mover {
	case .None:
		return false
	case .Npc:
		if !scene.player_in || the_player == nil do return false
		f := person_foot(the_player^)
		return in_shape(f, scene.player_pos, p) && !in_shape(f, scene.player_pos, from) && !in_doorway(scene, scene.player_pos)
	case .Player:
		for &o in scene.objects {
			if !o.walks || o.hidden || o.going || o.coming do continue
			f := person_foot(o.actor)
			if in_shape(f, o.actor.pos, p) && !in_shape(f, o.actor.pos, from) && !in_doorway(scene, o.actor.pos) do return true
		}
	}
	return false
}

@(private = "file")
in_doorway :: proc(scene: ^Scene, p: [2]f32) -> bool {
	for e in scene.exits {
		if !e.hidden && in_rect(p, {e.area.x - 16, e.area.y - 16, e.area.width + 32, e.area.height + 32}) do return true
	}
	return false
}

// The corners round the people, for the polygon's way-finding (scene_path):
// the oval's eight points, stood a little off.
people_corners :: proc(scene: ^Scene, out: ^[dynamic][2]f32) {
	round :: proc(out: ^[dynamic][2]f32, a: Actor) {
		f := person_foot(a)
		h := f.size / 2 + 6
		for i in 0 ..< 8 {
			t := f32(i) * math.PI / 4
			append(out, a.pos + {math.cos(t) * h.x, math.sin(t) * h.y})
		}
	}
	switch scene.mover {
	case .None:
	case .Npc:
		if scene.player_in && the_player != nil && !in_doorway(scene, scene.player_pos) {
			me := the_player^
			me.pos = scene.player_pos
			round(out, me)
		}
	case .Player:
		for &o in scene.objects {
			if !o.walks || o.hidden || o.going || o.coming || in_doorway(scene, o.actor.pos) do continue
			round(out, o.actor)
		}
	}
}

// Who is walking: what the room's people stop. Set round each step.
@(private)
mover_of :: proc(a: ^Actor) -> Mover {
	if a == the_player do return .Player
	return .Npc if a.npc else .None
}

// The world, each frame: which actor is her, and in which room she stands.
@(private)
people_frame :: proc(w: ^World) {
	the_player = &w.player
	for &s, i in w.scenes {
		s.player_in = i == w.current
		if s.player_in do s.player_pos = w.player.pos
	}
}
WAY_AGAIN :: 3 // times the way is worked out again round somebody in it, before giving up
