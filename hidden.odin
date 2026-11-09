package nengine

import "core:fmt"
import "core:os"
import rl "vendor:raylib"

// A hidden window (NENGINE_HIDDEN) is for tests and scripts: nobody can see
// it, so nothing should be left running in one. Two guards make sure:
//
// - It dies with whatever started it. A test runner killed half-way, a
//   timeout, a closed terminal: the hidden game goes too, instead of sitting
//   in memory with a window nobody will ever close.
// - It does not run for ever. Without --shot a scripted run would wait for a
//   player who is not there; hidden, it stops after the frames a shot would
//   take, and nothing hidden outlives HIDDEN_MAX_SECS.

// The longest a hidden run may last, whatever it is doing.
HIDDEN_MAX_SECS :: 600

hidden :: proc() -> bool {
	return os.get_env("NENGINE_HIDDEN", context.temp_allocator) != ""
}

// Called as the window opens. Does nothing for a visible window.
hidden_guard :: proc() {
	if !hidden() do return
	if !die_with_parent() {
		fmt.eprintln("nengine: hidden, and whoever started this is gone; stopping")
		os.exit(1)
	}
}

// True when a hidden run has gone on longer than anything hidden should.
hidden_overdue :: proc() -> bool {
	if !hidden() || rl.GetTime() < HIDDEN_MAX_SECS do return false
	fmt.eprintfln("nengine: hidden for %v seconds; stopping", HIDDEN_MAX_SECS)
	return true
}
