package ui

import "core:testing"

@(test)
scroll_stays_within_what_there_is :: proc(t: ^testing.T) {
	// Ten rows of 20 in a box 100 tall: 100 pixels' worth to scroll.
	testing.expect_value(t, scroll_max(200, 100), 100)
	testing.expect_value(t, scroll_clamp(-30, 200, 100), 0)
	testing.expect_value(t, scroll_clamp(150, 200, 100), 100)
	testing.expect_value(t, scroll_clamp(40, 200, 100), 40)
	// Less than a boxful never scrolls at all.
	testing.expect_value(t, scroll_max(60, 100), 0)
	testing.expect_value(t, scroll_clamp(30, 60, 100), 0)
}

@(test)
the_wheel_moves_the_list_and_stops_at_the_ends :: proc(t: ^testing.T) {
	// Towards you (negative, as raylib reports it) goes down the list.
	testing.expect_value(t, scroll_by_wheel(0, -3, 26, 1000, 300), 78)
	testing.expect_value(t, scroll_by_wheel(78, 1, 26, 1000, 300), 52)
	testing.expect_value(t, scroll_by_wheel(0, 2, 26, 1000, 300), 0)
	testing.expect_value(t, scroll_by_wheel(690, -3, 26, 1000, 300), 700)
	// A trackpad's fraction of a notch is a fraction of a step.
	testing.expect_value(t, scroll_by_wheel(0, -0.5, 26, 1000, 300), 13)
}

@(test)
showing_a_row_moves_only_as_far_as_it_must :: proc(t: ^testing.T) {
	// Already in view: nothing moves. This is the case the browser got wrong —
	// it pinned the view to the selection every frame, so the wheel could
	// never take the selected row off screen.
	testing.expect_value(t, scroll_to_show(100, 120, 26, 2000, 300), 100)
	// Above the view: the row comes to the top.
	testing.expect_value(t, scroll_to_show(100, 52, 26, 2000, 300), 52)
	// Below it: the row comes to the bottom, not the top.
	testing.expect_value(t, scroll_to_show(0, 400, 26, 2000, 300), 126)
	// And never past either end.
	testing.expect_value(t, scroll_to_show(0, 1990, 26, 2000, 300), 1700)
}
