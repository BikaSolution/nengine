package nengine

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import rl "vendor:raylib"

// Sound. All of it is optional: leave a field empty and it's silent.
//
//   Scene.ambience    background loop for the scene. Switches when the scene
//                     does, and keeps playing if the next scene uses the same one.
//   Object.loop       a looping sound coming from the object. Louder the closer
//                     the player is, and panned towards whichever side it's on.
//   Object.tick       a short sound played whenever the object's animation
//                     reaches one of its tick_frames: a flicker, a drip, a tick.
//   Actor.step        a footstep, played as each foot lands (walk frames 0 and 2).
//   World.key_sound   a click for each key typed at the prompt.
//   play()            anything else, from game code: a door creaking open.
//
// Sounds can come from files (assets_sound, assets_loop), or be built from raw
// samples (sound_from_samples, loop_from_samples). Samples are for
// placeholders; a real game plays what `just bake` makes of its .song and
// .sound files: a .qoa for music and long beds, a .wav for short effects
// (Baking, below).
//
// What it costs: raylib keeps every rl.Sound in memory whole, as 32-bit float
// stereo at the device's rate, whatever the file was: a minute of music is
// 20 MB that way, a twelve-second bed 4 MB. So anything long is a Loop —
// music (play_music, Menu.music), a bed (play_bed), a room's ambience, an
// object's hum — and streams from its file a buffer at a time, at the cost
// of rl.UpdateMusicStream every frame (update_audio, update_menu). Only short
// files become Sounds when the folder loads (asset_file.odin); a long one
// becomes one only if something plays it as a sound.

// The synth's rate, -1..1: a song renders stereo (interleaved, left then
// right) at this. A .sound renders mono at its own rate (SOUND_RATE unless
// it says). See master.odin's Audio.
SAMPLE_RATE :: 44100

// A looping sound. raylib streams these as music: from a .qoa, .ogg or .wav,
// whichever the folder has (asset_file.odin), a buffer at a time.
Loop :: struct {
	music:  rl.Music,
	wav:    []u8, // made from samples: the WAV file in memory it streams from
	volume: f32,  // as last set (loop_volume), which raylib cannot be asked
}

load_loop :: proc(path: cstring) -> Loop {
	l := Loop{music = rl.LoadMusicStream(path), volume = 1}
	l.music.looping = true
	return l
}

loop_from_samples :: proc(samples: []f32, channels := 1, rate := SAMPLE_RATE) -> Loop {
	wav := wav_file(samples, channels, rate)
	l := Loop{music = rl.LoadMusicStreamFromMemory(".wav", raw_data(wav), i32(len(wav))), wav = wav, volume = 1}
	l.music.looping = true
	return l
}

// How loud a loop plays, kept on it as well as given to raylib.
loop_volume :: proc(l: ^Loop, volume: f32) {
	l.volume = volume
	rl.SetMusicVolume(l.music, volume)
}

// Whether a loop has a file open to stream from. Without an audio device
// it has one and nothing to play it into (rl.IsMusicValid would say no), and
// is kept anyway: the rules about what plays where hold either way.
loop_open :: proc(l: ^Loop) -> bool {
	return l != nil && l.music.ctxData != nil
}

unload_loop :: proc(l: ^Loop) {
	rl.UnloadMusicStream(l.music)
	delete(l.wav)
	l^ = {}
}

sound_from_samples :: proc(samples: []f32, channels := 1, rate := SAMPLE_RATE) -> rl.Sound {
	pcm := to_pcm16(samples)
	defer delete(pcm)
	ch := max(channels, 1)
	wave := rl.Wave {
		frameCount = u32(len(pcm) / ch),
		sampleRate = u32(rate),
		sampleSize = 16,
		channels   = u32(ch),
		data       = raw_data(pcm),
	}
	return rl.LoadSoundFromWave(wave) // copies the samples
}

// Write samples to a .wav file, to listen to outside the game. Stereo
// samples are interleaved, left then right.
export_wav :: proc(samples: []f32, path: string, channels := 1, rate := SAMPLE_RATE) -> bool {
	wav := wav_file(samples, channels, rate)
	defer delete(wav)
	return os.write_entire_file(path, wav) == nil
}

// Play a sound once. pan: -1 left, 0 centre, 1 right.
play :: proc(s: rl.Sound, volume: f32 = 1, pan: f32 = 0) {
	rl.SetSoundVolume(s, volume)
	rl.SetSoundPan(s, pan)
	rl.PlaySound(s)
}

@(private)
update_audio :: proc(w: ^World) {
	scene := current_scene(w)

	if !w.audio_started || w.audio_scene != w.current {
		old: ^Scene = &w.scenes[w.audio_scene] if w.audio_started else nil
		switch_scene_audio(old, scene)
		w.audio_scene = w.current
		w.audio_started = true
		w.audio_loop = scene.ambience
	}
	// The same room, a different sound: the hour changed it (`ambience when=`).
	if scene.ambience != w.audio_loop {
		if w.audio_loop != nil do rl.StopMusicStream(w.audio_loop.music)
		if scene.ambience != nil do rl.PlayMusicStream(scene.ambience.music)
		w.audio_loop = scene.ambience
	}

	// The room's ambience at full: an object somewhere else may have left
	// the shared stream quieter (several rooms play one loop). An object
	// here whose loop *is* the ambience is the ambience, and is not placed.
	if scene.ambience != nil {
		loop_volume(scene.ambience, 1)
		rl.SetMusicPan(scene.ambience.music, 0)
		rl.UpdateMusicStream(scene.ambience.music)
	}
	if w.music != nil {
		rl.UpdateMusicStream(w.music.music)
		if !w.music.music.looping && !rl.IsMusicStreamPlaying(w.music.music) {
			w.music = nil
			delete(w.music_name)
			w.music_name = ""
		}
	}
	if loop_open(&w.bed) {
		// A room whose ambience is the bed's sound plays it nearer: the bed
		// goes quiet there rather than doubling it.
		loop_volume(&w.bed, 0 if scene.ambience_name == w.bed_name else w.bed_volume)
		rl.UpdateMusicStream(w.bed.music)
	}

	for &o in scene.objects {
		volume, pan := placement(w, o.pos)
		if o.hidden do volume = 0 // not here at this hour: neither is its sound
		if o.loop != nil && o.loop != scene.ambience {
			loop_volume(o.loop, volume)
			rl.SetMusicPan(o.loop.music, pan)
			rl.UpdateMusicStream(o.loop.music)
		}
		if o.fps > 0 && o.tick_frames != {} {
			frame := i32(w.time * o.fps) % max(o.sprite.frames, 1)
			if frame != o.last_frame && int(frame) in o.tick_frames do play(o.tick, volume, pan)
			o.last_frame = frame
		}
	}

	// Footsteps: the walk cycle's feet land on frames 0 and 2.
	p := &w.player
	step := i32(-1)
	if p.walking do step = i32(p.anim_time * p.walk_fps) % max(p.walk.frames, 1)
	// The floor's own footstep, where it has one: boards, tiles, a deck.
	footstep := scene.step if scene.step.frameCount > 0 else p.step
	if step != p.last_step && (step == 0 || step == 2) do play(footstep, 0.6)
	p.last_step = step
}

@(private)
stop_scene_audio :: proc(s: ^Scene) {
	if s.ambience != nil do rl.StopMusicStream(s.ambience.music)
	for o in s.objects {
		if o.loop != nil do rl.StopMusicStream(o.loop.music)
	}
}

// Stop the old scene's sounds and start the new one's.
@(private)
switch_scene_audio :: proc(old, new: ^Scene) {
	if old != nil {
		if old.ambience != nil && old.ambience != new.ambience do rl.StopMusicStream(old.ambience.music)
		for o in old.objects {
			if o.loop != nil do rl.StopMusicStream(o.loop.music)
		}
	}
	if new.ambience != nil && (old == nil || old.ambience != new.ambience) {
		rl.PlayMusicStream(new.ambience.music)
	}
	for o in new.objects {
		if o.loop != nil do rl.PlayMusicStream(o.loop.music)
	}
}

// How loud, and how far left or right, something at pos sounds to the player.
@(private)
placement :: proc(w: ^World, pos: [2]f32) -> (volume, pan: f32) {
	d := pos - w.player.pos
	volume = clamp(1.3 - length(d) / 160, 0.15, 1)
	pan = clamp(d.x / 160, -0.8, 0.8)
	return
}

@(private)
to_pcm16 :: proc(samples: []f32) -> []i16 {
	pcm := make([]i16, len(samples))
	for s, i in samples do pcm[i] = i16(clamp(s, -1, 1) * 32767)
	return pcm
}

// A complete .wav file: a 44 byte header, then the samples as 16 bit, mono
// or interleaved stereo.
@(private)
wav_file :: proc(samples: []f32, channels := 1, rate := SAMPLE_RATE) -> []u8 {
	pcm := to_pcm16(samples)
	defer delete(pcm)
	data := slice.to_bytes(pcm)
	ch := u32(max(channels, 1))

	b := make([]u8, 44 + len(data))
	copy(b[0:], "RIFF")
	endian.put_u32(b[4:], .Little, u32(36 + len(data)))
	copy(b[8:], "WAVEfmt ")
	endian.put_u32(b[16:], .Little, 16)              // size of the format block
	endian.put_u16(b[20:], .Little, 1)               // plain PCM
	endian.put_u16(b[22:], .Little, u16(ch))              // channels
	endian.put_u32(b[24:], .Little, u32(rate))
	endian.put_u32(b[28:], .Little, u32(rate) * 2 * ch) // bytes per second
	endian.put_u16(b[32:], .Little, u16(2 * ch))          // bytes per frame
	endian.put_u16(b[34:], .Little, 16)              // bits per sample
	copy(b[36:], "data")
	endian.put_u32(b[40:], .Little, u32(len(data)))
	copy(b[44:], data)
	return b
}

// A sound of the game's, by name: `play_sound(w, "rifle_shot")`. Silent if
// there is no such sound, or no assets — a missing sound is not an error.
play_sound :: proc(w: ^World, name: string, volume: f32 = 1, pan: f32 = 0) {
	if name == "" do return
	s: rl.Sound
	if w.assets != nil do s = assets_sound(w.assets, name)
	hear(w, name if s.frameCount > 0 else fmt.tprintf("%v (silent: no such sound)", name), volume)
	if s.frameCount > 0 do play(s, volume, pan)
}

// What play_sound was asked for, for `!sound`. The last HEARD_KEPT only.
HEARD_KEPT :: 32

// One sound heard, and how many times running: a beat that writes six lines
// is one pen, six times, and says so once.
Heard :: struct {
	name:  string,
	times: int,
}

@(private)
hear :: proc(w: ^World, name: string, volume: f32) {
	said := fmt.tprintf("%v", name) if volume == 1 else fmt.tprintf("%v at %.2f", name, volume)
	if n := len(w.heard); n > 0 && w.heard[n - 1].name == said {
		w.heard[n - 1].times += 1
		return
	}
	if len(w.heard) >= HEARD_KEPT {
		delete(w.heard[0].name)
		ordered_remove(&w.heard, 0)
	}
	append(&w.heard, Heard{strings.clone(said), 1})
}

@(private)
forget_heard :: proc(w: ^World) {
	for h in w.heard do delete(h.name)
	clear(&w.heard)
}

// Music over the room, by name: what `just bake` made of a .song, streamed
// from its file. `loop` false plays it once and lets it go (a cue); true keeps
// it going (a bed) until stop_music or another play_music. The room's
// ambience carries on under it.
play_music :: proc(w: ^World, name: string, loop := false, volume: f32 = 1) {
	stop_music(w)
	if w.assets == nil do return
	m := assets_loop(w.assets, name)
	if m == nil do return
	m.music.looping = loop
	loop_volume(m, volume)
	// From the top. raylib's seek writes to the stream's buffer, which a
	// stream opened with no audio device does not have.
	if m.music.stream.buffer != nil do rl.SeekMusicStream(m.music, 0)
	rl.PlayMusicStream(m.music)
	w.music = m
	w.music_name = strings.clone(name)
}

stop_music :: proc(w: ^World) {
	if w.music != nil do rl.StopMusicStream(w.music.music)
	w.music = nil
	delete(w.music_name)
	w.music_name = ""
}

// A bed: one sound under every room, wherever she goes, that the game keeps
// from its clock — an aeroplane coming in over the plain, a storm getting up.
// Not the room's (`ambience`, which changes at the door), and not music (a
// cue stops music; a bed carries on under it). Calling it again with the
// same name only changes how loud, so `on_clock` can build it a tick at a
// time without starting it over. It streams on its own, so a room whose
// ambience is the same sound neither stops it nor sets its volume; in that
// room the bed is quiet, since the room plays it nearer.
//
//     if m >= 30*60 + 5 do ne.play_bed(w, "engine_idle", f32(m - 30*60) / 10)
//     else do ne.stop_bed(w)
//
// A new game stops it; a restore leaves it to `on_clock`, which runs after.
play_bed :: proc(w: ^World, name: string, volume: f32 = 1) {
	if name == "" {
		stop_bed(w)
		return
	}
	if name != w.bed_name {
		stop_bed(w)
		w.bed_name = strings.clone(name)
		if w.assets != nil {
			if path, has := assets_audio_path(w.assets, name); has {
				w.bed = load_loop(strings.clone_to_cstring(path, context.temp_allocator))
				rl.PlayMusicStream(w.bed.music)
			}
		}
	}
	w.bed_volume = volume // update_audio sets it on the stream, room by room
}

stop_bed :: proc(w: ^World) {
	if loop_open(&w.bed) {
		rl.StopMusicStream(w.bed.music)
		unload_loop(&w.bed)
	}
	w.bed = {}
	delete(w.bed_name)
	w.bed_name = ""
	w.bed_volume = 0
}

// What she can hear, as a line, for the harness's `!sound`: the room's
// ambience, the loops of what is here, the music, the bed, and every sound
// played since the last time this was asked. Asking forgets the played.
sound_report :: proc(w: ^World) -> string {
	b := strings.builder_make(context.temp_allocator)
	ambience := "none"
	loops := make([dynamic]string, context.temp_allocator)
	if len(w.scenes) > 0 {
		sc := current_scene(w)
		if sc.ambience_name != "" do ambience = sc.ambience_name
		for o in sc.objects do if !o.hidden && o.loop_name != "" do append(&loops, o.loop_name)
	}
	fmt.sbprintf(&b, "ambience %v; loops %v; music %v; bed ", ambience,
		strings.join(loops[:], ", ", context.temp_allocator) if len(loops) > 0 else "none",
		w.music_name if w.music_name != "" else "none")
	if w.bed_name != "" do fmt.sbprintf(&b, "%v at %.2f", w.bed_name, w.bed_volume)
	else do strings.write_string(&b, "none")
	strings.write_string(&b, "; played ")
	if len(w.heard) == 0 do strings.write_string(&b, "nothing")
	for h, i in w.heard {
		if i > 0 do strings.write_string(&b, ", ")
		strings.write_string(&b, h.name)
		if h.times > 1 do fmt.sbprintf(&b, " x%v", h.times)
	}
	forget_heard(w)
	return strings.to_string(b)
}

// --- Baking ---
//
// The game never renders: `just bake` turns every .song and .sound into the
// file the game plays, beside its source (nsound's `song bake` and `sound
// bake`, which are bake_target, bake_fresh and bake_write):
//
//   a song, a looping sound, or one longer than LONG_SOUND_SECS    .qoa
//   any other sound: a short effect                                .wav
//
// QOA (qoa.odin) because raylib streams it natively, it is a fifth the size
// of the .wav, and it is sample-exact where a loop goes round: no padding,
// no encoder delay (an .ogg or .mp3 has to be trusted on both), and the
// predictor primed from the end of the loop. Short effects stay .wav: they
// are loaded whole as Sounds, they are small, and they cost the ear nothing.
//
// A bake removes the name's other baked files, so the folder never holds a
// stale one beside a fresh one; if it does (an editor's export), the newer is
// played (asset_file.odin).

LONG_SOUND_SECS :: 6

// The files a sound of a name can be played from, best first.
AUDIO_EXTENSIONS := [?]string{".qoa", ".ogg", ".wav"}

// Which of AUDIO_EXTENSIONS a file is, or -1.
audio_extension :: proc(file_name: string) -> int {
	for ext, i in AUDIO_EXTENSIONS do if strings.has_suffix(file_name, ext) do return i
	return -1
}

bake_extension :: proc(seconds: f32, loop: bool) -> string {
	return ".qoa" if loop || seconds > LONG_SOUND_SECS else ".wav"
}

// The file `source` (a .song or .sound) bakes to: beside it, its extension
// as bake_extension says.
bake_target :: proc(source: string, seconds: f32, loop: bool, allocator := context.temp_allocator) -> string {
	base := source[:len(source) - len(asset_extension(source))]
	return strings.concatenate({base, bake_extension(seconds, loop)}, allocator)
}

// Whether `target` is baked and up to date: there, no older than its
// source, and the only baked file of its name.
bake_fresh :: proc(source, target: string) -> bool {
	src := file_mtime(source)
	got := file_mtime(target)
	if got == 0 || got < src do return false
	base := target[:len(target) - len(asset_extension(target))]
	for ext in AUDIO_EXTENSIONS {
		other := strings.concatenate({base, ext}, context.temp_allocator)
		if other != target && os.exists(other) do return false
	}
	return true
}

// Writes `a` to `target` (from bake_target) and removes the name's other
// baked files. `loop`: it goes round (qoa_encode primes its seam).
bake_write :: proc(a: Audio, target: string, loop: bool) -> bool {
	if !export_audio(a.samples, target, a.channels, a.rate if a.rate > 0 else SAMPLE_RATE, loop) do return false
	base := target[:len(target) - len(asset_extension(target))]
	for ext in AUDIO_EXTENSIONS {
		other := strings.concatenate({base, ext}, context.temp_allocator)
		if other != target && os.exists(other) do os.remove(other)
	}
	return true
}

// Every .song and .sound under `dir` not baked as `just bake` bakes it — no
// file of the right kind beside it, another baked file of its name too, or
// one that does not open (a .qoa as a stream, a .wav whole) — one line each,
// for a test. Freshness is `just bake`'s and measure_sounds' business: a
// source being edited is not a broken build.
bake_problems :: proc(dir: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	bake_problems_in(dir, &out)
	return out[:]
}

@(private = "file")
bake_problems_in :: proc(dir: string, out: ^[dynamic]string) {
	files, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil do return
	for f in files {
		path := fmt.tprintf("%v/%v", dir, f.name)
		if f.type == .Directory {
			bake_problems_in(path, out)
			continue
		}
		seconds: f32
		loop: bool
		switch {
		case strings.has_suffix(f.name, ".song"):
			s, ok := load_song(path)
			if !ok {
				append(out, fmt.aprintf("%v: does not read", path, allocator = out.allocator))
				continue
			}
			seconds, loop = song_seconds(&s), s.loop
			song_destroy(&s)
		case strings.has_suffix(f.name, ".sound"):
			s, ok := load_sound(path)
			if !ok {
				append(out, fmt.aprintf("%v: does not read", path, allocator = out.allocator))
				continue
			}
			seconds, loop = s.length, s.loop
			sound_destroy(&s)
		case:
			continue
		}
		target := bake_target(path, seconds, loop)
		if !os.exists(target) {
			append(out, fmt.aprintf("%v: not baked, no %v (just bake)", path, target, allocator = out.allocator))
			continue
		}
		base := target[:len(target) - len(asset_extension(target))]
		for ext in AUDIO_EXTENSIONS {
			other := strings.concatenate({base, ext}, context.temp_allocator)
			if other != target && os.exists(other) {
				append(out, fmt.aprintf("%v: %v beside %v (just bake)", path, other, target, allocator = out.allocator))
			}
		}
		c := strings.clone_to_cstring(target, context.temp_allocator)
		if strings.has_suffix(target, ".qoa") {
			m := rl.LoadMusicStream(c)
			frames := m.frameCount
			rl.UnloadMusicStream(m)
			secs, known := audio_file_seconds(target)
			if frames == 0 || !known || secs <= 0 {
				append(out, fmt.aprintf("%v: does not open as a stream", target, allocator = out.allocator))
			}
		} else {
			w := rl.LoadWave(c)
			if w.frameCount == 0 do append(out, fmt.aprintf("%v: does not load", target, allocator = out.allocator))
			rl.UnloadWave(w)
		}
	}
}

// Writes samples to `path` as its extension says: .qoa (with `loop`, primed
// to go round: qoa.odin) or .wav. Stereo is interleaved, left then right.
export_audio :: proc(samples: []f32, path: string, channels := 1, rate := SAMPLE_RATE, loop := false) -> bool {
	if !strings.has_suffix(path, ".qoa") do return export_wav(samples, path, channels, rate)
	pcm := to_pcm16(samples)
	defer delete(pcm)
	file := qoa_encode(pcm, max(channels, 1), rate, loop)
	defer delete(file)
	return file != nil && os.write_entire_file(path, file) == nil
}

// How long a .qoa or .wav plays, from its header alone; false for anything
// else, or a file it cannot read.
audio_file_seconds :: proc(path: string) -> (seconds: f32, ok: bool) {
	f, err := os.open(path)
	if err != nil do return
	defer os.close(f)
	buf: [512]u8
	n, _ := os.read(f, buf[:])
	b := buf[:max(n, 0)]
	switch {
	case strings.has_suffix(path, ".qoa"):
		if len(b) < 16 do return
		head, _ := endian.get_u64(b, .Big)
		frame, _ := endian.get_u64(b[8:], .Big)
		rate := frame >> 32 & 0xffffff
		if head >> 32 != QOA_MAGIC || rate == 0 do return
		return f32(head & 0xffffffff) / f32(rate), true
	case strings.has_suffix(path, ".wav"):
		// Chunks after the RIFF header: "fmt " has the bytes a second,
		// "data" the size.
		if len(b) < 12 || string(b[0:4]) != "RIFF" || string(b[8:12]) != "WAVE" do return
		per_second: u32
		for p := 12; p + 8 <= len(b); {
			size, _ := endian.get_u32(b[p + 4:], .Little)
			switch string(b[p:p + 4]) {
			case "fmt ":
				if p + 20 <= len(b) do per_second, _ = endian.get_u32(b[p + 16:], .Little)
			case "data":
				if per_second == 0 do return
				return f32(size) / f32(per_second), true
			}
			p += 8 + int(size) + int(size & 1)
		}
	}
	return
}

// ".wav" of "x/y.wav"; "" for no extension.
@(private)
asset_extension :: proc(path: string) -> string {
	dot := strings.last_index_byte(path, '.')
	if dot <= strings.last_index_byte(path, '/') + 1 do return ""
	return path[dot:]
}

// When a file was last written, in unix nanoseconds; 0 if it is not there.
@(private)
file_mtime :: proc(path: string) -> i64 {
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil do return 0
	return time.to_unix_nanoseconds(fi.modification_time)
}
