package nengine

import "core:slice"
import "core:testing"

// Drawing order. Whoever's feet are lower on screen is nearer the camera, so
// walking down past a table puts you in front of it and walking up puts you
// behind — and because a person's feet are their position, that follows them
// as they move without anything having to be told about it.
//
// The sort itself is a few lines in draw_world, so these tests exercise the
// same key that draws: depth band, then feet, then the order the scene file
// gave them.

@(private = "file")
Item :: struct {
	depth: Depth,
	y:     f32,
	i:     int,
	name:  string,
}

@(private = "file")
order :: proc(items: []Item) -> []string {
	slice.sort_by(items, proc(a, b: Item) -> bool {
		if a.depth != b.depth do return a.depth < b.depth
		if a.y != b.y do return a.y < b.y
		return a.i < b.i
	})
	out := make([]string, len(items), context.temp_allocator)
	for it, n in items do out[n] = it.name
	return out
}

@(test)
lower_feet_are_drawn_later_so_they_are_in_front :: proc(t: ^testing.T) {
	// She walks up the room, behind the table.
	behind := [?]Item{{.Normal, 470, 0, "table"}, {.Normal, 430, 1, "elena"}}
	testing.expect_value(t, order(behind[:])[0], "elena")
	testing.expect_value(t, order(behind[:])[1], "table") // drawn last, so in front

	// She walks down the room, in front of it.
	front := [?]Item{{.Normal, 470, 0, "table"}, {.Normal, 500, 1, "elena"}}
	testing.expect_value(t, order(front[:])[0], "table")
	testing.expect_value(t, order(front[:])[1], "elena")
}

@(test)
a_rug_is_never_in_front_and_a_bush_always_is :: proc(t: ^testing.T) {
	// The rug's feet are far down the room, so by feet alone it would be
	// drawn over somebody standing on it. It is scenery, not furniture.
	items := [?]Item {
		{.Normal, 400, 0, "elena"},
		{.Back, 600, 1, "rug"},
		{.Front, 300, 2, "bush"},
		{.Normal, 470, 3, "table"},
	}
	got := order(items[:])
	testing.expect_value(t, got[0], "rug")
	testing.expect_value(t, got[1], "elena")
	testing.expect_value(t, got[2], "table")
	testing.expect_value(t, got[3], "bush") // in front of everything, always
}

@(test)
two_things_on_the_same_line_do_not_swap_about :: proc(t: ^testing.T) {
	// The sort underneath is not stable, so without the index two objects
	// standing on exactly the same line are free to trade places from one
	// frame to the next, which reads as a flicker.
	first := [?]Item{{.Normal, 470, 0, "table"}, {.Normal, 470, 1, "chair"}}
	second := [?]Item{{.Normal, 470, 1, "chair"}, {.Normal, 470, 0, "table"}}
	testing.expect_value(t, order(first[:])[0], "table")
	testing.expect_value(t, order(second[:])[0], "table")
}

@(test)
base_moves_the_line_a_thing_stands_on_without_moving_the_thing :: proc(t: ^testing.T) {
	// A hanging sign is drawn high on the wall but belongs at the back of the
	// room; `base` says where it meets the floor, and nothing else changes.
	sign := Object{pos = {200, 300}, base = 180}
	testing.expect_value(t, sign.pos.y + sign.base, f32(480))

	items := [?]Item{{.Normal, sign.pos.y + sign.base, 0, "sign"}, {.Normal, 450, 1, "elena"}}
	testing.expect_value(t, order(items[:])[0], "elena") // she is further back
	testing.expect_value(t, order(items[:])[1], "sign")
}

@(test)
a_person_sorts_by_where_they_have_walked_to :: proc(t: ^testing.T) {
	// The reason none of this needs telling about movement: a walking
	// object's pos is copied from its actor every frame, and pos is the sort
	// key. Walking past the table is all it takes.
	s, ok := parse_scene(`scene banda
walk 0,0 640,0 640,640 0,640
obj table pos=300,470
obj elena pos=300,400 char=elena speed=200
routine elena loop
step elena walk_to 300,560
`, nil)
	testing.expect(t, ok)
	w: World
	append(&w.scenes, s)
	refresh_world(&w)
	defer {
		for &o in w.scenes[0].objects do routine_destroy(&o.routine)
		free_scene_strings(&w.scenes[0])
		delete(w.scenes[0].objects)
		delete(w.scenes[0].exits)
		delete(w.scenes[0].triggers)
		delete(w.scenes[0].walk_area)
		delete(w.scenes[0].scenery)
		delete(w.scenes[0].said)
		delete(w.scenes)
		clear_flags(&w)
	}

	elena := object_here(&w.scenes[0], "elena")
	table := object_here(&w.scenes[0], "table")
	testing.expect(t, elena.pos.y < table.pos.y, "she starts behind it")

	for _ in 0 ..< 120 {
		w.time += 1.0 / 60
		update_people(&w, &w.scenes[0], 1.0 / 60)
	}
	testing.expect(t, elena.pos.y > table.pos.y, "and has walked out in front of it")
}

@(test)
depth_and_base_survive_being_written_and_read :: proc(t: ^testing.T) {
	s, ok := parse_scene(`scene hall
obj rug pos=300,600 depth=back
obj bush pos=300,200 depth=front
obj sign pos=200,300 base=180
`, nil)
	testing.expect(t, ok)
	again, good := parse_scene(scene_text(&s), nil)
	testing.expect(t, good)
	defer {
		free_scene_strings(&s)
		delete(s.objects); delete(s.exits); delete(s.triggers)
		delete(s.walk_area); delete(s.scenery); delete(s.said)
		free_scene_strings(&again)
		delete(again.objects); delete(again.exits); delete(again.triggers)
		delete(again.walk_area); delete(again.scenery); delete(again.said)
	}

	testing.expect_value(t, find_object(&again, "rug").depth, Depth.Back)
	testing.expect_value(t, find_object(&again, "bush").depth, Depth.Front)
	testing.expect_value(t, find_object(&again, "sign").base, f32(180))
	testing.expect_value(t, find_object(&again, "sign").depth, Depth.Normal)
}

@(test)
an_object_that_spans_depth_is_split_into_two :: proc(t: ^testing.T) {
	// A long counter running away from the camera is in front of you at one
	// end and behind you at the other, and one baseline cannot say both. The
	// answer is to split the ART, not the thing: one object carries the name,
	// the description and the verbs, and a second carries the near half of
	// the picture and nothing else. The player types BAR and finds the bar,
	// because the front half is not a word anybody knows.
	s, ok := parse_scene(`scene banda
obj bar pos=300,400 sprite=bar_back
text bar Zinc, and a great deal of polishing.
on bar look Somebody has been at it with a cloth.
obj bar_front pos=300,520 sprite=bar_front
`, nil)
	testing.expect(t, ok)
	w: World
	append(&w.scenes, s)
	refresh_world(&w)
	defer {
		free_scene_strings(&w.scenes[0])
		delete(w.scenes[0].objects); delete(w.scenes[0].exits); delete(w.scenes[0].triggers)
		delete(w.scenes[0].walk_area); delete(w.scenes[0].scenery); delete(w.scenes[0].said)
		delete(w.scenes)
		clear_flags(&w)
	}
	scene := &w.scenes[0]

	// Standing between the two halves: behind the near one, in front of the
	// far one, which is the whole point.
	items := [?]Item {
		{.Normal, 400, 0, "bar_back"},
		{.Normal, 460, 1, "ada"},
		{.Normal, 520, 2, "bar_front"},
	}
	got := order(items[:])
	testing.expect_value(t, got[0], "bar_back")
	testing.expect_value(t, got[1], "ada")
	testing.expect_value(t, got[2], "bar_front")

	// And there is still only one bar as far as anything else is concerned.
	text, found := describe(scene, "bar")
	testing.expect(t, found)
	testing.expect_value(t, text, "Zinc, and a great deal of polishing.")
	look := object_interaction(&w, object_here(scene, "bar"), Command{verb = "look", noun = "bar"})
	testing.expect(t, look != nil)
	testing.expect_value(t, look.text, "Somebody has been at it with a cloth.")

	// The front half is a picture. It has no description to give.
	front := object_here(scene, "bar_front")
	testing.expect(t, front != nil)
	testing.expect_value(t, front.description, "")
}
