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
