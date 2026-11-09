package nengine

import "core:strings"
import "core:testing"

// A frame that holds shows for that many ticks; the others for one.
@(test)
a_held_frame_shows_for_longer :: proc(t: ^testing.T) {
	holds := []i32{1, 2, 1, 3} // seven ticks; at ten a second, 0.7s
	testing.expect_value(t, anim_ticks(4, holds), i32(7))
	testing.expect_value(t, anim_secs(4, 10, holds), f32(0.7))

	at :: proc(secs: f32, holds: []i32, loop := true) -> i32 {
		f, _ := anim_frame(secs, 10, 4, holds, loop)
		return f
	}
	testing.expect_value(t, at(0.00, holds), i32(0))
	testing.expect_value(t, at(0.15, holds), i32(1))
	testing.expect_value(t, at(0.25, holds), i32(1)) // still the held one
	testing.expect_value(t, at(0.35, holds), i32(2))
	testing.expect_value(t, at(0.45, holds), i32(3))
	testing.expect_value(t, at(0.65, holds), i32(3)) // the long hold at the end
	testing.expect_value(t, at(0.75, holds), i32(0)) // and round again

	// Played once, it stops on its last frame and says so.
	f, done := anim_frame(0.75, 10, 4, holds, loop = false)
	testing.expect_value(t, f, i32(3))
	testing.expect(t, done)
	_, done = anim_frame(0.65, 10, 4, holds, loop = false)
	testing.expect(t, !done)

	// No holds at all is one tick a frame, as it always was.
	g, _ := anim_frame(0.25, 10, 4, nil)
	testing.expect_value(t, g, i32(2))
}

@(test)
a_hold_survives_the_character_file :: proc(t: ^testing.T) {
	c, ok := parse_character(`character ada
size 2 2
pal # 10,10,10,255
part pick_up frames=3 fps=8
frame 0
#.
..
frame 1 hold=3
.#
..
frame 2
..
#.
`)
	testing.expect(t, ok)
	defer character_destroy(&c)
	p := character_part(&c, "pick_up")
	testing.expect(t, p != nil)
	testing.expect_value(t, sprite_data_hold(&p.data, 0), i32(1))
	testing.expect_value(t, sprite_data_hold(&p.data, 1), i32(3))
	testing.expect_value(t, sprite_data_hold(&p.data, 2), i32(1))

	text := character_text(&c)
	testing.expect(t, strings.contains(text, "frame 1 hold=3\n"))
	testing.expect(t, strings.contains(text, "frame 0\n"), "a frame left at one says nothing")

	back, good := parse_character(text)
	testing.expect(t, good)
	defer character_destroy(&back)
	testing.expect_value(t, sprite_data_hold(&character_part(&back, "pick_up").data, 1), i32(3))

	// A copy of the pose holds the same.
	copied := character_copy_part(&c, "pick_up", "pick_up_2")
	testing.expect_value(t, sprite_data_hold(&copied.data, 1), i32(3))
}

// Art for the tests: a part with no real texture behind it, which is enough
// for timing as long as nothing draws it.
@(private = "file")
fake_art :: proc() -> Character_Art {
	art := Character_Art{name = "ada"}
	art.parts = make(map[string]Part_Art, context.temp_allocator)
	// Four frames at ten a second, the last held for three: 0.6s a time through.
	@(static) holds := [4]i32{1, 1, 1, 3}
	art.parts["pick_up"] = {sprite = {texture = {id = 1}, frames = 4}, fps = 10, holds = holds[:]}
	art.parts["wave"] = {sprite = {texture = {id = 1}, frames = 2}, fps = 10}
	art.parts["climb_up"] = {sprite = {texture = {id = 1}, frames = 4}, fps = 8}
	art.parts["climb_off"] = {sprite = {texture = {id = 1}, frames = 2}, fps = 8}
	return art
}

@(private = "file")
run :: proc(a: ^Actor, secs: f32, step: f32 = 1.0 / 60) {
	for t := f32(0); t < secs; t += step do actor_tick(a, step, a.pos)
}

@(test)
played_once_it_ends_and_hands_back_the_pose :: proc(t: ^testing.T) {
	art := fake_art()
	a := Actor{character = &art, pose = "sit"}

	actor_play(&a, "pick_up")
	testing.expect(t, actor_playing(&a))
	testing.expect_value(t, actor_part_secs(&a, "pick_up"), f32(0.6))
	run(&a, 0.5)
	testing.expect(t, actor_playing(&a), "half a second in, still reaching")
	run(&a, 0.2)
	testing.expect(t, !actor_playing(&a), "done")
	testing.expect_value(t, a.pose, "sit") // never touched

	// Three times through is three times as long.
	actor_play(&a, "wave", times = 3)
	run(&a, 0.5)
	testing.expect(t, actor_playing(&a))
	run(&a, 0.2)
	testing.expect(t, !actor_playing(&a))

	// Round and round, for so many seconds.
	actor_play(&a, "wave", times = 0, secs = 1)
	run(&a, 0.9)
	testing.expect(t, actor_playing(&a))
	run(&a, 0.2)
	testing.expect(t, !actor_playing(&a))

	// Nobody has drawn it: it is over before it starts.
	actor_play(&a, "somersault")
	run(&a, 1.0 / 60)
	testing.expect(t, !actor_playing(&a))
}

// TAKE CUP with `anim=pick_up`: she walks over, reaches, and the cup is taken
// at the end of the reach, not at the start of it.
@(private = "file")
CAFE :: `scene cafe
walk 0,0 640,0 640,480 0,480
obj cup pos=300,200 walk_to=300,240
text cup A cup.
on cup take anim=pick_up You pick up the cup.
on cup drink anim=no_such_part You drink. It is cold.
`

@(private = "file")
open_cafe :: proc(t: ^testing.T, art: ^Character_Art) -> World {
	s, ok := parse_scene(CAFE, nil)
	testing.expect(t, ok)
	w: World
	@(static) words := [?]Word{{.Noun, "cup", ""}}
	w.vocab = vocab_join(words[:], context.temp_allocator)
	append(&w.scenes, s)
	refresh_world(&w)
	w.player = {pos = {300, 240}, speed = 120, character = art}
	return w
}

@(private = "file")
shut_cafe :: proc(w: ^World) {
	free_scene_strings(&w.scenes[0])
	delete(w.scenes[0].objects)
	delete(w.scenes[0].exits)
	delete(w.scenes[0].triggers)
	delete(w.scenes[0].walk_area)
	delete(w.scenes[0].scenery)
	delete(w.scenes[0].said)
	delete(w.scenes)
	clear_flags(w)
}

@(test)
the_verb_waits_for_the_gesture :: proc(t: ^testing.T) {
	art := fake_art()
	w := open_cafe(t, &art)
	defer shut_cafe(&w)

	run_command(&w, "take cup")
	testing.expect(t, actor_playing(&w.player), "she reaches")
	testing.expect_value(t, message(&w), "") // the cup is not taken yet

	testing.expect_value(t, finish_player_anim(&w), "pick_up")
	testing.expect_value(t, message(&w), "You pick up the cup.")
	testing.expect(t, !w.after_anim.active)
}

@(test)
typing_over_a_gesture_finishes_it_first :: proc(t: ^testing.T) {
	art := fake_art()
	w := open_cafe(t, &art)
	defer shut_cafe(&w)

	run_command(&w, "take cup")
	run_command(&w, "look at cup")
	// The cup was taken before she looked at it, and the look is what shows.
	testing.expect(t, !actor_playing(&w.player))
	testing.expect_value(t, message(&w), "A cup.")
}

@(test)
an_undrawn_gesture_does_not_hold_the_game_up :: proc(t: ^testing.T) {
	art := fake_art()
	w := open_cafe(t, &art)
	defer shut_cafe(&w)

	run_command(&w, "drink cup")
	testing.expect(t, !actor_playing(&w.player))
	testing.expect_value(t, message(&w), "You drink. It is cold.")
}

@(test)
anim_on_an_interaction_survives_the_scene_file :: proc(t: ^testing.T) {
	s, ok := parse_scene(CAFE, nil)
	testing.expect(t, ok)
	defer {
		free_scene_strings(&s)
		delete(s.objects)
		delete(s.exits)
		delete(s.triggers)
		delete(s.walk_area)
		delete(s.scenery)
		delete(s.said)
	}
	testing.expect(t, strings.contains(scene_text(&s), "on cup take anim=pick_up You pick up the cup."))
}

@(test)
a_routine_can_play_something_once :: proc(t: ^testing.T) {
	once, ok := parse_step(parse_line("step elena play wave once"), "step elena play wave once")
	testing.expect(t, ok)
	defer free_step(&once)
	testing.expect_value(t, once.times, 1)
	testing.expect_value(t, step_text(once, "elena"), "step elena play wave once")

	thrice, ok2 := parse_step(parse_line("step elena play wave 3x"), "step elena play wave 3x")
	testing.expect(t, ok2)
	defer free_step(&thrice)
	testing.expect_value(t, thrice.times, 3)
	testing.expect_value(t, step_text(thrice, "elena"), "step elena play wave 3x")

	timed, ok3 := parse_step(parse_line("step elena play cleaning 4"), "step elena play cleaning 4")
	testing.expect(t, ok3)
	defer free_step(&timed)
	testing.expect_value(t, timed.times, 0)
	testing.expect_value(t, timed.secs, f32(4))
}

@(test)
a_cutscene_can_play_a_part :: proc(t: ^testing.T) {
	c, ok := parse_cutscene(`cut x
cast ada char=ada at=100,400 facing=right
0.5 ada play pick_up once
1.0 ada play wave 3x
2.0 ada play cleaning 2.5
`)
	testing.expect(t, ok)
	defer cutscene_destroy(&c)
	testing.expect_value(t, len(c.cues), 3)
	testing.expect_value(t, c.cues[0].action, Cue_Action.Play)
	testing.expect_value(t, c.cues[0].text, "pick_up")
	testing.expect_value(t, c.cues[0].times, 1)
	testing.expect_value(t, c.cues[1].times, 3)
	testing.expect_value(t, c.cues[2].times, 0)
	testing.expect_value(t, c.cues[2].amount, f32(2.5))

	text := cutscene_text(&c)
	testing.expect(t, strings.contains(text, "0.50 ada play pick_up once\n"))
	testing.expect(t, strings.contains(text, "1.00 ada play wave 3x\n"))
	testing.expect(t, strings.contains(text, "2.00 ada play cleaning 2.50\n"))
}

@(private = "file")
free_step :: proc(s: ^Routine_Step) {
	delete(s.pose)
	delete(s.text)
}

// A yard with a ladder up to a loft. The ladder's exit is climbed, not walked.
@(private = "file")
yard_and_loft :: proc(art: ^Character_Art) -> World {
	w: World
	yard := Scene{name = "yard"}
	loft := Scene{name = "loft"}
	@(static) floor := [4][2]f32{{0, 0}, {640, 0}, {640, 480}, {0, 480}}
	yard.walk_area = floor[:]
	append(&yard.exits, Exit{name = "ladder", area = {400, 280, 40, 40}, to = 1, arrive = {300, 420},
		anim = "climb_up", arrive_anim = "climb_off", face = Facing.Back})
	append(&yard.exits, Exit{name = "window", area = {100, 280, 40, 40}, to = 1, arrive = {50, 420},
		anim = "climb_up", at = {120, 330}, face = Facing.Back})
	append(&yard.exits, Exit{name = "hatch", area = {200, 280, 40, 40}, to = 1, arrive = {60, 60},
		anim = "no_such_part"})
	append(&w.scenes, yard, loft)
	w.player = {pos = {420, 340}, speed = 120, character = art}
	return w
}

@(test)
a_climbed_exit_changes_the_room_at_the_end_of_the_climb :: proc(t: ^testing.T) {
	art := fake_art()
	w := yard_and_loft(&art)
	defer destroy_world(&w)

	w.player.pos = {420, 300} // into the ladder's patch
	testing.expect(t, check_exits(&w))
	testing.expect_value(t, w.current, 0) // still in the yard, climbing
	testing.expect_value(t, w.player.anim, "climb_up")
	testing.expect_value(t, w.player.facing, Facing.Back)

	testing.expect_value(t, finish_player_anim(&w), "climb_up")
	testing.expect_value(t, w.current, 1) // up
	testing.expect_value(t, w.player.pos, [2]f32{300, 420})
	testing.expect_value(t, w.player.anim, "climb_off") // and off the ladder, in the loft
	testing.expect_value(t, finish_player_anim(&w), "climb_off")
	testing.expect(t, !actor_playing(&w.player))
}

@(test)
a_climbed_exit_walks_to_its_spot_first :: proc(t: ^testing.T) {
	art := fake_art()
	w := yard_and_loft(&art)
	defer destroy_world(&w)

	w.player.pos = {110, 300} // into the window's patch, off its spot
	check_exits(&w)
	testing.expect(t, w.exit_walk.active, "on her way to the sill")
	testing.expect(t, !actor_playing(&w.player))
	for _ in 0 ..< 600 {
		actor_follow_target(&w.player, 1.0 / 60, &w.scenes[0])
		exit_walk_step(&w)
		if actor_playing(&w.player) do break
	}
	testing.expect_value(t, w.player.pos, [2]f32{120, 330})
	testing.expect_value(t, w.player.anim, "climb_up")
	finish_player_anim(&w)
	testing.expect_value(t, w.current, 1)
	testing.expect_value(t, w.player.pos, [2]f32{50, 420})
}

@(test)
an_exit_whose_climb_is_not_drawn_is_an_ordinary_exit :: proc(t: ^testing.T) {
	art := fake_art()
	w := yard_and_loft(&art)
	defer destroy_world(&w)

	w.player.pos = {220, 300}
	testing.expect(t, check_exits(&w))
	testing.expect_value(t, w.current, 1) // straight through
	testing.expect(t, !actor_playing(&w.player))
}

@(test)
game_code_can_go_somewhere_after_a_gesture :: proc(t: ^testing.T) {
	art := fake_art()
	w := yard_and_loft(&art)
	defer destroy_world(&w)

	go_to_after(&w, "climb_up", 1, {10, 10}, arrive_part = "climb_off")
	testing.expect_value(t, w.current, 0)
	finish_player_anim(&w)
	testing.expect_value(t, w.current, 1)
	testing.expect_value(t, w.player.anim, "climb_off")
}

@(test)
a_climbed_exit_survives_the_scene_file :: proc(t: ^testing.T) {
	s, ok := parse_scene(`scene yard
walk 0,0 640,0 640,480 0,480
exit ladder area=400,280,40,40 to=loft arrive=300,420 anim=climb_up at=420,320 face=back arrive_anim=climb_off
`, nil)
	testing.expect(t, ok)
	defer {
		free_scene_strings(&s)
		delete(s.objects)
		delete(s.exits)
		delete(s.triggers)
		delete(s.walk_area)
		delete(s.scenery)
		delete(s.said)
	}
	e := s.exits[0]
	testing.expect_value(t, e.anim, "climb_up")
	testing.expect_value(t, e.arrive_anim, "climb_off")
	testing.expect_value(t, e.at, [2]f32{420, 320})
	testing.expect_value(t, e.face.?, Facing.Back)
	testing.expect(t, strings.contains(scene_text(&s), "anim=climb_up at=420,320 face=back arrive_anim=climb_off"))
}
