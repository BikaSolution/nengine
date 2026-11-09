package nengine

import "core:testing"

// Three screens in a row and a hut with a door into the middle one:
//
//     a | k | b        k is kept 10:10 to 10:20 on this clock (minutes 1010 to
//         ^            1020), and whenever it storms; out by the east, which
//         c            gate g1 (shut at night) also shuts.
@(private = "file")
KA :: `scene a
walk 0,100 400,100 400,200 0,200
side east to=k span=120,180
`
@(private = "file")
KK :: `scene k
walk 0,100 400,100 400,200 0,200
side west to=a span=120,180
side east to=b span=120,180 gate=g1
exit out area=180,190,40,10 to=c arrive=200,120
`
@(private = "file")
KB :: `scene b
walk 0,100 400,100 400,200 0,200
side west to=k span=120,180 gate=g1
`
@(private = "file")
KC :: `scene c
walk 0,100 400,100 400,200 0,200
exit in area=180,100,40,10 to=k arrive=200,180
`

@(private = "file")
KEEP_GATES := [?]Gate{{name = "g1", shut = "night", text = "Locked for the night."}}

@(private = "file")
KEEPS := [?]Keep_Out {
	{room = "k", from = 1010, until = 1020, text = "Voices.", out = "Voices, close.", out_by = "east"},
	{room = "k", only = "storm", text = "Storm."},
}

@(private = "file")
kept_row :: proc(t: ^testing.T) -> World {
	w: World
	w.gates = KEEP_GATES[:]
	w.keep_outs = KEEPS[:]
	for text in ([]string{KA, KK, KB, KC}) {
		s, ok := parse_scene(text, nil)
		testing.expect(t, ok)
		append(&w.scenes, s)
	}
	problem, ok := resolve_exits(&w)
	testing.expectf(t, ok, "resolve: %v", problem)
	refresh_world(&w)
	w.player = {pos = {200, 150}, speed = 120}
	w.time = 1
	w.clock_start = 1000
	w.clock_step = 1
	return w
}

@(private = "file")
room_now :: proc(w: ^World) -> string {
	return current_scene(w).name
}

// Walks along the heading, as update() does, until she stops or leaves.
@(private = "file")
walk_on :: proc(w: ^World, dir: [2]f32) {
	from := w.current
	w.player.heading = dir
	for _ in 0 ..< 600 {
		if w.player.heading == {0, 0} || w.current != from do break
		walk_heading(w, 1.0 / 60)
	}
}

@(test)
a_kept_room_refuses_every_way_in_for_its_window :: proc(t: ^testing.T) {
	w := kept_row(t)
	defer destroy_world(&w)
	// Before the window: in, by the arrow keys.
	w.clock_ticks = 9
	go_to(&w, 0, {380, 150})
	walk_on(&w, {1, 0})
	testing.expect_value(t, room_now(&w), "k")

	// In it: the arrow keys stop at the brink, and she is told.
	w.clock_ticks = 10
	go_to(&w, 0, {380, 150})
	w.message_len = 0
	walk_on(&w, {1, 0})
	testing.expect_value(t, room_now(&w), "a")
	testing.expect_value(t, message(&w), "Voices.")
	testing.expect_value(t, w.player.heading, [2]f32{0, 0})
	// GO WEST from the other side, and GO TO K from next door: the same.
	go_to(&w, 2, {200, 150})
	w.message_len = 0
	testing.expect(t, go_compass(&w, "west"))
	finish_walk(&w)
	testing.expect_value(t, room_now(&w), "b")
	testing.expect_value(t, message(&w), "Voices.")
	w.message_len = 0
	testing.expect(t, head_for_room(&w, "k"), "it is the way: she walks to it")
	finish_walk(&w)
	testing.expect_value(t, room_now(&w), "b")
	testing.expect_value(t, message(&w), "Voices.")
	// A door into it: the same words, and not through.
	go_to(&w, 3, {200, 150})
	w.message_len = 0
	testing.expect(t, head_for_exit(&w, "in"))
	finish_walk(&w)
	testing.expect_value(t, room_now(&w), "c")
	testing.expect_value(t, message(&w), "Voices.")
	// The window is [from, until): at its end, in again.
	w.clock_ticks = 20
	go_to(&w, 0, {380, 150})
	walk_on(&w, {1, 0})
	testing.expect_value(t, room_now(&w), "k")
}

@(test)
a_shut_gate_speaks_before_a_keep_out :: proc(t: ^testing.T) {
	w := kept_row(t)
	defer destroy_world(&w)
	set_flag(&w, "night")
	w.clock_ticks = 12
	go_to(&w, 2, {20, 150})
	w.message_len = 0
	walk_on(&w, {-1, 0})
	testing.expect_value(t, room_now(&w), "b")
	testing.expect_value(t, message(&w), "Locked for the night.")
}

@(test)
a_keep_out_with_a_condition_holds_at_any_hour :: proc(t: ^testing.T) {
	w := kept_row(t)
	defer destroy_world(&w)
	testing.expect(t, kept_out(&w, 1) == nil)
	set_flag(&w, "storm")
	k := kept_out(&w, 1)
	testing.expect(t, k != nil && k.text == "Storm.")
	w.clock_ticks = 500
	testing.expect(t, kept_out(&w, 1) != nil)
	set_flag(&w, "storm", false)
	testing.expect(t, kept_out(&w, 1) == nil)
	testing.expect(t, kept_out(&w, 0) == nil, "only the room it names")
}

@(test)
in_the_room_as_it_shuts_she_says_so_once_and_walks_out :: proc(t: ^testing.T) {
	w := kept_row(t)
	defer destroy_world(&w)
	w.clock_ticks = 9
	go_to(&w, 1, {100, 150})
	testing.expect(t, keep_out_due(&w) == nil)
	w.clock_ticks = 10
	w.message_len = 0
	keep_out_step(&w)
	testing.expect_value(t, message(&w), "Voices, close.")
	testing.expect(t, w.player.moving, "on her feet, to the east brink")
	// Sent somewhere else on the way: turned round again, without the line.
	walk_to(&w.player, {50, 150})
	w.message_len = 0
	keep_out_step(&w)
	testing.expect_value(t, message(&w), "")
	testing.expect(t, w.exit_walk.side.active)
	finish_walk(&w)
	testing.expect_value(t, room_now(&w), "b")
	// Out, and the room still kept: nothing more to do, and it forgets it went.
	testing.expect(t, keep_out_due(&w) == nil)
	testing.expect(t, !w.keep_out_going)
}

@(test)
with_its_way_out_shut_she_takes_the_nearest_open_one :: proc(t: ^testing.T) {
	w := kept_row(t)
	defer destroy_world(&w)
	set_flag(&w, "night") // g1: the east side is shut
	w.clock_ticks = 15
	go_to(&w, 1, {350, 150})
	k := keep_out_due(&w)
	testing.expect(t, k != nil)
	testing.expect(t, put_out(&w, k, walk = false))
	testing.expect_value(t, room_now(&w), "a")
	testing.expect_value(t, message(&w), "Voices, close.")
}

@(test)
the_developer_is_let_through_until_she_leaves :: proc(t: ^testing.T) {
	w := kept_row(t)
	defer destroy_world(&w)
	w.clock_ticks = 10
	go_to(&w, 1, {200, 150})
	testing.expect(t, keep_out_let_through(&w, 1))
	testing.expect(t, keep_out_due(&w) == nil, "let in: not put out")
	testing.expect(t, !keep_out_let_through(&w, 0), "a is not kept")
	go_to(&w, 0, {200, 150})
	testing.expect(t, keep_out_due(&w) == nil)
	testing.expect_value(t, w.keep_out_let, "")
	go_to(&w, 1, {200, 150})
	testing.expect(t, keep_out_due(&w) != nil, "back in by the game's hand, not the developer's: put out")
}

@(test)
no_hint_sends_her_where_she_is_kept_out :: proc(t: ^testing.T) {
	w := kept_row(t)
	defer destroy_world(&w)
	h := Hint{needs = "", place = "k", does = "look"}
	w.clock_ticks = 9
	testing.expect(t, hint_possible(&w, h))
	w.clock_ticks = 10
	testing.expect(t, !hint_possible(&w, h))
}
