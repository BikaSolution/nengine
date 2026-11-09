package main

import ne "../../"
import ui "../ui"
import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

// The music creator, in two views of one song.
//
// A song is notes on a time line, measured in ticks. That one fact is what
// lets it be edited two ways, and you switch with Tab:
//
//   GRID   a tracker: tracks down the side, a cell to a sixteenth, a note in
//          each. The right tool for drums and short looping beds, which is
//          most of what a game needs.
//   SHEET  four bars across, the whole piano range top to bottom, notes of
//          real lengths — dotted, triplet, tied across a bar. The right tool
//          for writing a tune. See sheet_view.odin.
//
// Both edit the same notes. A triplet written on the sheet shows in the grid
// in the cell it starts in, marked, because the grid cannot say it exactly.
//
//   space     play / stop
//   Tab       swap views
//   T         add a track, Shift+T remove the last one
//   I         pick the track's instrument
//   M / S     mute / solo the selected track
//   F5        re-read the instrument files
//   Ctrl+S    save
//   drop a .mid on the window to import it

Song_View :: enum {
	Grid,
	Sheet,
}

Song_Editor :: struct {
	path:     string,
	song:     ne.Song,
	view:     Song_View,
	track:    int,

	// Grid view
	step:     int,
	note:     int, // the note the next click writes
	view_x:   int, // first cell shown, for songs wider than the window
	was_step: int, // what `step` was last frame: only chase it when it moves
	follow:   bool,

	// Sheet view
	page:     i32,
	selected: int, // index into the active track's notes, or -1
	length:   ne.Length,
	mod:      ne.Length_Mod,
	acc:      Acc_Mode,
	drag:     Drag,

	side:     f32, // the track column's width, dragged and remembered
	playing:  bool,
	stream:   ne.Loop,
	started:  f64,

	text:     ui.Text_Input,
	history:  ui.History,
	dirty:    bool,
	loaded:   bool,

	insts:    ne.Instrument_Set,
	picking:  bool,
	pick_fresh: bool, // opened this frame: don't read the input that opened it
	pick_at:  int,
	audition: rl.Sound,
}

song_editor_open :: proc(e: ^Song_Editor, path: string) -> bool {
	e^ = {
		path     = strings.clone(path),
		note     = ne.parse_note("A3"),
		follow   = true,
		selected = -1,
		length   = .Quarter,
	}
	ne.instruments_load(&e.insts, instruments_root(path))

	if song, ok := ne.load_song(path, &e.insts); ok {
		e.song = song
	} else {
		name := path
		if slash := strings.last_index_byte(name, '/'); slash >= 0 do name = name[slash + 1:]
		if dot := strings.last_index_byte(name, '.'); dot >= 0 do name = name[:dot]
		e.song = ne.song_new(name, 90, 4)
		ne.song_add_track(&e.song, "bass", "triangle_bass", 0.3)
		ne.song_add_track(&e.song, "lead", "pulse_lead", 0.2)
		e.dirty = true
	}
	e.loaded = true
	return true
}

song_editor_close :: proc(e: ^Song_Editor) {
	if !e.loaded do return
	song_stop(e)
	stop_audition(e)
	ne.instrument_set_destroy(&e.insts)
	ne.song_destroy(&e.song)
	ui.text_input_destroy(&e.text)
	ui.history_destroy(&e.history)
	delete(e.path)
	e^ = {}
}

// Opens in the sheet view from outside. `nsound <song> --sheet` uses it.
song_editor_sheet :: proc(e: ^Song_Editor) {
	if e.loaded do e.view = .Sheet
}

@(private)
song_stop :: proc(e: ^Song_Editor) {
	if e.stream.music.stream.buffer != nil {
		rl.StopMusicStream(e.stream.music)
		ne.unload_loop(&e.stream)
	}
	e.playing = false
}

// Renders the song as it stands and streams it, so edits made while it plays
// are heard the next time you press play.
// Starts playback from outside the editor, so `nsound <song> --play` can
// check that the view really does follow the music.
song_editor_play :: proc(e: ^Song_Editor) {
	if e.loaded do song_play(e)
}

@(private)
song_play :: proc(e: ^Song_Editor) {
	song_stop(e)
	a := ne.render_song(&e.song, &e.insts)
	defer ne.audio_destroy(&a)
	if len(a.samples) == 0 do return
	e.stream = ne.loop_from_samples(a.samples, a.channels)
	rl.PlayMusicStream(e.stream.music)
	e.playing = true
	e.started = ui.now()
}

// Opens the instrument picker from outside, the way pressing I does.
song_editor_pick :: proc(e: ^Song_Editor) {
	if e.loaded do open_picker(e)
}

CELL_W :: 46
CELL_H :: 26
HEAD_H :: 88

// Where the column of track names starts out. It is dragged from there — a
// fixed width can't hold a name, and `triangle_bass` is longer than any
// number anyone would have picked.
SIDE_W :: f32(170)
SIDE_MIN :: f32(110)

song_editor_step :: proc(e: ^Song_Editor, status: ^ui.Status) -> bool {
	screen_now := [2]f32{f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
	// Nothing can be laid out until the column's width is known, so the drag
	// is resolved first and the handle drawn last.
	e.side = ui.split("nsound.side", SIDE_W, HEAD_H, screen_now.y - HEAD_H - ui.FOOTER_H,
		SIDE_MIN, max(screen_now.x * 0.5, SIDE_MIN)) if !e.picking else e.side
	if !e.loaded do return false
	// Leaving with unsaved changes asked a question last frame; this is the
	// answer, if it has come.
	switch ui.leave_answer() {
	case .Save:    if song_save(e, status) do return false
	case .Discard: return false
	case .None:
	}
	screen := [2]f32{f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
	if e.playing do rl.UpdateMusicStream(e.stream.music)

	take_dropped_files(e, status)

	if !ui.typing(&e.text) && !e.picking {
		if (ui.key_pressed(.ESCAPE) || ui.back_pressed()) && ui.leave_request(e.dirty, ui.file_of(e.path)) do return false
		if ui.key_pressed(.TAB) {
			e.view = .Sheet if e.view == .Grid else .Grid
		}
		if ui.undo_pressed() do song_step_back(e, status, false)
		if ui.redo_pressed() do song_step_back(e, status, true)
		if ui.key_pressed(.SPACE) {
			if e.playing {
				song_stop(e)
			} else {
				song_play(e)
				ui.say(status, "playing %v bars at %v bpm", e.song.bars, e.song.tempo)
			}
		}
		if ui.key_pressed(.F) do e.follow = !e.follow
		if ui.key_pressed(.I) && !ui.ctrl_down() && len(e.song.tracks) > 0 do open_picker(e)
		// The instrument files can change while this is open: F5 re-reads
		// them, so tuning a sound is a save and a keypress, not a rebuild.
		if ui.key_pressed(.F5) {
			ne.instrument_set_destroy(&e.insts)
			n := ne.instruments_load(&e.insts, instruments_root(e.path))
			ui.say(status, "reloaded %v instruments", n)
		}
		if ui.key_pressed(.M) && len(e.song.tracks) > 0 {
			song_mark(e)
			e.song.tracks[e.track].mute = !e.song.tracks[e.track].mute
			e.dirty = true
		}
		if ui.key_pressed(.S) && !ui.ctrl_down() && len(e.song.tracks) > 0 {
			song_mark(e)
			e.song.tracks[e.track].solo = !e.song.tracks[e.track].solo
			e.dirty = true
		}
		if ui.key_pressed(.T) {
			song_mark(e)
			if ui.shift_down() {
				if len(e.song.tracks) > 1 {
					ne.song_remove_track(&e.song, len(e.song.tracks) - 1)
					e.track = min(e.track, len(e.song.tracks) - 1)
					e.dirty = true
				}
			} else {
				ne.song_add_track(&e.song, fmt.tprintf("track%v", len(e.song.tracks) + 1), "pulse_lead", 0.3)
				e.track = len(e.song.tracks) - 1
				e.dirty = true
			}
		}
		if ui.save_pressed() do song_save(e, status)
		if ui.copy_pressed() && e.track < len(e.song.tracks) {
			t := e.song.tracks[e.track]
			clear(&clipboard.song_notes)
			append(&clipboard.song_notes, ..t.notes[:])
			ui.reset_string(&clipboard.inst, t.inst)
			clipboard.volume = t.volume
			ui.say(status, "copied %v: %v notes", t.name, len(t.notes))
		}
		if ui.paste_pressed() && len(clipboard.song_notes) > 0 && e.track < len(e.song.tracks) {
			song_mark(e)
			t := &e.song.tracks[e.track]
			clear(&t.notes)
			append(&t.notes, ..clipboard.song_notes[:])
			ne.track_set_instrument(t, clipboard.inst)
			t.volume = clipboard.volume
			ne.song_grow_bars(&e.song)
			e.dirty = true
			ui.say(status, "pasted into %v", t.name)
		}
	}

	rl.ClearBackground(ui.BG)
	leaving := draw_song_header(e, screen.x, status)

	switch e.view {
	case .Grid:  grid_step(e, screen, status)
	case .Sheet: sheet_step(e, screen, status)
	}

	// The divider is drawn after the panes, so nothing is painted over it, and
	// not while the picker is up — a modal that can be dragged behind is a
	// modal you will drag behind.
	if !e.picking do ui.splits_draw()
	if e.picking do draw_picker(e, screen)
	switch e.view {
	case .Grid:
		ui.footer(status, "Tab sheet  click a cell  up/down semitone  - hold  ^C ^V track  ^Z undo  I instrument  M mute  S solo  T +track  Space play  ^S save  Esc ^B files")
	case .Sheet:
		ui.footer(status, "Tab grid  click to place  drag to move  right-click deletes  wheel a semitone  1-6 length  . dotted  , triplet  Alt fine  [ ] page  F follow  Space play  ^S save  Esc ^B files")
	}
	return !leaving
}

@(private = "file")
song_save :: proc(e: ^Song_Editor, status: ^ui.Status) -> bool {
	if !ne.save_song(&e.song, e.path) {
		ui.say(status, "could not write %v", e.path)
		return false
	}
	e.dirty = false
	ui.say(status, "saved %v", e.path)
	return true
}

// Where the music has got to, in ticks, or -1 if it isn't playing.
@(private)
song_playhead_tick :: proc(e: ^Song_Editor) -> i32 {
	if !e.playing do return -1
	total := ne.song_total_ticks(&e.song)
	if total <= 0 do return -1
	at := i32(f32(ui.now() - e.started) / ne.tick_seconds(&e.song))
	return at %% total if e.song.loop else min(at, total)
}

@(private)
song_mark :: proc(e: ^Song_Editor) {
	ui.history_mark(&e.history, ne.song_text(&e.song))
}

@(private = "file")
song_step_back :: proc(e: ^Song_Editor, status: ^ui.Status, forward: bool) {
	now := ne.song_text(&e.song)
	step: string
	ok: bool
	if forward {
		step, ok = ui.history_redo(&e.history, now)
	} else {
		step, ok = ui.history_undo(&e.history, now)
	}
	if !ok {
		ui.say(status, "nothing to redo" if forward else "nothing to undo")
		return
	}
	defer ui.history_done(step)
	back, good := ne.parse_song(step, &e.insts)
	if !good do return
	ne.song_destroy(&e.song)
	e.song = back
	e.track = clamp(e.track, 0, max(len(e.song.tracks) - 1, 0))
	e.step = clamp(e.step, 0, max(ne.song_steps(&e.song) - 1, 0))
	e.selected = -1
	e.dirty = true
	ui.say(status, "redone" if forward else "undone")
}

// A .mid dropped on the window replaces the song. That is the whole of the
// import: write it somewhere else, finish it here.
@(private = "file")
take_dropped_files :: proc(e: ^Song_Editor, status: ^ui.Status) {
	for path in ui.dropped_files() {
		if !strings.has_suffix(path, ".mid") && !strings.has_suffix(path, ".midi") do continue
		song_mark(e)
		rep := ne.midi_import_file(path, &e.song, &e.insts)
		if rep.problem != "" {
			ui.say(status, "%v", rep.problem)
			delete(rep.problem)
			return
		}
		e.track, e.page, e.selected, e.step, e.view_x = 0, 0, -1, 0, 0
		e.view = .Sheet // it will be real music, so show it as music
		e.dirty = true
		ui.say(status, "imported %v notes on %v tracks%v", rep.notes, rep.tracks,
			fmt.tprintf(", %v moved into range", rep.transposed) if rep.transposed > 0 else "")
		return
	}
}

// --- The header, shared by both views ---

@(private = "file")
draw_song_header :: proc(e: ^Song_Editor, width: f32, status: ^ui.Status) -> (leaving: bool) {
	ui.panel({0, 0, width, HEAD_H})
	leaving = ui.back_button(6) && !e.picking && ui.leave_request(e.dirty, ui.file_of(e.path))
	ui.title_bar(e.song.name, e.path, e.dirty, width, ui.BACK_W)

	y: f32 = 40
	ui.label(10, i32(y) + 4, "bpm", ui.DIM, ui.SMALL)
	if v, done := ui.text_field(&e.text, {44, y, 52, 24}, "s.bpm", fmt.tprintf("%v", e.song.tempo)); done {
		e.song.tempo = max(ui.to_f32(v, e.song.tempo), 20)
		e.dirty = true
	}
	ui.label(106, i32(y) + 4, "time", ui.DIM, ui.SMALL)
	if v, done := ui.text_field(&e.text, {142, y, 50, 24}, "s.time",
		fmt.tprintf("%v/%v", e.song.beats, e.song.beat_unit)); done {
		if slash := strings.index_byte(v, '/'); slash > 0 {
			top, bottom := ui.to_int(v[:slash], int(e.song.beats)), ui.to_int(v[slash + 1:], int(e.song.beat_unit))
			if top > 0 do e.song.beats = i32(top)
			if bottom > 0 do e.song.beat_unit = i32(bottom)
			e.dirty = true
		}
	}
	// The key signature decides which black keys are sharps and which flats.
	ui.label(202, i32(y) + 4, "key", ui.DIM, ui.SMALL)
	if v, done := ui.number_field(&e.text, {234, y, 74, 24}, "s.key", int(e.song.key), 1); done {
		e.song.key = i32(clamp(v, -7, 7))
		e.dirty = true
	}
	ui.label(314, i32(y) + 4, ne.key_name(int(e.song.key)), ui.DIM, ui.SMALL)

	ui.label(420, i32(y) + 4, "bars", ui.DIM, ui.SMALL)
	if v, done := ui.number_field(&e.text, {456, y, 74, 24}, "s.bars", int(e.song.bars), 4); done {
		e.song.bars = i32(max(v, 1))
		ne.song_grow_bars(&e.song)
		e.dirty = true
	}
	// The buttons are anchored to the right edge, so in a narrow window the
	// fields that are only nice to have give up their room rather than being
	// drawn underneath them.
	buttons_from := width - 296
	if buttons_from > 730 {
		ui.label(542, i32(y) + 4, "name", ui.DIM, ui.SMALL)
		if v, done := ui.text_field(&e.text, {582, y, 140, 24}, "s.name", e.song.name); done {
			ui.reset_string(&e.song.name, v)
			e.dirty = true
		}
	}
	// The note a grid click writes, and what it is worth in Hz.
	if e.view == .Grid && buttons_from > 900 {
		ui.label(736, i32(y) + 4, "note", ui.DIM, ui.SMALL)
		rl.DrawRectangleRec({772, y, 62, 24}, {26, 26, 32, 255})
		rl.DrawRectangleLinesEx({772, y, 62, 24}, 1, ui.GOLD)
		ui.label(778, i32(y) + 4, ne.note_text(e.note), ui.GOLD, ui.SMALL)
		ui.label(842, i32(y) + 4, fmt.tprintf("%.0f Hz", ne.note_hz(e.note)), ui.DIM, ui.SMALL)
	}

	if ui.button({width - 296, y, 60, 24}, "grid", e.view == .Grid) do e.view = .Grid
	if ui.button({width - 232, y, 60, 24}, "sheet", e.view == .Sheet) do e.view = .Sheet
	if ui.button({width - 166, y, 56, 24}, "stop" if e.playing else "play") {
		if e.playing {
			song_stop(e)
		} else {
			song_play(e)
		}
	}
	if ui.button({width - 104, y, 94, 24}, "export wav") {
		wav := fmt.tprintf("%v.wav", strings.trim_suffix(e.path, ".song"))
		a := ne.render_song(&e.song, &e.insts)
		defer ne.audio_destroy(&a)
		if ne.export_wav(a.samples, wav, a.channels) {
			ui.say(status, "wrote %v", wav)
		} else {
			ui.say(status, "could not write %v", wav)
		}
	}
	return
}

// --- The tracker grid ---

@(private = "file")
grid_step :: proc(e: ^Song_Editor, screen: [2]f32, status: ^ui.Status) {
	grid := rl.Rectangle{e.side, HEAD_H + 8, screen.x - e.side - 10, screen.y - HEAD_H - 34}
	visible := max(int(grid.width) / CELL_W, 1)
	steps := ne.song_steps(&e.song)
	playhead := -1
	if tick := song_playhead_tick(e); tick >= 0 do playhead = int(tick / ne.song_grid(&e.song))

	if !ui.typing(&e.text) && !e.picking {
		if ui.key_pressed(.UP) do e.note = min(e.note + 1, 108)
		if ui.key_pressed(.DOWN) do e.note = max(e.note - 1, 12)
		if ui.key_pressed(.RIGHT) do e.step = min(e.step + 1, steps - 1)
		if ui.key_pressed(.LEFT) do e.step = max(e.step - 1, 0)
		if ui.key_pressed(.PAGE_UP) do e.note = min(e.note + 12, 108)
		if ui.key_pressed(.PAGE_DOWN) do e.note = max(e.note - 12, 12)
		if ui.key_pressed(.ENTER) {
			song_mark(e)
			write_cell(e, e.track, e.step, e.note)
		}
		if ui.key_pressed(.BACKSPACE) || ui.key_pressed(.DELETE) {
			song_mark(e)
			write_cell(e, e.track, e.step, ne.REST)
		}
		// A dash holds the note before it, which is how a chord sustains
		// instead of being struck over and over.
		if ui.key_pressed(.MINUS) || ui.key_pressed(.KP_SUBTRACT) {
			song_mark(e)
			write_cell(e, e.track, e.step, ne.HOLD)
			e.step = min(e.step + 1, steps - 1)
		}
	}

	furthest := max(steps - visible, 0)
	show :: proc(view_x: ^int, at, visible, furthest: int) {
		if at < view_x^ do view_x^ = at
		if at >= view_x^ + visible do view_x^ = at - visible + 1
		view_x^ = clamp(view_x^, 0, furthest)
	}
	// Chase the selected cell only when it actually moves, so scrolling away
	// from it stays scrolled away from it.
	if e.step != e.was_step {
		show(&e.view_x, e.step, visible, furthest)
		e.was_step = e.step
	}
	// Follow the music, a couple of cells ahead, so you can see what is about
	// to be played and not only what just was.
	if e.playing && e.follow && playhead >= 0 {
		show(&e.view_x, min(playhead + 2, steps - 1), visible, furthest)
	}
	if !ui.typing(&e.text) && !e.picking {
		if ui.key_pressed(.HOME) do e.view_x = 0
		if ui.key_pressed(.END) do e.view_x = furthest
	}
	if wheel := ui.wheel(); wheel != 0 && !e.picking {
		e.view_x = clamp(e.view_x - int(wheel) * 2, 0, furthest)
	}
	if ui.mouse_down(.MIDDLE) {
		e.view_x = clamp(e.view_x - int(ui.mouse_delta().x / CELL_W), 0, furthest)
	}
	e.view_x = clamp(e.view_x, 0, furthest)

	draw_song_grid(e, grid, visible, playhead)
	draw_song_scrollbar(e, grid, visible, steps)
}

@(private = "file")
write_cell :: proc(e: ^Song_Editor, track, step, note: int) {
	if track < 0 || track >= len(e.song.tracks) do return
	if step < 0 || step >= ne.song_steps(&e.song) do return
	ne.track_write_cell(&e.song, &e.song.tracks[track], step, note)
	e.dirty = true
}

@(private = "file")
draw_song_scrollbar :: proc(e: ^Song_Editor, grid: rl.Rectangle, visible, steps: int) {
	if steps <= visible do return
	y := grid.y + f32(len(e.song.tracks)) * CELL_H + 10
	bar := rl.Rectangle{grid.x, y, grid.width, 5}
	rl.DrawRectangleRec(bar, {40, 40, 50, 255})
	frac := f32(visible) / f32(steps)
	at := f32(e.view_x) / f32(steps)
	rl.DrawRectangleRec({bar.x + at * bar.width, bar.y, max(frac * bar.width, 12), bar.height}, ui.DIM)
}

@(private = "file")
draw_song_grid :: proc(e: ^Song_Editor, grid: rl.Rectangle, visible, playhead: int) {
	steps := ne.song_steps(&e.song)
	per_bar := int(ne.bar_ticks(&e.song) / ne.song_grid(&e.song))
	per_beat := max(int(ne.beat_ticks(&e.song) / ne.song_grid(&e.song)), 1)

	// Cell numbers along the top, with the bar each one starts.
	for i in 0 ..< visible {
		step := e.view_x + i
		if step >= steps do break
		x := grid.x + f32(i * CELL_W)
		on_bar := per_bar > 0 && step % per_bar == 0
		colour := ui.GOLD if step == playhead else (ui.INK if on_bar else ui.DIM)
		ui.label(i32(x) + 4, i32(grid.y) - 20, fmt.tprintf("%v", step), colour, ui.SMALL)
		if on_bar {
			ui.label(i32(x) + 4, i32(grid.y) - 34, fmt.tprintf("bar %v", step / per_bar + 1), ui.DIM, ui.SMALL)
		}
	}

	for &t, ti in e.song.tracks {
		y := grid.y + f32(ti * CELL_H)
		if y + CELL_H > grid.y + grid.height do break
		picked := ti == e.track
		ins := ne.instrument_get(&e.insts, t.inst)
		colour := rl_colour(ins.color)
		audible := ne.track_audible(&e.song, &t)

		// Track name, instrument and state down the left.
		name_rect := rl.Rectangle{6, y, e.side - 12, CELL_H - 2}
		rl.DrawRectangleRec(name_rect, {40, 40, 50, 255} if picked else ui.PANEL)
		rl.DrawRectangleLinesEx(name_rect, 1, ui.GOLD if picked else ui.EDGE)
		if !e.picking && rl.CheckCollisionPointRec(ui.mouse(), name_rect) &&
		   ui.mouse_pressed(.LEFT) {
			e.track = ti
		}
		// The instrument takes a share of what's left after the M/S letters, so
		// both it and the name get room — instead of the name winning and the
		// instrument running off the end of the column, which is what a fixed
		// 150 pixels did to `triangle_bass`.
		inst_w := max((e.side - 12) * 0.45, 60)
		inst_rect := rl.Rectangle{e.side - 8 - inst_w - 14, y + 3, inst_w, CELL_H - 8}
		ui.label(12, i32(y) + 4, ui.ellipsize(t.name, inst_rect.x - 18, ui.SMALL),
			(ui.INK if picked else ui.DIM) if audible else ui.EDGE, ui.SMALL)
		if !e.picking && rl.CheckCollisionPointRec(ui.mouse(), inst_rect) &&
		   ui.mouse_pressed(.LEFT) {
			e.track = ti
			open_picker(e)
		}
		rl.DrawRectangleRec({inst_rect.x, inst_rect.y + 2, 3, inst_rect.height - 4}, colour)
		ui.label(i32(inst_rect.x) + 8, i32(y) + 4, ui.ellipsize(t.inst, inst_rect.width - 12, ui.SMALL),
			ui.DIM if audible else ui.EDGE, ui.SMALL)
		if t.mute do ui.label(i32(e.side) - 18, i32(y) + 4, "M", ui.GOLD, ui.SMALL)
		if t.solo do ui.label(i32(e.side) - 18, i32(y) + 4, "S", ui.LIVE, ui.SMALL)

		for i in 0 ..< visible {
			step := e.view_x + i
			if step >= steps do break
			cell := rl.Rectangle{grid.x + f32(i * CELL_W), y, CELL_W - 2, CELL_H - 2}
			c := ne.track_cell(&e.song, &t, step)

			bg := rl.Color{30, 30, 38, 255} if per_bar > 0 && step % per_bar == 0 else
			      (rl.Color{27, 27, 34, 255} if step % per_beat == 0 else rl.Color{24, 24, 30, 255})
			if step == playhead do bg = {48, 44, 30, 255}
			if picked && step == e.step do bg = {56, 52, 36, 255}
			rl.DrawRectangleRec(cell, bg)
			rl.DrawRectangleLinesEx(cell, 1, ui.GOLD if picked && step == e.step else ui.EDGE)

			if c.note >= 0 {
				// A note the instrument cannot reach is drawn in red: a cello
				// part above the staff is a mistake you want to see rather
				// than hear.
				ink := colour if c.note >= ins.lo && c.note <= ins.hi else rl.Color{230, 80, 80, 255}
				if !audible do ink = rl.Color{ink.r / 2, ink.g / 2, ink.b / 2, 255}
				ui.label(i32(cell.x) + 5, i32(cell.y) + 4, ne.note_text(c.note), ink, ui.SMALL)
				// A note that didn't start on a cell boundary — written on
				// the sheet, or imported — can only be approximated here.
				if c.off_grid do rl.DrawRectangleRec({cell.x + cell.width - 5, cell.y + 2, 3, 3}, ui.GOLD)
			} else if c.note == ne.HOLD {
				held := colour
				held.a = 140 if audible else 60
				rl.DrawRectangleRec({cell.x + 4, cell.y + cell.height / 2 - 1, cell.width - 8, 2}, held)
			}

			if rl.CheckCollisionPointRec(ui.mouse(), cell) && !e.picking {
				if ui.mouse_pressed(.LEFT) {
					song_mark(e)
					e.track, e.step = ti, step
					// Clicking a cell that already holds this note clears it,
					// so one button both writes and rubs out.
					write_cell(e, ti, step, ne.REST if c.note == e.note else e.note)
				}
				if ui.mouse_pressed(.RIGHT) {
					song_mark(e)
					write_cell(e, ti, step, ne.REST)
				}
			}
		}
	}
}

// --- The instrument picker ---
//
// Every instrument the .inst files gave us, in a list over the view. Moving
// through it plays each one on the note you have selected, so you choose a
// sound by ear rather than by name; Enter or a second click sets it.

PICK_ROW :: 22

@(private)
open_picker :: proc(e: ^Song_Editor) {
	if len(e.song.tracks) == 0 do return
	e.picking = true
	// The picker is drawn later in the same frame that opened it, and the key
	// or the click that opened it is still down as far as raylib is concerned.
	// Without this the picker read its own opening input and shut again at
	// once: I set the instrument it already had, and a click on the swatch
	// counted as a click outside the box. Either way it never appeared.
	e.pick_fresh = true
	e.pick_at = 0
	for ins, i in e.insts.list do if ins.key == e.song.tracks[e.track].inst do e.pick_at = i
}

@(private = "file")
close_picker :: proc(e: ^Song_Editor) {
	e.picking = false
	stop_audition(e)
}

@(private)
stop_audition :: proc(e: ^Song_Editor) {
	if e.audition.stream.buffer != nil {
		rl.StopSound(e.audition)
		rl.UnloadSound(e.audition)
		e.audition = {}
	}
}

// Hear one instrument, on a note it can actually play.
@(private)
audition :: proc(e: ^Song_Editor, ins: ne.Instrument, note: int) {
	stop_audition(e)
	ins := ins
	a := ne.render_note(&ins, clamp(note, ins.lo, ins.hi))
	defer ne.audio_destroy(&a)
	if len(a.samples) == 0 do return
	// Played once, not looped: this is one note, not a bed.
	e.audition = ne.sound_from_samples(a.samples, a.channels)
	rl.PlaySound(e.audition)
}

@(private = "file")
audition_row :: proc(e: ^Song_Editor, i: int) {
	if i < 0 || i >= len(e.insts.list) do return
	audition(e, e.insts.list[i], e.note)
}

@(private = "file")
set_instrument :: proc(e: ^Song_Editor, i: int) {
	if i < 0 || i >= len(e.insts.list) || e.track >= len(e.song.tracks) do return
	song_mark(e)
	ne.track_set_instrument(&e.song.tracks[e.track], e.insts.list[i].key)
	e.dirty = true
}

@(private = "file")
draw_picker :: proc(e: ^Song_Editor, screen: [2]f32) {
	TOP :: f32(110)
	count := len(e.insts.list)
	rows := min(count, int((screen.y - TOP - 46 - 40) / PICK_ROW))
	if rows < 1 do rows = 1
	w: f32 = 340
	box := rl.Rectangle{screen.x / 2 - w / 2, TOP, w, f32(rows * PICK_ROW) + 46}

	// The frame it opened on is drawn and nothing else; see open_picker.
	if e.pick_fresh {
		e.pick_fresh = false
		draw_picker_rows(e, box, screen, rows, count, live = false)
		return
	}

	if ui.key_pressed(.ESCAPE) {
		close_picker(e)
		return
	}
	if ui.key_pressed(.DOWN) || ui.key_pressed(.TAB) {
		e.pick_at = (e.pick_at + 1) % max(count, 1)
		audition_row(e, e.pick_at)
	}
	if ui.key_pressed(.UP) {
		e.pick_at = (e.pick_at - 1 + count) % max(count, 1)
		audition_row(e, e.pick_at)
	}
	if ui.key_pressed(.ENTER) || ui.key_pressed(.I) {
		set_instrument(e, e.pick_at)
		close_picker(e)
		return
	}
	if ui.mouse_pressed(.LEFT) && !rl.CheckCollisionPointRec(ui.mouse(), box) {
		close_picker(e)
		return
	}

	draw_picker_rows(e, box, screen, rows, count, live = true)
}

// `live` is false on the frame the picker opened, when the click that opened
// it is still being reported and would be read as a choice.
@(private = "file")
draw_picker_rows :: proc(e: ^Song_Editor, box: rl.Rectangle, screen: [2]f32, rows, count: int, live: bool) {
	first := clamp(e.pick_at - rows / 2, 0, max(count - rows, 0))
	rl.DrawRectangleRec({0, 0, screen.x, screen.y}, {0, 0, 0, 150})
	ui.panel(box)
	ui.label(i32(box.x) + 10, i32(box.y) + 8, "instrument  (Enter picks, Esc backs out)", ui.DIM, ui.SMALL)

	for i in 0 ..< rows {
		idx := first + i
		if idx >= count do break
		ins := e.insts.list[idx]
		row := rl.Rectangle{box.x + 6, box.y + 30 + f32(i * PICK_ROW), box.width - 12, PICK_ROW - 2}
		hot := rl.CheckCollisionPointRec(ui.mouse(), row)
		if hot && live && ui.mouse_pressed(.LEFT) {
			if idx == e.pick_at {
				// A second click on the one already chosen accepts it.
				set_instrument(e, idx)
				close_picker(e)
				return
			}
			e.pick_at = idx
			audition_row(e, idx)
		}
		if idx == e.pick_at {
			rl.DrawRectangleRec(row, {56, 52, 36, 255})
			rl.DrawRectangleLinesEx(row, 1, ui.GOLD)
		} else if hot {
			rl.DrawRectangleRec(row, {40, 40, 50, 255})
		}
		rl.DrawRectangleRec({row.x + 4, row.y + 4, 4, row.height - 8}, rl_colour(ins.color))
		ui.label(i32(row.x) + 14, i32(row.y) + 3, ins.key, ui.INK if idx == e.pick_at else ui.DIM, ui.SMALL)
		ui.label(i32(row.x) + 130, i32(row.y) + 3, ins.family, ui.DIM, ui.SMALL)
		ui.label(i32(row.x) + 210, i32(row.y) + 3,
			fmt.tprintf("%v-%v", ne.note_text(ins.lo), ne.note_text(ins.hi)), ui.DIM, ui.SMALL)
	}
	if count == 0 {
		ui.label(i32(box.x) + 10, i32(box.y) + 34, "no .inst files found - see nengine/instruments/", ui.DIM, ui.SMALL)
	} else if count > rows {
		ui.label(i32(box.x) + 10, i32(box.y + box.height) - 14,
			fmt.tprintf("%v of %v", e.pick_at + 1, count), ui.DIM, ui.SMALL)
	}
}

// A game's own instruments live beside its music, in assets/instruments.
@(private)
instruments_root :: proc(path: string) -> string {
	dir := path
	for _ in 0 ..< 6 {
		slash := strings.last_index_byte(dir, '/')
		if slash <= 0 do break
		dir = dir[:slash]
		if strings.has_suffix(dir, "/assets") || dir == "assets" do return dir
	}
	return ""
}

@(private)
rl_colour :: proc(c: [4]u8) -> rl.Color {
	return {c[0], c[1], c[2], c[3]}
}

// Used by the CLI: a starting song file, without opening a window.
song_file_new :: proc(path, name: string, bpm: f32, bars: int) -> bool {
	s := ne.song_new(name, bpm, i32(max(bars, 1)))
	defer ne.song_destroy(&s)
	ne.song_add_track(&s, "bass", "triangle_bass", 0.3)
	ne.song_add_track(&s, "lead", "pulse_lead", 0.2)
	return ne.save_song(&s, path)
}
