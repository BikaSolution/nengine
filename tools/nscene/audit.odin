package main

// `nscene audit`: every room of a game read at once, for what is drawn in
// front of what and for the things a room file gets wrong without anybody
// noticing.
//
//     nscene audit <scenes-dir> [--assets <dir>] [--person <char>]
//                  [--tsv <file>] [--md <file>] [--points <dir>] [--only room,room]
//
// Drawing order (README, "Drawing order") is decided by feet lines, and a
// backdrop has none: whatever is painted into it is behind everybody. So the
// commonest mistake in a room is a table painted into the floor with a block
// round it and floor behind it — she walks behind the table and is drawn
// over it. Nothing in the file says so; only the painting does. This reads
// the files and the paintings together and lists suspects, ranked:
//
//   a  painted furniture with floor behind it: a block, or a hole in the
//      floor, with nothing drawn over it, and walkable floor behind it within
//      a person's height of what is painted there
//   b  a baseline that does not match its picture: a block's front edge and
//      the feet line apart, empty rows under the art, a negative base, one
//      thing covering another it stands behind
//   c  depth misused: depth=back art that stands up with floor behind it,
//      depth=front art with floor in front of it, a glow or an overlay drawn
//      over the people behind it
//   d  where people are put — a char= line, a routine's walk, a cutscene's
//      marks — inside a block, off the floor, or behind painted furniture
//   e  painted foreground: something painted at the front of the floor with
//      walkable floor behind it (a rail, a post, a bush)
//   f  two things on one feet line that overlap, which only file order sorts
//   g  the rest: art that is missing, a light the room is painted in that a
//      prop is not, walk_to points off the floor or unreachable, exits off the
//      floor, arrivals off the next room's floor, objects nobody can LOOK at
//
// It suspects; a picture decides. `--points <dir>` writes, for every room, the
// places worth standing somebody to see it (`<room>.points`, one line of
// `x,y[:as=char][:pose=p][:facing=f]`), for the harness's `!crowd` (probe.odin).
// No game is named in here: the rooms, the art and the person are arguments.

import ne "../../"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

Audit_Kind :: enum {
	Painted_Behind, // a
	Baseline,       // b
	Depth,          // c
	Spot,           // d
	Foreground,     // e
	Same_Line,      // f
	Missing_Art,    // g
	Missing_Light,
	Walk_To,
	Exit,
	Arrive,
	No_Text,
	Other,
}

AUDIT_CODE := [Audit_Kind]string {
	.Painted_Behind = "a",
	.Baseline       = "b",
	.Depth          = "c",
	.Spot           = "d",
	.Foreground     = "e",
	.Same_Line      = "f",
	.Missing_Art    = "g-art",
	.Missing_Light  = "g-light",
	.Walk_To        = "g-walk_to",
	.Exit           = "g-exit",
	.Arrive         = "g-arrive",
	.No_Text        = "g-text",
	.Other          = "g-other",
}

Finding :: struct {
	room:   string,
	kind:   Audit_Kind,
	score:  int, // 0..100: how sure, and how much it shows
	object: string,
	at:     [2]f32,
	what:   string,
	fix:    string,
	points: [dynamic]string, // where to stand somebody to see it, as !crowd points
	only:   string,          // when it can be seen: the when= of the thing it is about
	box:    [4]f32,          // a: the painted thing, x0, top, x1, front
}

// A picture, as painted: the grid, and which cells are not transparent in any
// frame.
Art :: struct {
	ok:     bool,
	d:      ne.Sprite_Data,
	opaque: []bool, // w*h, any frame
	pad:    [2]i32, // empty rows at the top and the bottom
}

Audit :: struct {
	assets:   string,
	scale:    f32,
	person:   [2]f32, // a standing person on the canvas: width of the body, height
	index:    map[string]string, // asset name -> path, .sprite .char .cut
	arts:     map[string]^Art,
	chars:    map[string][2]f32, // char name -> size on the canvas, front pose
	findings: [dynamic]Finding,
	rooms:    [dynamic]^Room,
	cuts:     [dynamic]ne.Cutscene,
}

Room :: struct {
	name:   string,
	scene:  ne.Scene,
	bg:     [ne.Light]^Art,
	lights: bit_set[ne.Light],
	gw, gh: int,    // the backdrop's grid, in art pixels
	floor:  []bool, // in the walk polygon
	stand:  []bool, // ...and in no thing's block
	comp:   []i32,  // which piece of standable floor; 0 for none
	main:   i32,    // the biggest piece: where she can actually get
	odd:    []bool, // a colour the floor near it is not painted in
}

audit_cmd :: proc(args: []string) -> bool {
	if len(args) < 1 do return ui_fail("audit: need a scenes folder")
	a := Audit{scale = 3.2, person = {26 * 3.2, 52 * 3.2}}
	scenes_dir := args[0]
	a.assets = scenes_dir
	if slash := strings.last_index_byte(strings.trim_right(scenes_dir, "/"), '/'); slash > 0 do a.assets = scenes_dir[:slash]
	tsv, md, points_dir, person := "", "", "", ""
	only: []string
	for i := 1; i < len(args); i += 1 {
		next := args[i + 1] if i + 1 < len(args) else ""
		switch args[i] {
		case "--assets": a.assets = next; i += 1
		case "--tsv":    tsv = next; i += 1
		case "--md":     md = next; i += 1
		case "--points": points_dir = next; i += 1
		case "--person": person = next; i += 1
		case "--scale":  a.scale = strconv.parse_f32(next) or_else 3.2; i += 1
		case "--only":   only = strings.split(next, ","); i += 1
		case "--dress":  audit_dress = strings.split(next, ","); i += 1
		case:            return ui_fail("audit: don't know %v", args[i])
		}
	}
	audit_index(&a, a.assets)
	if person != "" {
		if size, ok := audit_char_size(&a, person, ""); ok do a.person = size
	}
	for _, path in a.index {
		if !strings.has_suffix(path, ".cut") do continue
		if c, ok := ne.load_cutscene(path); ok do append(&a.cuts, c)
	}

	// Every room, by its own folder or loose.
	entries, err := os.read_directory_by_path(scenes_dir, -1, context.allocator)
	if err != nil do return ui_fail("audit: could not read %v", scenes_dir)
	names := make([dynamic]string)
	for e in entries {
		if e.type == .Directory {
			if os.exists(fmt.tprintf("%v/%v/%v.scene", scenes_dir, e.name, e.name)) do append(&names, strings.clone(e.name))
		} else if strings.has_suffix(e.name, ".scene") {
			append(&names, strings.clone(e.name[:len(e.name) - len(".scene")]))
		}
	}
	slice.sort(names[:])
	for n in names {
		path := fmt.tprintf("%v/%v/%v.scene", scenes_dir, n, n)
		if !os.exists(path) do path = fmt.tprintf("%v/%v.scene", scenes_dir, n)
		text, ok := ne.read_data_file(path, context.allocator)
		if !ok do continue
		r := new(Room)
		r.scene, _ = ne.parse_scene(text, nil)
		r.name = r.scene.name if r.scene.name != "" else n
		append(&a.rooms, r)
	}
	for r in a.rooms {
		if len(only) > 0 && !slice.contains(only, r.name) do continue
		audit_room(&a, r)
	}
	audit_arrivals(&a)

	slice.stable_sort_by(a.findings[:], proc(x, y: Finding) -> bool {
		if x.score != y.score do return x.score > y.score
		return x.room < y.room
	})
	if tsv != "" do audit_write_tsv(&a, tsv)
	if md != "" do audit_write_md(&a, md)
	if points_dir != "" do audit_write_points(&a, points_dir, only)
	if tsv == "" && md == "" {
		for f in a.findings do fmt.printfln("%3d  %-8v %-16v %-18v %4.0f,%-4.0f %v", f.score, AUDIT_CODE[f.kind], f.room, f.object, f.at.x, f.at.y, f.what)
	}
	counts: [Audit_Kind]int
	for f in a.findings do counts[f.kind] += 1
	fmt.printf("%v rooms, %v finding(s):", len(a.rooms), len(a.findings))
	for k in Audit_Kind do if counts[k] > 0 do fmt.printf(" %v=%v", AUDIT_CODE[k], counts[k])
	fmt.println()
	return true
}

@(private = "file")
join :: proc(parts: []string, sep: string, allocator := context.temp_allocator) -> string {
	out, _ := strings.join(parts, sep, allocator)
	return out
}

@(private = "file")
ui_fail :: proc(format: string, args: ..any) -> bool {
	fmt.eprintfln(format, ..args)
	return false
}

// Every asset file under a folder, by its own name, as the game's loader
// knows it: `hall.night.sprite` is `hall.night`.
@(private = "file")
audit_index :: proc(a: ^Audit, dir: string) {
	files, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil do return
	for f in files {
		path := fmt.aprintf("%v/%v", dir, f.name)
		if f.type == .Directory {
			audit_index(a, path)
			continue
		}
		for ext in ([]string{".sprite", ".char", ".cut"}) {
			if strings.has_suffix(f.name, ext) {
				name := f.name[:len(f.name) - len(ext)]
				a.index[fmt.aprintf("%v%v", name, ext)] = path
			}
		}
	}
}

@(private = "file")
audit_art :: proc(a: ^Audit, name: string) -> ^Art {
	if art, has := a.arts[name]; has do return art
	art := new(Art)
	a.arts[strings.clone(name)] = art
	path, found := a.index[fmt.tprintf("%v.sprite", name)]
	if !found do return art
	d, ok := ne.load_sprite_data(path)
	if !ok do return art
	art.ok, art.d = true, d
	art.opaque = make([]bool, int(d.w * d.h))
	for f in 0 ..< d.frames do for y in 0 ..< d.h do for x in 0 ..< d.w {
		idx := d.pixels[int((f * d.h + y) * d.w + x)]
		if int(idx) < len(d.palette) && d.palette[idx].color.a > 0 do art.opaque[y * d.w + x] = true
	}
	art.pad = {d.h, d.h}
	for y in 0 ..< d.h do for x in 0 ..< d.w do if art.opaque[y * d.w + x] {
		art.pad[0] = min(art.pad[0], y)
		art.pad[1] = min(art.pad[1], d.h - 1 - y)
	}
	return art
}

// A light's painting of a sprite: `lamp.night`, or nothing.
@(private = "file")
audit_lit :: proc(a: ^Audit, name: string, l: ne.Light) -> ^Art {
	art := audit_art(a, fmt.tprintf("%v%v", name, ne.LIGHT_SUFFIX[l]))
	return art if art.ok else nil
}

// The first light a sprite is painted in, day first.
@(private = "file")
audit_any_lit :: proc(a: ^Audit, name: string) -> ^Art {
	for l in ne.Light do if art := audit_lit(a, name, l); art != nil do return art
	return nil
}

@(private = "file")
audit_char_size :: proc(a: ^Audit, name, pose: string) -> (size: [2]f32, ok: bool) {
	key := fmt.tprintf("%v/%v", name, pose)
	if s, has := a.chars[key]; has do return s, s != {}
	path, found := a.index[fmt.tprintf("%v.char", name)]
	if found {
		if c, good := ne.load_character(path); good {
			want := pose if pose != "" else "front"
			for p in c.parts do if p.name == want do size = {f32(p.data.w), f32(p.data.h)} * a.scale
			if size == {} && len(c.parts) > 0 do size = {f32(c.parts[0].data.w), f32(c.parts[0].data.h)} * a.scale
		}
	}
	a.chars[strings.clone(key)] = size
	return size, size != {}
}

// --- One room ---

@(private = "file")
add :: proc(a: ^Audit, r: ^Room, kind: Audit_Kind, score: int, object: string, at: [2]f32, what, fix: string, points: ..string) -> bool {
	for g in a.findings do if g.room == r.name && g.kind == kind && g.object == object && g.what == what do return false
	f := Finding{room = r.name, kind = kind, score = clamp(score, 1, 100), object = strings.clone(object), at = at, what = strings.clone(what), fix = strings.clone(fix)}
	for p in points do append(&f.points, strings.clone(p))
	append(&a.findings, f)
	return true
}

@(private = "file")
pt :: proc(p: [2]f32) -> string {
	return fmt.tprintf("%.0f,%.0f", p.x, p.y)
}

// Two conditions that can hold at once: neither says !x where the other says x.
// With alternatives (`a,b|c`, flags.odin), if any one of each can.
compatible :: proc(x, y: string) -> bool {
	if strings.index_byte(x, '|') < 0 && strings.index_byte(y, '|') < 0 do return compatible_terms(x, y)
	xs := x
	for xa in strings.split_iterator(&xs, "|") {
		ys := y
		for ya in strings.split_iterator(&ys, "|") do if compatible_terms(xa, ya) do return true
	}
	return false
}

// The same, for two conditions without alternatives.
@(private = "file")
compatible_terms :: proc(x, y: string) -> bool {
	// A room worn several ways (README, "One room, worn several ways"):
	// `<group>_a` and `<group>_b` are never on together.
	dressed :: proc(term: string) -> (group: string, ok: bool) {
		for g in audit_dress do if strings.has_prefix(term, g) && len(term) > len(g) + 1 && term[len(g)] == '_' do return g, true
		return "", false
	}
	says :: proc(cond, term: string) -> bool {
		rest := cond
		for t in strings.split_iterator(&rest, ",") do if strings.trim_space(t) == term do return true
		return false
	}
	rest := x
	for raw in strings.split_iterator(&rest, ",") {
		t := strings.trim_space(raw)
		if t == "" do continue
		if strings.has_prefix(t, "!") {
			if says(y, t[1:]) do return false
		} else if says(y, fmt.tprintf("!%v", t)) {
			return false
		} else if g, is := dressed(t); is {
			other := y
			for raw2 in strings.split_iterator(&other, ",") {
				u := strings.trim_space(raw2)
				if h, also := dressed(u); also && h == g && u != t do return false
			}
		}
	}
	return true
}

// The dressing groups named by --dress: `tent` makes tent_1 and tent_2 never
// together.
audit_dress: []string

// A condition naming a dressing: true only in one of a room's several ways.
@(private = "file")
dressing_only :: proc(cond: string) -> bool {
	rest := cond
	for raw in strings.split_iterator(&rest, ",") {
		t := strings.trim_space(raw)
		for g in audit_dress do if strings.has_prefix(t, g) && len(t) > len(g) + 1 && t[len(g)] == '_' do return true
	}
	return false
}

// The canvas rectangle an object's picture covers, and the art: x0, y0, x1, y1.
@(private = "file")
art_rect :: proc(a: ^Audit, o: ^ne.Object, art: ^Art) -> [4]f32 {
	w, h := f32(art.d.w) * a.scale, f32(art.d.h) * a.scale
	x0 := f32(i32(o.pos.x - w / 2))
	y0 := f32(i32(o.pos.y - h))
	return {x0, y0, x0 + w, y0 + h}
}

// Is the canvas point p on an opaque pixel of the object's art?
@(private = "file")
art_hit :: proc(a: ^Audit, o: ^ne.Object, art: ^Art, p: [2]f32) -> bool {
	rc := art_rect(a, o, art)
	if p.x < rc[0] || p.x >= rc[2] || p.y < rc[1] || p.y >= rc[3] do return false
	x := i32((p.x - rc[0]) / a.scale)
	y := i32((p.y - rc[1]) / a.scale)
	if x < 0 || y < 0 || x >= art.d.w || y >= art.d.h do return false
	return art.opaque[y * art.d.w + x]
}

// The art cell a canvas point falls in.
@(private = "file")
cell :: proc(a: ^Audit, r: ^Room, p: [2]f32) -> (int, bool) {
	x, y := int(p.x / a.scale), int(p.y / a.scale)
	if x < 0 || y < 0 || x >= r.gw || y >= r.gh do return 0, false
	return y * r.gw + x, true
}

@(private = "file")
centre :: proc(a: ^Audit, x, y: int) -> [2]f32 {
	return {(f32(x) + 0.5) * a.scale, (f32(y) + 0.5) * a.scale}
}

@(private = "file")
reachable :: proc(a: ^Audit, r: ^Room, p: [2]f32) -> bool {
	i, ok := cell(a, r, p)
	return ok && r.comp[i] == r.main && r.main != 0
}

// How many of a person's pixels, standing at p, fall on the object's art.
@(private = "file")
body_on_art :: proc(a: ^Audit, o: ^ne.Object, art: ^Art, p: [2]f32, body: [2]f32) -> int {
	n := 0
	for y := p.y - body.y + 2; y < p.y; y += a.scale do for x := p.x - body.x / 2 + 2; x < p.x + body.x / 2; x += a.scale {
		if art_hit(a, o, art, {x, y}) do n += 1
	}
	return n
}

@(private = "file")
block_rect :: proc(o: ^ne.Object) -> [4]f32 {
	c := o.pos + o.block.offset
	h := o.block.size / 2
	return {c.x - h.x, c.y - h.y, c.x + h.x, c.y + h.y}
}

@(private = "file")
audit_room :: proc(a: ^Audit, r: ^Room) {
	sc := &r.scene
	// The backdrop in every light it is painted in.
	if sc.background_name != "" {
		for l in ne.Light {
			if art := audit_lit(a, sc.background_name, l); art != nil {
				r.bg[l] = art
				r.lights += {l}
			}
		}
		if r.lights == {} do add(a, r, .Missing_Art, 90, sc.background_name, {}, fmt.tprintf("backdrop %v is not painted in any light", sc.background_name), "paint it, or name the right one on the bg line")
	}
	day := r.bg[.Day]
	if day == nil do for l in ne.Light do if r.bg[l] != nil {day = r.bg[l]; break}
	r.gw, r.gh = 320, 200
	if day != nil do r.gw, r.gh = int(day.d.w), int(day.d.h)
	n := r.gw * r.gh
	r.floor = make([]bool, n)
	r.stand = make([]bool, n)
	r.comp = make([]i32, n)
	r.odd = make([]bool, n)
	for y in 0 ..< r.gh do for x in 0 ..< r.gw {
		p := centre(a, x, y)
		i := y * r.gw + x
		r.floor[i] = len(sc.walk_area) >= 3 && ne.point_in_polygon(p, sc.walk_area)
		if !r.floor[i] do continue
		r.stand[i] = true
		for &o in sc.objects {
			// One dressing's furniture is not in the others' way.
			if o.walks || o.block.kind == .None || dressing_only(o.only) do continue
			if ne.in_shape(o.block, o.pos, p) {r.stand[i] = false; break}
		}
	}
	// The pieces of standable floor; the biggest is where she can get.
	{
		id := i32(0)
		best, best_n := i32(0), 0
		stack := make([dynamic]int, context.temp_allocator)
		for start in 0 ..< n {
			if !r.stand[start] || r.comp[start] != 0 do continue
			id += 1
			count := 0
			append(&stack, start)
			r.comp[start] = id
			for len(stack) > 0 {
				i := pop(&stack)
				count += 1
				x, y := i % r.gw, i / r.gw
				for d in ([][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
					nx, ny := x + d.x, y + d.y
					if nx < 0 || ny < 0 || nx >= r.gw || ny >= r.gh do continue
					j := ny * r.gw + nx
					if r.stand[j] && r.comp[j] == 0 {
						r.comp[j] = id
						append(&stack, j)
					}
				}
			}
			if count > best_n do best, best_n = id, count
		}
		r.main = best
	}
	if day != nil do audit_odd(a, r, day)

	audit_general(a, r)
	audit_painted(a, r)
	audit_objects(a, r)
	audit_people(a, r)
	audit_foreground(a, r)
}

// Which cells are painted in a colour the floor around them is not: the
// colours of the standable floor within a band of rows, and anything under 3%
// of that band is odd. Shadows and rugs come out odd as well as tables; the
// shape and the place decide which is which.
@(private = "file")
audit_odd :: proc(a: ^Audit, r: ^Room, bg: ^Art) {
	BAND :: 18
	rows := make([][256]i32, r.gh, context.temp_allocator)
	totals := make([]i32, r.gh, context.temp_allocator)
	for y in 0 ..< r.gh do for x in 0 ..< r.gw {
		i := y * r.gw + x
		if !r.stand[i] do continue
		rows[y][bg.d.pixels[i]] += 1
		totals[y] += 1
	}
	for y in 0 ..< r.gh {
		hist: [256]i32
		total: i32
		for yy in max(0, y - BAND) ..< min(r.gh, y + BAND + 1) {
			total += totals[yy]
			for c in 0 ..< 256 do hist[c] += rows[yy][c]
		}
		if total < 40 do continue
		for x in 0 ..< r.gw {
			i := y * r.gw + x
			r.odd[i] = f32(hist[bg.d.pixels[i]]) / f32(total) < 0.03
		}
	}
}

// How far up the picture something painted at the floor goes: from its front
// edge, up the columns x0..x1 (art cells), while the rows look unlike the same
// rows either side of it. In art rows; at least `least`.
@(private = "file")
painted_height :: proc(r: ^Room, bg: ^Art, left, right, front: int, least: int) -> int {
	x0, x1 := clamp(left, 0, r.gw - 1), clamp(right, 0, r.gw - 1)
	if x1 <= x0 do return least
	top := front
	gap := 0
	for y := front; y >= max(0, front - 90); y -= 1 {
		inside: [256]i32
		outside: [256]i32
		ni, no: i32
		for x in x0 ..= x1 {
			inside[bg.d.pixels[y * r.gw + x]] += 1
			ni += 1
		}
		for x in max(0, x0 - 14) ..< x0 {outside[bg.d.pixels[y * r.gw + x]] += 1; no += 1}
		for x in x1 + 1 ..< min(r.gw, x1 + 15) {outside[bg.d.pixels[y * r.gw + x]] += 1; no += 1}
		if no == 0 || ni == 0 do break
		same: f32
		for c in 0 ..< 256 do same += min(f32(inside[c]) / f32(ni), f32(outside[c]) / f32(no))
		if same < 0.55 {
			top = y
			gap = 0
		} else {
			gap += 1
			if gap > 4 do break
		}
	}
	return max(front - top, least)
}

// Is the canvas rectangle mostly covered by the art of some shown, upright
// picture (not a glow, not depth=back) that can be here when `only` holds?
@(private = "file")
covered_by_sprite :: proc(a: ^Audit, r: ^Room, rc: [4]f32, only: string) -> (string, bool) {
	sc := &r.scene
	best, best_name := f32(0), ""
	for &o in sc.objects {
		if o.walks || o.glow || o.depth == .Back || o.sprite_name == "" || !compatible(o.only, only) do continue
		art := audit_any_lit(a, o.sprite_name)
		if art == nil do continue
		hit, all := 0, 0
		for y := rc[1] + 1; y < rc[3]; y += a.scale do for x := rc[0] + 1; x < rc[2]; x += a.scale {
			all += 1
			if art_hit(a, &o, art, {x, y}) do hit += 1
		}
		if all > 0 && f32(hit) / f32(all) > best {best, best_name = f32(hit) / f32(all), o.name}
	}
	return best_name, best > 0.45
}

// a: painted furniture with floor behind it.
@(private = "file")
audit_painted :: proc(a: ^Audit, r: ^Room) {
	sc := &r.scene
	bg := r.bg[.Day]
	if bg == nil do for l in ne.Light do if r.bg[l] != nil {bg = r.bg[l]; break}
	if bg == nil || len(sc.walk_area) < 3 do return

	// Footprints: every block of a thing that is not a person, and every
	// hole the floor's outline makes in a column (floor above it and below it).
	Foot :: struct {
		name:  string,
		only:  string,
		rc:    [4]f32, // canvas: x0, back, x1, front
	}
	feet := make([dynamic]Foot, context.temp_allocator)
	for &o in sc.objects {
		if o.walks || o.block.kind == .None do continue
		append(&feet, Foot{o.name, o.only, block_rect(&o)})
	}
	// Holes: runs of cells outside the polygon with floor above and below in
	// the same column, gathered into boxes.
	{
		hole := make([]bool, r.gw * r.gh, context.temp_allocator)
		for x in 0 ..< r.gw {
			first, last := -1, -1
			for y in 0 ..< r.gh do if r.floor[y * r.gw + x] {
				if first < 0 do first = y
				last = y
			}
			if first < 0 do continue
			for y in first ..= last do if !r.floor[y * r.gw + x] do hole[y * r.gw + x] = true
		}
		seen := make([]bool, r.gw * r.gh, context.temp_allocator)
		stack := make([dynamic]int, context.temp_allocator)
		for start in 0 ..< r.gw * r.gh {
			if !hole[start] || seen[start] do continue
			lo, hi := [2]int{r.gw, r.gh}, [2]int{-1, -1}
			count := 0
			append(&stack, start)
			seen[start] = true
			for len(stack) > 0 {
				i := pop(&stack)
				count += 1
				x, y := i % r.gw, i / r.gw
				lo, hi = {min(lo.x, x), min(lo.y, y)}, {max(hi.x, x), max(hi.y, y)}
				for d in ([][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
					nx, ny := x + d.x, y + d.y
					if nx < 0 || ny < 0 || nx >= r.gw || ny >= r.gh do continue
					j := ny * r.gw + nx
					if hole[j] && !seen[j] {seen[j] = true; append(&stack, j)}
				}
			}
			if count < 12 do continue
			rc := [4]f32{f32(lo.x) * a.scale, f32(lo.y) * a.scale, f32(hi.x + 1) * a.scale, f32(hi.y + 1) * a.scale}
			append(&feet, Foot{fmt.tprintf("(hole in the floor %v..%v)", int(rc[0]), int(rc[2])), "", rc})
		}
	}

	for f in feet {
		x0, x1 := int(f.rc[0] / a.scale), int(f.rc[2] / a.scale)
		front := clamp(int(f.rc[3] / a.scale), 0, r.gh - 1)
		tall := painted_height(r, bg, x0, x1, front, 8)
		top := f32(front - tall) * a.scale
		// What is painted there, if anything stands: the box from its top to
		// its front edge.
		art := [4]f32{f.rc[0], top, f.rc[2], f.rc[3]}
		if name, covered := covered_by_sprite(a, r, art, f.only); covered {
			_ = name
			continue
		}
		// The floor behind it that a person could stand on, with their body
		// over what is painted.
		count := 0
		pts := make([dynamic][2]f32, context.temp_allocator)
		for y := f.rc[1] - a.scale; y > top + 6; y -= a.scale {
			for x := f.rc[0] + 4; x < f.rc[2] - 4; x += a.scale {
				if !reachable(a, r, {x, y}) do continue
				count += 1
				if len(pts) < 3 || (len(pts) < 6 && abs(pts[len(pts) - 1].x - x) > 90) do append(&pts, [2]f32{x, y})
			}
		}
		if count < 6 do continue
		depth := f.rc[1] - top // how far behind it the floor goes and still overlaps
		score := 40 + min(count / 8, 30) + min(int(depth / 6), 25)
		is_hole := strings.has_prefix(f.name, "(")
		what := fmt.tprintf("%v %v: painted into the backdrop about %v px tall (art %v rows), no sprite over it, and %v cells of reachable floor behind it (y %.0f..%.0f) — she is drawn over it there",
			"floor hole" if is_hole else "block of", f.name, int(f.rc[3] - top), tall, count, top, f.rc[1])
		fix := fmt.tprintf("cut the painted thing out of the backdrop as its own sprite object (feet line at its front edge, y=%.0f), or a front piece of it; or pull the floor polygon in so nobody stands behind it", f.rc[3])
		ps := make([dynamic]string, context.temp_allocator)
		for p in pts do append(&ps, pt(p))
		append(&ps, pt({(f.rc[0] + f.rc[2]) / 2, f.rc[3] + 30}))
		if add(a, r, .Painted_Behind, score, f.name, {(f.rc[0] + f.rc[2]) / 2, f.rc[3]}, what, fix, ..ps[:]) {
			a.findings[len(a.findings) - 1].only = strings.clone(f.only)
			a.findings[len(a.findings) - 1].box = {f.rc[0], top, f.rc[2], f.rc[3]}
		}
	}
}

// b, c, f: the objects with pictures, and g's art and lights.
@(private = "file")
audit_objects :: proc(a: ^Audit, r: ^Room) {
	sc := &r.scene
	body := a.person
	for &o, i in sc.objects {
		if o.walks || o.sprite_name == "" do continue
		day := audit_lit(a, o.sprite_name, .Day)
		art := audit_any_lit(a, o.sprite_name)
		if art == nil {
			add(a, r, .Missing_Art, 80, o.name, o.pos, fmt.tprintf("sprite=%v is not painted in any light", o.sprite_name), "paint it, or link the right sprite")
			continue
		}
		// Lights the room is painted in that the prop is not. A glow is
		// meant to be only some of them; so is something only there by night.
		if !o.glow && day != nil {
			missing := make([dynamic]string, context.temp_allocator)
			for l in r.lights do if l != .Day && audit_lit(a, o.sprite_name, l) == nil do append(&missing, ne.LIGHT_SUFFIX[l][1:])
			if len(missing) > 0 {
				add(a, r, .Missing_Light, 12, o.name, o.pos, fmt.tprintf("sprite=%v has no %v painting though the room has; it is drawn from day through the tint", o.sprite_name, join(missing[:], "/", context.temp_allocator)),
					"paint the missing light(s), or confirm the tint reads")
			}
		}
		rc := art_rect(a, &o, art)
		feet := o.pos.y + o.base
		bottom := rc[3] - f32(art.pad[1]) * a.scale // where the picture visibly ends
		cx := o.pos.x

		// b: the block's front edge against the feet line.
		if o.block.kind != .None && o.depth == .Normal {
			b := block_rect(&o)
			if abs(b[3] - feet) > 18 {
				add(a, r, .Baseline, 45 + min(int(abs(b[3] - feet) / 4), 30), o.name, {cx, feet},
					fmt.tprintf("feet line y=%.0f but its block's front edge is y=%.0f (%+.0f): a person between the two is on the wrong side of it", feet, b[3], b[3] - feet),
					fmt.tprintf("make them agree: base=%.0f, or move the block", b[3] - o.pos.y), pt({cx, (feet + b[3]) / 2}), pt({cx, min(feet, b[3]) - 20}))
			}
		}
		// b: empty rows at the bottom of the picture.
		if o.depth == .Normal && !o.glow && art.pad[1] >= 4 && o.base == 0 {
			add(a, r, .Baseline, 20 + min(int(art.pad[1]) * 2, 30), o.name, {cx, feet},
				fmt.tprintf("%v empty rows under the art: it sorts at y=%.0f but meets the floor at y=%.0f", art.pad[1], feet, bottom),
				fmt.tprintf("trim the empty rows, or base=-%.0f", f32(art.pad[1]) * a.scale), pt({cx, (feet + bottom) / 2}))
		}
		// b: a negative base on something standing on the floor.
		if o.depth == .Normal && o.base < -4 {
			if c, ok := cell(a, r, {cx, bottom - 2}); ok && r.floor[c] {
				add(a, r, .Baseline, 50, o.name, {cx, feet},
					fmt.tprintf("base=%v puts its feet line at y=%.0f, above where it meets the floor (y=%.0f): people standing just in front of it are drawn behind it", o.base, feet, bottom),
					"base=0, or split the art", pt({cx, feet + (bottom - feet) / 2}))
			}
		}

		// c: whoever stands where this picture is, drawn over it or under it,
		// against which of the two the picture says is nearer.
		big := (rc[2] - rc[0]) * (rc[3] - rc[1]) > 1024 * 640 * 0.2
		flat := false
		if o.depth == .Back && !o.glow {
			on_floor, all := 0, 0
			for y := rc[1] + 1; y < rc[3]; y += a.scale do for x := rc[0] + 1; x < rc[2]; x += a.scale {
				if !art_hit(a, &o, art, {x, y}) do continue
				all += 1
				if c, ok := cell(a, r, {x, y}); ok && r.stand[c] do on_floor += 1
			}
			flat = all == 0 || f32(on_floor) / f32(all) > 0.5 // lying on the floor: a rug, a shadow
		}
		if (o.depth == .Back && !o.glow && !flat) || o.depth == .Front || (o.depth == .Normal && (o.glow || big)) {
			hits, pts := people_against(a, r, &o, art, rc, body)
			if hits > 0 {
				what, fix: string
				score := 40 + min(hits * 2, 45)
				switch {
				case o.depth == .Back:
					what = fmt.tprintf("depth=back, but it stands up: at %v reachable spots a person is drawn over parts of it that stand nearer than her feet", hits)
					fix = fmt.tprintf("depth=normal with its feet line at its front edge (y=%.0f), or split it into a back piece and a front piece", bottom)
				case o.depth == .Front:
					what = fmt.tprintf("depth=front, but at %v reachable spots a person in front of it is drawn behind it", hits)
					fix = "depth=normal with a feet line at its front edge, or pull the floor back so nobody can get in front of it"
				case o.glow:
					what = fmt.tprintf("a glow sorted at y=%.0f: at %v reachable spots its light on things behind her is drawn over her", feet, hits)
					fix = "depth=back if it is light on the floor or the walls; or split the near part (a lamp) from the light"
				case:
					what = fmt.tprintf("a large overlay sorted at y=%.0f: at %v reachable spots parts of it farther back than her are drawn over her", feet, hits)
					fix = "depth=back, or split it"
					score -= 5
				}
				add(a, r, .Depth, score, o.name, {cx, feet}, what, fix, ..pts)
			}
		}

		// b/f: this picture against every other one shown with it.
		if o.depth != .Normal || o.glow do continue
		for &q, j in sc.objects {
			if j <= i || q.walks || q.sprite_name == "" || q.depth != .Normal || q.glow || !compatible(o.only, q.only) do continue
			if q.name == o.name && q.sprite_name == o.sprite_name do continue // one thing, two states
			qart := audit_any_lit(a, q.sprite_name)
			if qart == nil do continue
			qrc := art_rect(a, &q, qart)
			if qrc[0] >= rc[2] || rc[0] >= qrc[2] || qrc[1] >= rc[3] || rc[1] >= qrc[3] do continue
			qfeet := q.pos.y + q.base
			// Who is drawn last: the lower feet line, then file order.
			o_on_top := feet > qfeet || (feet == qfeet && i > j)
			both, o_should, q_should := 0, 0, 0
			for y := max(rc[1], qrc[1]) + 1; y < min(rc[3], qrc[3]); y += a.scale do for x := max(rc[0], qrc[0]) + 1; x < min(rc[2], qrc[2]); x += a.scale {
				p := [2]f32{x, y}
				if !art_hit(a, &o, art, p) || !art_hit(a, &q, qart, p) do continue
				both += 1
				ob, qb := run_end(a, &o, art, p), run_end(a, &q, qart, p)
				switch {
				case art_hit(a, &q, qart, {x, ob + a.scale / 2}): o_should += 1 // o rests on q
				case art_hit(a, &o, art, {x, qb + a.scale / 2}):  q_should += 1 // q rests on o
				case ob > qb + 9:                                  o_should += 1
				case qb > ob + 9:                                  q_should += 1
				}
			}
			if both < 6 do continue
			over, under := (&o if o_on_top else &q), (&q if o_on_top else &o)
			if feet == qfeet {
				add(a, r, .Same_Line, 25 + min(both / 4, 30), fmt.tprintf("%v/%v", o.name, q.name), {cx, feet},
					fmt.tprintf("%v and %v both sort at y=%.0f and overlap by %v cells: only file order puts %v on top", o.name, q.name, feet, both, over.name),
					"give the one in front a base of a pixel or two so the order is meant, not inherited")
				continue
			}
			wrong := q_should if o_on_top else o_should
			right := o_should if o_on_top else q_should
			if wrong >= 8 && wrong > right {
				add(a, r, .Baseline, 40 + min(wrong * 40 / max(both, 1), 40), fmt.tprintf("%v/%v", over.name, under.name), {cx, feet},
					fmt.tprintf("%v (feet y=%.0f) is drawn over %v (feet y=%.0f) where they overlap (%v cells), but the pictures say %v is in front or sits on it there (%v cells to %v)",
						over.name, over.pos.y + over.base, under.name, under.pos.y + under.base, both, under.name, wrong, right),
					fmt.tprintf("change a feet line (base) so %v sorts after %v", under.name, over.name))
			}
		}
	}
}

// Where a column of a picture stops going down, from p: the bottom of the
// stretch of art p is in, on the canvas. Where it meets the floor, for
// something standing; where it meets the thing it rests on, for something on
// something else.
@(private = "file")
run_end :: proc(a: ^Audit, o: ^ne.Object, art: ^Art, p: [2]f32) -> f32 {
	rc := art_rect(a, o, art)
	x := i32((p.x - rc[0]) / a.scale)
	y := i32((p.y - rc[1]) / a.scale)
	if x < 0 || x >= art.d.w do return p.y
	for y + 1 < art.d.h && art.opaque[(y + 1) * art.d.w + x] do y += 1
	return rc[1] + f32(y + 1) * a.scale
}

// The reachable spots where a person and this picture overlap and are drawn
// the wrong way round: drawn over parts of it that stand nearer than her
// feet, or under parts that stand farther back. The count, and a few spots.
@(private = "file")
people_against :: proc(a: ^Audit, r: ^Room, o: ^ne.Object, art: ^Art, rc: [4]f32, body: [2]f32) -> (int, []string) {
	hits := 0
	pts := make([dynamic]string, context.temp_allocator)
	line := o.pos.y + o.base
	for fy := max(rc[1], 0); fy < min(rc[3] + body.y, 640); fy += 9 do for fx := rc[0] - body.x / 2; fx < rc[2] + body.x / 2; fx += 18 {
		p := [2]f32{fx, fy}
		if !reachable(a, r, p) do continue
		art_over := o.depth == .Front || (o.depth == .Normal && line > p.y)
		bad := 0
		for y := p.y - body.y + 2; y < p.y; y += a.scale do for x := p.x - body.x / 2 + 2; x < p.x + body.x / 2; x += a.scale {
			if !art_hit(a, o, art, {x, y}) do continue
			end := run_end(a, o, art, {x, y})
			farther, nearer := end < p.y - 9, end > p.y + 9
			if (art_over && farther) || (!art_over && nearer) do bad += 1
		}
		if bad < 15 do continue
		hits += 1
		if len(pts) < 4 && (len(pts) == 0 || abs(fx - parse_x(pts[len(pts) - 1])) > 60) do append(&pts, pt(p))
	}
	return hits, pts[:]
}

@(private = "file")
parse_x :: proc(s: string) -> f32 {
	comma := strings.index_byte(s, ',')
	if comma <= 0 do return 0
	return strconv.parse_f32(s[:comma]) or_else 0
}

// d: where the people go.
@(private = "file")
audit_people :: proc(a: ^Audit, r: ^Room) {
	sc := &r.scene
	Mark :: struct {
		who, char, pose, why, only: string,
		at:                         [2]f32,
		facing:                     ne.Facing,
	}
	marks := make([dynamic]Mark, context.temp_allocator)
	for &o in sc.objects {
		if !o.walks do continue
		append(&marks, Mark{o.name, o.char_name, o.rest_pose, "its line", o.only, o.pos, o.actor.facing})
		for st in o.routine.steps do if st.kind == .Walk_To do append(&marks, Mark{o.name, o.char_name, "", "its routine", o.only, st.to, .Front})
	}
	for &c in a.cuts {
		if c.scene != r.name do continue
		chars := make(map[string]string, allocator = context.temp_allocator)
		for m in c.people {
			ch := m.character if m.character != "" else m.name
			chars[m.name] = ch
			if !m.keep_place do append(&marks, Mark{m.name, ch, "", fmt.tprintf("cutscene %v", c.name), "", m.at, m.facing})
		}
		for cue in c.cues do if cue.action == .Walk_To {
			ch := chars[cue.who] or_else cue.who
			append(&marks, Mark{cue.who, ch, "", fmt.tprintf("cutscene %v", c.name), "", cue.to, .Front})
		}
	}
	for m in marks {
		size, has := audit_char_size(a, m.char, m.pose)
		if !has do size = a.person
		p := fmt.tprintf("%v:as=%v%v:facing=%v", pt(m.at), m.char, fmt.tprintf(":pose=%v", m.pose) if m.pose != "" else "", ne.facing_text(m.facing))
		i, inside := cell(a, r, m.at)
		// A cutscene's mark off the picture, or at its very edge, is somebody
		// walking in or out.
		entrance := strings.has_prefix(m.why, "cutscene") && (m.at.x < 40 || m.at.x > f32(r.gw) * a.scale - 40 || m.at.y > f32(r.gh) * a.scale - 10)
		if entrance do continue
		if !inside {
			add(a, r, .Spot, 40, m.who, m.at, fmt.tprintf("%v (%v) stands off the picture at %v", m.who, m.why, pt(m.at)), "move the spot onto the floor", p)
			continue
		}
		if !r.floor[i] {
			sitting := m.pose != "" && m.pose != "front"
			add(a, r, .Spot, 22 if sitting else 38, m.who, m.at, fmt.tprintf("%v (%v%v) stands off the walk polygon at %v", m.who, m.why, fmt.tprintf(", pose=%v", m.pose) if m.pose != "" else "", pt(m.at)),
				"move the spot onto the floor (or confirm: a sitting pose on a painted seat can be off it)", p)
		}
		for &o in sc.objects {
			if o.walks || o.block.kind == .None || !compatible(o.only, m.only) do continue
			if ne.in_shape(o.block, o.pos, m.at) {
				add(a, r, .Spot, 45, m.who, m.at, fmt.tprintf("%v (%v) stands inside %v's block at %v", m.who, m.why, o.name, pt(m.at)), "move the spot out of the block, or the block off the spot", p)
				break
			}
		}
		// Behind something painted: a block (or a hole in the floor) in front
		// of the feet within a body's width, with nothing drawn over it.
		for f in a.findings {
			if f.room != r.name || f.kind != .Painted_Behind || !compatible(f.only, m.only) do continue
			// Her body over the painted thing, her feet behind its front.
			half := size.x / 2
			if m.at.x + half > f.box[0] && m.at.x - half < f.box[2] && m.at.y < f.box[3] && m.at.y > f.box[1] {
				add(a, r, .Spot, 55, m.who, m.at, fmt.tprintf("%v (%v) at %v stands behind painted %v (front edge y=%.0f): drawn over it", m.who, m.why, pt(m.at), f.object, f.at.y),
					"move the spot in front of it, or cut the thing out as a sprite (see the a finding)", p)
				break
			}
		}
	}
}

// e: painted foreground, and odd painting on the floor people walk over.
@(private = "file")
audit_foreground :: proc(a: ^Audit, r: ^Room) {
	if r.bg[.Day] == nil && r.lights == {} do return
	// Pieces of odd paint that touch standable floor: something painted where
	// she walks. Its height tells a rail or a post from a rug or a shadow.
	seen := make([]bool, r.gw * r.gh, context.temp_allocator)
	stack := make([dynamic]int, context.temp_allocator)
	for start in 0 ..< r.gw * r.gh {
		if !r.odd[start] || seen[start] || !r.stand[start] do continue
		lo, hi := [2]int{r.gw, r.gh}, [2]int{-1, -1}
		count, standing := 0, 0
		append(&stack, start)
		seen[start] = true
		for len(stack) > 0 {
			i := pop(&stack)
			count += 1
			if r.stand[i] do standing += 1
			x, y := i % r.gw, i / r.gw
			lo, hi = {min(lo.x, x), min(lo.y, y)}, {max(hi.x, x), max(hi.y, y)}
			for d in ([][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {-1, 1}, {1, -1}, {-1, -1}}) {
				nx, ny := x + d.x, y + d.y
				if nx < 0 || ny < 0 || nx >= r.gw || ny >= r.gh do continue
				j := ny * r.gw + nx
				if r.odd[j] && !seen[j] && (r.floor[j] || r.floor[i]) {seen[j] = true; append(&stack, j)}
			}
		}
		if standing < 30 do continue
		w, h := hi.x - lo.x + 1, hi.y - lo.y + 1
		// How much of it is painted above standable floor in its own columns:
		// floor behind it in the picture.
		behind := 0
		for x in lo.x ..= hi.x do for y in max(0, lo.y - 50) ..< lo.y do if r.comp[y * r.gw + x] == r.main && r.main != 0 do behind += 1
		upright := f32(h) / f32(max(w, 1))
		near_bottom := hi.y >= r.gh - 12
		if behind < 20 do continue
		// Covered by a sprite? Then it is that sprite's business.
		rc := [4]f32{f32(lo.x) * a.scale, f32(lo.y) * a.scale, f32(hi.x + 1) * a.scale, f32(hi.y + 1) * a.scale}
		if _, covered := covered_by_sprite(a, r, rc, ""); covered do continue
		score := 15 + min(int(upright * 25), 35) + (20 if near_bottom else 0) + min(standing / 40, 15)
		front := [2]f32{(rc[0] + rc[2]) / 2, rc[3]}
		add(a, r, .Foreground, score, fmt.tprintf("(painted %v..%v x %v..%v)", int(rc[0]), int(rc[2]), int(rc[1]), int(rc[3])), front,
			fmt.tprintf("a %vx%v-px patch painted in colours the floor around it is not, %v cells of it on standable floor, %v reachable cells behind it%v — if it stands up (rail, post, bush, frame, counter front) whoever walks over it is drawn over it; if it lies flat (rug, shadow, path) it is fine",
				int(rc[2] - rc[0]), int(rc[3] - rc[1]), standing, behind, ", at the bottom of the frame" if near_bottom else ""),
			"if it stands: cut it out of the backdrop as a sprite with its feet line at its foot (or depth=front if nobody can get in front of it), or take the floor out from behind/under it",
			pt({front.x, rc[1] - 10}), pt({front.x, rc[1] + (rc[3] - rc[1]) / 2}), pt({front.x, rc[3] + 20}))
	}
}

// g: the rest of a room's housekeeping.
@(private = "file")
audit_general :: proc(a: ^Audit, r: ^Room) {
	sc := &r.scene
	if len(sc.walk_area) < 3 {
		add(a, r, .Other, 30, "walk", {}, "no floor polygon", "draw one")
		return
	}
	for &o in sc.objects {
		// Art.
		if o.walks {
			if _, has := a.index[fmt.tprintf("%v.char", o.char_name)]; !has {
				add(a, r, .Missing_Art, 85, o.name, o.pos, fmt.tprintf("char=%v has no .char", o.char_name), "draw the character or fix the name")
			}
		}
		// Words: something with a picture or a person nobody can LOOK at.
		looks := o.description != ""
		for it in o.on do if it.verb == "look" || it.verb == "look at" || it.verb == "examine" do looks = true
		if !looks && (o.sprite_name != "" || o.walks || o.peep.is || len(o.on) > 0) && !o.glow && o.loop_name == "" {
			score := 20 if len(o.on) > 0 || o.walks else 6
			add(a, r, .No_Text, score, o.name, o.pos, fmt.tprintf("%v has no text line%v", o.name, fmt.tprintf(" (but %v on lines)", len(o.on)) if len(o.on) > 0 else " (art only? then fine if its name is in no vocabulary)"),
				"add `text <name> ...`, or confirm it is art only")
		}
		// Where she walks to do something to it.
		if o.walk_to != {} {
			i, ok := cell(a, r, o.walk_to)
			switch {
			case !ok || !r.floor[i]:
				add(a, r, .Walk_To, 50, o.name, o.walk_to, fmt.tprintf("walk_to=%v is off the floor", pt(o.walk_to)), "move it onto the floor in front of the thing")
			case !r.stand[i]:
				add(a, r, .Walk_To, 50, o.name, o.walk_to, fmt.tprintf("walk_to=%v is inside a block", pt(o.walk_to)), "move it out of the block")
			case r.comp[i] != r.main:
				add(a, r, .Walk_To, 45, o.name, o.walk_to, fmt.tprintf("walk_to=%v is on a piece of floor she cannot get to", pt(o.walk_to)), "move it, or open a way round the blocks")
			}
		}
	}
	for e in sc.exits {
		// The exit's patch must have floor she can reach in it.
		any := false
		for y := e.area.y; y < e.area.y + e.area.height && !any; y += a.scale do for x := e.area.x; x < e.area.x + e.area.width; x += a.scale {
			if reachable(a, r, {x, y}) {any = true; break}
		}
		if !any {
			add(a, r, .Exit, 55, e.name, {e.area.x + e.area.width / 2, e.area.y + e.area.height / 2}, fmt.tprintf("exit %v -> %v: no reachable floor inside its area %.0f,%.0f %.0fx%.0f", e.name, e.to_name, e.area.x, e.area.y, e.area.width, e.area.height),
				"move the area onto the edge of the floor, or the floor out to it")
		}
	}
}

// Arrivals are checked once every room is read: an exit's arrive point is in
// the next room.
@(private = "file")
audit_arrivals :: proc(a: ^Audit) {
	for r in a.rooms {
		if r.floor == nil do continue
		for e in r.scene.exits {
			for t in a.rooms {
				if t.name != e.to_name || t.floor == nil do continue
				i, ok := cell(a, t, e.arrive)
				switch {
				case !ok || !t.floor[i]:
					add(a, r, .Arrive, 55, e.name, e.arrive, fmt.tprintf("exit %v arrives in %v at %v, off that room's floor", e.name, t.name, pt(e.arrive)), "move the arrive point onto the floor")
				case !t.stand[i]:
					add(a, r, .Arrive, 50, e.name, e.arrive, fmt.tprintf("exit %v arrives in %v at %v, inside a block", e.name, t.name, pt(e.arrive)), "move the arrive point out of the block")
				case t.comp[i] != t.main:
					add(a, r, .Arrive, 45, e.name, e.arrive, fmt.tprintf("exit %v arrives in %v at %v, on floor cut off from the rest", e.name, t.name, pt(e.arrive)), "move it")
				}
				if ok && t.floor[i] {
					for back in t.scene.exits do if !back.closed && ne.in_rect(e.arrive, back.area) && compatible(back.only, e.only) {
						add(a, r, .Arrive, 40, e.name, e.arrive, fmt.tprintf("exit %v arrives in %v at %v, inside that room's exit %v (-> %v)", e.name, t.name, pt(e.arrive), back.name, back.to_name), "arrive a step clear of the exit")
						break
					}
				}
			}
		}
	}
}

// --- Writing it down ---

@(private = "file")
audit_write_tsv :: proc(a: ^Audit, path: string) {
	b := strings.builder_make()
	strings.write_string(&b, "score\tkind\troom\tobject\tx\ty\twhat\tfix\tpoints\n")
	for f in a.findings {
		fmt.sbprintf(&b, "%v\t%v\t%v\t%v\t%.0f\t%.0f\t%v\t%v\t%v\n", f.score, AUDIT_CODE[f.kind], f.room, f.object, f.at.x, f.at.y, f.what, f.fix, join(f.points[:], " ", context.temp_allocator))
	}
	_ = os.write_entire_file(path, transmute([]u8)strings.to_string(b))
}

@(private = "file")
audit_write_md :: proc(a: ^Audit, path: string) {
	b := strings.builder_make()
	fmt.sbprintf(&b, "# Room audit\n\n%v rooms, %v findings, most likely first within each room.\n", len(a.rooms), len(a.findings))
	for r in a.rooms {
		fmt.sbprintf(&b, "\n## %v\n\n", r.name)
		lights := make([dynamic]string, context.temp_allocator)
		for l in r.lights do append(&lights, "day" if l == .Day else ne.LIGHT_SUFFIX[l][1:])
		fmt.sbprintf(&b, "Painted in: %v. ", join(lights[:], ", ", context.temp_allocator))
		nouns := make([dynamic]string, context.temp_allocator)
		for o in r.scene.objects do if o.description != "" && !slice.contains(nouns[:], o.name) do append(&nouns, o.name)
		for s in r.scene.scenery do if !slice.contains(nouns[:], s.name) do append(&nouns, s.name)
		fmt.sbprintf(&b, "Answers LOOK AT: %v.\n\n", join(nouns[:], ", ", context.temp_allocator))
		for f in a.findings do if f.room == r.name {
			fmt.sbprintf(&b, "- **%v** `%v` %v at %.0f,%.0f — %v. *Fix:* %v\n", f.score, AUDIT_CODE[f.kind], f.object, f.at.x, f.at.y, f.what, f.fix)
		}
	}
	_ = os.write_entire_file(path, transmute([]u8)strings.to_string(b))
}

@(private = "file")
audit_write_points :: proc(a: ^Audit, dir: string, only: []string) {
	if !os.is_dir(dir) do _ = os.make_directory(dir)
	for r in a.rooms {
		if len(only) > 0 && !slice.contains(only, r.name) do continue
		people := make([dynamic]string, context.temp_allocator)
		places := make([dynamic]string, context.temp_allocator)
		for f in a.findings do if f.room == r.name {
			for p in f.points {
				list := &people if strings.contains(p, ":as=") else &places
				if !slice.contains(list[:], p) do append(list, p)
			}
		}
		text := fmt.tprintf("%v\n%v\n", join(places[:], " ", context.temp_allocator), join(people[:], " ", context.temp_allocator))
		_ = os.write_entire_file(fmt.tprintf("%v/%v.points", dir, r.name), transmute([]u8)text)
	}
}
