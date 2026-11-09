package nengine

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

// The front of a game and the loop that runs it: the studio card, the title
// screen, then play — and the handful of command-line switches every game
// wants for testing itself. None of it knows what the game is about, so none
// of it belongs in one.
//
//     l := ne.launch_flags()
//     ne.init("My Game", 1024, 640)
//     ...load assets, make the World, load the rooms...
//     ne.new_game(&w, start)
//     ne.run_script(&w, l.script, harness)
//     front := ne.front_new(logo, menu, l, start)
//     ne.run_game(&w, &front, l)
//
// `start` is the game's: put the world at the beginning. Which room, where the
// player stands, which act. It is called for a new game from the menu and for
// Restart from the death box, after `reset_story` has wiped everything the
// last game left behind, so a game never has to remember what to clear.
//
// `front.intro`, if the game sets one, is called instead of `start` for a new
// game from the menu, and only then: the story before the story, once per
// game begun. It sets its own stage and, when it is over or skipped, calls
// `begin_after_intro(w, start)`. Restart from the death box and `--skip` go
// straight to `start`, so a player who dies does not sit through it twice and
// the harness never sees it unless it asks.

// What the game was asked to do from the command line.
Launch :: struct {
	skip:    bool,   // --skip: straight to play, no card and no menu
	menu:    bool,   // --menu: straight to the title screen
	debug:   bool,   // --debug: the F1 overlay on from the first frame
	shot:    bool,   // --shot: write shot.png and exit, which is how tests look
	shot_at: int,    // --at N: which frame, so a fade can be caught halfway
	script:  string, // --script "a; b; c": commands typed before the window opens
	play:    string, // --play file: the game plays that script itself, in the window
	speed:   f32,    // --speed N: how much faster the world runs while it does (4)
	log:     string, // --log file: every command typed and every reply, as TSV (playlog.odin)
	dev:     bool,   // --dev (or NENGINE_DEV=1): TELEPORT and TIMETRAVEL at the prompt (dev.odin)
}

// Reads the switches from the command line. `args` is for tests; a game
// passes nothing and gets os.args.
launch_flags :: proc(given: []string = nil) -> Launch {
	args := given if given != nil else os.args[1:]
	l := Launch{shot_at = 24, speed = 4}
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--skip":
			l.skip = true
		case "--menu":
			l.menu = true
		case "--dev":
			l.dev = true
		case "--debug":
			l.debug = true
		case "--shot":
			l.shot = true
		case "--at":
			if i + 1 < len(args) {
				if v, ok := strconv.parse_int(args[i + 1]); ok do l.shot_at = v
				i += 1
			}
		case "--play":
			if i + 1 < len(args) {
				if text, ok := read_script_file(args[i + 1]); ok do l.play = text
				i += 1
			}
		case "--log":
			if i + 1 < len(args) {
				l.log = args[i + 1]
				i += 1
			}
		case "--speed":
			if i + 1 < len(args) {
				if v, ok := strconv.parse_f32(args[i + 1]); ok && v > 0 do l.speed = v
				i += 1
			}
		case "--script":
			// `--script "a; b"`, or `--script @file` for one read from a file.
			if i + 1 < len(args) {
				l.script = args[i + 1]
				if strings.has_prefix(l.script, "@") {
					if text, ok := read_script_file(l.script[1:]); ok do l.script = text
				}
				i += 1
			}
		}
	}
	// The game's own command line names the play log for its World, which
	// opens it the first time it has something to write (playlog.odin).
	if given == nil do launch_log = l.log
	// And whether the developer's commands are there (dev.odin): --dev, or
	// NENGINE_DEV=1. Only for the real command line, so a test is never
	// switched on by the shell it runs in.
	if given == nil {
		if dev_env() do l.dev = true
		launch_dev = l.dev
	}
	return l
}

Front_Phase :: enum {
	Logo,
	Menu,
	Playing,
}

// The card, the title screen, and which of the three is showing.
//
// The menu's first item starts a new game and its last one quits; anything in
// between goes to `on_menu`, which is where a Restore or a Credits would live.
Front :: struct {
	logo:     Splash,
	has_logo: bool,
	menu:     Menu,
	phase:    Front_Phase,
	start:    proc(w: ^World),
	intro:    proc(w: ^World), // nil: the menu's Start goes straight to `start`
	on_menu:  proc(w: ^World, f: ^Front, item: int),
}

// `logo` may be the zero Sprite, and then there is no card: a game without one
// should not open on a black screen waiting for a picture that is not there.
front_new :: proc(logo: Sprite, menu: Menu, l: Launch, start: proc(w: ^World)) -> Front {
	f := Front{menu = menu, start = start}
	if logo.texture.id != 0 {
		f.logo, f.has_logo = splash_new(logo), true
	}
	switch {
	case l.skip || l.play != "":
		f.phase = .Playing
	case l.menu || !f.has_logo:
		f.phase = .Menu
	case:
		f.phase = .Logo
	}
	// The harness asked for the title screen (`!title`), for a --shot of it.
	if title_harness.on {
		f.phase = .Menu
		f.menu.dusk_held, f.menu.dusk_hold = title_harness.held, title_harness.at
		f.menu.about_open = title_harness.about
	}
	return f
}

// The title's Load Game: the same Load screen the bar opens (screens.odin),
// over the title, every slot and the two autosaves, the empty ones greyed. A
// game calls it from Front.on_menu. The world is begun afresh first, as for
// Start, so a slot picked is loaded into a clean game and nothing the last
// one left (a conversation, a cutscene, a half-made turn) comes with it; the
// intro does not play. Picking a slot goes straight to play in it (run_game,
// `w.restored`); Esc, or a click outside, goes back to the title.
title_load :: proc(w: ^World, f: ^Front) {
	new_game(w, f.start)
	open_load_screen(w)
}

// The title as text: how many layers have a painting, the dusk and the
// light, and the choices. What `!title` prints.
title_report :: proc(m: ^Menu) -> string {
	painted, nights := 0, 0
	for l in m.layers {
		if l.sprite.texture.id != 0 do painted += 1
		if l.night.texture.id != 0 do nights += 1
	}
	secs := menu_dusk_seconds(m)
	dusk := "no dusk"
	if nights > 0 && secs > 0 do dusk = fmt.tprintf("a dusk of %v s into %v night paintings", secs, nights)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "title: %v of %v layers painted, %v, the %v theme", painted, len(m.layers), dusk, m.lights[0])
	if dusk != "no dusk" do fmt.sbprintf(&b, " then the %v", m.lights[1])
	strings.write_string(&b, "; choices")
	for item, i in m.items do fmt.sbprintf(&b, "%v %v", "" if i == 0 else ",", string(item))
	return strings.to_string(b)
}

// The harness's title load: the screen opened, and row n (from 1; 0 for
// none) picked as a click would. Prints where that left her, and a load the
// harness asked for that did not load ends the run with a failure, so a
// smoke row that only reads the exit code still catches it.
@(private)
title_load_aloud :: proc(w: ^World, f: ^Front, row: int) {
	title_load(w, f)
	if row <= 0 {
		fmt.println("  [the title's Load screen]")
		return
	}
	if row > screen_rows(w) {
		fmt.printfln("  [the title's Load screen has no row %v]", row)
		os.exit(1)
	}
	info, _ := row_info(w, row - 1)
	screen_pick(w, row - 1)
	if !w.restored {
		fmt.printfln("  [title load: row %v (%v) did not load: %v]", row, slot_column(info.slot), message(w))
		os.exit(1)
	}
	things := strings.builder_make(context.temp_allocator)
	for it, i in carried(w) do fmt.sbprintf(&things, "%v%v", "" if i == 0 else ", ", it.name)
	fmt.printfln("  [loaded from the title: %v at %.0f,%.0f, %v, the %v light, carrying %v, score %v, playing] %v",
		current_scene(w).name, w.player.pos.x, w.player.pos.y, clock_face(clock_minute(w)), w.light,
		strings.to_string(things) if len(carried(w)) > 0 else "nothing", score(w), message(w))
}

// The harness's `!title [at=F] [about]` (script.odin): the title screen,
// whatever else the command line says, its dusk held at F of the way (0 the
// first painting, 1 night) and its About page up, for a --shot. Read by
// front_new, which comes after the script has run.
@(private)
title_harness: struct {
	on, held, about, load: bool,
	at:                    f32,
	load_row:              int, // `load <n>`: the row to pick, from 1; 0 just opens the screen
}

@(private) TITLE_BANG_USAGE :: "!title [at=0..1] [about] [load [n]]"

@(private)
title_bang :: proc(arg: string) -> string {
	h := &title_harness
	h^ = {on = true}
	words := strings.fields(arg, context.temp_allocator)
	for i := 0; i < len(words); i += 1 {
		word := words[i]
		switch {
		case word == "about":
			h.about = true
		case word == "load":
			h.load = true
			if i + 1 < len(words) {
				if n, ok := strconv.parse_int(words[i + 1]); ok && n >= 1 {
					h.load_row = n
					i += 1
				}
			}
		case strings.has_prefix(word, "at="):
			v, ok := strconv.parse_f32(word[len("at="):])
			if !ok || v < 0 || v > 1 do return TITLE_BANG_USAGE
			h.held, h.at = true, v
		case:
			return TITLE_BANG_USAGE
		}
	}
	dusk := fmt.tprintf(", its dusk held at %.2f", h.at) if h.held else ""
	load := ""
	if h.load do load = fmt.tprintf(", the Load screen up%v", fmt.tprintf(", row %v picked", h.load_row) if h.load_row > 0 else "")
	return fmt.tprintf("the title screen%v%v%v", dusk, ", the About page up" if h.about else "", load)
}

front_destroy :: proc(f: ^Front) {
	leave_menu(&f.menu)
}

// The whole loop. Returns when the window closes, the game quits, or the
// screenshot the harness asked for has been written.
run_game :: proc(w: ^World, f: ^Front, l: Launch) {
	if l.debug do w.debug = true
	if l.log != "" && launch_log == "" do launch_log = l.log
	log_ready(w) // the header, before anything is typed
	defer log_end(w) // the last row, however the loop ends
	// --play: the menu's Start, as a player would press it, and then the
	// script plays itself (autoplay.odin).
	auto: Autoplay
	playing_itself := l.play != ""
	if playing_itself {
		auto = autoplay_new(l.play)
		new_game(w, f.intro if f.intro != nil else f.start)
	}
	defer if playing_itself do autoplay_destroy(&auto)
	// `!title`: what the title is, for a check to read; `!title load [n]`:
	// its Load screen, and a slot picked from it.
	if title_harness.on && f.phase == .Menu do fmt.printfln("  [%v]", title_report(&f.menu))
	if title_harness.load && f.phase == .Menu do title_load_aloud(w, f, title_harness.load_row)
	frame := 0
	for !rl.WindowShouldClose() && !w.quit {
		dt := rl.GetFrameTime()
		// --play runs the world `speed` times faster, in steps no longer
		// than a sixtieth of a second: one big step would move her twenty
		// pixels at a time, into the edge of a tent's block, where a walk a
		// player makes at ordinary speed arrives.
		substeps := 1
		if playing_itself && f.phase == .Playing {
			dt *= l.speed
			substeps = max(1, int(dt * 60 + 0.999))
			dt /= f32(substeps)
		}

		// The death box's Restart. The same path as the menu's Start, so the
		// two cannot come to disagree about what a new game is.
		if w.restart {
			new_game(w, f.start)
			f.phase = .Playing
		}

		switch f.phase {
		case .Logo:
			if !splash_update(&f.logo, dt) do f.phase = .Menu
			splash_draw(&f.logo)

		case .Menu:
			// The Load screen over the title (title_load): it has the keys
			// and the mouse; the title goes on drifting and playing under it.
			loading := screen_open(w) == .Load
			f.menu.covered = loading
			chosen := update_menu(&f.menu, dt)
			if loading do screen_update(w, dt)
			last := len(f.menu.items) - 1
			switch {
			case w.restored:
				// A slot loaded: straight into it, as it was saved.
				w.restored = false
				leave_menu(&f.menu)
				f.phase = .Playing
			case chosen == 0:
				leave_menu(&f.menu)
				new_game(w, f.intro if f.intro != nil else f.start)
				f.phase = .Playing
			case chosen == last && last > 0:
				w.quit = true
			case chosen > 0:
				if f.on_menu != nil do f.on_menu(w, f, chosen)
			}
			if f.phase == .Menu do draw_menu(&f.menu, w)
			else do draw(w)

		case .Playing:
			w.restored = false // a load from the bar's screen: already playing
			for _ in 0 ..< substeps {
				if playing_itself do autoplay_step(w, &auto, dt)
				update(w, dt)
			}
			draw(w)
		}

		frame += 1
		if l.shot && frame >= l.shot_at {
			save_screenshot("shot.png")
			break
		}
		// Hidden, nobody will ever press a key: a scripted run with no shot
		// stops where the shot would have been taken, and nothing hidden runs
		// past HIDDEN_MAX_SECS (hidden.odin). --play is its own player, and
		// only the time limit stops it.
		if hidden() && !l.shot && !playing_itself && frame >= l.shot_at do break
		if hidden_overdue() do break
	}
}

// Everything the last game left behind, gone: flags, score, the notebook and
// its answers, the story clock, the play clock, a death, an overlay, a half
// typed command. The rooms stay loaded — they are files, and everything about
// them that changes during play is flags — but the people in them go back to
// the start of their routines.
//
// Accusation questions go too, and `start` asks them again. A game that asked
// them once at load would get them twice on the second game.
reset_story :: proc(w: ^World) {
	close_overlay(w)
	close_announcement(w)
	actor_stop_anim(&w.player) // and so does a gesture, and what it was for
	w.after_anim = {}
	w.exit_walk = {}
	w.peeping = {}
	clear_flags(w)
	clear_awards(w)
	w.hint = {index = -1} // a new game's hints start at the nudge (hint.odin)
	clear_notebook(w)
	clear_accusations(w)
	w.clock_ticks = 0
	w.ride = {}
	passer_cancel(w)
	clear(&w.timers)
	w.pending = ""
	stop_music(w)
	stop_bed(w)
	w.time = 0
	w.death = {}
	w.dead, w.death_box, w.restart = false, false, false
	clear_restore_points(w) // a new game's deaths go back into the new game
	w.message_until = 0
	w.input_len = 0
	w.last_noun = ""
	w.player.moving = false
	w.player.heading = {}
	for &sc in w.scenes {
		for &o in sc.objects do if o.walks do routine_restart(&o.routine)
	}
}

// The intro is over, read or skipped: the game proper, from a clean slate,
// so nothing the intro set or carried leaks into it.
begin_after_intro :: proc(w: ^World, start: proc(w: ^World)) {
	new_game(w, start)
}

// A game from the beginning: wipe it, let the game set it up, and let the
// story clock tell the world what hour it is before anybody sees a frame.
new_game :: proc(w: ^World, start: proc(w: ^World)) {
	reset_story(w)
	// The last game's light goes with its flags, before `start` runs (it may
	// play a line, and a line is seen, and logged, in the light it is in).
	relight(w)
	if start != nil do start(w)
	if w.on_clock != nil do w.on_clock(w)
	relight(w)
	refresh_world(w)
}
