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
