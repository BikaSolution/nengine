// nsound: the nengine music studio.
//
// Songs and sound effects. A song is notes on a time line — 24 ticks to a
// quarter note — and it can be edited two ways, because they suit different
// jobs: a TRACKER GRID for drums and short looping beds, and a SHEET of music
// for writing a tune. Tab swaps between them. A .sound is a handful of layers
// of maths, for footsteps and hinges and cats, and has no editor yet: the CLI
// renders it and tells you what is in it.
//
//     nsound                                pick a song to open
//     nsound assets/music/house.song        open that one
//
// Or from the command line:
//
//     nsound song new assets/music/theme.song theme 96 8
//     nsound song import tune.mid assets/music/tune.song
//     nsound song render assets/music/theme.song out.wav
//     nsound sound info assets/sounds/door.sound
//
// `nsound help` lists the lot.
package main

import ne "../../"
import ui "../ui"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

main :: proc() {
	args := os.args[1:]
	if len(args) > 0 {
		switch args[0] {
		case "help", "-h", "--help":
			usage()
			return
		case "song":
			if !song_cmd(args[1:]) do os.exit(1)
			return
		case "sound":
			if !sound_cmd(args[1:]) do os.exit(1)
			return
		}
	}

	flags := ui.parse_flags(args)
	app := App{}

	for a in flags.rest {
		switch a {
		case "--play":  app.play = true
		case "--sheet": app.sheet = true
		case "--pick":  app.pick_inst = true
		case:
			// A file to open, or a folder to go looking in.
			switch ui.target_of(a) {
			case .Folder:  app.dir = strings.clone(a)
			case .Nothing: // nothing to do
			case .Missing:
				fmt.eprintfln("nsound: there is no %v", a)
				fmt.eprintfln("        make one with `nsound song new %v`, or run `nsound` and browse", a)
				os.exit(1)
			case .File:
				if strings.has_suffix(a, ".sound") {
					// Listed and previewed in the browser, but there is no
					// editor for one yet. Say which way to go instead.
					fmt.eprintfln("nsound: no editor for a .sound yet")
					fmt.eprintfln("        `nsound sound info %v` reads it, `sound render` hears it", a)
					os.exit(1)
				}
				if !strings.has_suffix(a, ".song") {
					fmt.eprintfln("nsound: %v is not a .song", a)
					os.exit(1)
				}
				app.path = strings.clone(a)
			}
		}
	}
	if app.path == "" do app.browsing = true

	app.find = flags.find
	ui.run({title = "nsound", size = flags.window, shot = flags.shot, frames = flags.frames, events = flags.events}, &app, frame, app_close)
}

usage :: proc() {
	fmt.println(`nsound - nengine's music studio

  nsound                             pick a song to open
  nsound <file.song>                 open that one
  nsound <file> --sheet              open in the sheet view rather than the grid
  nsound <file> --window 900x600 --shot out.png [--frames N] [--play] [--pick]

song
  song new <file> [name] [bpm] [bars]
  song info <file>                   tracks and notes
  song instruments <file>            every instrument you can name below
  song track <file> <name> <instrument> [volume]
  song set <file> <track> <cell> <note>       e.g. A2, C#5, . for a rest
  song fill <file> <track> <from> <every> <note>...  lay a phrase down repeatedly
  song tempo <file> <n>
  song import <file.mid> <out.song>  a MIDI file onto the sheet
  song render <file> <out.wav>       hear it without opening anything (or out.qoa)
  song bake <file> [--force]         the .qoa the game plays, beside it, if stale

sound
  sound info <file>                  its layers
  sound render <file> <out.wav>      hear it without opening anything (or out.qoa)
  sound bake <file> [--force]        the .wav (an effect) or .qoa (a loop, a long
                                     one) the game plays, beside it, if stale`)
}

// --- The window ---

App :: struct {
	path:      string,
	dir:       string, // where the browser starts, if a folder was named
	browsing:  bool,
	find:      string, // --find: what to put in the search box (borrowed from the command line)
	opened:    bool,
	play:      bool, // start playing straight away, to check the view follows
	sheet:     bool, // open in the sheet view
	pick_inst: bool, // open with the instrument picker up
	browser:   ui.Browser,
	preview:   Browse_Preview,
	song:      Song_Editor,
}

// Songs and sound effects are both listed. Only a song has an editor so far;
// a .sound is here so it can be found, heard and tidied, and the browser says
// as much rather than pretending to open one.
KINDS := [?]ui.File_Kind {
	{suffix = ".song", label = "song", color = {150, 220, 140, 255}, blank = song_blank, fields = SONG_FIELDS[:]},
	{suffix = ".sound", label = "sound", color = {120, 190, 255, 255}},
}

SONG_FIELDS := [?]ui.New_Field {
	{label = "bpm", value = 90, lo = 20, hi = 400},
	{label = "bars", value = 4, lo = 1, hi = 256},
}

frame :: proc(data: rawptr, status: ^ui.Status) -> bool {
	app := cast(^App)data

	if !app.browsing {
		if !app.opened do open_editor(app)
		if song_editor_step(&app.song, status) do return true
		back_to_browser(app)
		// The key or the click that left the editor has done its job. The
		// browser opens on this same frame rather than leaving one blank, and
		// must not see it too: an Esc that closed the editor would quit.
		ui.input_swallow()
	}

	if !app.browser.loaded {
		ui.browser_open(&app.browser, "Music", "nsound", KINDS[:], app.dir, audio_detail, audio_preview, app, app.find)
		ui.browser_select(&app.browser, app.path)
	}
	path, chosen, running := ui.browser_step(&app.browser, status)
	if chosen {
		if !strings.has_suffix(path, ".song") {
			// There is no editor for a sound effect yet. Say so; don't
			// open an empty window and let them work out why.
			ui.say(status, "no editor for %v yet - try: just sound sound info <file>", ui.base_name(path))
			return true
		}
		file := strings.clone(path, context.temp_allocator)
		ui.browser_close(&app.browser)
		browse_preview_close(&app.preview)
		app.browsing = false
		delete(app.path)
		app.path = strings.clone(file)
		open_editor(app)
	}
	if !running {
		ui.browser_close(&app.browser)
		browse_preview_close(&app.preview)
	}
	return running || chosen
}

// Esc in the editor goes back to the list rather than out of the program, so
// a second song is one keypress away instead of another `just sound`.
back_to_browser :: proc(app: ^App) {
	if app.opened {
		song_editor_close(&app.song)
		app.opened = false
	}
	ui.reset_dir(&app.dir, app.path)
	app.find = "" // a slice of the command line: dropped, never freed
	app.browsing = true
}

open_editor :: proc(app: ^App) {
	app.opened = true
	song_editor_open(&app.song, app.path)
	if app.sheet do song_editor_sheet(&app.song)
	if app.play do song_editor_play(&app.song)
	if app.pick_inst do song_editor_pick(&app.song)
}

// Called by ui.run on the way out, while the window is still open. It takes a
// rawptr for the same reason `frame` does: the host knows nothing about App.
app_close :: proc(data: rawptr) {
	app := cast(^App)data
	ui.browser_close(&app.browser)
	browse_preview_close(&app.preview)
	if app.opened do song_editor_close(&app.song)
	clipboard_destroy()
	delete(app.path)
	delete(app.dir)
}

song_blank :: proc(path, name: string, opts: []int) -> bool {
	bpm := f32(opts[0]) if len(opts) > 0 else 90
	bars := opts[1] if len(opts) > 1 else 4
	return song_file_new(path, name, bpm, bars)
}

// --- song ---

song_cmd :: proc(args: []string) -> bool {
	if len(args) < 2 do return ui.fail("song: need a command and a file")
	path := args[1]

	if args[0] == "new" {
		name := args[2] if len(args) > 2 else ui.base_name(path)
		bpm := f32(ui.num(args, 3, 90))
		bars := ui.num(args, 4, 4)
		if !song_file_new(path, name, bpm, bars) do return ui.fail("song new: could not write %v", path)
		fmt.printfln("%v: song %v  %v bpm  %v bars", path, name, bpm, bars)
		return true
	}

	insts: ne.Instrument_Set
	defer ne.instrument_set_destroy(&insts)
	ne.instruments_load(&insts, ui.assets_root(path))

	// Import reads a .mid rather than a .song, so it comes before the load.
	if args[0] == "import" {
		if len(args) < 3 do return ui.fail("song import: need a .mid and an output .song")
		imported: ne.Song
		defer ne.song_destroy(&imported)
		rep := ne.midi_import_file(path, &imported, &insts)
		if rep.problem != "" {
			defer delete(rep.problem)
			return ui.fail("song import: %v", rep.problem)
		}
		if !ne.save_song(&imported, args[2]) do return ui.fail("song import: could not write %v", args[2])
		fmt.printfln("wrote %v: %v notes on %v tracks, %v bpm, %v/%v, %v, %v bars",
			args[2], rep.notes, rep.tracks, imported.tempo, imported.beats, imported.beat_unit,
			ne.key_name(int(imported.key)), imported.bars)
		if rep.transposed > 0 {
			fmt.printfln("  %v notes moved by octaves to fit their instrument's range", rep.transposed)
		}
		for &t in imported.tracks do fmt.printfln("  %v  %v  %v notes", t.name, t.inst, len(t.notes))
		return true
	}

	s, ok := ne.load_song(path, &insts)
	if !ok do return ui.fail("song: could not read %v", path)
	defer ne.song_destroy(&s)

	switch args[0] {
	case "info":
		seconds := ne.song_seconds(&s)
		fmt.printfln("song %v  %v bpm  %v/%v  %v  %v bars  (%.1fs)%v",
			s.name, s.tempo, s.beats, s.beat_unit, ne.key_name(int(s.key)), s.bars, seconds,
			"" if s.loop else "  (does not loop)")
		for &t in s.tracks {
			fmt.printfln("  %v  %v  vol %v  %v notes%v%v",
				t.name, t.inst, t.volume, len(t.notes),
				"  muted" if t.mute else "", "  solo" if t.solo else "")
		}
		return true

	case "render":
		if len(args) < 3 do return ui.fail("song render: need an output .wav")
		for w in s.warnings do fmt.eprintfln("song render: %v", w)
		if n := ne.song_tails_wrapping(&s); n > 0 {
			fmt.printfln("  %v note(s) ring past the end of the loop and on into its start", n)
		}
		a := ne.render_song(&s, &insts)
		defer ne.audio_destroy(&a)
		if !ne.export_audio(a.samples, args[2], a.channels, a.rate if a.rate > 0 else ne.SAMPLE_RATE, s.loop) do return ui.fail("song render: could not write %v", args[2])
		fmt.printfln("wrote %v  (%.1fs, %v frames, stereo, %.1f LUFS)", args[2], ne.audio_seconds(a), ne.audio_frames(a),
			ne.loudness(a.samples, a.channels))
		return true

	case "bake":
		// `just bake`: what the game plays, beside the song (nengine
		// audio.odin, Baking), unless it is there and newer.
		target := ne.bake_target(path, ne.song_seconds(&s), s.loop)
		if !(len(args) > 2 && args[2] == "--force") && ne.bake_fresh(path, target) {
			fmt.printfln("fresh %v", target)
			return true
		}
		for w in s.warnings do fmt.eprintfln("song bake: %v", w)
		a := ne.render_song(&s, &insts)
		defer ne.audio_destroy(&a)
		if !ne.bake_write(a, target, s.loop) do return ui.fail("song bake: could not write %v", target)
		fmt.printfln("wrote %v  (%.1fs, %v frames, %.1f LUFS)", target, ne.audio_seconds(a), ne.audio_frames(a),
			ne.loudness(a.samples, a.channels))
		return true

	case "track":
		if len(args) < 4 do return ui.fail("song track: need a name and an instrument")
		if _, good := ne.instrument_find(&insts, args[3]); !good {
			return ui.fail("song track: no instrument called %v. Try: %v", args[3], instrument_list(&insts))
		}
		volume := f32(0.3)
		if len(args) > 4 {
			if v, v_ok := strconv.parse_f32(args[4]); v_ok do volume = v
		}
		ne.song_add_track(&s, args[2], args[3], volume)

	case "instruments":
		for &i in insts.list {
			fmt.printfln("  %-16v %-12v %-20v %v..%v", i.key, i.family, i.name, ne.note_text(i.lo), ne.note_text(i.hi))
		}
		return true

	case "bpm", "tempo":
		if len(args) < 3 do return ui.fail("song tempo: need a number")
		s.tempo = f32(ui.num(args, 2, int(s.tempo)))

	case "set":
		if len(args) < 5 do return ui.fail("song set: need a track, a step and a note")
		t := find_track(&s, args[2])
		if t == nil do return ui.fail("song set: no track called %v", args[2])
		step := ui.num(args, 3, 0)
		steps := ne.song_steps(&s)
		if step < 0 || step >= steps do return ui.fail("song set: cell %v is outside 0..<%v", step, steps)
		ne.track_write_cell(&s, t, step, ne.parse_note(args[4]))

	case "fill":
		// "fill bass 0 4 A2 F2" puts A2 at step 0, F2 at 4, A2 at 8...
		if len(args) < 6 do return ui.fail("song fill: need a track, a starting step, a spacing and some notes")
		t := find_track(&s, args[2])
		if t == nil do return ui.fail("song fill: no track called %v", args[2])
		start := ui.num(args, 3, 0)
		every := max(ui.num(args, 4, 4), 1)
		phrase := args[5:]
		step := start
		i := 0
		for step < ne.song_steps(&s) {
			ne.track_write_cell(&s, t, step, ne.parse_note(phrase[i % len(phrase)]))
			step += every
			i += 1
		}

	case:
		return ui.fail("song: don't know %v", args[0])
	}

	if !ne.save_song(&s, path) do return ui.fail("song: could not write %v", path)
	fmt.printfln("%v updated", path)
	return true
}

find_track :: proc(s: ^ne.Song, name: string) -> ^ne.Track {
	for &t in s.tracks {
		if t.name == name do return &t
	}
	return nil
}

// Every instrument key, for the error messages.
instrument_list :: proc(set: ^ne.Instrument_Set) -> string {
	out := make([dynamic]string, context.temp_allocator)
	for &i in set.list do append(&out, i.key)
	joined, _ := strings.join(out[:], " ", context.temp_allocator)
	return joined
}

// A game's own instruments sit in assets/instruments, beside the music. Walk
// up from the .song being edited until an "assets" folder turns up.
assets_root :: proc(path: string) -> string {
	dir := path
	for _ in 0 ..< 6 {
		slash := strings.last_index_byte(dir, '/')
		if slash <= 0 do break
		dir = dir[:slash]
		if strings.has_suffix(dir, "/assets") || dir == "assets" do return dir
	}
	return ""
}

// --- sound ---

sound_cmd :: proc(args: []string) -> bool {
	if len(args) < 2 do return ui.fail("sound: need a command and a file")
	path := args[1]
	s, ok := ne.load_sound(path)
	if !ok do return ui.fail("sound: could not read %v", path)
	defer ne.sound_destroy(&s)

	switch args[0] {
	case "info":
		fmt.printfln("sound %v  %.3fs  %v layer(s)", s.name, s.length, len(s.layers))
		waves := [ne.Sound_Wave]string{.Sine = "sine", .Square = "square", .Saw = "saw", .Noise = "noise", .Bell = "bell"}
		for v in s.layers {
			fmt.printfln("  %-6v at %.2f for %.2f  vol %.2f%v", waves[v.wave], v.at,
				v.dur if v.dur > 0 else s.length - v.at, v.vol,
				fmt.tprintf("  %.0fHz", v.freq) if v.freq > 0 else "")
		}
		return true

	case "render":
		if len(args) < 3 do return ui.fail("sound render: need an output .wav")
		a := ne.render_sound(&s)
		defer ne.audio_destroy(&a)
		if !ne.export_audio(a.samples, args[2], a.channels, a.rate, s.loop) do return ui.fail("sound render: could not write %v", args[2])
		fmt.printfln("wrote %v  (%.2fs)", args[2], ne.audio_seconds(a))
		return true

	case "bake":
		// `just bake`: a .wav for an effect, a .qoa for a loop or a long one
		// (nengine audio.odin, Baking), unless it is there and newer.
		target := ne.bake_target(path, s.length, s.loop)
		if !(len(args) > 2 && args[2] == "--force") && ne.bake_fresh(path, target) {
			fmt.printfln("fresh %v", target)
			return true
		}
		a := ne.render_sound(&s)
		defer ne.audio_destroy(&a)
		if !ne.bake_write(a, target, s.loop) do return ui.fail("sound bake: could not write %v", target)
		fmt.printfln("wrote %v  (%.2fs)", target, ne.audio_seconds(a))
		return true
	}
	return ui.fail("sound: don't know %v", args[0])
}

