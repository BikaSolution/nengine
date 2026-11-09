package main

import ne "../../"
import "core:strings"
import "core:testing"

// `nscene world` (world.odin), on WORLD.md's floor template: the walk band
// canvas y 384..624, full width; east and west cross in y 400..608, north and
// south in x 384..640.

@(private = "file")
room :: proc(name: string, lines: ..string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "scene ")
	strings.write_string(&b, name)
	strings.write_string(&b, "\nwalk 0,384 1024,384 1024,624 0,624\n")
	for l in lines {
		strings.write_string(&b, l)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

@(private = "file")
world_of :: proc(texts: ..string) -> ne.World {
	w: ne.World
	for t in texts {
		s, _ := ne.parse_scene(t, nil)
		append(&w.scenes, s)
	}
	return w
}

@(private = "file")
says :: proc(r: ^World_Report, code: World_Code, room: string, words := "") -> bool {
	for f in r.findings do if f.code == code && f.room == room && strings.contains(f.what, words) do return true
	return false
}

// nw | ne
// ---+---   the gate g1 between ne and se, both sides
// sw | se
@(private = "file")
square :: proc() -> ne.World {
	return world_of(
		room("nw", "side east to=ne span=400,608", "side south to=sw span=384,640"),
		room("ne", "side west to=nw span=400,608", "side south to=se span=448,576 gate=g1", "shut south Padlocked."),
		room("sw", "side north to=nw span=384,640", "side east to=se span=400,608"),
		room("se", "side north to=ne span=448,576 gate=g1", "shut north Padlocked.", "side west to=sw span=400,608"),
	)
}

@(test)
a_sound_world_has_nothing_to_say_but_its_gates :: proc(t: ^testing.T) {
	w := square()
	defer ne.destroy_world(&w)
	r := world_audit(w.scenes[:], "nw")
	for f in r.findings do testing.expectf(t, f.code == .Gated, "unexpected: %v %v %v", WORLD_CODE[f.code], f.room, f.what)
	testing.expect_value(t, r.sides, 8)
	testing.expect_value(t, r.sided, 4)
	testing.expectf(t, strings.contains(r.grid, "[nw]--[ne]\n"), "%v", r.grid)
	testing.expectf(t, strings.contains(r.grid, "[sw]--[se]\n"), "%v", r.grid)
	lines := strings.split_lines(r.grid, context.temp_allocator)
	testing.expectf(t, strings.contains(lines[1], "|") && strings.contains(lines[1], "="), "the north-south sides: %q", lines[1])
	text := world_report_text(&r, "nw")
	testing.expect(t, strings.contains(text, "4 rooms, 4 with sides, 8 sides"))
}

// --strict passes the info lines (a gate's own words said, what a gate cuts
// off) and fails on anything more.
@(test)
strict_passes_only_the_info_lines :: proc(t: ^testing.T) {
	w := world_of(
		room("a", "side east to=b span=400,608 gate=g1"),
		room("b", "side west to=a span=400,608 gate=g1"),
	)
	defer ne.destroy_world(&w)
	r := world_audit(w.scenes[:], "a")
	testing.expect(t, says(&r, .Gate, "a", "the gate's own words"))
	testing.expect(t, !world_fails(&r, strict = true), "only info lines")
	w2 := world_of(
		room("a", "side east to=b span=400,608 when=day"),
		room("b", "side west to=a span=400,608 when=day,!rain"),
	)
	defer ne.destroy_world(&w2)
	r2 := world_audit(w2.scenes[:], "a")
	testing.expect(t, says(&r2, .When, "a"))
	testing.expect(t, !world_fails(&r2), "a when= that may differ is only a warning")
	testing.expect(t, world_fails(&r2, strict = true), "but strict fails it")
}

@(test)
a_side_needs_a_partner_facing_back :: proc(t: ^testing.T) {
	{
		w := world_of(room("a", "side east to=b span=400,608"), room("b"))
		defer ne.destroy_world(&w)
		r := world_audit(w.scenes[:], "a")
		testing.expect(t, says(&r, .Partner, "a", "b has no west side back here"))
	}
	{
		w := world_of(room("a", "side east to=b span=400,608"), room("b", "side north to=a span=384,640"))
		defer ne.destroy_world(&w)
		r := world_audit(w.scenes[:], "a")
		testing.expect(t, says(&r, .Dir, "a", "faces north, not west"))
	}
	{
		w := world_of(room("a", "side east to=nowhere span=400,608"))
		defer ne.destroy_world(&w)
		r := world_audit(w.scenes[:], "a")
		testing.expect(t, says(&r, .Partner, "a", "no room called that"))
	}
}

@(test)
east_and_west_spans_must_agree :: proc(t: ^testing.T) {
	w := world_of(room("a", "side east to=b span=400,608"), room("b", "side west to=a span=430,608"))
	defer ne.destroy_world(&w)
	r := world_audit(w.scenes[:], "a")
	testing.expect(t, says(&r, .Span, "a", "share the floor template"))
	testing.expect(t, says(&r, .Span, "b", "share the floor template"))
}

@(test)
landing_in_something_solid_is_found :: proc(t: ^testing.T) {
	w := world_of(
		room("a", "side north to=b span=384,640"),
		room("b", "side south to=a span=384,640", "obj cart pos=500,600 block=box:80,40"),
	)
	defer ne.destroy_world(&w)
	r := world_audit(w.scenes[:], "a")
	testing.expect(t, says(&r, .Span, "a", "inside cart"))
	testing.expect(t, !says(&r, .Span, "b"), "leaving b north lands in a, which is clear")
}

@(test)
north_south_pairs_keep_one_proportion :: proc(t: ^testing.T) {
	w := world_of(
		room("r0", "side north to=r1 span=384,640"),
		room("r1", "side south to=r0 span=384,640", "side north to=r2 span=384,640"),
		room("r2", "side south to=r1 span=384,640", "side north to=r3 span=384,640"),
		room("r3", "side south to=r2 span=384,512"),
	)
	defer ne.destroy_world(&w)
	r := world_audit(w.scenes[:], "r0")
	testing.expect(t, says(&r, .Span, "r2", "off the template"))
	testing.expect(t, !says(&r, .Span, "r0"))
}

@(test)
gates_and_conditions_on_both_partners :: proc(t: ^testing.T) {
	w := world_of(
		room("a", "side east to=b span=400,608 gate=g1", "side south to=c span=384,640 when=day"),
		room("b", "side west to=a span=400,608"),
		room("c", "side north to=a span=384,640 when=!day"),
	)
	defer ne.destroy_world(&w)
	r := world_audit(w.scenes[:], "a")
	testing.expect(t, says(&r, .Gate, "a", `gate "g1" here, "" on b's side back`))
	testing.expect(t, says(&r, .Gate, "a", "no `shut east` line"))
	testing.expect(t, says(&r, .When, "a", "can never both hold"))
	w2 := world_of(room("a", "side east to=b span=400,608 when=day"), room("b", "side west to=a span=400,608 when=day,warm"))
	defer ne.destroy_world(&w2)
	r2 := world_audit(w2.scenes[:], "a")
	testing.expect(t, says(&r2, .When, "a", "the same times?"))
}

@(test)
every_room_with_a_side_can_be_reached :: proc(t: ^testing.T) {
	w := world_of(
		room("gate", "side south to=track span=448,576 gate=g1", "exit hut area=10,400,40,40 to=hut arrive=500,500"),
		room("track", "side north to=gate span=448,576 gate=g1"),
		room("hut"),
		room("island", "side east to=isle span=400,608"),
		room("isle", "side west to=island span=400,608"),
	)
	defer ne.destroy_world(&w)
	r := world_audit(w.scenes[:], "gate")
	testing.expect(t, says(&r, .Reach, "island", "cannot be walked to from gate"))
	testing.expect(t, says(&r, .Reach, "isle"))
	testing.expect(t, !says(&r, .Reach, "hut"), "a room with no side is not the audit's to place")
	testing.expect(t, says(&r, .Gated, "gate", "gate g1 shut cuts off track"))
	r2 := world_audit(w.scenes[:], "nowhere")
	testing.expect(t, says(&r2, .Reach, "nowhere", "names no room"))
}

@(test)
the_sides_must_make_a_grid :: proc(t: ^testing.T) {
	// a - b - c along the top, and c south of a as well: two places at once.
	w := world_of(
		room("a", "side east to=b span=400,608", "side south to=c span=384,640"),
		room("b", "side west to=a span=400,608", "side east to=c span=400,608"),
		room("c", "side west to=b span=400,608", "side north to=a span=384,640"),
	)
	defer ne.destroy_world(&w)
	r := world_audit(w.scenes[:], "a")
	testing.expect(t, says(&r, .Grid, "c"))
	// A long walk is off the grid, and listed after it.
	w2 := world_of(room("track", "side west to=far span=400,608 arrive=480,600"), room("far"))
	defer ne.destroy_world(&w2)
	r2 := world_audit(w2.scenes[:], "track")
	testing.expect(t, !says(&r2, .Partner, "track"), "a long walk wants no partner")
	testing.expect(t, strings.contains(r2.grid, "long walks:\n  track west -> far (480,600)"), r2.grid)
	w3 := world_of(room("track", "side west to=far span=400,608 arrive=480,100"), room("far"))
	defer ne.destroy_world(&w3)
	r3 := world_audit(w3.scenes[:], "track")
	testing.expect(t, says(&r3, .Span, "track", "off that room's floor"))
}

@(test)
what_stands_at_a_side_is_found :: proc(t: ^testing.T) {
	w := world_of(
		room("a", "side east to=b span=400,608 name=lines", "exit lines area=980,420,44,100 to=hut arrive=500,500", "edge drop action=fall 0,300 1024,300 1024,380 0,380", "side north to=c span=384,640"),
		room("b", "side west to=a span=400,608"),
		room("c", "side south to=a span=384,640"),
		room("hut"),
	)
	defer ne.destroy_world(&w)
	r := world_audit(w.scenes[:], "a")
	testing.expect(t, says(&r, .Exit, "a", "exit lines is in the lane"))
	testing.expect(t, says(&r, .Name, "a", "exit lines answers to the same word"))
	testing.expect(t, says(&r, .Edge, "a", "edge drop is at the brink"))
}

@(test)
a_span_must_have_floor_along_it :: proc(t: ^testing.T) {
	w := world_of(
		"scene a\nwalk 300,384 900,384 900,624 300,624\nside north to=b span=100,400\nside west to=b span=400,608\n",
		"scene b\nwalk 0,384 1024,384 1024,624 0,624\nside south to=a span=100,400\nside east to=a span=400,608\n",
	)
	defer ne.destroy_world(&w)
	r := world_audit(w.scenes[:], "a")
	testing.expect(t, says(&r, .Floor, "a", "no floor at"))
	testing.expect(t, says(&r, .Floor, "a", "px in from the west border"))
}

@(test)
alternatives_are_compatible_if_any_pair_is :: proc(t: ^testing.T) {
	testing.expect(t, compatible("day|night", "night"))
	testing.expect(t, !compatible("a,b|a,c", "!a"))
	testing.expect(t, compatible("a,b|!a", "!a"))
	testing.expect(t, !compatible("x", "!x|!x,y"))
}

// --- The document's sides ---

@(test)
sides_are_added_shut_moved_and_removed_a_line_at_a_time :: proc(t: ^testing.T) {
	d: Doc
	defer doc_destroy(&d)
	doc_set_text_all(&d, "scene a\nwalk 0,384 1024,384 1024,624 0,624\nexit door area=0,0,10,10 to=b arrive=1,1\n# a note\n")
	i := doc_add_side(&d, .South, "track", {576, 448})
	testing.expect_value(t, len(d.sides), 1)
	testing.expect_value(t, d.lines[d.sides[i].line], "side south to=track span=448,576")
	doc_set_side_shut(&d, i, "Padlocked.")
	testing.expect_value(t, d.lines[d.sides[i].line + 1], "shut south Padlocked.")
	testing.expect_value(t, d.strays, 0)
	doc_set_side_span(&d, i, {450, 580})
	testing.expect_value(t, d.sides[i].span, [2]f32{450, 580})
	doc_set_side_dir(&d, i, .North)
	testing.expect_value(t, d.sides[i].dir, ne.Compass.North)
	testing.expect_value(t, d.lines[d.sides[i].line + 1], "shut north Padlocked.")
	j := doc_add_side(&d, .East, "", {400, 608})
	testing.expect_value(t, d.lines[d.sides[j].line], "side east to=nowhere span=400,608")
	testing.expect(t, d.sides[j].line > d.sides[i].line + 1, "after the last side and its shut line")
	doc_remove_side(&d, i)
	testing.expect_value(t, len(d.sides), 1)
	testing.expect(t, !strings.contains(doc_text(&d), "shut north"))
	testing.expect(t, strings.contains(doc_text(&d), "# a note\n"))
	// A `shut` for a way no side faces is a stray, as for an exit.
	doc_set_text_all(&d, "scene a\nshut west Nothing.\n")
	testing.expect_value(t, d.strays, 1)
}

@(test)
border_exits_are_proposed_as_sides :: proc(t: ^testing.T) {
	d: Doc
	defer doc_destroy(&d)
	// main_gate as it was: the compound west, the track south behind a
	// three-line gate, and the hut's door in the middle of the floor.
	doc_set_text_all(&d, `scene main_gate
walk 4,506 358,422 666,422 1018,496 1018,634 320,634 154,592 4,550
exit compound area=0,505,24,42 to=fire_pit arrive=512,590
exit track area=420,612,190,24 to=track arrive=512,420 when=!dusk
exit track area=420,612,190,24 to=track arrive=512,420 when=main_gate_open
exit track area=420,612,190,24 to=track arrive=512,420 when=dusk,!main_gate_open closed=true
shut track Padlocked at dusk.
exit hut area=500,500,40,40 to=moore_hut arrive=512,580
`)
	plans := sides_from_exits(&d)
	testing.expect_value(t, len(plans), 2)
	testing.expect_value(t, plans[0].dir, ne.Compass.West)
	testing.expect_value(t, plans[0].span, [2]f32{512, 544})
	testing.expect_value(t, plans[1].dir, ne.Compass.South)
	testing.expect_value(t, plans[1].lines, 3)
	testing.expect(t, plans[1].gated)
	testing.expect_value(t, plans[1].shut, "Padlocked at dusk.")
}
