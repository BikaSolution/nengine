package nengine

import "core:strings"
import "core:testing"

// world_check.odin, on side_test's square: four floors 400 wide, the band y
// 100 to 200, gate g1 between ne and se (shut at night).
//
//     nw | ne
//     ---+---
//     sw | se
@(private = "file")
NW :: `scene nw
walk 0,100 400,100 400,200 0,200
side east to=ne span=120,180
side south to=sw span=100,300
`
@(private = "file")
NE :: `scene ne
walk 0,100 400,100 400,200 0,200
side west to=nw span=120,180
side south to=se span=100,300 gate=g1
shut south The gate is padlocked.
`
@(private = "file")
SW :: `scene sw
walk 0,100 400,100 400,200 0,200
side north to=nw span=100,300
side east to=se span=120,180
`
@(private = "file")
SE :: `scene se
walk 0,100 400,100 400,200 0,200
side north to=ne span=100,300 gate=g1
side west to=sw span=120,180
`

@(private = "file")
GATES := [?]Gate{{name = "g1", shut = "night", text = "Locked for the night."}}

@(private = "file")
world_of :: proc(t: ^testing.T, texts: ..string) -> World {
	w: World
	w.gates = GATES[:]
	for text in texts {
		s, ok := parse_scene(text, nil)
		testing.expect(t, ok)
		append(&w.scenes, s)
	}
	problem, ok := resolve_exits(&w)
	testing.expectf(t, ok, "resolve: %v", problem)
	refresh_world(&w)
	return w
}

@(private = "file")
reached :: proc(w: ^World, from: int) -> string {
	seen := rooms_reached(w, from)
	b := strings.builder_make(context.temp_allocator)
	for sc, i in w.scenes do if seen[i] {
		if strings.builder_len(b) > 0 do strings.write_byte(&b, ' ')
		strings.write_string(&b, sc.name)
	}
	return strings.to_string(b)
}

@(private = "file")
says :: proc(faults: [dynamic]World_Fault, room, words: string) -> bool {
	for f in faults do if f.room == room && strings.contains(fault_text(f), words) do return true
	return false
}

@(test)
a_sound_square_has_no_faults :: proc(t: ^testing.T) {
	w := world_of(t, NW, NE, SW, SE)
	defer destroy_world(&w)
	for f in world_faults(&w) do testing.expectf(t, false, "%v", fault_text(f))
	set_flag(&w, "night")
	for f in world_faults(&w) do testing.expectf(t, false, "at night: %v", fault_text(f))
}

@(test)
reaching_honours_gates_and_conditions :: proc(t: ^testing.T) {
	w := world_of(t, NW, NE, SW + "side west to=far span=100,200 when=day arrive=200,150\n", SE, `scene far
walk 0,100 400,100 400,200 0,200
exit back area=0,100,20,100 to=sw arrive=380,150
exit hut area=380,100,20,100 to=hut arrive=200,150 closed=true
`, `scene hut
walk 0,100 400,100 400,200 0,200
exit out area=0,100,20,100 to=far arrive=200,150
`)
	defer destroy_world(&w)
	testing.expect_value(t, reached(&w, 0), "nw ne sw se")
	set_flag(&w, "day")
	testing.expect_value(t, reached(&w, 0), "nw ne sw se far")
	// The gate shut: round by the other way, all the same.
	set_flag(&w, "night")
	testing.expect_value(t, reached(&w, 1), "nw ne sw se far")
	// One way cut by the gate, the other by its condition: se and ne are
	// still each other's only way, and shut.
	delete(w.scenes[0].sides[1].only)
	w.scenes[0].sides[1].only = strings.clone("never")
	testing.expect_value(t, reached(&w, 1), "nw ne")
	// An exit opened in code is a way in.
	w.scenes[4].exits[1].closed = false
	testing.expect_value(t, reached(&w, 4), "nw ne sw se far hut")
}

@(test)
a_side_must_be_a_way_back :: proc(t: ^testing.T) {
	w := world_of(t,
		NW + "side north to=sw span=100,300\n", // sw has no south side back
		NE,
		strings.concatenate({SW[:len(SW) - len("side east to=se span=120,180\n")], "side east to=se span=120,160\n"}, context.temp_allocator),
		`scene se
walk 0,100 400,100 400,200 0,200
side north to=ne span=100,300 gate=g1 when=open
side west to=sw span=120,180
`)
	defer destroy_world(&w)
	f := side_faults(&w)
	testing.expect(t, says(f, "nw", "side north: sw has no south side back"))
	testing.expect(t, says(f, "sw", "span 120..160 here and 120..180"))
	testing.expect(t, says(f, "ne", "when= here and when=open"))
	testing.expect(t, says(f, "se", "when=open here and when="))
}

@(test)
a_gate_on_one_side_only_is_found :: proc(t: ^testing.T) {
	se, _ := strings.replace(SE, " gate=g1", "", 1, context.temp_allocator)
	w := world_of(t, NW, NE, SW, se)
	defer destroy_world(&w)
	f := side_faults(&w)
	testing.expect(t, says(f, "ne", `gate "g1" here and "" on se's side back`))
	testing.expect(t, says(f, "se", `gate "" here and "g1" on ne's side back`))
}

@(test)
a_shut_side_must_say_something :: proc(t: ^testing.T) {
	w := world_of(t, NW, NE, SW, SE)
	defer destroy_world(&w)
	w.gates = []Gate{{name = "g1", shut = "night"}}
	f := side_faults(&w)
	testing.expect(t, says(f, "se", "side north: gate g1 shut says nothing"))
	testing.expect(t, !says(f, "ne", "says nothing"), "ne has its own shut line")
}

@(test)
landings_must_be_clear :: proc(t: ^testing.T) {
	w := world_of(t,
		NW + "obj crate pos=200,150 block=box:40,40 when=crated\n",
		NE,
		SW + "side west to=nw span=100,200 arrive=200,150\nside west to=nw span=210,220 arrive=200,50\n",
		SE + "exit door area=180,140,40,20 to=nw arrive=200,150\n",
	)
	defer destroy_world(&w)
	testing.expect(t, !says(side_faults(&w), "sw", "arriving at 200,150"))
	testing.expect(t, says(side_faults(&w), "sw", "arriving at 200,50: off the floor"))
	testing.expect(t, !says(exit_faults(&w), "se", "exit door"))
	// The crate is there now: in the way of the long walk and the door.
	set_flag(&w, "crated")
	testing.expect(t, says(side_faults(&w), "sw", "arriving at 200,150: inside crate"))
	testing.expect(t, says(exit_faults(&w), "se", "exit door: arrives in nw at 200,150: inside crate"))
	// Landing in an open exit's patch carries her straight on out.
	w2 := world_of(t, `scene a
walk 0,100 400,100 400,200 0,200
exit out area=0,100,40,100 to=b arrive=20,150
`, `scene b
walk 0,100 400,100 400,200 0,200
exit in area=0,100,40,100 to=a arrive=20,150
`)
	defer destroy_world(&w2)
	testing.expect(t, says(exit_faults(&w2), "a", "in exit in's patch"))
	testing.expect(t, exit_back(&w2, 0, &w2.scenes[0].exits[0]))
}

@(test)
gates_are_declared_once_used_and_can_shut :: proc(t: ^testing.T) {
	w := world_of(t, NW, NE, SW, SE)
	defer destroy_world(&w)
	testing.expect_value(t, len(gate_faults(&w)), 0)
	w.gates = []Gate{{name = "g1", shut = "night"}, {name = "g1", shut = "day"}, {name = "g9", shut = ""}}
	f := gate_faults(&w)
	testing.expect(t, says(f, "", "gate g1: declared twice"))
	testing.expect(t, says(f, "", "gate g9: has no `shut` condition"))
	testing.expect(t, says(f, "", "gate g9: no side or exit names it"))
}

@(test)
a_door_with_no_door_back_is_found :: proc(t: ^testing.T) {
	w := world_of(t, NW + "exit hut area=380,100,20,100 to=hut arrive=200,150\n", NE, SW, SE, `scene hut
walk 0,100 400,100 400,200 0,200
`)
	defer destroy_world(&w)
	testing.expect(t, !exit_back(&w, 0, &w.scenes[0].exits[0]))
}
