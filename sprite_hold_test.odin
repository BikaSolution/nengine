package nengine

import "core:strings"
import "core:testing"

// A room sprite's frames can hold, like a pose's: a bush that sways in a gust
// and then stands still. Read, written back, and handed to the drawing.
@(test)
a_sprite_frame_can_hold :: proc(t: ^testing.T) {
	text := "sprite bush\nsize 2 1\nframes 2\npal . 0,0,0,0\npal x 0,170,0,255\nframe 0 hold=6\nxx\nframe 1\n.x\n"
	d, ok := parse_sprite_data(text)
	testing.expect(t, ok)
	defer sprite_data_destroy(&d)
	testing.expect_value(t, sprite_data_hold(&d, 0), i32(6))
	testing.expect_value(t, sprite_data_hold(&d, 1), i32(1))
	testing.expect(t, strings.contains(sprite_data_text(&d), "frame 0 hold=6"))
	holds := sprite_data_holds(&d)
	defer delete(holds)
	f, _ := anim_frame(0.5, 10, 2, holds) // the fifth tick: still the held first frame
	testing.expect_value(t, f, i32(0))
	f, _ = anim_frame(0.65, 10, 2, holds) // the seventh: the second
	testing.expect_value(t, f, i32(1))
}

// A painted shot plays its frames when its file says `fps`, and not otherwise.
@(test)
a_shot_with_fps_advances_with_the_clock :: proc(t: ^testing.T) {
	s := Sprite{frames = 3, fps = 3}
	testing.expect_value(t, shot_frame(s, 0, 0), i32(0))
	testing.expect_value(t, shot_frame(s, 0, 0.34), i32(1))
	testing.expect_value(t, shot_frame(s, 0, 0.67), i32(2))
	testing.expect_value(t, shot_frame(s, 0, 1.01), i32(0)) // and round again
}

@(test)
a_shot_without_fps_keeps_its_pinned_frame :: proc(t: ^testing.T) {
	s := Sprite{frames = 3}
	testing.expect_value(t, shot_frame(s, 2, 0), i32(2))
	testing.expect_value(t, shot_frame(s, 2, 5.5), i32(2))
}

// A held frame is held in a shot too: six ticks of the first, one of the second.
@(test)
a_shot_with_fps_keeps_its_holds :: proc(t: ^testing.T) {
	holds := []i32{6, 1}
	s := Sprite{frames = 2, fps = 10, holds = holds}
	testing.expect_value(t, shot_frame(s, 1, 0.55), i32(0)) // the sixth tick: still the first
	testing.expect_value(t, shot_frame(s, 1, 0.65), i32(1)) // the seventh: the second
	testing.expect_value(t, shot_frame(s, 1, 0.75), i32(0)) // seven ticks round, and the first again
}

@(test)
a_one_frame_shot_with_fps_stays_at_frame_zero :: proc(t: ^testing.T) {
	s := Sprite{frames = 1, fps = 3}
	testing.expect_value(t, shot_frame(s, 0, 0.67), i32(0))
}

@(test)
a_sprite_fps_line_reads_and_round_trips :: proc(t: ^testing.T) {
	text := "sprite river\nsize 2 1\nframes 2\nfps 3\npal . 0,0,0,0\npal x 0,0,170,255\nframe 0\nxx\nframe 1\n.x\n"
	d, ok := parse_sprite_data(text)
	testing.expect(t, ok)
	defer sprite_data_destroy(&d)
	testing.expect_value(t, d.fps, f32(3))
	out := sprite_data_text(&d)
	testing.expect(t, strings.contains(out, "\nfps 3\n"))
	back, ok2 := parse_sprite_data(out)
	testing.expect(t, ok2)
	defer sprite_data_destroy(&back)
	testing.expect_value(t, back.fps, f32(3))

	// A still has no line at all, so old files are written back unchanged.
	still, ok3 := parse_sprite_data("sprite s\nsize 1 1\nframes 1\npal . 0,0,0,0\nframe 0\n.\n")
	testing.expect(t, ok3)
	defer sprite_data_destroy(&still)
	testing.expect(t, !strings.contains(sprite_data_text(&still), "fps"))
}
