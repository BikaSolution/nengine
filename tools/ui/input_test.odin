package ui

import "core:testing"
import rl "vendor:raylib"

// The replay script, read and played without a window: the state it drives is
// plain data, and the tools read it through the same calls a person's input
// comes through.

@(test)
events_parse_frames_verbs_and_keys :: proc(t: ^testing.T) {
	list: [dynamic]Input_Event
	defer delete(list)
	ok, problem := parse_events(`
# a comment, and a blank line

30 move 400 300
+1 click            # left by default
+0 click right
40 wheel -3; 41 key ctrl+shift+z
50 key ESCAPE
51 key KEY_A
52 type hello world
90 shot /tmp/x.png
120 quit`, &list)
	testing.expect(t, ok, problem)
	testing.expect_value(t, len(list), 10)
	if len(list) < 10 do return

	testing.expect_value(t, list[0].kind, Event_Kind.Move)
	testing.expect_value(t, list[0].pos, [2]f32{400, 300})
	testing.expect_value(t, list[1].frame, 31) // +1 after 30
	testing.expect_value(t, list[1].button, rl.MouseButton.LEFT)
	testing.expect_value(t, list[2].frame, 31)
	testing.expect_value(t, list[2].button, rl.MouseButton.RIGHT)
	testing.expect_value(t, list[3].amount, -3)
	testing.expect_value(t, list[4].frame, 41)
	testing.expect_value(t, list[4].key, rl.KeyboardKey.Z)
	testing.expect(t, list[4].mods == {.Ctrl, .Shift}, "ctrl+shift+z holds both")
	testing.expect_value(t, list[5].key, rl.KeyboardKey.ESCAPE)
	testing.expect_value(t, list[6].key, rl.KeyboardKey.A)
	testing.expect_value(t, list[7].text, "hello world")
	testing.expect_value(t, list[8].text, "/tmp/x.png")
	testing.expect_value(t, list[9].kind, Event_Kind.Quit)
}

@(test)
events_refuse_what_they_do_not_understand :: proc(t: ^testing.T) {
	bad := [?]string{
		"30 jump",          // no such verb
		"move 1 2",         // no frame
		"30 move 1",        // half a position
		"30 key NOSUCHKEY",
		"30 click sideways",
		"30 type",
	}
	for script in bad {
		list: [dynamic]Input_Event
		ok, _ := parse_events(script, &list)
		testing.expectf(t, !ok, "%q should be refused", script)
		delete(list)
	}
}

@(test)
key_names_are_forgiving :: proc(t: ^testing.T) {
	k, mods, ok := key_named("esc")
	testing.expect(t, ok && k == .ESCAPE && mods == {}, "esc")
	k, mods, ok = key_named("Ctrl+B")
	testing.expect(t, ok && k == .B && mods == {.Ctrl}, "Ctrl+B")
	k, _, ok = key_named("3")
	testing.expect(t, ok && k == .THREE, "a digit is that key")
	k, _, ok = key_named("[")
	testing.expect(t, ok && k == .LEFT_BRACKET, "[")
}

// One test, not several: the replay, the block and the question are the
// program's single input state, and tests run side by side.
@(test)
a_script_is_input_the_tools_cannot_tell_from_a_person :: proc(t: ^testing.T) {
	defer events_destroy()
	defer leave_reset()
	ok := events_load("2 move 40 50; 3 click; 4 hold ctrl; 5 key s; 6 let ctrl; 7 wheel -2; 8 type ab; 9 down right; 11 up right; 12 quit")
	testing.expect(t, ok, "the script loads")
	testing.expect(t, replaying(), "and takes over the input")

	input_begin(1)
	testing.expect_value(t, mouse(), rl.Vector2{0, 0})

	input_begin(2)
	testing.expect_value(t, mouse(), rl.Vector2{40, 50})
	testing.expect_value(t, mouse_delta(), rl.Vector2{40, 50})

	// A click is pressed and down for one frame, released on the next.
	input_begin(3)
	testing.expect(t, mouse_pressed(.LEFT) && mouse_down(.LEFT), "click goes down")
	testing.expect_value(t, mouse_delta(), rl.Vector2{0, 0})
	input_begin(4)
	testing.expect(t, !mouse_pressed(.LEFT) && !mouse_down(.LEFT) && mouse_released(.LEFT), "and comes up")
	testing.expect(t, ctrl_down(), "hold ctrl")

	// A key tap with ctrl held is ^S, once.
	input_begin(5)
	testing.expect(t, save_pressed(), "^S")
	input_begin(6)
	testing.expect(t, !save_pressed(), "pressed is one frame only")
	testing.expect(t, !ctrl_down(), "let ctrl")

	input_begin(7)
	testing.expect_value(t, wheel(), -2)
	input_begin(8)
	testing.expect_value(t, wheel(), 0)
	testing.expect_value(t, char_pressed(), 'a') // in the order typed
	testing.expect_value(t, char_pressed(), 'b')
	testing.expect_value(t, char_pressed(), 0)

	// A drag: down, held across frames, up.
	input_begin(9)
	testing.expect(t, mouse_pressed(.RIGHT), "down right")
	input_begin(10)
	testing.expect(t, mouse_down(.RIGHT) && !mouse_pressed(.RIGHT), "held")

	// A question up blocks everything underneath it.
	testing.expect(t, leave_request(false, "x.sprite"), "a clean file just goes")
	testing.expect(t, !leave_request(true, "x.sprite"), "a changed one asks")
	testing.expect(t, leave_asking(), "and is asking")
	testing.expect(t, !mouse_down(.RIGHT), "nothing reaches the editor while it asks")
	testing.expect_value(t, mouse(), NOWHERE)
	leave_reset()
	testing.expect(t, mouse_down(.RIGHT), "and it comes back after")

	// Swallowed: what left an editor doesn't reach the browser too.
	input_begin(11)
	testing.expect(t, mouse_released(.RIGHT), "up right")
	input_swallow()
	testing.expect(t, !key_pressed(.S), "swallowed")

	testing.expect(t, !replay_quit(), "not yet")
	input_begin(12)
	testing.expect(t, replay_quit(), "quit")
	testing.expect_value(t, replay_last_frame(), 12)
}
