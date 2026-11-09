package nengine

import "core:encoding/endian"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
wav_file_has_a_valid_header :: proc(t: ^testing.T) {
	samples := []f32{0, 1, -1, 0.5, 2} // 2 is out of range and should clip to 1
	b := wav_file(samples)
	defer delete(b)

	testing.expect_value(t, len(b), 44 + len(samples) * 2)
	testing.expect_value(t, string(b[0:4]), "RIFF")
	testing.expect_value(t, string(b[8:16]), "WAVEfmt ")
	testing.expect_value(t, string(b[36:40]), "data")

	rate, _ := endian.get_u32(b[24:], .Little)
	testing.expect_value(t, rate, u32(SAMPLE_RATE))
	size, _ := endian.get_u32(b[40:], .Little)
	testing.expect_value(t, size, u32(len(samples) * 2))

	loudest, _ := endian.get_i16(b[44 + 2:], .Little)
	quietest, _ := endian.get_i16(b[44 + 4:], .Little)
	clipped, _ := endian.get_i16(b[44 + 8:], .Little)
	testing.expect_value(t, loudest, i16(32767))
	testing.expect_value(t, quietest, i16(-32767))
	testing.expect_value(t, clipped, i16(32767))
}

// A looping tone that should end on a whole cycle does: the seam from the
// last sample to the first is no bigger than any other step. (Added up in
// f32, a 50 Hz tone over 8 s missed by a tenth of full scale and clicked.)
@(test)
a_looping_tone_joins_without_a_click :: proc(t: ^testing.T) {
	s := sound_new("hum", 8)
	defer sound_destroy(&s)
	s.loop = true
	s.norm = 0
	layer := Sound_Layer{wave = .Sine, freq = 50, vol = 0.5, n_partials = 1}
	layer.partials[0] = 1
	append(&s.layers, layer)
	out := render_sound(&s).samples
	defer delete(out)
	biggest: f32
	for i in 1 ..< len(out) do biggest = max(biggest, abs(out[i] - out[i - 1]))
	seam := abs(out[0] - out[len(out) - 1])
	testing.expectf(t, seam <= biggest * 1.05, "seam %v against an ordinary step of %v", seam, biggest)
}

// `!sound` says what was played since it last asked, the bed and how loud,
// and a name with no sound behind it as silent; a bed asked for again only
// gets louder.
@(test)
the_harness_hears_what_was_played :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	play_sound(&w, "rifle_shot")
	play_sound(&w, "padlock", 0.5)
	play_bed(&w, "engine_idle", 0.25)
	play_bed(&w, "engine_idle", 0.5)
	r := bang(&w, "sound", nil)
	testing.expectf(t, strings.contains(r, "ambience none; loops none; music none; bed engine_idle at 0.50"), "%v", r)
	testing.expectf(t, strings.contains(r, "played rifle_shot (silent: no such sound), padlock (silent: no such sound) at 0.50"), "%v", r)
	r = bang(&w, "sound", nil)
	testing.expectf(t, strings.contains(r, "played nothing"), "asking forgets what was played: %v", r)
	play_bed(&w, "")
	testing.expect_value(t, w.bed_name, "")
	for _ in 0 ..< 3 do play_sound(&w, "drip")
	testing.expectf(t, strings.contains(bang(&w, "sound", nil), "played drip (silent: no such sound) x3"), "the same sound running is one entry")
	for i in 0 ..< HEARD_KEPT + 5 do play_sound(&w, "drip" if i % 2 == 0 else "drop")
	testing.expect_value(t, len(w.heard), HEARD_KEPT)
}

// A hidden window is a silent one: smoke never makes a noise.
@(test)
a_hidden_window_is_silent :: proc(t: ^testing.T) {
	was := os.get_env("NENGINE_HIDDEN", context.temp_allocator)
	defer if was != "" do os.set_env("NENGINE_HIDDEN", was)
	else do os.unset_env("NENGINE_HIDDEN")
	os.set_env("NENGINE_HIDDEN", "1")
	testing.expect_value(t, master_volume(), f32(0))
	os.unset_env("NENGINE_HIDDEN")
	testing.expect_value(t, master_volume(), f32(1))
}

// The pen is heard as an entry goes in, once per new entry, and not when a
// restore writes the book back.
@(test)
a_new_entry_is_heard_and_a_restored_one_is_not :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	w.note_sound = "pen_scratch"
	note(&w, {id = "shoe", tab = "things", text = "One shoe."})
	note(&w, {id = "shoe", tab = "things", text = "One shoe."})
	testing.expect_value(t, len(w.heard), 1)
	s: Save
	defer save_destroy(&s)
	notebook_save(&w, &s)
	forget_heard(&w)
	notebook_load(&w, &s)
	testing.expect_value(t, len(w.heard), 0)
	testing.expect_value(t, w.note_sound, "pen_scratch")
}
