package nengine

import "core:fmt"

// Checking a world of sides as it stands now: where she can walk to, and
// whether every way across is a way back. For a game's own tests, at the
// hours that matter (by day, after dusk, first light). `nscene world` (tools/nscene/world.odin) reads the files
// cold, with no flags, no clock and none of the game's gates; this reads the
// live world, so a gate is shut or open as the game's clock has it now, and a
// gate's own words count as said.
//
//     reached := ne.rooms_reached(&w, start)        // by sides and exits, now
//     for f in ne.world_faults(&w) do testing.expectf(t, false, "%v", ne.fault_text(f))
//     ne.exit_back(&w, from, &exit)                 // a door with a door back
//
// Nothing here changes the world: no refresh, no walking. The conditions are
// asked afresh, so it needs no refresh_world first either.

// A way across or through that is wrong, for a test to print.
World_Fault :: struct {
	room: string, // where the way starts
	way:  string, // "side east", "exit door", "gate g1"
	what: string, // in words, temp-allocated
}

fault_text :: proc(f: World_Fault) -> string {
	return fmt.tprintf("%v %v: %v", f.room, f.way, f.what)
}

// A side she can cross now: there (its `when=`) and its gate open.
side_open_now :: proc(w: ^World, s: ^Side) -> bool {
	return s.to >= 0 && s.to < len(w.scenes) && condition_met(w, s.only) && !gate_shut(w, s.gate)
}

// An exit she can go through now: there, and not closed (by the file, the
// game, or its gate).
exit_open_now :: proc(w: ^World, e: ^Exit) -> bool {
	if e.to < 0 || e.to >= len(w.scenes) || !condition_met(w, e.only) do return false
	if e.gate != "" do return !e.closed_file && !gate_shut(w, e.gate)
	return !e.closed
}

// Every room she can walk to from `from` as the world stands: over sides
// that are there and not shut, and through exits that are there and open.
// Long walks count; a door some code opens (a tent's ENTER) does not.
rooms_reached :: proc(w: ^World, from: int, allocator := context.temp_allocator) -> []bool {
	seen := make([]bool, len(w.scenes), allocator)
	if from < 0 || from >= len(w.scenes) do return seen
	queue := make([dynamic]int, 0, len(w.scenes), context.temp_allocator)
	append(&queue, from)
	seen[from] = true
	for len(queue) > 0 {
		at := pop_front(&queue)
		sc := &w.scenes[at]
		for &s in sc.sides do if side_open_now(w, &s) && !seen[s.to] {
			seen[s.to] = true
			append(&queue, s.to)
		}
		for &e in sc.exits do if exit_open_now(w, &e) && !seen[e.to] {
			seen[e.to] = true
			append(&queue, e.to)
		}
	}
	return seen
}

// Is `p` somewhere she can be put down in `sc`: on the floor, in nothing
// solid as the room stands now, and in no open exit's patch (which would
// carry her straight on out)? "" if so, else why not.
landing_fault :: proc(w: ^World, sc: ^Scene, p: [2]f32) -> string {
	if !point_in_polygon(p, sc.walk_area) do return "off the floor"
	for o in sc.objects {
		if o.block.kind != .None && condition_met(w, o.only) && in_shape(o.block, o.pos, p) do return fmt.tprintf("inside %v", o.name)
	}
	if solid_at(sc, p) do return "inside something painted solid (the room's solid map)"
	for &e in sc.exits {
		if exit_open_now(w, &e) && in_rect(p, e.area) do return fmt.tprintf("in exit %v's patch", e.name)
	}
	return ""
}

// Every side of every room, as the world stands now:
//
//   - it goes to a room;
//   - a long walk (`arrive=`) arrives on the floor there, clear;
//   - any other has a partner facing back (side_partner), with the same gate
//     and the same `when=` (so both are there, and both shut, at the same
//     times), east and west spans equal (one floor template), floor all along
//     its own span, and every 16 px of it landing clear on the partner's;
//   - a gated side says something when shut (its `shut` line or the gate's).
side_faults :: proc(w: ^World, allocator := context.temp_allocator) -> [dynamic]World_Fault {
	out := make([dynamic]World_Fault, allocator)
	for &a, ai in w.scenes {
		for &s in a.sides {
			way := fmt.tprintf("side %v", COMPASS_WORDS[s.dir])
			if s.to < 0 || s.to >= len(w.scenes) {
				append(&out, World_Fault{a.name, way, fmt.tprintf("goes to %q, no room", s.to_name)})
				continue
			}
			b := &w.scenes[s.to]
			if s.gate != "" && side_shut_text(w, &s) == "" {
				append(&out, World_Fault{a.name, way, fmt.tprintf("gate %v shut says nothing: no `shut %v` line and no gate text", s.gate, COMPASS_WORDS[s.dir])})
			}
			for c := s.span[0]; c <= s.span[1] + 0.01; c += 16 {
				if _, ok := side_brink(&a, s.dir, min(c, s.span[1])); !ok {
					append(&out, World_Fault{a.name, way, fmt.tprintf("no floor at %.0f along its span", min(c, s.span[1]))})
					break
				}
			}
			if s.has_arrive {
				if why := landing_fault(w, b, s.arrive); why != "" {
					append(&out, World_Fault{a.name, way, fmt.tprintf("a long walk to %v arriving at %.0f,%.0f: %v", b.name, s.arrive.x, s.arrive.y, why)})
				}
				continue
			}
			p := side_partner(w, ai, &s)
			if p == nil {
				append(&out, World_Fault{a.name, way, fmt.tprintf("%v has no %v side back", b.name, COMPASS_WORDS[opposite(s.dir)])})
				continue
			}
			if p.gate != s.gate {
				append(&out, World_Fault{a.name, way, fmt.tprintf("gate %q here and %q on %v's side back", s.gate, p.gate, b.name)})
			}
			if p.only != s.only {
				append(&out, World_Fault{a.name, way, fmt.tprintf("when=%v here and when=%v on %v's side back", s.only, p.only, b.name)})
			}
			if (s.dir == .East || s.dir == .West) && (abs(s.span[0] - p.span[0]) > 0.5 || abs(s.span[1] - p.span[1]) > 0.5) {
				append(&out, World_Fault{a.name, way, fmt.tprintf("span %.0f..%.0f here and %.0f..%.0f on %v's side back", s.span[0], s.span[1], p.span[0], p.span[1], b.name)})
			}
			for c := s.span[0]; c <= s.span[1] + 0.01; c += 16 {
				v := min(c, s.span[1])
				land := side_arrival(b, p.dir, p.span, span_map(v, s.span, p.span))
				if why := landing_fault(w, b, land); why != "" {
					append(&out, World_Fault{a.name, way, fmt.tprintf("leaving at %.0f lands in %v at %.0f,%.0f: %v", v, b.name, land.x, land.y, why)})
					break
				}
			}
		}
	}
	return out
}

// The game's gates: each named, declared once, named by some side or exit,
// and able to shut.
gate_faults :: proc(w: ^World, allocator := context.temp_allocator) -> [dynamic]World_Fault {
	out := make([dynamic]World_Fault, allocator)
	for g, i in w.gates {
		way := fmt.tprintf("gate %v", g.name)
		if g.name == "" do append(&out, World_Fault{"", way, "has no name"})
		for h in w.gates[:i] do if h.name == g.name {
			append(&out, World_Fault{"", way, "declared twice"})
			break
		}
		if g.shut == "" do append(&out, World_Fault{"", way, "has no `shut` condition: it never shuts"})
		used := false
		for sc in w.scenes {
			for s in sc.sides do used ||= s.gate == g.name
			for e in sc.exits do used ||= e.gate == g.name
		}
		if !used do append(&out, World_Fault{"", way, "no side or exit names it"})
	}
	return out
}

// Every exit that goes somewhere arrives on the floor there, clear, as the
// world stands now. Whether it is there or open now does not matter: when it
// is, that is where she lands.
exit_faults :: proc(w: ^World, allocator := context.temp_allocator) -> [dynamic]World_Fault {
	out := make([dynamic]World_Fault, allocator)
	for &a in w.scenes {
		for &e in a.exits {
			if e.to_name == "" do continue
			way := fmt.tprintf("exit %v", e.name)
			if e.to < 0 || e.to >= len(w.scenes) {
				append(&out, World_Fault{a.name, way, fmt.tprintf("goes to %q, no room", e.to_name)})
				continue
			}
			b := &w.scenes[e.to]
			if why := landing_fault(w, b, e.arrive); why != "" {
				append(&out, World_Fault{a.name, way, fmt.tprintf("arrives in %v at %.0f,%.0f: %v", b.name, e.arrive.x, e.arrive.y, why)})
			}
		}
	}
	return out
}

// All three, in that order.
world_faults :: proc(w: ^World, allocator := context.temp_allocator) -> [dynamic]World_Fault {
	out := side_faults(w, allocator)
	append(&out, ..gate_faults(w, context.temp_allocator)[:])
	append(&out, ..exit_faults(w, context.temp_allocator)[:])
	return out
}

// Does the room exit `e` (in room `from`) leads to have an exit back to
// `from`? A door with a door back; whether either is open now is the game's.
exit_back :: proc(w: ^World, from: int, e: ^Exit) -> bool {
	if e.to < 0 || e.to >= len(w.scenes) do return false
	for o in w.scenes[e.to].exits do if o.to == from do return true
	return false
}
