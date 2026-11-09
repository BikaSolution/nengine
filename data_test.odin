package nengine

import "core:os"
import "core:testing"
import rl "vendor:raylib"

@(test)
lines_drop_blanks_and_comments :: proc(t: ^testing.T) {
	got := data_lines("# a comment\n\nkey one\n   \n  indented two\n")
	testing.expect_value(t, len(got), 2)
	testing.expect_value(t, got[0], "key one")
	testing.expect_value(t, got[1], "indented two")
}

@(test)
lines_split_into_words_and_pairs :: proc(t: ^testing.T) {
	l := parse_line("obj lamp pos=232,158 fps=6 block=circle:10,0,-3")
	testing.expect_value(t, l.key, "obj")
	testing.expect_value(t, len(l.words), 1)
	testing.expect_value(t, l.words[0], "lamp")
	testing.expect_value(t, field_vec2(l, "pos"), [2]f32{232, 158})
	testing.expect_value(t, field_f32(l, "fps"), f32(6))

	shape := field_shape(l, "block")
	testing.expect_value(t, shape.kind, Shape_Kind.Oval)
	testing.expect_value(t, shape.size, [2]f32{10, 5})
	testing.expect_value(t, shape.offset, [2]f32{0, -3})

	// Missing fields fall back rather than blowing up.
	testing.expect_value(t, field_f32(l, "nope", 42), f32(42))
	testing.expect_value(t, field_shape(l, "reach").kind, Shape_Kind.None)
}

@(test)
free_text_survives_to_the_end_of_the_line :: proc(t: ^testing.T) {
	testing.expect_value(t, line_tail("text lamp It flickers. Nobody paid the bill.", 2), "It flickers. Nobody paid the bill.")
	testing.expect_value(t, line_tail("desc Just one room.", 1), "Just one room.")
	testing.expect_value(t, line_tail("text lamp", 2), "")
}

@(test)
shapes_round_trip_through_text :: proc(t: ^testing.T) {
	for original in ([]Shape{box(30, 8), box(56, 30, {0, -2}), circle(26), circle(48, {0, -3})}) {
		line := parse_line(fmt_shape_line(original))
		testing.expect_value(t, field_shape(line, "s"), original)
	}
}

@(private = "file")
fmt_shape_line :: proc(s: Shape) -> string {
	text := shape_text(s)
	out := make([]u8, len("x s=") + len(text), context.temp_allocator)
	copy(out, "x s=")
	copy(out[4:], text)
	return string(out)
}

@(test)
notes_round_trip :: proc(t: ^testing.T) {
	testing.expect_value(t, parse_note("A4"), 69)
	testing.expect_value(t, note_hz(parse_note("A4")), f32(440))
	testing.expect_value(t, parse_note("."), REST)
	testing.expect_value(t, note_text(69), "A4")
	testing.expect_value(t, note_text(REST), ".")
	testing.expect_value(t, parse_note("C#5"), parse_note("Db5"))
	for n in 24 ..= 96 {
		testing.expectf(t, parse_note(note_text(n)) == n, "note %v", n)
	}
}

@(test)
a_song_survives_saving_and_loading :: proc(t: ^testing.T) {
	path := test_tmp("nengine_test.song")
	defer os.remove(path)

	s := song_new("test", 120, 2)
	defer song_destroy(&s)
	song_add_track(&s, "bass", "saw", 0.4)
	song_add_track(&s, "lead", "bell", 0.2)
	track_write_cell(&s, &s.tracks[0], 0, parse_note("A2"))
	track_write_cell(&s, &s.tracks[0], 4, parse_note("F2"))
	track_write_cell(&s, &s.tracks[1], 2, parse_note("E5"))
	testing.expect(t, save_song(&s, path))

	back, ok := load_song(path)
	defer song_destroy(&back)
	testing.expect(t, ok)
	testing.expect_value(t, back.name, "test")
	testing.expect_value(t, back.tempo, f32(120))
	testing.expect_value(t, back.bars, i32(2))
	testing.expect_value(t, len(back.tracks), 2)
	testing.expect_value(t, back.tracks[0].inst, "saw")
	testing.expect_value(t, back.tracks[0].volume, f32(0.4))
	// Read back through the tracker's own view of it, which is how it went in.
	testing.expect_value(t, track_cell(&back, &back.tracks[0], 0).note, parse_note("A2"))
	testing.expect_value(t, track_cell(&back, &back.tracks[0], 4).note, parse_note("F2"))
	testing.expect_value(t, track_cell(&back, &back.tracks[1], 2).note, parse_note("E5"))
	testing.expect_value(t, track_cell(&back, &back.tracks[1], 1).note, REST)
}

@(test)
a_held_note_keeps_sounding :: proc(t: ^testing.T) {
	testing.expect_value(t, parse_note("-"), HOLD)
	testing.expect_value(t, note_text(HOLD), "-")

	// The same note, once held over eight cells of the tracker grid and once
	// struck and left to fade. Late on, the held one should still be loud.
	loudness :: proc(s: ^Song, from, to: f32) -> f32 {
		samples := test_song_mono(s)
		defer delete(samples)
		loudest: f32
		for i in int(from * SAMPLE_RATE) ..< min(int(to * SAMPLE_RATE), len(samples)) {
			loudest = max(loudest, abs(samples[i]))
		}
		return loudest
	}

	held := song_new("held", 120, 1)
	defer song_destroy(&held)
	song_add_track(&held, "organ", "sine", 0.5)
	track_write_cell(&held, &held.tracks[0], 0, parse_note("A3"))
	for i in 1 ..< 8 do track_write_cell(&held, &held.tracks[0], i, HOLD)
	// Holding eight cells is one note eight cells long, not eight notes.
	testing.expect_value(t, len(held.tracks[0].notes), 1)
	testing.expect_value(t, held.tracks[0].notes[0].len, 8 * song_grid(&held))

	struck := song_new("struck", 120, 1)
	defer song_destroy(&struck)
	song_add_track(&struck, "organ", "sine", 0.5)
	track_write_cell(&struck, &struck.tracks[0], 0, parse_note("A3"))

	// Eight sixteenths at 120bpm is one second, so look at the second half.
	testing.expect(t, loudness(&held, 0.5, 0.9) > 4 * loudness(&struck, 0.5, 0.9),
		"a held note is still sounding when a struck one has faded")
}

@(test)
rendering_a_song_makes_sound_of_the_right_length :: proc(t: ^testing.T) {
	// One 4/4 bar at 120bpm is two seconds.
	s := song_new("test", 120, 1)
	defer song_destroy(&s)
	song_add_track(&s, "bass", "sine", 0.5)
	track_write_cell(&s, &s.tracks[0], 0, parse_note("A4"))

	samples := test_song_mono(&s)
	defer delete(samples)
	testing.expect_value(t, len(samples), 2 * SAMPLE_RATE)

	loudest: f32
	for v in samples do loudest = max(loudest, abs(v))
	testing.expect(t, loudest > 0.1, "the note actually sounds")
	testing.expect(t, loudest <= 0.9001, "and doesn't clip")
}

@(test)
a_sprite_survives_saving_and_loading :: proc(t: ^testing.T) {
	path := test_tmp("nengine_test.sprite")
	defer os.remove(path)

	d := sprite_data_new("crate", 4, 3, 2)
	defer sprite_data_destroy(&d)
	append(&d.palette, Palette_Entry{'#', {70, 46, 26, 255}})
	append(&d.palette, Palette_Entry{'o', {146, 104, 62, 255}})
	// A solid top row: every character is '#', which is also the comment
	// marker. Rows are pixels, not keywords, so this row must survive.
	for x in 0 ..< i32(4) do sprite_data_at(&d, 0, x, 0)^ = 1
	sprite_data_at(&d, 0, 1, 1)^ = 2
	sprite_data_at(&d, 1, 3, 2)^ = 2
	testing.expect(t, save_sprite_data(&d, path))

	back, ok := load_sprite_data(path)
	defer sprite_data_destroy(&back)
	testing.expect(t, ok)
	testing.expect_value(t, back.name, "crate")
	testing.expect_value(t, back.w, i32(4))
	testing.expect_value(t, back.h, i32(3))
	testing.expect_value(t, back.frames, i32(2))
	for x in 0 ..< i32(4) {
		testing.expectf(t, sprite_data_at(&back, 0, x, 0)^ == 1, "solid '#' row, pixel %v", x)
	}
	testing.expect_value(t, sprite_data_at(&back, 0, 1, 1)^, u8(2))
	testing.expect_value(t, sprite_data_at(&back, 1, 3, 2)^, u8(2))
	testing.expect_value(t, sprite_data_at(&back, 1, 0, 0)^, u8(0))
}

@(test)
resizing_a_sprite_keeps_what_still_fits :: proc(t: ^testing.T) {
	d := sprite_data_new("box", 4, 3, 2)
	defer sprite_data_destroy(&d)
	append(&d.palette, Palette_Entry{'#', {1, 2, 3, 255}})
	for f in 0 ..< i32(2) {
		for y in 0 ..< i32(3) do for x in 0 ..< i32(4) {
			sprite_data_at(&d, f, x, y)^ = 1
		}
	}

	// Growing keeps the old corner and pads the rest with nothing.
	sprite_data_resize(&d, 6, 5)
	testing.expect_value(t, d.w, i32(6))
	testing.expect_value(t, d.h, i32(5))
	testing.expect_value(t, d.frames, i32(2))
	testing.expect_value(t, len(d.pixels), 6 * 5 * 2)
	testing.expect_value(t, sprite_data_at(&d, 0, 3, 2)^, u8(1)) // was there
	testing.expect_value(t, sprite_data_at(&d, 1, 3, 2)^, u8(1)) // in both frames
	testing.expect_value(t, sprite_data_at(&d, 0, 5, 4)^, u8(0)) // new, empty

	// Shrinking crops, and every frame shrinks with it.
	sprite_data_resize(&d, 2, 2)
	testing.expect_value(t, d.w, i32(2))
	testing.expect_value(t, len(d.pixels), 2 * 2 * 2)
	testing.expect_value(t, sprite_data_at(&d, 0, 1, 1)^, u8(1))
	testing.expect_value(t, sprite_data_at(&d, 1, 1, 1)^, u8(1))

	// It never goes to nothing.
	sprite_data_resize(&d, 0, -4)
	testing.expect_value(t, d.w, i32(1))
	testing.expect_value(t, d.h, i32(1))
}

@(test)
a_sound_survives_saving_and_loading :: proc(t: ^testing.T) {
	path := test_tmp("nengine_test.sound")
	defer os.remove(path)

	s := sound_new("thud", 0.4)
	defer sound_destroy(&s)
	s.norm = 0.8
	s.lowpass = 0.2
	append(&s.layers, Sound_Layer{wave = .Sine, freq = 58, to = 46, decay = 12, vol = 1, trem_pow = 1, n_partials = 1, partials = {0 = 1}})
	append(&s.layers, Sound_Layer{wave = .Noise, decay = 60, vol = 0.5, trem_pow = 1, n_partials = 1, partials = {0 = 1}})
	testing.expect(t, save_sound(&s, path))

	back, ok := load_sound(path)
	defer sound_destroy(&back)
	testing.expect(t, ok)
	testing.expect_value(t, back.name, "thud")
	testing.expect_value(t, back.length, f32(0.4))
	testing.expect_value(t, back.norm, f32(0.8))
	testing.expect_value(t, len(back.layers), 2)
	testing.expect_value(t, back.layers[0].wave, Sound_Wave.Sine)
	testing.expect_value(t, back.layers[0].freq, f32(58))
	testing.expect_value(t, back.layers[1].wave, Sound_Wave.Noise)

	samples := render_sound(&back).samples
	defer delete(samples)
	testing.expect_value(t, len(samples), int(0.4 * SOUND_RATE))
	loudest: f32
	for v in samples do loudest = max(loudest, abs(v))
	testing.expectf(t, abs(loudest - 0.8) < 0.001, "normalised to 0.8, got %v", loudest)
}

@(test)
a_sound_renders_the_same_way_every_time :: proc(t: ^testing.T) {
	// The noise is deterministic, so a baked .wav only changes when the
	// .sound does. Without this, every bake would rewrite every file.
	s := sound_new("hiss", 0.1)
	defer sound_destroy(&s)
	append(&s.layers, Sound_Layer{wave = .Noise, vol = 1, trem_pow = 1, n_partials = 1, partials = {0 = 1}})

	first := render_sound(&s).samples
	defer delete(first)
	second := render_sound(&s).samples
	defer delete(second)
	testing.expect_value(t, len(first), len(second))
	for i in 0 ..< len(first) {
		if first[i] != second[i] {
			testing.expectf(t, false, "sample %v differs between renders", i)
			break
		}
	}
}

@(test)
a_character_survives_saving_and_loading :: proc(t: ^testing.T) {
	path := test_tmp("nengine_test.char")
	defer os.remove(path)

	c := character_new("potato", 4, 3)
	defer character_destroy(&c)
	front := character_add_part(&c, "front", 1)
	append(&front.data.palette, Palette_Entry{'#', {10, 20, 30, 255}})
	sprite_data_at(&front.data, 0, 0, 0)^ = 1

	// A second part with a different size, its own speed, and a colour the
	// first one doesn't have: the shared palette has to hold both.
	//
	// A new part normally starts with the character's colours — see
	// character_add_part — so this one is given a tray of its own on purpose,
	// which is what a pose pasted in from another character looks like. The
	// two parts now disagree about what index 1 means, and saving has to
	// renumber one of them.
	walk := character_add_part(&c, "walk_left", 2, 8)
	clear(&walk.data.palette)
	append(&walk.data.palette, Palette_Entry{'.', {0, 0, 0, 0}})
	append(&walk.data.palette, Palette_Entry{'#', {90, 80, 70, 255}})
	sprite_data_at(&walk.data, 1, 2, 1)^ = 1
	testing.expect(t, save_character(&c, path))

	back, ok := load_character(path)
	defer character_destroy(&back)
	testing.expect(t, ok)
	testing.expect_value(t, back.name, "potato")
	testing.expect_value(t, len(back.parts), 2)

	f := character_part(&back, "front")
	testing.expect(t, f != nil)
	testing.expect_value(t, f.data.frames, i32(1))
	testing.expect_value(t, f.data.palette[int(sprite_data_at(&f.data, 0, 0, 0)^)].color, rl.Color{10, 20, 30, 255})

	wl := character_part(&back, "walk_left")
	testing.expect(t, wl != nil)
	testing.expect_value(t, wl.fps, f32(8))
	testing.expect_value(t, wl.data.frames, i32(2))
	testing.expect_value(t, wl.data.palette[int(sprite_data_at(&wl.data, 1, 2, 1)^)].color, rl.Color{90, 80, 70, 255})
	testing.expect_value(t, sprite_data_at(&wl.data, 0, 0, 0)^, u8(0))
}

@(test)
a_scene_survives_saving_and_loading :: proc(t: ^testing.T) {
	path := test_tmp("nengine_test.scene")
	defer os.remove(path)

	walk := [][2]f32{{24, 122}, {318, 122}, {318, 186}, {4, 186}}
	s := Scene {
		name        = "parlour",
		description = "A small parlour, with a hole in the floor.",
		walk_area   = walk,
	}
	append(&s.objects, Object {
		name        = "lamp",
		description = "It flickers. Nobody paid the bill.",
		pos         = {232, 158},
		fps         = 6,
		walk_to     = {214, 162},
		block       = circle(10),
		reach       = circle(48),
	})
	append(&s.exits, Exit {
		name        = "door",
		area        = {256, 122, 30, 4},
		to          = 1,
		arrive      = {160, 142},
		closed      = true,
		closed_text = "The door is closed.",
	})
	testing.expect(t, save_scene(&s, path))
	delete(s.objects)
	delete(s.exits)

	back, ok := load_scene(path, nil)
	defer {
		free_scene_strings(&back)
		delete(back.objects)
		delete(back.exits)
		delete(back.triggers)
		delete(back.walk_area)
		delete(back.scenery)
		delete(back.said)
	}
	testing.expect(t, ok)
	testing.expect_value(t, back.name, "parlour")
	testing.expect_value(t, back.description, "A small parlour, with a hole in the floor.")
	testing.expect_value(t, len(back.walk_area), 4)
	testing.expect_value(t, back.walk_area[1], [2]f32{318, 122})

	testing.expect_value(t, len(back.objects), 1)
	o := back.objects[0]
	testing.expect_value(t, o.name, "lamp")
	testing.expect_value(t, o.description, "It flickers. Nobody paid the bill.")
	testing.expect_value(t, o.pos, [2]f32{232, 158})
	testing.expect_value(t, o.fps, f32(6))
	testing.expect_value(t, o.block, circle(10))
	testing.expect_value(t, o.reach, circle(48))

	testing.expect_value(t, len(back.exits), 1)
	e := back.exits[0]
	testing.expect_value(t, e.name, "door")
	testing.expect_value(t, e.to, 1)
	testing.expect_value(t, e.closed, true)
	testing.expect_value(t, e.closed_text, "The door is closed.")
	testing.expect_value(t, e.arrive, [2]f32{160, 142})
}
