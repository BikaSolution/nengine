package assetcache

import ne "../../"
import ui "../ui"
import "core:fmt"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

// A sound effect, heard before it is chosen: its waveform, drawn from the
// samples it actually makes, and a button that plays it, because a sound is
// the one kind of file a picture can only half describe.
//
// nsound's browser shows a `.sound` with it, and a question asking for a
// sound (the cutscene editor's `sound` cue) lists the game's sounds with it:
//
//     ui.pick_open(&e.pick, "sound", "Choose a sound", ac.SOUND_KINDS[:], start,
//                  preview = ac.sound_preview, ctx = &e.pick_sound,
//                  accept = ac.sound_listed)
//     ...
//     ac.sound_preview_close(&e.pick_sound)   // when it has answered
//
// A game plays what `just bake` renders each `.sound` to (a `.wav` for an
// effect, a `.qoa` for a loop or a long one: nengine audio.odin, Baking), and
// a sound is known by the file's name either way, so a `.sound` and the file
// made from it are one sound and are listed once, as the `.sound`.

SOUND_KINDS := [?]ui.File_Kind {
	{suffix = ".sound", label = "sound", color = {120, 190, 255, 255}},
	{suffix = ".wav", label = "wav", color = {150, 170, 200, 255}},
	{suffix = ".qoa", label = "qoa", color = {150, 190, 180, 255}},
}

// For a picker's `accept`: every .sound, and a .wav or .qoa only when there
// is no .sound it was made from.
sound_listed :: proc(ctx: rawptr, path: string) -> bool {
	if !strings.has_suffix(path, ".wav") && !strings.has_suffix(path, ".qoa") do return true
	return !os.exists(strings.concatenate({path[:len(path) - 4], ".sound"}, context.temp_allocator))
}

Sound_Preview :: struct {
	path:       string,
	ok:         bool,
	effect:     ne.Sound, // a .sound's layers; empty for a .wav
	has_effect: bool,
	wave:       []f32, // what it sounds like, for drawing and for playing
	length:     f32,
	sound:      rl.Sound,
	has_sound:  bool,
	baked:      bool, // a .sound with its .wav or .qoa beside it, which is what a game plays
}

sound_preview_close :: proc(p: ^Sound_Preview) {
	if p.has_sound do rl.UnloadSound(p.sound)
	delete(p.wave)
	if p.has_effect do ne.sound_destroy(&p.effect)
	delete(p.path)
	p^ = {}
}

// Loads `path` into the preview, unless it is already the one shown.
sound_preview_load :: proc(p: ^Sound_Preview, path: string) {
	if p.path == path do return
	sound_preview_close(p)
	p.path = strings.clone(path)

	if strings.has_suffix(path, ".wav") || strings.has_suffix(path, ".qoa") {
		w := rl.LoadWave(strings.clone_to_cstring(path, context.temp_allocator))
		if w.frameCount == 0 do return
		defer rl.UnloadWave(w)
		samples := rl.LoadWaveSamples(w)
		defer rl.UnloadWaveSamples(samples)
		ch := int(max(w.channels, 1))
		p.wave = make([]f32, int(w.frameCount))
		for i in 0 ..< int(w.frameCount) do p.wave[i] = samples[i * ch]
		p.length = f32(w.frameCount) / f32(max(w.sampleRate, 1))
		p.sound = rl.LoadSoundFromWave(w)
		p.has_sound = p.sound.frameCount > 0
		p.ok = true
		return
	}

	s, ok := ne.load_sound(path)
	if !ok do return
	p.effect = s
	p.has_effect = true
	p.length = s.length
	rendered := ne.render_sound(&p.effect)
	p.wave = rendered.samples // mono
	if len(p.wave) > 0 {
		p.sound = ne.sound_from_samples(p.wave, 1, rendered.rate)
		p.has_sound = true
	}
	base := path[:len(path) - len(".sound")]
	p.baked = os.exists(strings.concatenate({base, ".wav"}, context.temp_allocator)) ||
		os.exists(strings.concatenate({base, ".qoa"}, context.temp_allocator))
	p.ok = true
}

// As a picker's preview: `ctx` is the ^Sound_Preview.
sound_preview :: proc(ctx: rawptr, path: string, kind: int, area: rl.Rectangle) -> bool {
	p := cast(^Sound_Preview)ctx
	if p == nil do return false
	sound_preview_load(p, path)
	if !p.ok {
		ui.label(i32(area.x), i32(area.y), "could not read it", ui.DIM, ui.SMALL)
		return true
	}
	return sound_preview_draw(p, area, picking = true)
}

// The waveform, how long and how loud, a play button, and what it is made of.
// `picking` adds whether the game can play it yet.
sound_preview_draw :: proc(p: ^Sound_Preview, area: rl.Rectangle, picking := false) -> bool {
	box := rl.Rectangle{area.x, area.y, area.width, min(area.height * 0.32, 130)}
	rl.DrawRectangleRec(box, {20, 20, 26, 255})
	rl.DrawRectangleLinesEx(box, 1, ui.EDGE)
	mid := box.y + box.height / 2
	rl.DrawLine(i32(box.x), i32(mid), i32(box.x + box.width), i32(mid), {50, 50, 60, 255})

	// One vertical bar per column of pixels, from peak to peak: the shape of
	// the envelope, which is what tells a thud from a fizz.
	if len(p.wave) > 0 {
		cols := int(box.width)
		per := max(len(p.wave) / max(cols, 1), 1)
		for c in 0 ..< cols {
			from := c * per
			if from >= len(p.wave) do break
			to := min(from + per, len(p.wave))
			lo, hi := f32(0), f32(0)
			for v in p.wave[from:to] {
				lo = min(lo, v)
				hi = max(hi, v)
			}
			x := box.x + f32(c)
			y0 := mid - hi * (box.height / 2 - 2)
			y1 := mid - lo * (box.height / 2 - 2)
			rl.DrawLine(i32(x), i32(y0), i32(x), i32(y1), {120, 190, 255, 255})
		}
	}

	y := i32(box.y + box.height) + 12
	peak := f32(0)
	for v in p.wave do peak = max(peak, abs(v))
	ui.label(i32(area.x), y, fmt.tprintf("%.2f seconds   peak %.2f", p.length, peak), ui.INK, ui.SMALL)
	y += 22

	if p.has_sound {
		if ui.button({area.x, f32(y), 78, 24}, "play") || ui.key_pressed(.SPACE) {
			rl.PlaySound(p.sound)
		}
		ui.label(i32(area.x) + 88, y + 5, "or press space", {96, 96, 112, 255}, ui.SMALL)
		y += 34
	}

	if picking {
		note := "a recording: the game plays it as it is"
		if p.has_effect do note = "baked: the game plays what it was baked to" if p.baked else "not baked yet: `just bake` makes the file the game plays"
		for row in ui.text_rows(note, area.width) {
			ui.label(i32(area.x), y, note[row.start:row.end], {150, 172, 196, 255} if p.baked || !p.has_effect else {220, 150, 110, 255}, ui.SMALL)
			y += 17
		}
		y += 6
	}
	if !p.has_effect do return true

	ui.label(i32(area.x), y, fmt.tprintf("%v layers", len(p.effect.layers)), ui.DIM, ui.SMALL)
	y += 20
	for l, i in p.effect.layers {
		if f32(y) > area.y + area.height - 18 {
			ui.label(i32(area.x), y, fmt.tprintf("... and %v more", len(p.effect.layers) - i), {96, 96, 112, 255}, ui.SMALL)
			break
		}
		// Noise has no pitch, so it gets its length instead of a "0 Hz" that
		// looks like something went wrong.
		text := fmt.tprintf("%v  %.2fs", l.wave, l.dur)
		switch {
		case l.wave == .Noise:
		case l.to != 0: text = fmt.tprintf("%v  %.0f to %.0f Hz", l.wave, l.freq, l.to)
		case l.freq > 0: text = fmt.tprintf("%v  %.0f Hz", l.wave, l.freq)
		}
		ui.label(i32(area.x), y, ui.ellipsize(text, area.width, ui.SMALL), {150, 172, 196, 255}, ui.SMALL)
		y += 18
	}
	return true
}

// The file a sound called `name` comes from, for a question to start on: its
// .sound in sounds/ (or its .wav or .qoa, or a song's in music/), or one of that name
// anywhere in the assets. "" if there is none.
find_sound :: proc(asset_dir, name: string) -> string {
	if name == "" || name == "?" do return ""
	for try in ([]string{"sounds/%v.sound", "sounds/%v.wav", "sounds/%v.qoa", "music/%v.qoa", "music/%v.wav", "%v.sound", "%v.wav", "%v.qoa"}) {
		p := ui.path_join(asset_dir, fmt.tprintf(try, name))
		if os.is_file(p) do return p
	}
	search :: proc(dir, name: string, depth: int) -> string {
		if depth > 5 do return ""
		infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
		if err != nil do return ""
		for f in infos do if f.type != .Directory && (f.name == fmt.tprintf("%v.sound", name) || f.name == fmt.tprintf("%v.wav", name) || f.name == fmt.tprintf("%v.qoa", name)) do return ui.path_join(dir, f.name)
		for f in infos do if f.type == .Directory && !ui.skipped(f.name) {
			if p := search(ui.path_join(dir, f.name), name, depth + 1); p != "" do return p
		}
		return ""
	}
	return search(asset_dir, name, 0)
}
