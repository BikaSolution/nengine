package main

import ne "../../"
import ac "../assetcache"
import ui "../ui"
import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

// What the browser shows about a song or a sound before you open it.
//
// You cannot hear a filename, and the old picker offered nothing but
// filenames, so choosing between four songs meant opening all four. This
// draws the notes, and for a sound effect it draws the waveform and will play
// it: the file names itself out loud, which beats any label.

Browse_Preview :: struct {
	path:   string,
	kind:   int,
	ok:     bool,

	song:   ne.Song,
	insts:  ne.Instrument_Set,

	effect: ac.Sound_Preview, // a .sound: its waveform and a play button (assetcache/sound.odin)
}

browse_preview_close :: proc(p: ^Browse_Preview) {
	ac.sound_preview_close(&p.effect)
	if p.ok && !strings.has_suffix(p.path, ".sound") do ne.song_destroy(&p.song)
	ne.instrument_set_destroy(&p.insts)
	delete(p.path)
	p^ = {}
}

@(private = "file")
browse_preview_load :: proc(p: ^Browse_Preview, path: string, kind: int) {
	if p.path == path do return
	browse_preview_close(p)
	p.path = strings.clone(path)
	p.kind = kind

	if strings.has_suffix(path, ".sound") {
		ac.sound_preview_load(&p.effect, path)
		p.ok = p.effect.ok
		return
	}

	ne.instruments_load(&p.insts, instruments_root(path))
	s, ok := ne.load_song(path, &p.insts)
	if !ok do return
	p.song = s
	p.ok = true
}

// --- What the browser calls ---

audio_detail :: proc(ctx: rawptr, path: string, kind: int) -> string {
	if strings.has_suffix(path, ".sound") {
		s, ok := ne.load_sound(path)
		if !ok do return "unreadable"
		defer ne.sound_destroy(&s)
		return fmt.aprintf("%.2fs  %v layers", s.length, len(s.layers))
	}
	insts: ne.Instrument_Set
	defer ne.instrument_set_destroy(&insts)
	ne.instruments_load(&insts, instruments_root(path))
	s, ok := ne.load_song(path, &insts)
	if !ok do return "unreadable"
	defer ne.song_destroy(&s)
	notes := 0
	for &t in s.tracks do notes += len(t.notes)
	return fmt.aprintf("%v bars  %v voices  %v notes", s.bars, len(s.tracks), notes)
}

audio_preview :: proc(ctx: rawptr, path: string, kind: int, area: rl.Rectangle) -> bool {
	app := cast(^App)ctx
	browse_preview_load(&app.preview, path, kind)
	p := &app.preview
	if !p.ok {
		ui.label(i32(area.x), i32(area.y), "could not read it", ui.DIM, ui.SMALL)
		return true
	}
	if strings.has_suffix(path, ".sound") do return draw_sound(p, area)
	return draw_song(p, area)
}

// A piano roll of the whole song at a glance: time across, pitch up, one
// colour per voice. What you are looking for is shape — where it's busy,
// where it stops, whether a voice is silent all the way through.
@(private = "file")
draw_song :: proc(p: ^Browse_Preview, area: rl.Rectangle) -> bool {
	s := &p.song
	roll := rl.Rectangle{area.x, area.y, area.width, min(area.height * 0.46, 200)}
	rl.DrawRectangleRec(roll, {20, 20, 26, 255})
	rl.DrawRectangleLinesEx(roll, 1, ui.EDGE)

	total := f32(ne.song_total_ticks(s))
	// The roll is drawn in sounding semitones, so two voices written in
	// different keys still line up against each other.
	lo, hi := 127, 0
	for &t in s.tracks {
		for n in t.notes {
			m := ne.pitch_midi(n.pitch)
			lo = min(lo, m)
			hi = max(hi, m)
		}
	}
	if hi < lo do lo, hi = 48, 72 // an empty song still gets a sensible frame
	if hi - lo < 12 {
		mid := (lo + hi) / 2
		lo, hi = mid - 6, mid + 6
	}

	// Bar lines, so the length means something.
	if s.bars > 0 {
		for b in 1 ..< s.bars {
			x := roll.x + roll.width * f32(b) / f32(s.bars)
			rl.DrawLine(i32(x), i32(roll.y), i32(x), i32(roll.y + roll.height), {44, 44, 54, 255})
		}
	}

	if total > 0 {
		for &t, i in s.tracks {
			col := voice_color(i)
			if t.mute do col = rl.Color{70, 70, 80, 255}
			for n in t.notes {
				x := roll.x + roll.width * f32(n.tick) / total
				w := max(roll.width * f32(n.len) / total, 2)
				y := roll.y + roll.height * (1 - f32(ne.pitch_midi(n.pitch) - lo) / f32(hi - lo))
				y = clamp(y, roll.y + 1, roll.y + roll.height - 3)
				rl.DrawRectangleRec({x, y, min(w, roll.x + roll.width - x), 2.5}, col)
			}
		}
	} else {
		ui.label(i32(roll.x) + 10, i32(roll.y) + 10, "no notes yet", {96, 96, 112, 255}, ui.SMALL)
	}

	y := i32(roll.y + roll.height) + 12
	ui.label(i32(area.x), y, fmt.tprintf("%v bpm   %v/%v   %v bars", int(s.tempo), s.beats, s.beat_unit, s.bars), ui.INK, ui.SMALL)
	y += 20
	if s.loop do ui.label(i32(area.x), y, "loops", ui.DIM, ui.SMALL)
	else do ui.label(i32(area.x), y, "plays once", ui.DIM, ui.SMALL)
	y += 24

	// The voices, each with its instrument and how much it actually plays.
	ui.hline(i32(area.x), y - 6, i32(area.width))
	for &t, i in s.tracks {
		if f32(y) > area.y + area.height - 18 {
			ui.label(i32(area.x), y, fmt.tprintf("... and %v more", len(s.tracks) - i), {96, 96, 112, 255}, ui.SMALL)
			break
		}
		rl.DrawRectangleRec({area.x, f32(y) + 4, 8, 8}, voice_color(i))
		name := ui.ellipsize(t.name, area.width * 0.42, ui.SMALL)
		ui.label(i32(area.x) + 14, y, name, ui.INK if !t.mute else ui.DIM, ui.SMALL)
		inst := ui.ellipsize(t.inst, area.width * 0.3, ui.SMALL)
		ui.label(i32(area.x + area.width * 0.52), y, inst, {150, 172, 196, 255}, ui.SMALL)
		n := fmt.tprintf("%v", len(t.notes))
		ui.label(i32(area.x + area.width) - ui.measure(n, ui.SMALL), y, n, ui.DIM, ui.SMALL)
		y += 19
	}
	return true
}

// One colour per voice, so the roll and the list below agree with each other.
voice_color :: proc(i: int) -> rl.Color {
	colors := [?]rl.Color {
		{120, 190, 255, 255},
		{240, 180, 110, 255},
		{150, 220, 140, 255},
		{230, 140, 190, 255},
		{200, 200, 120, 255},
		{170, 150, 240, 255},
		{120, 220, 210, 255},
		{240, 130, 120, 255},
	}
	return colors[i % len(colors)]
}

// The effect's waveform and a button that plays it: the same pane a question
// asking for a sound shows (assetcache/sound.odin).
@(private = "file")
draw_sound :: proc(p: ^Browse_Preview, area: rl.Rectangle) -> bool {
	return ac.sound_preview_draw(&p.effect, area)
}
