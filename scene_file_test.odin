package nengine

import "core:strings"
import "core:testing"

@(private = "file")
rooms :: proc(t: ^testing.T, texts: ..string) -> World {
	w: World
	for text in texts {
		s, ok := parse_scene(text, nil)
		testing.expect(t, ok)
		append(&w.scenes, s)
	}
	return w
}

@(private = "file")
tidy_rooms :: proc(w: ^World) {
	for &sc in w.scenes {
		free_scene_strings(&sc)
		delete(sc.objects)
		delete(sc.exits)
		delete(sc.triggers)
		delete(sc.walk_area)
		delete(sc.scenery)
		delete(sc.said)
	}
	delete(w.scenes)
}

@(private = "file")
ROW :: `scene tent_row
walk 0,0 640,0 640,480 0,480
peep window pos=200,260 into=kitchen kind=window blind=night walk_to=200,300 reach=box:80,60 frame=window_frame
text window The kitchen window, propped open for the heat.
peep net5 pos=612,300 into=tent dress=5 kind=net blind=lamp_in_5 walk_to=612,330 when=act2
`

@(test)
a_peep_loads_with_its_far_room :: proc(t: ^testing.T) {
	w := rooms(t, ROW, "scene kitchen\nwalk 0,0 10,0 10,10\n", "scene tent\nwalk 0,0 10,0 10,10\n")
	defer tidy_rooms(&w)
	_, ok := resolve_exits(&w)
	testing.expect(t, ok)

	win := find_object(&w.scenes[0], "window")
	testing.expect(t, win != nil && win.peep.is)
	testing.expect_value(t, win.peep.into, "kitchen")
	testing.expect_value(t, win.peep.into_at, 1)
	testing.expect_value(t, win.peep.kind, Peep_Kind.Window)
	testing.expect_value(t, win.peep.blind, "night")
	testing.expect_value(t, win.peep.frame, "window_frame")
	testing.expect_value(t, win.walk_to, [2]f32{200, 300})
	testing.expect_value(t, win.reach.kind, Shape_Kind.Box)
	testing.expect_value(t, win.description, "The kitchen window, propped open for the heat.")
	// The parser finds it by name like any other object.
	testing.expect(t, object_here(&w.scenes[0], "window") != nil)

	// And the room editor saving the file writes it back as a peep.
	text := scene_text(&w.scenes[0])
	testing.expect(t, strings.contains(text, "peep window pos=200,260 into=kitchen kind=window blind=night frame=window_frame"))
}

@(test)
a_peep_into_a_dressing_names_the_dressing :: proc(t: ^testing.T) {
	w := rooms(t, ROW, "scene kitchen\nwalk 0,0 10,0 10,10\n", "scene tent\nwalk 0,0 10,0 10,10\n")
	defer tidy_rooms(&w)
	_, ok := resolve_exits(&w)
	testing.expect(t, ok)

	net := find_object(&w.scenes[0], "net5")
	testing.expect_value(t, net.peep.into_at, 2)
	testing.expect_value(t, net.peep.dress, "5")
	testing.expect_value(t, peep_dress_flag(net.peep), "tent_5")
	testing.expect_value(t, net.peep.kind, Peep_Kind.Net)
	testing.expect(t, strings.contains(scene_text(&w.scenes[0]), "peep net5 pos=612,300 into=tent dress=5 kind=net blind=lamp_in_5"))
}

@(test)
an_unknown_far_room_is_an_error :: proc(t: ^testing.T) {
	w := rooms(t, ROW, "scene tent\nwalk 0,0 10,0 10,10\n") // no kitchen
	defer tidy_rooms(&w)
	problem, ok := resolve_exits(&w)
	testing.expect(t, !ok)
	testing.expect_value(t, problem, "tent_row: peep window looks into kitchen, and there is no room called that")
}

@(private = "file")
DECK :: `scene deck
walk 100,100 500,100 500,400 100,400
trigger find_bodies area=0,0,640,480 action=find_bodies
trigger rail area=450,100,50,50 action=rail
`

@(private = "file", thread_local)
found_count: int

@(test)
a_whole_floor_trigger_fires_on_arrival :: proc(t: ^testing.T) {
	w := rooms(t, "scene path\nwalk 0,0 10,0 10,10\n", DECK)
	defer tidy_rooms(&w)
	refresh_world(&w)
	found_count = 0
	scene_bind_trigger(&w.scenes[1], "find_bodies", proc(w: ^World) {found_count += 1})
	scene_bind_trigger(&w.scenes[1], "rail", proc(w: ^World) {found_count += 100})

	go_to(&w, 1, {470, 120}) // arrives standing in both
	testing.expect(t, check_triggers(&w, w.player.pos))
	testing.expect_value(t, found_count, 1) // the whole floor fires; the rail waits to be stepped into
	testing.expect(t, !check_triggers(&w, w.player.pos), "once per arrival")
	testing.expect_value(t, found_count, 1)
}

// A still object's `frame=` (a door drawn shut on its second frame) used to be
// read and never written, so a room saved through scene_text lost it.
@(test)
an_objects_frame_survives_being_written :: proc(t: ^testing.T) {
	w := rooms(t, "scene hall\nwalk 0,0 10,0 10,10\nobj door pos=5,5 sprite=door frame=2\n")
	defer tidy_rooms(&w)
	text := scene_text(&w.scenes[0])
	testing.expect(t, strings.contains(text, "obj door pos=5,5 sprite=door frame=2"), text)
	back, ok := parse_scene(text, nil)
	testing.expect(t, ok)
	testing.expect_value(t, back.objects[0].frame, 2)
	free_scene_strings(&back)
	delete(back.objects); delete(back.exits); delete(back.triggers); delete(back.walk_area); delete(back.scenery); delete(back.said)
}

// A layer drifting over the backdrop: read, and written back as it was read,
// so the room editor saves what it loaded.
@(test)
a_drifting_layer_survives_being_written :: proc(t: ^testing.T) {
	w := rooms(t, "scene shore\nbg shore\ndrift clouds speed=6 y=0\ndrift water speed=24.5 y=300 fps=5\nwalk 0,0 10,0 10,10\n")
	defer tidy_rooms(&w)
	sc := &w.scenes[0]
	testing.expect_value(t, len(sc.drifts), 2)
	testing.expect_value(t, sc.drifts[0].name, "clouds")
	testing.expect_value(t, sc.drifts[0].layer.speed, f32(6))
	testing.expect_value(t, sc.drifts[0].layer.fps, f32(0))
	testing.expect_value(t, sc.drifts[1].name, "water")
	testing.expect_value(t, sc.drifts[1].layer.speed, f32(24.5))
	testing.expect_value(t, sc.drifts[1].layer.y, f32(300))
	testing.expect_value(t, sc.drifts[1].layer.fps, f32(5))
	text := scene_text(sc)
	testing.expect(t, strings.contains(text, "bg shore\ndrift clouds speed=6 y=0\ndrift water speed=24.5 y=300 fps=5\n"), text)
	back, ok := parse_scene(text, nil)
	testing.expect(t, ok)
	testing.expect_value(t, len(back.drifts), 2)
	testing.expect_value(t, scene_text(&back), text)
	free_scene_strings(&back)
	delete(back.objects); delete(back.exits); delete(back.triggers); delete(back.walk_area); delete(back.scenery); delete(back.said)
}

// Its paintings are found as a backdrop's are, one for each light it was
// painted in, and it drifts and plays as a title screen's layer does.
@(test)
a_drifting_layer_is_painted_for_each_light_and_drifts :: proc(t: ^testing.T) {
	a: Assets
	a.sprites = make(map[string]Sprite)
	defer delete(a.sprites)
	a.sprites["water"] = Sprite{frame_w = 320, frame_h = 5, frames = 3}
	a.sprites["water.night"] = Sprite{frame_w = 320, frame_h = 7, frames = 3}
	s, ok := parse_scene("scene shore\ndrift water speed=24 y=300 fps=5\n", &a)
	testing.expect(t, ok)
	d := s.drifts[0]
	testing.expect_value(t, d.lit.painted, bit_set[Light]{.Day, .Night})
	testing.expect_value(t, d.lit.by[.Night].frame_h, 7)
	testing.expect_value(t, d.lit.by[.Sunset].frame_h, 5) // not painted for it: borrows the day's
	testing.expect_value(t, d.layer.sprite.frame_h, 5)

	// Left at its speed, and round again after a whole width with no gap.
	l := d.layer
	testing.expect_value(t, layer_offset(0, l.speed, 320), 0)
	testing.expect_value(t, layer_offset(1, l.speed, 320), -24)
	testing.expect_value(t, layer_offset(14, l.speed, 320), -16) // 336 gone: a width and 16
	for i in 0 ..< 500 {
		o := layer_offset(f32(i) * 0.113, l.speed, 320)
		testing.expectf(t, o <= 0 && o > -320, "offset %v out of range", o)
	}
	// Its three frames, five a second.
	testing.expect_value(t, layer_frame(l, 0.2), 1)
	testing.expect_value(t, layer_frame(l, 0.65), 0)

	free_scene_strings(&s)
	delete(s.objects); delete(s.exits); delete(s.triggers); delete(s.walk_area); delete(s.scenery); delete(s.said)
}
