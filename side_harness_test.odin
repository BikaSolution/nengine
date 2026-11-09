package nengine

import "core:strings"
import "core:testing"

// `!sides` and `!cross` (side_harness.odin), on WORLD.md's floor template: the
// band canvas y 384..624, full width; east and west cross in y 400..608, north
// and south in x 384..640. `!strip` draws, so it is a smoke row, not a test.

@(private = "file")
TWO_A :: `scene a
walk 0,384 1024,384 1024,624 0,624
side east to=b span=400,608 name=yard
side south to=b span=384,640 gate=lock
shut south Bolted.
side west to=b span=400,608 when=dawn
`
@(private = "file")
TWO_B :: `scene b
walk 0,384 1024,384 1024,624 0,624
side west to=a span=400,608
side north to=a span=384,640 gate=lock
`

@(private = "file")
LOCKS := [?]Gate{{name = "lock", shut = "night", text = "Locked."}}

@(private = "file")
two :: proc(t: ^testing.T) -> World {
	w: World
	w.gates = LOCKS[:]
	for text in ([]string{TWO_A, TWO_B}) {
		s, ok := parse_scene(text, nil)
		testing.expect(t, ok)
		append(&w.scenes, s)
	}
	_, ok := resolve_exits(&w)
	testing.expect(t, ok)
	refresh_world(&w)
	w.player = {pos = {512, 500}, speed = 120}
	w.time = 1
	return w
}

@(test)
sides_bang_says_what_each_side_is :: proc(t: ^testing.T) {
	w := two(t)
	defer destroy_world(&w)
	said := sides_bang(&w)
	testing.expectf(t, strings.contains(said, "east -> b span 400..608 brink 1023,400..1023,608 name yard partner ok"), "%v", said)
	testing.expectf(t, strings.contains(said, "south -> b span 384..640"), "%v", said)
	testing.expectf(t, strings.contains(said, "gate lock open partner ok"), "%v", said)
	testing.expectf(t, strings.contains(said, "west -> b span 400..608"), "%v", said)
	testing.expectf(t, strings.contains(said, "(hidden: when=dawn) NO PARTNER"), "%v", said)
	set_flag(&w, "night")
	testing.expectf(t, strings.contains(sides_bang(&w), `gate lock SHUT "Bolted."`), "%v", sides_bang(&w))
	go_to(&w, 1, {512, 500})
	testing.expectf(t, strings.contains(sides_bang(&w), `gate lock SHUT "Locked."`), "%v", sides_bang(&w))
	w2: World
	defer destroy_world(&w2)
	s, _ := parse_scene("scene c\nwalk 0,0 10,0 10,10 0,10\n", nil)
	append(&w2.scenes, s)
	testing.expect_value(t, sides_bang(&w2), "no sides")
}

@(test)
cross_bang_crosses_every_way :: proc(t: ^testing.T) {
	w := two(t)
	defer destroy_world(&w)
	said := cross_bang(&w, "east")
	testing.expectf(t, strings.has_prefix(said, "crossed east to b at 25,500"), "%v", said)
	said = cross_bang(&w, "west by=arrow at=450")
	testing.expectf(t, strings.has_prefix(said, "crossed west to a at 999,450"), "%v", said)
	said = cross_bang(&w, "south by=click at=500")
	testing.expectf(t, strings.has_prefix(said, "crossed south to b at 500,409"), "%v", said)
	testing.expect_value(t, cross_bang(&w, "east"), "no side east")
	testing.expect(t, strings.has_prefix(cross_bang(&w, "sideways"), "!cross"))
	testing.expect(t, strings.has_prefix(cross_bang(&w, "north by=boat"), "!cross"))
	// A shut gate: she walks to it and is told.
	set_flag(&w, "night")
	said = cross_bang(&w, "north")
	testing.expectf(t, strings.contains(said, "Locked."), "%v", said)
	testing.expect_value(t, current_scene(&w).name, "b")
}
