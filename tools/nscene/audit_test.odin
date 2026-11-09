package main

import "core:testing"

// `nscene audit` compares things that can be in a room at once; two lines
// whose when= contradict each other never are.
@(test)
conditions_that_cannot_hold_together_are_never_compared :: proc(t: ^testing.T) {
	testing.expect(t, compatible("", "night"))
	testing.expect(t, compatible("act2,night", "night"))
	testing.expect(t, !compatible("generator_off", "!generator_off"))
	testing.expect(t, !compatible("!shop_empty,act2", "shop_empty"))
	testing.expect(t, compatible("!a", "!a,b"))
	// A room dressed one way at a time.
	audit_dress = {"booth"}
	defer audit_dress = nil
	testing.expect(t, !compatible("booth_1", "booth_2,night"))
	testing.expect(t, compatible("booth_1", "booth_1"))
	testing.expect(t, compatible("booth_1", "boothy_2"))
}
