package nengine

import "core:testing"

// The canvas keeps its shape and sits in the middle of whatever window it
// is given. These check the arithmetic without opening a window.

@(test)
a_window_the_size_of_the_canvas_fits_exactly :: proc(t: ^testing.T) {
	v := fit_canvas({1024, 640}, {1024, 640})
	testing.expect_value(t, v.scale, f32(1))
	testing.expect_value(t, v.at, [2]f32{0, 0})
	testing.expect_value(t, v.size, [2]f32{1024, 640})
}

@(test)
a_wide_window_gets_bars_at_the_sides :: proc(t: ^testing.T) {
	// 1600x640 against a 1024x640 canvas: height decides, so scale is 1 and
	// there are 288 pixels of black either side.
	v := fit_canvas({1600, 640}, {1024, 640})
	testing.expect_value(t, v.scale, f32(1))
	testing.expect_value(t, v.size, [2]f32{1024, 640})
	testing.expect_value(t, v.at, [2]f32{288, 0})
}

@(test)
a_tall_window_gets_bars_above_and_below :: proc(t: ^testing.T) {
	v := fit_canvas({1024, 900}, {1024, 640})
	testing.expect_value(t, v.scale, f32(1))
	testing.expect_value(t, v.at, [2]f32{0, 130})
}

@(test)
a_window_smaller_than_the_canvas_shrinks_it :: proc(t: ^testing.T) {
	v := fit_canvas({512, 320}, {1024, 640})
	testing.expect_value(t, v.scale, f32(0.5))
	testing.expect_value(t, v.at, [2]f32{0, 0})
	testing.expect_value(t, v.size, [2]f32{512, 320})
}

@(test)
scaling_up_goes_in_whole_steps :: proc(t: ^testing.T) {
	// 1280x800 would fit a 320x200 canvas exactly four times over.
	testing.expect_value(t, fit_canvas({1280, 800}, {320, 200}).scale, f32(4))

	// 1500x900 would allow 4.5. Half a pixel is not a pixel, so: 4.
	v := fit_canvas({1500, 900}, {320, 200})
	testing.expect_value(t, v.scale, f32(4))
	testing.expect_value(t, v.size, [2]f32{1280, 800})
	testing.expect_value(t, v.at, [2]f32{110, 50})

	// Under 1x there is nothing to round to, so it shrinks smoothly.
	testing.expect_value(t, fit_canvas({160, 100}, {320, 200}).scale, f32(0.5))
}

@(test)
clicks_land_where_the_player_aimed :: proc(t: ^testing.T) {
	// A window bigger than the canvas and a different shape. 1600x900 over
	// 1024x640 allows 1.40625, which rounds down to 1.
	v := fit_canvas({1600, 900}, {1024, 640})
	testing.expect_value(t, v.scale, f32(1))

	// The corners of the picture are the corners of the canvas.
	testing.expect_value(t, canvas_point(v.at, v), [2]f32{0, 0})
	middle := canvas_point(v.at + v.size / 2, v)
	testing.expect(t, abs(middle.x - 512) < 0.01 && abs(middle.y - 320) < 0.01,
		"the middle of the picture is the middle of the canvas")

	// Anywhere a canvas pixel can be, a window point maps back to it.
	for want in ([]([2]f32){{0, 0}, {1, 1}, {640, 400}, {1023, 639}}) {
		got := canvas_point(v.at + want * v.scale, v)
		testing.expectf(t, abs(got.x - want.x) < 0.01 && abs(got.y - want.y) < 0.01,
			"%v came back as %v", want, got)
	}

	// A click in the black bar is outside the canvas, which is what lets
	// game code treat it as "not on the floor".
	testing.expect(t, canvas_point({4, 450}, v).x < 0, "the left bar is off-canvas")
}
