package nengine

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import rl "vendor:raylib"

// Music streams (audio.odin, qoa.odin): a baked loop goes round sample-exact,
// and what plays where holds with the music and the bed as streams. No audio
// device is opened: raylib opens the file and its decoder all the same, and
// has nothing to play it into, so the rules are tested and nothing is heard.

@(private = "file")
stream_dir :: proc(name: string) -> string {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" do base = "/tmp"
	dir := strings.concatenate({base, "/nengine-stream-", name}, context.temp_allocator)
	os.remove_all(dir)
	os.make_directory(dir)
	return dir
}

// A loop of whole cycles that starts well away from zero, where a plain
// encoder's first guess (silence) is at its worst; the channels apart. Its
// length is not a whole number of QOA frames or slices, so the last frame is
// a short one.
@(private = "file")
stream_test_loop :: proc(frames, channels: int) -> []f32 {
	out := make([]f32, frames * channels)
	for i in 0 ..< frames {
		t := f64(i) / f64(frames)
		for c in 0 ..< channels {
			v := 0.5 * math.sin(2 * math.PI * 40 * t + 1.2 + f64(c)) + 0.25 * math.sin(2 * math.PI * 97 * t + 0.4)
			out[i * channels + c] = f32(v)
		}
	}
	return out
}

// The seam, decoded two loops running: the file is exactly the loop's length
// (no padding, no priming), raylib decodes it as qoa.odin does, the second
// time round is the first again, and the step across the turn is the
// source's own give or take the codec's ordinary error — where a plain encode,
// starting from silence, is far out.
@(test)
a_streamed_loop_goes_round_sample_exact :: proc(t: ^testing.T) {
	rl.SetTraceLogLevel(.ERROR)
	dir := stream_dir("seam")
	for ch in 1 ..= 2 {
		rate := 22050 if ch == 1 else SAMPLE_RATE
		frames := 3 * QOA_FRAME_LEN + 77
		src := stream_test_loop(frames, ch)
		defer delete(src)
		pcm := to_pcm16(src)
		defer delete(pcm)

		path := fmt.tprintf("%v/loop%v.qoa", dir, ch)
		testing.expect(t, export_audio(src, path, ch, rate, loop = true))
		file, err := os.read_entire_file(path, context.allocator)
		testing.expect(t, err == nil)
		defer delete(file)
		testing.expect_value(t, len(file), qoa_size(frames, ch))

		// raylib's own decoder, which is the one the game streams through.
		w := rl.LoadWave(strings.clone_to_cstring(path, context.temp_allocator))
		defer rl.UnloadWave(w)
		testing.expect_value(t, int(w.frameCount), frames)
		testing.expect_value(t, int(w.channels), ch)
		testing.expect_value(t, int(w.sampleRate), rate)
		theirs := ([^]i16)(w.data)[:frames * ch]
		mine, _, _, ok := qoa_decode(file)
		defer delete(mine)
		testing.expect(t, ok)
		testing.expectf(t, slice.equal(mine, theirs), "%vch: qoa.odin decodes as raylib does", ch)
		m := rl.LoadMusicStream(strings.clone_to_cstring(path, context.temp_allocator))
		testing.expect_value(t, int(m.frameCount), frames)
		rl.UnloadMusicStream(m)

		// Two loops and a bit, a raylib-sized buffer at a time.
		s, opened := qoa_stream_open(file)
		testing.expect(t, opened)
		defer qoa_stream_close(&s)
		total := 2 * frames + 333
		two := make([]i16, total * ch)
		defer delete(two)
		for done := 0; done < total; {
			n := qoa_stream_read(&s, two[done * ch:min(done + 2048, total) * ch])
			if n == 0 do break
			done += n
		}
		testing.expectf(t, slice.equal(two[:frames * ch], mine), "%vch: the first time round is the file", ch)
		testing.expectf(t, slice.equal(two[frames * ch:2 * frames * ch], mine), "%vch: the second time round is the first", ch)
		testing.expectf(t, slice.equal(two[2 * frames * ch:], mine[:333 * ch]), "%vch: and the third begins as they did", ch)

		// The codec's ordinary error, and the turn's.
		sum: f64
		for v, i in mine do sum += f64(int(v) - int(pcm[i])) * f64(int(v) - int(pcm[i]))
		ordinary := math.sqrt(sum / f64(len(mine)))
		plain := qoa_encode(pcm, ch, rate, loop = false)
		defer delete(plain)
		flat, _, _, _ := qoa_decode(plain)
		defer delete(flat)
		for c in 0 ..< ch {
			last, first := (frames - 1) * ch + c, frames * ch + c
			want := int(pcm[c]) - int(pcm[last])
			got := int(two[first]) - int(two[last])
			testing.expectf(t, f64(abs(got - want)) <= 4 * ordinary + 2,
				"%vch/%v: the turn steps %v where the source steps %v (ordinary error %.1f)", ch, c, got, want, ordinary)
			testing.expectf(t, abs(int(flat[c]) - int(pcm[c])) > 4 * abs(int(mine[c]) - int(pcm[c])) + 50,
				"%vch/%v: primed, the first sample is %v out; plain, %v", ch, c,
				int(mine[c]) - int(pcm[c]), int(flat[c]) - int(pcm[c]))
		}
	}
	os.remove_all(dir)
}

// play_music, stop_music and the bed's rules, with both streamed from baked
// .qoa files: a song loops on until stopped, a cue replaces it, a new game
// and a restore stop the music; the bed is its own stream, gets louder
// without starting over, goes quiet in the room whose ambience it is, and
// goes with a new game. `!sound` says the same.
@(test)
music_and_the_bed_hold_with_streams :: proc(t: ^testing.T) {
	rl.SetTraceLogLevel(.ERROR)
	dir := stream_dir("rules")
	song := stream_test_loop(3 * QOA_FRAME_LEN, 2)
	defer delete(song)
	hum := stream_test_loop(QOA_FRAME_LEN, 1)
	defer delete(hum)
	testing.expect(t, export_audio(song, fmt.tprintf("%v/song.qoa", dir), 2, SAMPLE_RATE, loop = true))
	testing.expect(t, export_audio(song[:QOA_FRAME_LEN * 2], fmt.tprintf("%v/cue.qoa", dir), 2, SAMPLE_RATE))
	testing.expect(t, export_audio(hum, fmt.tprintf("%v/hum.qoa", dir), 1, 22050, loop = true))

	a: Assets
	defer assets_destroy(&a)
	testing.expect_value(t, assets_load_folder(&a, dir), 3)
	testing.expect_value(t, len(a.sounds), 0) // nothing long is loaded whole

	w: World
	defer destroy_world(&w)
	w.assets = &a
	append(&w.scenes, Scene{name = "yard"}, Scene{name = "shed", ambience_name = "hum"})

	play_music(&w, "song", loop = true, volume = 0.4)
	testing.expect(t, w.music != nil && w.music == assets_loop(&a, "song"))
	if w.music == nil do return
	testing.expect(t, loop_open(w.music))
	testing.expect(t, w.music.music.looping)
	testing.expect_value(t, w.music.volume, f32(0.4))
	testing.expect_value(t, int(w.music.music.frameCount), 3 * QOA_FRAME_LEN)
	testing.expect_value(t, w.music_name, "song")
	update_audio(&w)
	testing.expect_value(t, w.music_name, "song") // a looping song goes on

	play_music(&w, "cue")
	testing.expect_value(t, w.music_name, "cue")
	testing.expect(t, w.music != nil && !w.music.music.looping)
	stop_music(&w)
	testing.expect(t, w.music == nil)
	testing.expect_value(t, w.music_name, "")
	play_music(&w, "no_such_song")
	testing.expect(t, w.music == nil)

	play_bed(&w, "hum", 0.25)
	testing.expect(t, loop_open(&w.bed))
	stream := w.bed.music.ctxData
	update_audio(&w)
	testing.expect_value(t, w.bed.volume, f32(0.25))
	play_bed(&w, "hum", 0.5)
	testing.expect(t, w.bed.music.ctxData == stream) // louder, not started over
	update_audio(&w)
	testing.expect_value(t, w.bed.volume, f32(0.5))
	w.current = 1 // the shed, whose ambience is the hum: the room plays it nearer
	update_audio(&w)
	testing.expect_value(t, w.bed.volume, f32(0))
	testing.expect_value(t, w.bed_volume, f32(0.5))
	w.current = 0
	update_audio(&w)
	testing.expect_value(t, w.bed.volume, f32(0.5))
	r := sound_report(&w)
	testing.expectf(t, strings.contains(r, "music none; bed hum at 0.50"), "%v", r)

	// A restore stops the music and leaves the bed to on_clock.
	play_music(&w, "song", loop = true)
	s: Save
	defer save_destroy(&s)
	save_world(&w, &s, "")
	testing.expect(t, load_world(&w, save_text_of(&s)))
	testing.expect(t, w.music == nil)
	testing.expect(t, loop_open(&w.bed))

	// A new game stops both.
	play_music(&w, "song", loop = true)
	reset_story(&w)
	testing.expect(t, w.music == nil)
	testing.expect(t, !loop_open(&w.bed))
	testing.expect_value(t, w.bed_name, "")
	r = sound_report(&w)
	testing.expectf(t, strings.contains(r, "music none; bed none"), "%v", r)
	os.remove_all(dir)
}

// A cue over the music holds it and gives it back (play_over, stop_over): a
// theme over a bed and back to the bed, a sting that ends by itself on the
// play clock, the hour changing the music under a cue, and a death's cue as
// the box opens, which a restore ends with the music. The music ducks under
// a conversation, and can come from somewhere (music_from). `!sound` says it.
@(test)
a_cue_over_the_music_gives_it_back :: proc(t: ^testing.T) {
	rl.SetTraceLogLevel(.ERROR)
	dir := stream_dir("over")
	song := stream_test_loop(3 * QOA_FRAME_LEN, 2)
	defer delete(song)
	for name in ([]string{"bed", "theme", "other"}) {
		testing.expect(t, export_audio(song, fmt.tprintf("%v/%v.qoa", dir, name), 2, SAMPLE_RATE, loop = true))
	}
	testing.expect(t, export_audio(song[:QOA_FRAME_LEN * 2], fmt.tprintf("%v/sting.qoa", dir), 2, SAMPLE_RATE))
	a: Assets
	defer assets_destroy(&a)
	testing.expect_value(t, assets_load_folder(&a, dir), 4)
	w: World
	defer destroy_world(&w)
	w.assets = &a
	append(&w.scenes, Scene{name = "bar"}, Scene{name = "quay"}, Scene{name = "deck"})
	said :: proc(w: ^World) -> string {return sound_report(w)}

	// A theme over the bed, and back to the bed.
	play_music(&w, "bed", loop = true, volume = 0.3, duck = 0.5)
	play_over(&w, "theme", loop = true, volume = 0.6)
	testing.expect_value(t, music_heard(&w), "theme")
	testing.expect_value(t, w.music_name, "bed")
	r := said(&w)
	testing.expectf(t, strings.contains(r, "music theme at 0.60 over bed; bed none"), "%v", r)
	update_audio(&w)
	testing.expect_value(t, music_heard(&w), "theme") // a looping cue goes on
	stop_over(&w, "sting") // not the one up: nothing happens
	testing.expect_value(t, music_heard(&w), "theme")
	stop_over(&w, "theme")
	testing.expect_value(t, music_heard(&w), "bed")
	r = said(&w)
	testing.expectf(t, strings.contains(r, "music bed at 0.30; bed none"), "%v", r)

	// A sting is over when it has played, by the play clock, and the bed
	// comes back.
	play_over(&w, "sting")
	testing.expectf(t, w.over_secs > 0.1 && w.over_secs < 0.13, "the sting (5120 frames) is %v s", w.over_secs)
	update_audio(&w)
	testing.expect_value(t, music_heard(&w), "sting")
	w.time += 1
	update_audio(&w)
	testing.expect_value(t, music_heard(&w), "bed")

	// The hour moves the music on under a cue, and leaves the cue alone.
	play_over(&w, "theme", loop = true)
	play_music(&w, "other", loop = true)
	testing.expect_value(t, music_heard(&w), "theme")
	testing.expect_value(t, w.music_name, "other")
	stop_music(&w)
	r = said(&w)
	testing.expectf(t, strings.contains(r, "music theme; bed none"), "%v", r)
	stop_over(&w)
	testing.expect_value(t, music_heard(&w), "")

	// Words duck it, down and back up again.
	play_music(&w, "bed", loop = true, volume = 0.4, duck = 0.5)
	c: Conversation
	begin_conversation(&w, &c, []Talk_Line{{text = "Listen."}})
	for _ in 0 ..< 30 do update_audio(&w)
	testing.expectf(t, abs(w.music.volume - 0.2) < 0.001, "ducked to %v", w.music.volume)
	end_conversation(&w)
	for _ in 0 ..< 30 do update_audio(&w)
	testing.expectf(t, abs(w.music.volume - 0.4) < 0.001, "back to %v", w.music.volume)

	// From somewhere: loud at it, quieter across the room and leaning to its
	// side, its other room's own, and faint everywhere else.
	music_from(&w, {{room = "bar", at = {500, 400}, near = 0.6, far = 0.4, reach = 500},
	                {room = "quay", at = {100, 500}, near = 0.4, far = 0.1, reach = 400}}, 0.05)
	near_enough :: proc(a, b: f32) -> bool {return abs(a - b) < 0.001}
	w.current, w.player.pos = 0, {500, 400}
	v, pan := music_level(&w)
	testing.expectf(t, near_enough(v, 0.6) && pan == 0, "at it: %v, %v", v, pan)
	w.player.pos = {1000, 400}
	v, pan = music_level(&w)
	testing.expectf(t, near_enough(v, 0.4) && near_enough(pan, -0.6), "across the room: %v, %v", v, pan)
	w.current, w.player.pos = 1, {300, 500}
	v, _ = music_level(&w)
	testing.expectf(t, near_enough(v, 0.25), "half way in the other: %v", v)
	w.current = 2
	v, _ = music_level(&w)
	testing.expectf(t, near_enough(v, 0.05), "elsewhere: %v", v)
	r = said(&w)
	testing.expectf(t, strings.contains(r, "music bed at 0.05;"), "%v", r)
	play_music(&w, "bed", loop = true)
	testing.expect_value(t, len(w.music_places), 0) // the places went with the music

	// A death's cue as the box opens, over the music; a restore ends both.
	w.current = 0
	die(&w, Death{reason = "Eaten.", music = "sting"})
	advance_death(&w, 0.1)
	testing.expect(t, w.death_box)
	testing.expect_value(t, music_heard(&w), "sting")
	testing.expect_value(t, w.music_name, "bed")
	s: Save
	defer save_destroy(&s)
	save_world(&w, &s, "")
	testing.expect(t, load_world(&w, save_text_of(&s)))
	testing.expect_value(t, music_heard(&w), "")
	testing.expect(t, w.music == nil && w.over == nil)
	os.remove_all(dir)
}

// What `just bake` writes loads: a looping or long sound becomes a .qoa that
// opens as a stream of its length, an effect a .wav that loads whole, each
// fresh, and the name's old file goes; the folder loader plays the newer of
// two, and the .qoa of two the same age.
@(test)
what_bake_writes_loads :: proc(t: ^testing.T) {
	rl.SetTraceLogLevel(.ERROR)
	dir := stream_dir("bake")
	bed := Audio{samples = stream_test_loop(22050 * 8, 1), channels = 1, rate = 22050}
	defer audio_destroy(&bed)
	click := Audio{samples = stream_test_loop(2205, 1), channels = 1, rate = 22050}
	defer audio_destroy(&click)

	bed_src := fmt.tprintf("%v/bed.sound", dir)
	click_src := fmt.tprintf("%v/click.sound", dir)
	testing.expect(t, os.write_entire_file(bed_src, transmute([]u8)string("sound bed\nlength 8\nloop\n")) == nil)
	testing.expect(t, os.write_entire_file(click_src, transmute([]u8)string("sound click\nlength 0.1\n")) == nil)
	// The bed's last bake, a .wav, from before there were streams.
	testing.expect(t, export_wav(bed.samples, fmt.tprintf("%v/bed.wav", dir), 1, 22050))
	testing.expect_value(t, len(bake_problems(dir)), 2) // the bed not a .qoa, the click not at all

	bed_out := bake_target(bed_src, audio_seconds(bed), loop = true)
	click_out := bake_target(click_src, audio_seconds(click), loop = false)
	testing.expect(t, strings.has_suffix(bed_out, "/bed.qoa"))
	testing.expect(t, strings.has_suffix(click_out, "/click.wav"))
	testing.expect_value(t, bake_target(click_src, 7, loop = false), fmt.tprintf("%v/click.qoa", dir)) // long: streamed
	testing.expect(t, !bake_fresh(bed_src, bed_out))
	testing.expect(t, bake_write(bed, bed_out, loop = true))
	testing.expect(t, bake_write(click, click_out, loop = false))
	testing.expect(t, !os.exists(fmt.tprintf("%v/bed.wav", dir))) // the stale one, gone
	testing.expect(t, bake_fresh(bed_src, bed_out))
	testing.expect(t, bake_fresh(click_src, click_out))
	problems := bake_problems(dir)
	testing.expectf(t, len(problems) == 0, "%v", problems)

	secs, known := audio_file_seconds(bed_out)
	testing.expect(t, known && abs(secs - 8) < 0.001)
	secs, known = audio_file_seconds(click_out)
	testing.expect(t, known && abs(secs - 0.1) < 0.001)

	a: Assets
	defer assets_destroy(&a)
	testing.expect_value(t, assets_load_folder(&a, dir), 2)
	path, has := assets_audio_path(&a, "bed")
	testing.expect(t, has && strings.has_suffix(path, ".qoa"))
	l := assets_loop(&a, "bed")
	testing.expect(t, loop_open(l))
	if l != nil do testing.expect_value(t, int(l.music.frameCount), 22050 * 8)
	testing.expect(t, "click" in a.sounds) // short: loaded whole with the folder
	testing.expect(t, !("bed" in a.sounds))

	// Two files of a name: the newer plays; of two the same age, the .qoa.
	assets_note_audio(&a, "bed", "x/bed.wav", 2, max(i64))
	path, _ = assets_audio_path(&a, "bed")
	testing.expect_value(t, path, "x/bed.wav")
	assets_note_audio(&a, "bed", "x/bed.qoa", 0, max(i64))
	path, _ = assets_audio_path(&a, "bed")
	testing.expect_value(t, path, "x/bed.qoa")
	assets_note_audio(&a, "bed", "y/bed.wav", 2, max(i64))
	path, _ = assets_audio_path(&a, "bed")
	testing.expect_value(t, path, "x/bed.qoa")
	os.remove_all(dir)
}
