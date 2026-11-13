package nengine

import "core:testing"

@(test)
parallax_layers_drift_and_wrap :: proc(t: ^testing.T) {
	testing.expect_value(t, layer_offset(0, 40, 320), 0)
	testing.expect_value(t, layer_offset(1, 40, 320), -40)
	testing.expect_value(t, layer_offset(1, 6, 320), -6) // far layers drift slower
	testing.expect_value(t, layer_offset(0, 0, 320), 0)  // speed 0 stays put
	testing.expect_value(t, layer_offset(100, 0, 320), 0)

	// After exactly one width it's back where it started, and it never
	// leaves a gap: always between -width and 0.
	testing.expect_value(t, layer_offset(8, 40, 320), 0)
	for i in 0 ..< 1000 {
		o := layer_offset(f32(i) * 0.037, 40, 320)
		testing.expectf(t, o <= 0 && o > -320, "offset %v out of range", o)
	}
}

// A layer of several frames plays them, as a sprite does: moving water. One
// frame, or no `fps`, shows the first.
@(test)
a_layer_of_several_frames_plays_them :: proc(t: ^testing.T) {
	water := Layer{sprite = Sprite{frame_w = 320, frames = 3}, speed = 24, fps = 5}
	testing.expect_value(t, layer_frame(water, 0), 0)
	testing.expect_value(t, layer_frame(water, 0.2), 1)
	testing.expect_value(t, layer_frame(water, 0.45), 2)
	testing.expect_value(t, layer_frame(water, 0.65), 0) // round again
	still := water
	still.fps = 0
	testing.expect_value(t, layer_frame(still, 0.45), 0)
	one := Layer{sprite = Sprite{frame_w = 320, frames = 1}, fps = 5}
	testing.expect_value(t, layer_frame(one, 0.45), 0)
}
