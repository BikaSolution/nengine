package main

import ne "../../"
import ui "../ui"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// `nscene world <scenes-dir> --start <room>`: the rooms read together, as one
// world joined by its sides (nengine/side.odin), and checked as one:
//
//   w-partner  every side's room has a side back
//   w-dir      ...facing the opposite way: A east of B is B west of A
//   w-span     partners' spans agree: east and west equal (one floor
//              template), north and south landing somewhere free all along,
//              and every north-south pair in the same proportion
//   w-floor    there is floor all along a span, and its brink is near the
//              border it says (else the span is in the wrong place)
//   w-gate     both partners name the same gate, and say something when shut
//   w-when     both partners are there at the same times
//   w-reach    every room with a side can be walked to from --start
//   w-gated    what each gate cuts off when shut (for reading, not a fault)
//   w-grid     the sides make a grid: no room in two places, no place
//              holding two rooms, loops that close
//   w-exit     no exit's patch in the lane she walks in or lands on
//   w-edge     no deadly edge at a span's brink
//   w-name     no side named (or facing) like an exit in its room
//
// Then the grid as it stands, drawn from the files: `--` a side, `==` a
// gated one. Exits 1 if anything scores 50 or more; with --strict, if
// anything is found but the info lines (WORLD_INFO): what a gate cuts off,
// and a gate's own words said where a side has no `shut` line. Only the game
// knows its gates' words, so whether they are said is the game's test.

World_Code :: enum {
	Partner,
	Dir,
	Span,
	Floor,
	Gate,
	When,
	Reach,
	Gated,
	Grid,
	Exit,
	Edge,
	Name,
}

WORLD_CODE := [World_Code]string {
	.Partner = "w-partner",
	.Dir     = "w-dir",
	.Span    = "w-span",
	.Floor   = "w-floor",
	.Gate    = "w-gate",
	.When    = "w-when",
	.Reach   = "w-reach",
	.Gated   = "w-gated",
	.Grid    = "w-grid",
	.Exit    = "w-exit",
	.Edge    = "w-edge",
	.Name    = "w-name",
}

World_Finding :: struct {
	score: int,
	code:  World_Code,
	room:  string,
	side:  string, // "east", or "" for the room as a whole
	what:  string,
}

World_Report :: struct {
	findings: [dynamic]World_Finding,
	rooms:    int, // read
	sided:    int, // with at least one side
	sides:    int,
	grid:     string, // the map
}

// A finding scoring this or less is for reading, not a fault: --strict
// passes it.
WORLD_INFO :: 10

// Canvas size, for how far a brink is from its border.
@(private = "file")
CANVAS :: [2]f32{1024, 640}

// How far apart two east-west partners' spans may be at either end: one
// 5 art px step.
@(private = "file")
SPAN_SLACK :: f32(16)

@(private = "file")
STEP := [ne.Compass][2]int {
	.North = {0, -1},
	.East  = {1, 0},
	.South = {0, 1},
	.West  = {-1, 0},
}

@(private = "file")
found :: proc(r: ^World_Report, score: int, code: World_Code, room, side: string, what: string) {
	append(&r.findings, World_Finding{score, code, room, side, what})
}

// The audit itself, over rooms already read. Everything in the report is in
// the temp allocator.
world_audit :: proc(scenes: []ne.Scene, start: string) -> (r: World_Report) {
	r.findings = make([dynamic]World_Finding, context.temp_allocator)
	r.rooms = len(scenes)
	index := make(map[string]int, len(scenes), context.temp_allocator)
	for &sc, i in scenes do index[sc.name] = i
	ratios := make([dynamic]f32, context.temp_allocator)
	Ratio_At :: struct {
		room: string,
		r:    f32,
	}
	ratio_at := make([dynamic]Ratio_At, context.temp_allocator)

	for &a in scenes {
		if len(a.sides) > 0 do r.sided += 1
		r.sides += len(a.sides)
		for &s in a.sides {
			dir := ne.COMPASS_WORDS[s.dir]
			side_checks(&r, &a, &s)
			bi, there := index[s.to_name]
			if !there {
				found(&r, 70, .Partner, a.name, dir, fmt.tprintf("goes to %v, and there is no room called that", s.to_name))
				continue
			}
			b := &scenes[bi]
			if s.has_arrive {
				// A long walk: its own arrival, and no partner wanted.
				if !ne.point_in_polygon(s.arrive, b.walk_area) {
					found(&r, 45, .Span, a.name, dir, fmt.tprintf("a long walk to %v arriving at %.0f,%.0f, off that room's floor", b.name, s.arrive.x, s.arrive.y))
				}
				continue
			}
			p := partner_of(scenes, index, &a, &s)
			if p == nil {
				other := ""
				for o in b.sides do if o.to_name == a.name && !o.has_arrive do other = ne.COMPASS_WORDS[o.dir]
				if other != "" {
					found(&r, 60, .Dir, a.name, dir, fmt.tprintf("%v's side back here faces %v, not %v", b.name, other, ne.COMPASS_WORDS[ne.opposite(s.dir)]))
				} else {
					found(&r, 60, .Partner, a.name, dir, fmt.tprintf("%v has no %v side back here", b.name, ne.COMPASS_WORDS[ne.opposite(s.dir)]))
				}
				continue
			}
			if s.gate != p.gate {
				found(&r, 55, .Gate, a.name, dir, fmt.tprintf("gate %q here, %q on %v's side back", s.gate, p.gate, b.name))
			}
			if s.only != p.only {
				if compatible(s.only, p.only) {
					found(&r, 20, .When, a.name, dir, fmt.tprintf("when=%v here, when=%v on %v's side back: the same times?", s.only, p.only, b.name))
				} else {
					found(&r, 45, .When, a.name, dir, fmt.tprintf("when=%v here and when=%v on %v's side back can never both hold: one way only", s.only, p.only, b.name))
				}
			}
			if s.dir == .East || s.dir == .West {
				if abs(s.span[0] - p.span[0]) > SPAN_SLACK || abs(s.span[1] - p.span[1]) > SPAN_SLACK {
					found(&r, 40, .Span, a.name, dir, fmt.tprintf("span %.0f..%.0f here, %.0f..%.0f on %v's side back: east and west share the floor template", s.span[0], s.span[1], p.span[0], p.span[1], b.name))
				}
			}
			if s.dir == .North && s.span[1] > s.span[0] {
				q := (p.span[1] - p.span[0]) / (s.span[1] - s.span[0])
				append(&ratios, q)
				append(&ratio_at, Ratio_At{a.name, q})
			}
			landing_checks(&r, &a, &s, b, p)
		}
	}

	// One template, one proportion between a back line and the next front line.
	if len(ratios) >= 3 {
		sorted := slice.clone(ratios[:], context.temp_allocator)
		slice.sort(sorted)
		median := sorted[len(sorted) / 2]
		for q in ratio_at do if median > 0 && abs(q.r / median - 1) > 0.15 {
			found(&r, 30, .Span, q.room, "north", fmt.tprintf("its north span is %.2f of its partner's against %.2f for most: off the template?", 1 / q.r, 1 / median))
		}
	}

	reach_checks(&r, scenes, index, start)
	r.grid = grid_checks(&r, scenes, index, start)

	slice.stable_sort_by(r.findings[:], proc(x, y: World_Finding) -> bool {
		if x.score != y.score do return x.score > y.score
		if x.room != y.room do return x.room < y.room
		return x.side < y.side
	})
	return
}

// The side in `s`'s room that leads back: facing the other way, leading here,
// and the same one counting along the side (as ne.side_partner pairs them).
@(private = "file")
partner_of :: proc(scenes: []ne.Scene, index: map[string]int, a: ^ne.Scene, s: ^ne.Side) -> ^ne.Side {
	bi, ok := index[s.to_name]
	if !ok do return nil
	rank := 0
	for o in a.sides do if o.dir == s.dir && o.to_name == s.to_name && !o.has_arrive && o.span[0] < s.span[0] do rank += 1
	b := &scenes[bi]
	want := ne.opposite(s.dir)
	for &o in b.sides {
		if o.dir != want || o.to_name != a.name || o.has_arrive do continue
		n := 0
		for q in b.sides do if q.dir == want && q.to_name == a.name && !q.has_arrive && q.span[0] < o.span[0] do n += 1
		if n == rank do return &o
	}
	return nil
}

// What one side says about itself: floor along it, a brink near its border,
// no exit in its lane, no drop at its brink, no name an exit has.
@(private = "file")
side_checks :: proc(r: ^World_Report, a: ^ne.Scene, s: ^ne.Side) {
	dir := ne.COMPASS_WORDS[s.dir]
	for e in a.exits {
		if (s.name != "" && e.name == s.name) || e.name == dir {
			found(r, 25, .Name, a.name, dir, fmt.tprintf("exit %v answers to the same word: GO %v takes the exit", e.name, strings.to_upper(e.name, context.temp_allocator)))
		}
	}
	if s.gate != "" && s.closed_text == "" {
		found(r, 10, .Gate, a.name, dir, fmt.tprintf("gate %v and no `shut %v` line: the gate's own words are said", s.gate, dir))
	}
	missing, first_missing := 0, f32(0)
	far := f32(0)
	inward := -ne.outward(s.dir)
	lane_exit, edge_near := "", ""
	for c := s.span[0]; c <= s.span[1] + 0.01; c += 8 {
		v := min(c, s.span[1])
		b, ok := ne.side_brink(a, s.dir, v)
		if !ok {
			if missing == 0 do first_missing = v
			missing += 1
			continue
		}
		switch s.dir {
		case .East:  far = max(far, CANVAS.x - b.x)
		case .West:  far = max(far, b.x)
		case .South: far = max(far, CANVAS.y - b.y)
		case .North:
		}
		lane := b + inward * ne.ARRIVE_IN
		for e in a.exits do if lane_exit == "" && e.only == "" && !e.closed && ne.in_rect(lane, e.area) do lane_exit = e.name
		for e in a.edges {
			if edge_near != "" || len(e.area) < 3 do continue
			for d := f32(0); d <= ne.EDGE_REACH; d += 4 {
				if ne.point_in_polygon(b + ne.outward(s.dir) * d, e.area) {
					edge_near = e.name
					break
				}
			}
		}
	}
	if missing > 0 {
		found(r, 50, .Floor, a.name, dir, fmt.tprintf("no floor at %v point(s) along the span, the first at %.0f", missing, first_missing))
	}
	if far > 200 {
		found(r, 30, .Floor, a.name, dir, fmt.tprintf("the brink is %.0f px in from the %v border somewhere along the span: is the span where the band crosses?", far, dir))
	}
	if lane_exit != "" {
		found(r, 30, .Exit, a.name, dir, fmt.tprintf("exit %v is in the lane she walks out by: it fires before the side does", lane_exit))
	}
	if edge_near != "" {
		found(r, 35, .Edge, a.name, dir, fmt.tprintf("edge %v is at the brink: the edge wins there, so she cannot cross", edge_near))
	}
}

// Crossing from `a` over `s` into `b` over `p`, every 16 px of the span: does
// she land on floor, clear of anything always solid and any exit's patch?
@(private = "file")
landing_checks :: proc(r: ^World_Report, a: ^ne.Scene, s: ^ne.Side, b: ^ne.Scene, p: ^ne.Side) {
	dir := ne.COMPASS_WORDS[s.dir]
	inward := -ne.outward(p.dir)
	for c := s.span[0]; c <= s.span[1] + 0.01; c += 16 {
		v := min(c, s.span[1])
		w := ne.span_map(v, s.span, p.span)
		brink, ok := ne.side_brink(b, p.dir, w)
		why := ""
		land := brink + inward * ne.ARRIVE_IN
		switch {
		case !ok:
			why = "no floor there"
		case !ne.point_in_polygon(land, b.walk_area):
			why = "off its floor"
		case:
			for o in b.objects do if why == "" && o.only == "" && o.block.kind != .None && ne.in_shape(o.block, o.pos, land) do why = fmt.tprintf("inside %v", o.name)
			for e in b.exits do if why == "" && e.only == "" && !e.closed && ne.in_rect(land, e.area) do why = fmt.tprintf("in exit %v's patch", e.name)
		}
		if why != "" {
			found(r, 35, .Span, a.name, dir, fmt.tprintf("leaving at %.0f lands in %v at %.0f,%.0f: %v", v, b.name, land.x, land.y, why))
			return
		}
	}
}

// Every room with a side, walked to from `start` by sides and exits, gates
// and conditions ignored; then what each gate cuts off, shut.
@(private = "file")
reach_checks :: proc(r: ^World_Report, scenes: []ne.Scene, index: map[string]int, start: string) {
	if start == "" do return
	si, ok := index[start]
	if !ok {
		found(r, 70, .Reach, start, "", "--start names no room")
		return
	}
	all := walk_from(scenes, index, si, "")
	for &sc, i in scenes do if len(sc.sides) > 0 && !all[i] {
		found(r, 60, .Reach, sc.name, "", fmt.tprintf("cannot be walked to from %v", start))
	}
	gates := make([dynamic]string, context.temp_allocator)
	for sc in scenes {
		for s in sc.sides do if s.gate != "" && !slice.contains(gates[:], s.gate) do append(&gates, s.gate)
		for e in sc.exits do if e.gate != "" && !slice.contains(gates[:], e.gate) do append(&gates, e.gate)
	}
	slice.sort(gates[:])
	for g in gates {
		shut := walk_from(scenes, index, si, g)
		lost := make([dynamic]string, context.temp_allocator)
		others := 0
		for &sc, i in scenes do if all[i] && !shut[i] {
			if len(sc.sides) > 0 do append(&lost, sc.name)
			else do others += 1
		}
		if len(lost) == 0 && others == 0 do continue
		joined, _ := strings.join(lost[:], ", ", context.temp_allocator)
		found(r, 5, .Gated, start, "", fmt.tprintf("gate %v shut cuts off %v%v", g, joined, fmt.tprintf(" and %v room(s) inside them", others) if others > 0 else ""))
	}
}

@(private = "file")
walk_from :: proc(scenes: []ne.Scene, index: map[string]int, from: int, without_gate: string) -> []bool {
	seen := make([]bool, len(scenes), context.temp_allocator)
	queue := make([dynamic]int, context.temp_allocator)
	append(&queue, from)
	seen[from] = true
	for len(queue) > 0 {
		at := pop_front(&queue)
		next := make([dynamic]string, context.temp_allocator)
		for s in scenes[at].sides do if without_gate == "" || s.gate != without_gate do append(&next, s.to_name)
		for e in scenes[at].exits do if without_gate == "" || e.gate != without_gate do append(&next, e.to_name)
		for n in next {
			i, ok := index[n]
			if !ok || seen[i] do continue
			seen[i] = true
			append(&queue, i)
		}
	}
	return seen
}

// The rooms laid out by their sides from `start`, and the map of them.
@(private = "file")
grid_checks :: proc(r: ^World_Report, scenes: []ne.Scene, index: map[string]int, start: string) -> string {
	si, ok := index[start]
	if !ok do return ""
	cell := make(map[int][2]int, len(scenes), context.temp_allocator)
	at := make(map[[2]int]int, len(scenes), context.temp_allocator)
	cell[si] = {0, 0}
	at[{0, 0}] = si
	queue := make([dynamic]int, context.temp_allocator)
	append(&queue, si)
	clash := make(map[int]bool, context.temp_allocator)
	for len(queue) > 0 {
		i := pop_front(&queue)
		for s in scenes[i].sides {
			if s.has_arrive do continue
			j, there := index[s.to_name]
			if !there do continue
			want := cell[i] + STEP[s.dir]
			if have, placed := cell[j]; placed {
				if have != want && !clash[j] {
					clash[j] = true
					found(r, 50, .Grid, scenes[j].name, "", fmt.tprintf("at %v,%v by way of %v's %v side, and at %v,%v another way: a loop that does not close", want.x, want.y, scenes[i].name, ne.COMPASS_WORDS[s.dir], have.x, have.y))
				}
				continue
			}
			if other, taken := at[want]; taken {
				found(r, 50, .Grid, scenes[j].name, "", fmt.tprintf("%v's %v side puts it at %v,%v, where %v is already", scenes[i].name, ne.COMPASS_WORDS[s.dir], want.x, want.y, scenes[other].name))
				continue
			}
			cell[j] = want
			at[want] = j
			append(&queue, j)
		}
	}
	return draw_grid(scenes, index, cell, at)
}

// The grid as text: each room in brackets, `--` or `==` (gated) between east
// and west neighbours, `|` or `=` between north and south. Long walks after it.
@(private = "file")
draw_grid :: proc(scenes: []ne.Scene, index: map[string]int, cell: map[int][2]int, at: map[[2]int]int) -> string {
	if len(cell) == 0 do return ""
	lo, hi := [2]int{max(int), max(int)}, [2]int{min(int), min(int)}
	width := 4
	for i, c in cell {
		lo = {min(lo.x, c.x), min(lo.y, c.y)}
		hi = {max(hi.x, c.x), max(hi.y, c.y)}
		width = max(width, len(scenes[i].name) + 2)
	}
	link :: proc(scenes: []ne.Scene, index: map[string]int, from, to: int, d: ne.Compass) -> (linked, gated: bool) {
		for s in scenes[from].sides do if s.dir == d && !s.has_arrive && s.to_name == scenes[to].name {
			linked = true
			if s.gate != "" do gated = true
		}
		for s in scenes[to].sides do if s.dir == ne.opposite(d) && !s.has_arrive && s.to_name == scenes[from].name {
			linked = true
			if s.gate != "" do gated = true
		}
		return
	}
	b := strings.builder_make(context.temp_allocator)
	for y in lo.y ..= hi.y {
		// The rooms, and the sides between them.
		for x in lo.x ..= hi.x {
			text := ""
			if i, has := at[{x, y}]; has do text = fmt.tprintf("[%v]", scenes[i].name)
			strings.write_string(&b, pad(text, width))
			if x == hi.x do break
			conn := "  "
			if i, has := at[{x, y}]; has {
				if j, also := at[{x + 1, y}]; also {
					if linked, gated := link(scenes, index, i, j, .East); linked do conn = "==" if gated else "--"
				}
			}
			strings.write_string(&b, conn)
		}
		strings.write_byte(&b, '\n')
		if y == hi.y do break
		// The sides down to the next row.
		for x in lo.x ..= hi.x {
			mark := " "
			if i, has := at[{x, y}]; has {
				if j, also := at[{x, y + 1}]; also {
					if linked, gated := link(scenes, index, i, j, .South); linked do mark = "=" if gated else "|"
				}
			}
			strings.write_string(&b, pad(strings.concatenate({pad("", width / 2), mark}, context.temp_allocator), width + (2 if x < hi.x else 0)))
		}
		strings.write_byte(&b, '\n')
	}
	walks := make([dynamic]string, context.temp_allocator)
	for sc in scenes do for s in sc.sides do if s.has_arrive {
		append(&walks, fmt.tprintf("  %v %v -> %v (%.0f,%.0f)%v", sc.name, ne.COMPASS_WORDS[s.dir], s.to_name, s.arrive.x, s.arrive.y, fmt.tprintf(" gate %v", s.gate) if s.gate != "" else ""))
	}
	if len(walks) > 0 {
		strings.write_string(&b, "long walks:\n")
		for line in walks do fmt.sbprintf(&b, "%v\n", line)
	}
	return strings.to_string(b)
}

@(private = "file")
pad :: proc(s: string, n: int) -> string {
	if len(s) >= n do return s
	return strings.concatenate({s, strings.repeat(" ", n - len(s), context.temp_allocator)}, context.temp_allocator)
}

// --- The command ---

world_cmd :: proc(args: []string) -> bool {
	if len(args) < 1 do return ui.fail("world: need a scenes folder")
	dir := args[0]
	start, md := "", ""
	strict, quiet := false, false
	for i := 1; i < len(args); i += 1 {
		next := args[i + 1] if i + 1 < len(args) else ""
		switch args[i] {
		case "--start":  start = next; i += 1
		case "--md":     md = next; i += 1
		case "--strict": strict = true
		case "--quiet":  quiet = true
		case:            return ui.fail("world: don't know %v", args[i])
		}
	}
	w: ne.World
	defer ne.destroy_world(&w)
	entries, err := os.read_directory_by_path(dir, -1, context.allocator)
	if err != nil do return ui.fail("world: could not read %v", dir)
	names := make([dynamic]string, context.temp_allocator)
	for e in entries {
		if e.type == .Directory {
			if os.exists(fmt.tprintf("%v/%v/%v.scene", dir, e.name, e.name)) do append(&names, strings.clone(e.name, context.temp_allocator))
		} else if strings.has_suffix(e.name, ".scene") {
			append(&names, strings.clone(e.name[:len(e.name) - len(".scene")], context.temp_allocator))
		}
	}
	slice.sort(names[:])
	for n in names {
		path := fmt.tprintf("%v/%v/%v.scene", dir, n, n)
		if !os.exists(path) do path = fmt.tprintf("%v/%v.scene", dir, n)
		text, ok := ne.read_data_file(path, context.temp_allocator)
		if !ok do continue
		sc, _ := ne.parse_scene(text, nil)
		if sc.name == "" do sc.name = strings.clone(n)
		append(&w.scenes, sc)
	}
	if start == "" {
		// The first room with a side, by name: something to walk from.
		for sc in w.scenes do if len(sc.sides) > 0 {
			start = sc.name
			break
		}
	}
	rep := world_audit(w.scenes[:], start)
	text := world_report_text(&rep, start, quiet)
	fmt.print(text)
	if md != "" {
		if os.write_entire_file(md, transmute([]byte)fmt.tprintf("# nscene world\n\n```\n%v```\n", text)) != nil do return ui.fail("world: could not write %v", md)
	}
	return !world_fails(&rep, strict)
}

// Anything scoring 50 or more fails; with `strict`, anything over WORLD_INFO.
world_fails :: proc(r: ^World_Report, strict := false) -> bool {
	worst := 0
	for f in r.findings do if f.code != .Gated do worst = max(worst, f.score)
	return worst >= 50 || (strict && worst > WORLD_INFO)
}

world_report_text :: proc(r: ^World_Report, start: string, quiet := false) -> string {
	b := strings.builder_make(context.temp_allocator)
	for f in r.findings {
		fmt.sbprintf(&b, "%3d  %-9v %-16v %-6v %v\n", f.score, WORLD_CODE[f.code], f.room, f.side, f.what)
	}
	if !quiet && r.grid != "" {
		fmt.sbprintf(&b, "\nthe grid from %v:\n%v\n", start, r.grid)
	}
	counts: [World_Code]int
	for f in r.findings do counts[f.code] += 1
	fmt.sbprintf(&b, "%v rooms, %v with sides, %v sides, %v finding(s):", r.rooms, r.sided, r.sides, len(r.findings))
	for k in World_Code do if counts[k] > 0 do fmt.sbprintf(&b, " %v=%v", WORLD_CODE[k], counts[k])
	strings.write_byte(&b, '\n')
	return strings.to_string(b)
}
