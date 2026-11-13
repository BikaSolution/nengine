package nengine

import "core:strings"
import "core:testing"

// A character is ten poses the engine picks by itself and as many extras as
// the game wants. These check the extras: that the file carries them, that
// the ten are protected from being renamed out from under the engine, and
// that a new pose starts in the character's own colours rather than an empty
// tray — which is the difference between drawing and mixing paint first.

@(test)
a_character_with_extra_poses_survives_a_round_trip :: proc(t: ^testing.T) {
	c := character_new("moore", 32, 58)
	defer character_destroy(&c)
	front := character_add_part(&c, "front")
	append(&front.data.palette, Palette_Entry{'#', {28, 26, 32, 255}})
	append(&front.data.palette, Palette_Entry{'o', {200, 180, 40, 255}})
	for y in 0 ..< i32(58) do for x in 0 ..< i32(32) {
		sprite_data_at(&front.data, 0, x, y)^ = u8((int(x) + int(y)) % 3)
	}

	// An extra with its own size and its own speed: a pose that sits in a
	// chair for an hour of play is not the same shape as one that walks.
	chair := character_add_part(&c, "chair", 2, 1.5)
	sprite_data_resize(&chair.data, 40, 40)
	sprite_data_at(&chair.data, 1, 3, 4)^ = 2

	back, ok := parse_character(character_text(&c))
	defer character_destroy(&back)
	testing.expect(t, ok)
	testing.expect_value(t, len(back.parts), 2)

	got := character_part(&back, "chair")
	testing.expect(t, got != nil, "the extra pose did not come back")
	if got == nil do return
	testing.expect_value(t, got.data.w, 40)
	testing.expect_value(t, got.data.h, 40)
	testing.expect_value(t, got.data.frames, 2)
	testing.expect_value(t, got.fps, 1.5)
	testing.expect_value(t, sprite_data_at(&got.data, 1, 3, 4)^, 2)
}

@(test)
a_new_pose_starts_in_the_characters_colours :: proc(t: ^testing.T) {
	c := character_new("elena")
	defer character_destroy(&c)
	front := character_add_part(&c, "front")
	append(&front.data.palette, Palette_Entry{'#', {28, 26, 32, 255}})
	append(&front.data.palette, Palette_Entry{'o', {200, 180, 40, 255}})

	desk := character_add_part(&c, "desk")
	testing.expect_value(t, len(desk.data.palette), len(front.data.palette))
	testing.expect_value(t, desk.data.palette[2].color, front.data.palette[2].color)
}

@(test)
copying_a_pose_copies_the_pixels :: proc(t: ^testing.T) {
	c := character_new("percy")
	defer character_destroy(&c)
	front := character_add_part(&c, "front")
	append(&front.data.palette, Palette_Entry{'#', {28, 26, 32, 255}})
	sprite_data_at(&front.data, 0, 5, 6)^ = 1

	sit := character_copy_part(&c, "front", "sit")
	testing.expect(t, sit != nil, "the copy was refused")
	if sit == nil do return
	testing.expect_value(t, sprite_data_at(&sit.data, 0, 5, 6)^, 1)

	// Painting the copy must not paint the original: they are two poses now.
	sprite_data_at(&sit.data, 0, 5, 6)^ = 0
	testing.expect_value(t, sprite_data_at(&character_part(&c, "front").data, 0, 5, 6)^, 1)

	// A name already taken, and a name the format could not write.
	testing.expect(t, character_copy_part(&c, "front", "sit") == nil, "took a name already in use")
	testing.expect(t, character_copy_part(&c, "front", "on a chair") == nil, "took a name with spaces in it")
	testing.expect(t, character_copy_part(&c, "nothing", "kneel") == nil, "copied a pose that is not there")
}

@(test)
extras_can_be_renamed_and_removed_and_the_standard_ten_cannot :: proc(t: ^testing.T) {
	c := character_new("hawkes")
	defer character_destroy(&c)
	character_add_part(&c, "front")
	character_add_part(&c, "camera", 2, 6)

	testing.expect(t, character_rename_part(&c, "camera", "tripod"), "could not rename an extra")
	testing.expect(t, character_part(&c, "camera") == nil, "the old name is still there")
	testing.expect(t, character_part(&c, "tripod") != nil, "the new name is not")

	// The engine looks the ten up by name, so the editor may not move them.
	testing.expect(t, !character_rename_part(&c, "front", "standing"), "renamed one of the ten")
	testing.expect(t, !character_remove_part(&c, "front"), "removed one of the ten")
	testing.expect(t, character_part(&c, "front") != nil, "front went missing")

	testing.expect(t, character_remove_part(&c, "tripod"), "could not remove an extra")
	testing.expect_value(t, len(c.parts), 1)
	testing.expect(t, !character_remove_part(&c, "tripod"), "removed it twice")
}

@(test)
a_pose_name_has_to_be_writable_and_typable :: proc(t: ^testing.T) {
	for good in ([?]string{"sit", "at_tripod", "walk_left", "hurt_walk", "pose2"}) {
		testing.expectf(t, char_part_name_ok(good), "%v should be a fine name for a pose", good)
	}
	// Spaces would split the `part` line in two, `=` would look like a field,
	// and `part` and `frame` are the format's own words.
	for bad in ([?]string{"", "in a chair", "Sit", "fps=6", "2nd", "_sit", "part", "frame", "sit-down"}) {
		testing.expectf(t, !char_part_name_ok(bad), "%v should not be a name for a pose", bad)
	}
}

@(test)
the_extras_are_the_poses_beyond_the_ten :: proc(t: ^testing.T) {
	c := character_new("margaret")
	defer character_destroy(&c)
	for p in CHAR_PARTS do character_add_part(&c, p)
	character_add_part(&c, "steps", 3, 4)
	character_add_part(&c, "sit_chair", 2, 2)

	extras := character_extras(&c)
	testing.expect_value(t, len(extras), 2)
	testing.expect_value(t, extras[0], "steps")
	testing.expect_value(t, extras[1], "sit_chair")

	// And they survive being written out and read back in that order.
	back, ok := parse_character(character_text(&c))
	defer character_destroy(&back)
	testing.expect(t, ok)
	again := character_extras(&back)
	testing.expect_value(t, len(again), 2)
	testing.expect_value(t, strings.concatenate({again[0], ",", again[1]}, context.temp_allocator), "steps,sit_chair")
}

@(test)
a_walk_with_a_step_plays_as_fast_as_it_moves :: proc(t: ^testing.T) {
	// `step=` survives the file both ways, and a part without it has none.
	text := "character stride\nsize 4 4\npal # 0,0,0,255\npart walk_right frames=4 fps=8 step=13\nframe 0\n####\n####\n####\n####\nframe 1\n####\n####\n####\n####\nframe 2\n####\n####\n####\n####\nframe 3\n####\n####\n####\n####\npart front frames=1\nframe 0\n####\n####\n####\n####\n"
	c, ok := parse_character(text)
	testing.expect(t, ok)
	defer character_destroy(&c)
	testing.expect_value(t, character_part(&c, "walk_right").step, 13)
	testing.expect_value(t, character_part(&c, "front").step, 0)
	again, ok2 := parse_character(character_text(&c))
	testing.expect(t, ok2)
	defer character_destroy(&again)
	testing.expect_value(t, character_part(&again, "walk_right").step, 13)

	// Two strides a cycle: 190 canvas px/s at 3.2 over 13 px strides is
	// 190 / 83.2 = 2.28 cycles, 9.1 frames a second for a four-frame walk.
	s := Sprite{frames = 4, scale = 3.2}
	rate := walk_rate(190, 13, s)
	testing.expect(t, rate > 9.1 && rate < 9.2)
	// Half the speed, half the rate: the feet stay planted at any speed.
	testing.expect(t, abs(walk_rate(95, 13, s) - rate / 2) < 0.001)
}

// An extra pose never mirrors, so a man carrying a sack drawn facing left
// would walk backwards to the right. A pose may be drawn again for a facing,
// `sack_right`, and is used while facing that way; without one, the pose.
@(test)
a_pose_drawn_for_a_facing_is_used_that_way :: proc(t: ^testing.T) {
	art := Character_Art{name = "porter"}
	defer delete(art.parts)
	art.parts["sack"] = Part_Art{sprite = Sprite{texture = {id = 1}, frames = 4}}
	art.parts["sack_right"] = Part_Art{sprite = Sprite{texture = {id = 2}, frames = 4}}
	a := Actor{character = &art, pose = "sack", facing = .Left}
	s, _, _ := actor_picture(a)
	testing.expect_value(t, s.texture.id, 1)
	a.facing = .Right
	s, _, _ = actor_picture(a)
	testing.expect_value(t, s.texture.id, 2)
	a.facing = .Front
	s, _, _ = actor_picture(a)
	testing.expect_value(t, s.texture.id, 1)
	// Played, too: a kick at a dog on the left is the kick drawn facing left.
	art.parts["kick"] = Part_Art{sprite = Sprite{texture = {id = 3}, frames = 2}, fps = 4}
	art.parts["kick_left"] = Part_Art{sprite = Sprite{texture = {id = 4}, frames = 3}, fps = 4}
	a.pose = ""
	a.facing = .Left
	actor_play(&a, "kick")
	s, _, _ = actor_picture(a)
	testing.expect_value(t, s.texture.id, 4)
	testing.expect_value(t, actor_part_secs(&a, "kick"), 0.75)
	a.facing = .Right
	s, _, _ = actor_picture(a)
	testing.expect_value(t, s.texture.id, 3)
	free_all(context.temp_allocator)
}

// A walk part held as somebody's pose while they stand still stands on its
// first passing frame instead of walking on the spot; walking, it walks.
@(test)
a_walk_held_standing_still_stands :: proc(t: ^testing.T) {
	art := Character_Art{name = "ranger"}
	defer delete(art.parts)
	art.parts["lamp_walk"] = Part_Art{sprite = Sprite{texture = {id = 1}, frames = 4, scale = 3.2}, fps = 8, step = 8}
	a := Actor{character = &art, pose = "lamp_walk", facing = .Left, speed = 120}
	for t_ in ([]f32{0, 0.3, 0.7, 1.9}) {
		a.anim_time = t_
		_, frame, _ := actor_picture(a)
		testing.expect_value(t, frame, 1)
	}
	a.walking = true
	a.anim_time = 0
	_, f0, _ := actor_picture(a)
	a.anim_time = 0.15
	_, f1, _ := actor_picture(a)
	testing.expect(t, f0 != f1, "walking, the frames go round")
	free_all(context.temp_allocator)
}
