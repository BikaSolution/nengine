package main

import ne "../../"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// The room editor's load and save, against every room in the checkout, and
// its changes against the engine's own reading of what they wrote.

// The checkout: three folders up from this file (nengine/tools/nscene).
@(private = "file")
checkout :: proc() -> string {
	dir := #directory
	for _ in 0 ..< 3 do dir = dir[:strings.last_index_byte(strings.trim_right(dir, "/"), '/')]
	return dir
}

// The games beside the engine: every folder next to nengine/ with an assets/
// folder in it. The engine checked out on its own has none, and these tests
// then have nothing to read.
@(private = "file")
games :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	infos, err := os.read_directory_by_path(checkout(), -1, context.temp_allocator)
	if err != nil do return out[:]
	for f in infos {
		if f.type != .Directory || f.name == "nengine" do continue
		if os.is_dir(fmt.tprintf("%v/%v/assets", checkout(), f.name)) do append(&out, f.name)
	}
	return out[:]
}

@(private = "file")
scene_files :: proc(dir: string, out: ^[dynamic]string) {
	infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil do return
	for f in infos {
		path := fmt.tprintf("%v/%v", dir, f.name)
		if f.type == .Directory {
			scene_files(path, out)
		} else if strings.has_suffix(f.name, ".scene") {
			append(out, path)
		}
	}
}

// Every .scene in every game beside the engine, opened and saved by the editor with no change
// made, comes back byte for byte: comments, blank lines, the order of lines
// and of fields, fields the engine's own writer would drop (`frame=` on an
// object), and whether the file ends in a newline.
@(test)
every_room_in_every_game_saves_back_exactly :: proc(t: ^testing.T) {
	files := make([dynamic]string, context.temp_allocator)
	for game in games() {
		scene_files(fmt.tprintf("%v/%v", checkout(), game), &files)
	}
	if len(files) == 0 do return // no game beside the engine

	for path in files {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if !testing.expectf(t, err == nil, "could not read %v", path) do continue
		d: Doc
		ok := doc_load(&d, path)
		testing.expectf(t, ok, "%v did not load", path)
		back := doc_text(&d)
		if back != string(data) {
			testing.expectf(t, false, "%v: saved %v bytes for %v", path, len(back), len(data))
		}

		// And the editor sees what the engine sees: as many objects, exits,
		// triggers and scenery, in the same order, under the same names.
		s, parsed := ne.parse_scene(string(data), nil)
		testing.expectf(t, parsed, "%v: the engine could not read it", path)
		testing.expectf(t, len(s.objects) == len(d.objects), "%v: %v objects, the engine has %v", path, len(d.objects), len(s.objects))
		testing.expectf(t, len(s.exits) == len(d.exits), "%v: %v exits, the engine has %v", path, len(d.exits), len(s.exits))
		testing.expectf(t, len(s.scenery) == len(d.scenery), "%v: %v scenery, the engine has %v", path, len(d.scenery), len(s.scenery))
		testing.expectf(t, len(s.walk_area) == len(d.walk), "%v: %v floor corners, the engine has %v", path, len(d.walk), len(s.walk_area))
		testing.expectf(t, len(s.windows) == len(d.windows), "%v: %v windows, the engine has %v", path, len(d.windows), len(s.windows))
		for win, i in s.windows {
			if i >= len(d.windows) do break
			dw := d.windows[i]
			testing.expectf(t, win.name == dw.name && win.feet == dw.feet && win.frame == dw.frame && win.only == dw.only &&
				win.glass == {dw.glass[0], dw.glass[1], dw.glass[2], dw.glass[3]}, "%v: window %v differs from the engine's", path, dw.name)
		}
		for o, i in s.objects {
			if i >= len(d.objects) do break
			testing.expectf(t, o.name == d.objects[i].name && o.pos == d.objects[i].pos, "%v: object %v is %v at %v, the engine has %v at %v", path, i, d.objects[i].name, d.objects[i].pos, o.name, o.pos)
			// Which lines belong to it, the way the engine attaches them.
			n_on := len(doc_attached(&d, i, "on"))
			testing.expectf(t, n_on == len(o.on), "%v: %v has %v `on` lines, the engine has %v", path, o.name, n_on, len(o.on))
			n_steps := len(doc_attached(&d, i, "step"))
			testing.expectf(t, n_steps == len(o.routine.steps), "%v: %v has %v steps, the engine has %v", path, o.name, n_steps, len(o.routine.steps))
			if o.description != "" {
				testing.expectf(t, d.objects[i].text >= 0 && doc_line_text(&d, d.objects[i].text) == o.description, "%v: %v's text differs", path, o.name)
			}
		}
		engine_free(&s)
		doc_destroy(&d)
	}
}

@(private = "file")
ROOM :: `# The office.
scene admin
bg admin
desc An office.
walk 0,400 1000,400 1000,600 0,600

# The chest, under the window.
obj chest pos=407,488 sprite=chest block=box:80,20,0,-10 walk_to=470,492 reach=box:2100,800
text chest A tin box.
# the count first
on chest look when=bodies_found action=count_the_chest
on chest open when=!bodies_found Locked.
obj elena pos=220,462 char=elena pose=desk when=early
text elena Elena, at the desk.
on elena talk_to action=elena_topics
obj elena pos=220,462 char=elena pose=desk when=late
text elena Elena, later.

exit compound area=960,540,64,94 to=fire_pit arrive=80,520
exit back area=100,440,60,76 to=back_room arrive=512,580 closed=true
shut back Her door.
trigger darting area=212,451,811,183 action=the_darting_talk when=talk_now
`

@(private = "file")
room :: proc() -> (d: Doc) {
	doc_set_text_all(&d, ROOM)
	return
}

@(private = "file")
engine_view :: proc(d: ^Doc) -> ne.Scene {
	s, _ := ne.parse_scene(doc_text(d), nil)
	return s
}

@(private = "file")
engine_free :: proc(s: ^ne.Scene) {
	for o in s.objects {
		for st in o.routine.steps {
			delete(st.pose)
			delete(st.text)
		}
		delete(o.routine.steps)
	}
	ne.free_scene_strings(s)
	delete(s.objects); delete(s.exits); delete(s.triggers); delete(s.walk_area); delete(s.scenery); delete(s.windows)
	delete(s.said)
}

@(test)
lines_attach_to_the_latest_object_of_their_name :: proc(t: ^testing.T) {
	d := room()
	defer doc_destroy(&d)
	testing.expect_value(t, len(d.objects), 3)
	testing.expect_value(t, len(doc_attached(&d, 0, "on")), 2)
	testing.expect_value(t, len(doc_attached(&d, 1, "on")), 1) // the early elena
	testing.expect_value(t, len(doc_attached(&d, 2, "on")), 0)
	testing.expect_value(t, doc_line_text(&d, d.objects[2].text), "Elena, later.")
	testing.expect_value(t, len(doc_shuts(&d, 1)), 1)
	testing.expect_value(t, len(doc_shuts(&d, 0)), 0)
	notes := doc_notes_above(&d, d.objects[0].line)
	testing.expect_value(t, len(notes), 1)
	if len(notes) == 1 do testing.expect_value(t, notes[0], "The chest, under the window.")
}

@(test)
changing_a_field_changes_only_that_line :: proc(t: ^testing.T) {
	d := room()
	defer doc_destroy(&d)
	on := doc_attached(&d, 0, "on")[1]
	doc_set_field(&d, on, "when", "night")
	doc_set_line_text(&d, on, "Locked, and dark.")
	want, _ := strings.replace(ROOM, "on chest open when=!bodies_found Locked.", "on chest open when=night Locked, and dark.", 1, context.temp_allocator)
	testing.expect_value(t, doc_text(&d), want)

	s := engine_view(&d)
	defer engine_free(&s)
	it := s.objects[0].on[1]
	testing.expect_value(t, it.verb, "open")
	testing.expect_value(t, it.only, "night")
	testing.expect_value(t, it.text, "Locked, and dark.")
}

@(test)
a_field_set_to_nothing_comes_off_and_a_new_one_goes_on_the_end :: proc(t: ^testing.T) {
	d := room()
	defer doc_destroy(&d)
	line := d.objects[0].line
	doc_set_field(&d, line, "block", "")
	doc_set_field(&d, line, "glow", "true")
	testing.expect_value(t, d.lines[line], "obj chest pos=407,488 sprite=chest walk_to=470,492 reach=box:2100,800 glow=true")
	// Setting a field to what it already says leaves the line as written.
	before := strings.clone(d.lines[line], context.temp_allocator)
	doc_set_field(&d, line, "pos", "407,488")
	testing.expect_value(t, d.lines[line], before)
}

@(test)
renaming_an_object_renames_its_lines_and_no_one_elses :: proc(t: ^testing.T) {
	d := room()
	defer doc_destroy(&d)
	doc_rename_object(&d, 1, "Elena Early")
	testing.expect_value(t, d.objects[1].name, "elena_early")
	testing.expect_value(t, len(doc_attached(&d, 1, "on")), 1)
	testing.expect_value(t, d.objects[2].name, "elena")
	testing.expect_value(t, doc_line_text(&d, d.objects[2].text), "Elena, later.")
	s := engine_view(&d)
	defer engine_free(&s)
	testing.expect_value(t, s.objects[1].name, "elena_early")
	testing.expect_value(t, s.objects[1].description, "Elena, at the desk.")
	testing.expect_value(t, len(s.objects[1].on), 1)
}

@(test)
interactions_are_added_moved_and_removed :: proc(t: ^testing.T) {
	d := room()
	defer doc_destroy(&d)
	l := doc_add_on(&d, 0, "turn on")
	doc_set_field(&d, l, "with", "key")
	doc_set_line_text(&d, l, "It turns.")
	ons := doc_attached(&d, 0, "on")
	testing.expect_value(t, len(ons), 3)
	testing.expect_value(t, d.lines[ons[2]], "on chest turn_on with=key It turns.")
	doc_swap(&d, ons[1], ons[2])
	s := engine_view(&d)
	testing.expect_value(t, s.objects[0].on[1].verb, "turn on")
	testing.expect_value(t, s.objects[0].on[1].with, "key")
	testing.expect_value(t, s.objects[0].on[2].verb, "open")
	engine_free(&s)
	doc_remove(&d, doc_attached(&d, 0, "on")[0])
	testing.expect_value(t, len(doc_attached(&d, 0, "on")), 2)
	// The comment above the one taken out stays; it is the author's.
	testing.expect(t, strings.contains(doc_text(&d), "# the count first"))
}

@(test)
objects_exits_and_triggers_are_added_and_removed_whole :: proc(t: ^testing.T) {
	d := room()
	defer doc_destroy(&d)
	i := doc_add_object(&d, "obj", doc_free_name(&d, "chest"), {100, 500}, [2]string{"sprite", "lamp"})
	testing.expect_value(t, d.objects[i].name, "chest2")
	doc_set_object_text(&d, i, "A second chest.")
	doc_add_on(&d, i, "open")
	testing.expect_value(t, len(doc_object_lines(&d, i)), 3)
	doc_remove_object(&d, 0)
	testing.expect_value(t, len(d.objects), 3)
	s := engine_view(&d)
	testing.expect_value(t, len(s.objects), 3)
	testing.expect_value(t, s.objects[2].name, "chest2")
	testing.expect_value(t, s.objects[2].description, "A second chest.")
	testing.expect_value(t, s.objects[2].sprite_name, "lamp")
	engine_free(&s)

	e := doc_add_exit(&d, "gate", {0, 500, 40, 100}, "admin", {60, 560})
	doc_set_shut(&d, e, "Locked.")
	testing.expect_value(t, len(doc_shuts(&d, e)), 1)
	doc_remove_exit(&d, e)
	testing.expect(t, !strings.contains(doc_text(&d), "shut gate"))

	tr := doc_add_trigger(&d, "trap", {10, 10, 20, 20}, "spring")
	testing.expect_value(t, d.triggers[tr].action, "spring")
	s2 := engine_view(&d)
	testing.expect_value(t, len(s2.triggers), 2)
	engine_free(&s2)
}

@(test)
the_floor_and_the_room_lines :: proc(t: ^testing.T) {
	d := room()
	defer doc_destroy(&d)
	doc_set_walk(&d, {{0, 0}, {10, 0}, {10, 10}})
	testing.expect_value(t, d.lines[d.walk_at], "walk 0,0 10,0 10,10")
	doc_set_room_word(&d, "bg", "admin_night")
	doc_set_room_word(&d, "footstep", "step_boards")
	doc_set_indoors(&d, true)
	doc_add_desc(&d, "dark", "Dark.")
	doc_add_ambience(&d, "hum", "")
	s := engine_view(&d)
	defer engine_free(&s)
	testing.expect_value(t, s.background_name, "admin_night")
	testing.expect_value(t, s.step_name, "step_boards")
	testing.expect(t, s.indoors)
	testing.expect_value(t, len(s.said), 2)
	testing.expect_value(t, s.said[1].only, "dark")
	testing.expect_value(t, len(s.ambiences), 1)
}

@(test)
a_copied_object_pastes_renamed_and_moved :: proc(t: ^testing.T) {
	d := room()
	defer doc_destroy(&d)
	block := doc_object_block(&d, 0)
	defer delete(block)
	i := doc_paste_object(&d, block, {8, 8})
	testing.expect_value(t, d.objects[i].name, "chest2")
	testing.expect_value(t, d.objects[i].pos, [2]f32{415, 496})
	testing.expect_value(t, len(doc_attached(&d, i, "on")), 2)
	testing.expect_value(t, len(doc_attached(&d, 0, "on")), 2)
}

@(test)
free_text_keeps_its_place_after_the_fields :: proc(t: ^testing.T) {
	p := parts_of("on door unlock with=key when=night The lock gives.")
	testing.expect_value(t, p.key, "on")
	testing.expect_value(t, len(p.head), 2)
	testing.expect_value(t, p.text, "The lock gives.")
	testing.expect_value(t, len(p.fields), 2)
	q := parts_of("step elena say Hello there.")
	testing.expect_value(t, q.text, "Hello there.")
	r := parts_of("step elena walk_to 300,520")
	testing.expect_value(t, len(r.head), 3)
	testing.expect_value(t, r.text, "")
	w := parts_of("desc when=dawn Elena at the desk.")
	testing.expect_value(t, w.text, "Elena at the desk.")
	testing.expect_value(t, fmt.tprint(parts_text(w)), "desc when=dawn Elena at the desk.")
}

@(private = "file")
HUT :: `# A hut.
scene hut
indoors
walk 0,400 1000,400 1000,600 0,600

# The back window: the frame is its own sprite, over whoever is outside.
window back glass=445,176,138,122 feet=380 frame=win_back
obj win_back pos=512,400 sprite=win_back depth=back base=200
# The shutter, open only once it is cut.
window side  glass=854,262,32,218 when=shutter_cut
obj win_side pos=856,592 sprite=win_side depth=back base=8
`

// A `window` line: read, kept byte for byte (two spaces and all), changed a
// field at a time, and seen by the engine as the editor sees it.
@(test)
window_lines_are_read_kept_and_changed :: proc(t: ^testing.T) {
	d: Doc
	doc_set_text_all(&d, HUT)
	defer doc_destroy(&d)
	testing.expect_value(t, doc_text(&d), HUT)
	testing.expect_value(t, len(d.windows), 2)
	testing.expect_value(t, d.windows[0].name, "back")
	testing.expect_value(t, d.windows[0].glass, [4]f32{445, 176, 138, 122})
	testing.expect_value(t, d.windows[0].feet, f32(380))
	testing.expect_value(t, d.windows[0].frame, "win_back")
	testing.expect_value(t, d.windows[1].only, "shutter_cut")
	// No feet: the engine's default, the foot of the glass and half a person.
	testing.expect_value(t, doc_window_feet(d.windows[1]), f32(262 + 218) + PERSON_H / 2)
	notes := doc_notes_above(&d, d.windows[1].line)
	testing.expect_value(t, len(notes), 1)
	// It names `shutter_cut`, so the flags view offers it.
	found := false
	for f in room_flags(&d) do if f == "shutter_cut" do found = true
	testing.expect(t, found)

	// Dragging the feet line changes that field on that line, nothing else.
	doc_set_field(&d, d.windows[0].line, "feet", "392")
	want, _ := strings.replace(HUT, "feet=380", "feet=392", 1, context.temp_allocator)
	testing.expect_value(t, doc_text(&d), want)
	// Resizing the glass, and giving the side window a feet line of its own.
	doc_set_field(&d, d.windows[1].line, "glass", rect_text({850, 260, 40, 220}))
	doc_set_field(&d, d.windows[1].line, "feet", "500")
	testing.expect_value(t, d.lines[d.windows[1].line], "window side glass=850,260,40,220 when=shutter_cut feet=500")

	s := engine_view(&d)
	testing.expect_value(t, len(s.windows), 2)
	testing.expect_value(t, s.windows[0].feet, f32(392))
	testing.expect_value(t, s.windows[1].glass.width, f32(40))
	testing.expect_value(t, s.windows[1].feet, f32(500))
	testing.expect_value(t, s.windows[1].only, "shutter_cut")
	engine_free(&s)

	// Added with the others, named so as not to clash, and removed whole.
	testing.expect_value(t, doc_free_name(&d, "back"), "back2")
	i := doc_add_window(&d, "door", {10, 20, 30, 40})
	testing.expect_value(t, d.windows[i].name, "door")
	testing.expect_value(t, d.lines[d.windows[i].line], "window door glass=10,20,30,40")
	testing.expect_value(t, d.windows[i].line, d.windows[1].line + 1)
	doc_remove(&d, d.windows[i].line)
	testing.expect_value(t, len(d.windows), 2)
	// Renamed: the first word.
	doc_set_head(&d, d.windows[1].line, 0, "shutter")
	testing.expect_value(t, d.windows[1].name, "shutter")
	testing.expect_value(t, len(d.objects), 2)
}
