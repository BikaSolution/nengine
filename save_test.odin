package nengine

import "core:os"
import "core:strings"
import "core:testing"

// Saving is the one feature where a bug is only discovered by somebody who
// has already lost their progress, so it is worth testing properly: that a
// world comes back the way it went in, that the autosave really does keep the
// step before, and that a slot can be overwritten without leaving traces of
// what was there before.

@(private = "file")
Test_State :: struct {
	lucidity: int,
	has_key:  bool,
	note:     string,
}

// The state hangs off the world rather than off a global, so that these tests
// can run beside each other without scribbling on one another — which is the
// same reason a game with more than one save-capable thing would want it.
@(private = "file")
write_state :: proc(w: ^World, s: ^Save) {
	state := cast(^Test_State)w.user
	save_put_int(s, "lucidity", state.lucidity)
	save_put_bool(s, "has_key", state.has_key)
	save_put(s, "note", state.note)
}

@(private = "file")
read_state :: proc(w: ^World, s: ^Save) {
	state := cast(^Test_State)w.user
	state.lucidity = save_int(s, "lucidity", 100)
	state.has_key = save_bool(s, "has_key")
	state.note = save_text(s, "note")
}

// A world with two rooms and somewhere private to save into.
@(private = "file")
test_world :: proc(t: ^testing.T, name: string, state: ^Test_State) -> World {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" do base = "/tmp"
	dir := strings.concatenate({base, "/nengine-save-", name}, context.temp_allocator)
	os.remove_all(dir)

	w := World {
		save_name = strings.clone(dir, context.temp_allocator),
		on_save   = write_state,
		on_load   = read_state,
		user      = state,
	}
	append(&w.scenes, Scene{name = "parlour"})
	append(&w.scenes, Scene{name = "veranda"})
	state^ = {lucidity = 100}
	return w
}

@(private = "file")
clean_up :: proc(w: ^World) {
	os.remove_all(save_dir(w))
	delete(w.scenes)
	clear_flags(w) // a load sets the flags the save had
}

@(test)
a_world_comes_back_the_way_it_went_in :: proc(t: ^testing.T) {
	state: Test_State
	w := test_world(t, "roundtrip", &state)
	defer clean_up(&w)

	w.current = 1 // the veranda
	w.player.pos = {412, 470}
	w.player.facing = .Left
	w.time = 91.5
	state = {lucidity = 42, has_key = true, note = "he lied about the time"}

	testing.expect(t, save_game(&w, 3, "second night"))

	// Wreck everything, then put it back.
	w.current = 0
	w.player.pos = {0, 0}
	w.player.facing = .Back
	w.time = 0
	state = {}

	testing.expect(t, load_game(&w, 3))
	testing.expect_value(t, w.current, 1)
	testing.expect_value(t, w.player.pos.x, f32(412))
	testing.expect_value(t, w.player.pos.y, f32(470))
	testing.expect_value(t, w.player.facing, Facing.Left)
	testing.expect_value(t, w.time, f32(91.5))

	// And the game's own state, which the engine knows nothing about.
	testing.expect_value(t, state.lucidity, 42)
	testing.expect_value(t, state.has_key, true)
	testing.expect_value(t, state.note, "he lied about the time")
}

@(test)
a_scene_is_found_by_name_not_by_number :: proc(t: ^testing.T) {
	state: Test_State
	w := test_world(t, "byname", &state)
	defer clean_up(&w)

	w.current = 1 // veranda
	testing.expect(t, save_game(&w, 1))

	// The rooms are reordered, as they are every time a game grows a scene.
	// A save that stored the index would now open the wrong room.
	w.scenes[0], w.scenes[1] = w.scenes[1], w.scenes[0]
	w.current = 0

	testing.expect(t, load_game(&w, 1))
	testing.expect_value(t, current_scene(&w).name, "veranda")
	testing.expect_value(t, w.current, 0) // where the veranda is now
}

@(test)
the_autosave_keeps_the_step_before :: proc(t: ^testing.T) {
	state: Test_State
	w := test_world(t, "rolling", &state)
	defer clean_up(&w)

	w.player.pos = {100, 100}
	testing.expect(t, autosave(&w, "arriving"))
	testing.expect(t, save_exists(&w, AUTOSAVE))
	// Nothing to roll down yet.
	testing.expect(t, !save_exists(&w, AUTOSAVE_PREVIOUS))

	w.player.pos = {200, 200}
	testing.expect(t, autosave(&w, "the pool"))
	testing.expect(t, save_exists(&w, AUTOSAVE_PREVIOUS))

	// The newest autosave is where we just were...
	testing.expect(t, load_game(&w, AUTOSAVE))
	testing.expect_value(t, w.player.pos.x, f32(200))

	// ...and the one behind it is where we were before that, which is the
	// whole point: autosaving into the trap must not erase the way out.
	testing.expect(t, load_game(&w, AUTOSAVE_PREVIOUS))
	testing.expect_value(t, w.player.pos.x, f32(100))

	// A third autosave pushes the middle one down and drops the oldest.
	w.player.pos = {300, 300}
	testing.expect(t, autosave(&w, "the fuel store"))
	testing.expect(t, load_game(&w, AUTOSAVE))
	testing.expect_value(t, w.player.pos.x, f32(300))
	testing.expect(t, load_game(&w, AUTOSAVE_PREVIOUS))
	testing.expect_value(t, w.player.pos.x, f32(200))
}

@(test)
there_are_eight_slots_and_they_can_be_written_over :: proc(t: ^testing.T) {
	state: Test_State
	w := test_world(t, "slots", &state)
	defer clean_up(&w)

	for slot in 1 ..= SAVE_SLOTS {
		w.player.pos = {f32(slot * 10), 0}
		testing.expect(t, save_game(&w, slot))
	}
	for slot in 1 ..= SAVE_SLOTS {
		testing.expect(t, load_game(&w, slot))
		testing.expect_value(t, w.player.pos.x, f32(slot * 10))
	}

	// Writing over one leaves nothing of what was there.
	w.player.pos = {999, 0}
	state.note = "written over"
	testing.expect(t, save_game(&w, 4, "new"))
	state = {}
	testing.expect(t, load_game(&w, 4))
	testing.expect_value(t, w.player.pos.x, f32(999))
	testing.expect_value(t, state.note, "written over")

	// The others are untouched.
	testing.expect(t, load_game(&w, 5))
	testing.expect_value(t, w.player.pos.x, f32(50))
}

@(test)
loading_a_slot_that_was_never_written_fails_quietly :: proc(t: ^testing.T) {
	state: Test_State
	w := test_world(t, "empty", &state)
	defer clean_up(&w)

	w.player.pos = {7, 7}
	testing.expect(t, !load_game(&w, 6), "there is nothing in slot 6")
	// And the world is left exactly as it was, not half-loaded.
	testing.expect_value(t, w.player.pos.x, f32(7))
	testing.expect(t, !any_save(&w))
	testing.expect_value(t, newest_save(&w), 0)
}

@(test)
the_slots_can_be_listed_without_loading_them :: proc(t: ^testing.T) {
	state: Test_State
	w := test_world(t, "list", &state)
	defer clean_up(&w)

	testing.expect(t, save_game(&w, 2, "before the storm"))
	testing.expect(t, autosave(&w, "arriving"))

	infos := save_infos(&w)
	defer save_info_destroy(infos)
	testing.expect_value(t, len(infos), SAVE_SLOTS + 2)

	// The two autosaves lead, then 1 to 8 in order, so a window can draw them
	// straight down the list.
	testing.expect_value(t, infos[0].slot, AUTOSAVE)
	testing.expect_value(t, infos[1].slot, AUTOSAVE_PREVIOUS)
	testing.expect_value(t, infos[2].slot, 1)

	testing.expect(t, infos[0].used)
	testing.expect_value(t, infos[0].title, "arriving")
	testing.expect(t, !infos[1].used, "nothing has rolled down yet")
	testing.expect(t, !infos[2].used)

	testing.expect(t, infos[3].used) // slot 2
	testing.expect_value(t, infos[3].title, "before the storm")
	testing.expect_value(t, infos[3].scene, "parlour")
}

@(test)
a_title_with_spaces_survives :: proc(t: ^testing.T) {
	state: Test_State
	w := test_world(t, "title", &state)
	defer clean_up(&w)

	// The value runs to the end of the line, so a title reads like a title.
	testing.expect(t, save_game(&w, 1, "Ada Westcott, the second night"))
	infos := save_infos(&w)
	defer save_info_destroy(infos)
	testing.expect_value(t, infos[2].title, "Ada Westcott, the second night")
}

@(test)
an_untitled_save_is_named_after_the_room :: proc(t: ^testing.T) {
	state: Test_State
	w := test_world(t, "untitled", &state)
	defer clean_up(&w)

	w.current = 1
	testing.expect(t, save_game(&w, 1))
	infos := save_infos(&w)
	defer save_info_destroy(infos)
	testing.expect_value(t, infos[2].title, "veranda")
}

@(test)
a_save_file_is_text_a_person_can_read :: proc(t: ^testing.T) {
	state: Test_State
	w := test_world(t, "text", &state)
	defer clean_up(&w)

	w.current = 1
	w.player.pos = {412, 470}
	state.note = "two of them, in the water"
	testing.expect(t, save_game(&w, 1, "the pool"))

	text, ok := read_data_file(save_path(&w, 1))
	testing.expect(t, ok)
	testing.expect(t, strings.contains(text, "scene veranda"))
	testing.expect(t, strings.contains(text, "title the pool"))
	testing.expect(t, strings.contains(text, "x 412"))
	testing.expect(t, strings.contains(text, "note two of them, in the water"))
}

@(test)
writing_the_same_key_twice_replaces_it :: proc(t: ^testing.T) {
	s: Save
	defer save_destroy(&s)
	save_put(&s, "lucidity", "100")
	save_put(&s, "lucidity", "42")
	testing.expect_value(t, len(s.values), 1)
	testing.expect_value(t, save_int(&s, "lucidity"), 42)
}

@(test)
reading_something_that_was_never_written_gives_the_fallback :: proc(t: ^testing.T) {
	s: Save
	defer save_destroy(&s)
	testing.expect_value(t, save_int(&s, "nothing", 7), 7)
	testing.expect_value(t, save_bool(&s, "nothing", true), true)
	testing.expect_value(t, save_text(&s, "nothing", "none"), "none")
	testing.expect(t, !save_has(&s, "nothing"))

	// A key written empty is still a key, and must not read as missing.
	save_put(&s, "note", "")
	testing.expect(t, save_has(&s, "note"))
	testing.expect_value(t, save_text(&s, "note", "fallback"), "")
}

@(test)
a_slot_can_be_deleted :: proc(t: ^testing.T) {
	state: Test_State
	w := test_world(t, "delete", &state)
	defer clean_up(&w)

	testing.expect(t, save_game(&w, 1))
	testing.expect(t, save_exists(&w, 1))
	testing.expect(t, save_delete(&w, 1))
	testing.expect(t, !save_exists(&w, 1))
	testing.expect(t, !save_delete(&w, 1), "deleting nothing is not a success")
}
