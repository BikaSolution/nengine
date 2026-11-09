package nengine

import rl "vendor:raylib"

// Everything the engine runs: all the scenes, which one we're in, and the
// player, who carries over from scene to scene. Keeping it all in one struct
// also means hot reloading can be added later without a rewrite.
World :: struct {
	scenes:        [dynamic]Scene,
	current:       int,
	player:        Actor,

	vocab:         []Word,
	on_command:    proc(w: ^World, cmd: Command), // runs when the scene's on_command doesn't

	// What to say when a sentence does not parse. True if the game answered;
	// false, or nil, and the engine says something correct in nobody's voice.
	// A finished game answers every one of these itself — a reply the player
	// reads twenty times is characterisation whether you wrote it or not.
	on_parse_error: proc(w: ^World, err: Parse_Error, bad: string) -> bool,

	// A short line of the game's own state for the play log: the act, what she
	// carries, whose company she is in. nil, and the engine says the light and
	// what she carries (default_status). See playlog.odin.
	on_status:      proc(w: ^World) -> string,
	// The play log being written, if --log asked for one. See playlog.odin.
	log:            Play_Log,

	// A line of the game's own state for the F1 overlay: the hour, which act
	// it thinks it is, how drunk somebody is. Returned as a string rather than
	// drawn, so there is only ever one debug layer to remember to turn off.
	on_debug_text:  proc(w: ^World) -> string,

	// Everybody who speaks, for the talk files to name. See talk.odin.
	speakers:        []^Speaker,
	topics:          [dynamic]Topic,
	topic_talk:      Conversation,
	on_topic:        proc(w: ^World, action: string), // a topic's action=, by name

	// A question the player answers with whatever they type next. See talk.odin.
	pending:         string,
	on_answer:       proc(w: ^World, question: string, cmd: Command) -> bool,

	// Seconds of real time until something happens. See timer.odin.
	timers:          [dynamic]Timer,

	// What can be carried, and (as flags) what is. See inventory.odin.
	items:           []Item,

	// Things that happen at an hour, in a room, once. See beat.odin.
	beats:           []Beat,

	// A discovery that stops the game: a close-up and a big box, the first
	// time the player is in a room while it holds. See announce.odin.
	announcements:   []Announcement,
	announcing:      ^Announcement,
	announced_at:    f32,
	beat_talk:       Conversation,

	// Light: day, sunset, night or sunrise, and each room painted for it.
	// See light.odin. `light` is what the player sees, latched outdoors;
	// `on_light_now` is the game's: what the light is by its clock;
	// `light_tint` is the game's: the palette map for whatever in a room was
	// not painted for its light — people, and a painting not yet made.
	light:           Light,
	on_light_now:    proc(w: ^World) -> Light,
	light_tint:      proc(w: ^World, scene: ^Scene, light: Light) -> Palette_Map,

	// Walked into a room, through one of its exits. The game's chance to start
	// whatever happens when somebody comes in: a talk already under way, a
	// dog that gets up. Not called by go_to, which restores and cutscenes use
	// too, and which should not set a scene off twice.
	on_arrive:       proc(w: ^World),

	// Walking over to do something. See approach.odin. `far_verbs` are the
	// ones done from where the player stands — {"look"} when nil. The hook
	// says, in the game's voice, that a thing is out of reach; true if it did.
	far_verbs:       []string,
	on_out_of_reach: proc(w: ^World, o: ^Object, why: Out_Of_Reach) -> bool,
	approach:        Approach,
	// The command an object's bound action is running for. See run_interaction.
	cmd:             Command,
	// A verb waiting for the player to finish a gesture: TAKE CUP with
	// `anim=pick_up` plays the reach first and takes the cup at the end of it.
	// See anim.odin.
	after_anim:      After_Anim,
	// On her way to an exit's `at`, to go through it as something she does.
	exit_walk:       Exit_Walk,
	// Just arrived: the next check_triggers fires any trigger that covers the
	// whole floor, wherever she stands in it. See check_triggers.
	fresh_room:      bool,

	// Peeps: what is said at each aperture and when, and the game's words for
	// the outcomes it does not play. See peep.odin.
	peep_windows:    []Peep_Window,
	on_peep:         proc(w: ^World, o: ^Object, outcome: Peep_Outcome),
	peeping:         Peep_State,
	peep_talk:       Conversation,
	peep_caught_by:  string, // the last catch, for the harness: who
	peep_caught_at:  int,    // and at which line
	peep_lines:      [dynamic]Talk_Line, // a blind window's lines, with faceless speakers
	// `!leave n` in the harness: the next conversation it reads out is left
	// (Escape) on its nth line. 0 is none. See script.odin.
	script_leave_after: int,
	// `!hold <words>`: the next conversation the harness reads out stops on
	// the first line with these words in it (or on the nth line) and stays up,
	// for a --shot of it. `script_held` is that line, still up. See script.odin.
	script_hold:     string,
	script_held:     bool,

	// Dialogue nodes, read from the writers' files, played by id. See nodes.odin.
	nodes:           map[string]Node,
	node_talk:       Conversation,
	node_end:        proc(w: ^World),
	node_sets:       []string,
	node_lines:      [dynamic]Talk_Line, // the telling being played
	on_node:         proc(w: ^World, n: ^Node), // a node starts: award what it `gives`, note what it says
	bark_next:       map[string]int,     // where each list of barks has got to (bark, nodes.odin)
	peep_voices:     [8]Speaker,          // and the speakers

	// What the player last talked about, which is what "it" means. Borrowed
	// from the vocabulary, which outlives every command.
	last_noun:     string,

	// Saving. See save.odin. `save_name` is the folder a game's saves live in
	// under the user's data directory — or, if it has a slash in it, the
	// folder itself. The two hooks are how a game puts its own state into a
	// save and takes it out again.
	save_name:     string,
	on_save:       proc(w: ^World, s: ^Save),
	on_load:       proc(w: ^World, s: ^Save),
	// Which world a save belongs to. 0, and saves carry no version and any
	// loads; otherwise a save of another version is refused, and `old_save`
	// says that was why. See save.odin.
	save_version:  int,
	old_save:      bool,

	// Score. The game declares every award once so that "45 of 250" is known
	// from the first minute; `earned` is what has actually been found, and
	// when. See score.odin.
	awards:        []Award,
	earned:        map[string]f32,
	earned_minute: map[string]int, // the story clock when each was found
	// The hint book: what the game says she could do next, and which of its
	// entries is up and how plainly. See hint.odin.
	hints:         []Hint,
	hint:          Hint_Shown,

	// The story clock: what hour the fiction has reached, as opposed to `time`,
	// which is how long the player has been at the keyboard. The game sets
	// where it starts and what a tick is worth; the engine keeps the count and
	// saves it. `on_clock` is the game's: what the hour does to the world. See
	// clock.odin.
	clock_start:    int,
	clock_step:     int,
	clock_ticks:    int,
	clock_paces:    []Clock_Pace,
	clock_held:     string, // a condition: while it holds, a tick spends nothing
	// A tick is a turn: the clock runs on to the next change in the world,
	// at most `clock_turn_max` minutes. Set `clock_step` to 1 with it, so the
	// clock counts minutes underneath. See clock.odin, `turn`.
	clock_turns:    bool,
	clock_turn_max: int,
	// Every new entry in the notebook spends a tick — a clue is progress, and
	// progress is what time is made of — but no command spends more than one
	// that way: three lines about one discovery are one discovery. `ticked`
	// is whether the command being run has spent any time yet.
	notes_tick:     bool,
	ticked:         bool,
	// Played, by name, as a new entry goes in: a pen on paper. Not on a
	// restore, which writes the whole book back at once.
	note_sound:     string,
	on_clock:       proc(w: ^World),

	// The notebook: what the player has written down. The game declares the
	// tabs and which entries contradict each other; the engine keeps the
	// entries, the order and the answers. See notebook.odin.
	notebook_tabs:  []Notebook_Tab,
	contradictions: []Contradiction,
	notebook:       [dynamic]Entry,
	notebook_seq:   int,
	accusations:    [dynamic]Accusation,

	// Named story state: "act3", "found_body". Nothing in the engine sets one
	// or knows what it means; what they do is decide which parts of a scene
	// exist right now. See flags.odin.
	flags:         map[string]bool,

	// Seeing through something else's eyes. See ride.odin. The game declares
	// the hosts; `on_ride_command` is what it says to anything but WAIT and
	// coming back, and `on_ride_end` is her coming round.
	hosts:           []Host,
	ride:            Ride,
	on_ride_command: proc(w: ^World, cmd: Command) -> bool,
	on_ride_end:     proc(w: ^World, h: ^Host, broke_off: bool),

	// What is holding the screen, if anything. See Overlay above.
	overlay:        Overlay,
	// The menu bar along the top, and the engine's screens it opens (Save,
	// Load, the things she carries, a small menu) with the game's words for
	// them. See menubar.odin and screens.odin.
	bar:            Menu_Bar,
	screen:         Screen,
	screen_words:   Screen_Words,

	// The game's own state, if it would rather not keep it in a global. The
	// engine never touches it; it only carries it, so that a callback with
	// nothing but a ^World can still find the thing it needs to change.
	user:          rawptr,

	time:          f32,
	debug:         bool, // F1 toggles it
	quit:          bool, // the game should end: set by QUIT, or the death box
	restart:       bool, // the game should start over: set by the death box
	restored:      bool, // a slot was just loaded from the Load screen: the title (launch.odin) goes to play
	shake:         f32,  // seconds of screen shake left. See shake().

	// The prompt and the message box. See prompt.odin.
	input:         [48]u8,
	input_len:     int,
	last_input:    [48]u8,
	last_len:      int,
	message_buf:   [600]u8,
	message_len:   int,
	message_until: f32,
	message_mode:  Message_Mode,
	message_who:   ^Speaker, // whose portrait sits beside the box
	// Who is saying it, when the box shows no face for them: a voice through
	// a wall, somebody in a close-up, somebody whose face is not drawn. The
	// comic look (look.odin) names them over their balloon.
	message_speaker: ^Speaker,

	// How this game's boxes look. Set them once at startup; leave them and
	// you get the plain ones. See textbox.odin.
	narration_style: Maybe(Box_Style),
	speech_style:    Maybe(Box_Style),
	thought_style:   Maybe(Box_Style),
	prompt_style:    Maybe(Box_Style),

	// A conversation in progress, if any. See conversation.odin.
	talk:          ^Conversation,

	// Exits. See check_exits.
	exit_grace:    bool,
	bumped:        bool,
	exit_passed:   bool,      // stood in one a walk to somewhere else crossed
	door_walk:     Door_Walk, // the one exit a walk means to go through

	// The harness's (edge.odin's walked_aloud): the last edge gone over, by
	// name, and the last side crossed. Each world's own, not the package's:
	// tests run side by side, each with its own world, and a package global
	// is all of theirs at once.
	stepped_over:  string,
	crossed:       Maybe(Compass),

	// The game's gates: every side and exit that names one is shut while it
	// is, in every room at once. Set before the rooms are loaded. And who
	// walked off through a side in the last cutscene, for the next one to
	// bring on. See side.odin.
	gates:         []Gate,
	cut_handoff:   [dynamic]Cut_Handoff,
	// The game's keep-outs: a room shut from every side and door for a window
	// on the story clock, with a line; the room the developer was let into
	// anyway (TELEPORT, `!room`); and whether she has said she is going. See
	// keep_out.odin.
	keep_outs:      []Keep_Out,
	keep_out_let:   string,
	keep_out_going: bool,
	// True while set_flag refreshes the rooms: a person whose `when=` turns
	// then, in the room she is in, walks off or on through a side.
	flag_live:     bool,

	// Sound. See audio.odin.
	key_sound:     rl.Sound,
	audio_scene:   int,
	audio_started: bool,
	audio_loop:    ^Loop, // the ambience playing now: a flag can change it mid-room

	// The game's sounds by name, for play_sound and play_music; and the music
	// playing now, over the room. See audio.odin.
	assets:        ^Assets,
	music:         ^Loop,
	music_name:    string,
	// A bed under every room (play_bed): its own stream, so a room that
	// plays the same sound as its ambience never stops it. See audio.odin.
	bed:           Loop,
	bed_name:      string,
	bed_volume:    f32,
	// The last sounds play_sound was asked for, oldest first, for the
	// harness's `!sound`. Kept short: nothing reads it in play.
	heard:         [dynamic]Heard,

	// A cutscene playing in the room, in the middle of play: see play_cutscene
	// in cutscene.odin. `player_name` is the cast name that means the player
	// in one; empty, and it is whoever's .char she is wearing.
	cut:           Cutscene_Player,
	player_name:   string,

	// Dying. See death.odin.
	death:         Death,
	dead:          bool, // a death is playing, or its box is up
	death_box:     bool, // the box is up
	death_time:    f32,
	death_pick:    Death_Choice,
	// Restore points, by name: each a save kept in memory, for a death that
	// names one to go back to. See save.odin.
	restore_points: map[string]string,

	// Somebody going past outside a window, now and then: something seen,
	// nothing more. See passer.odin.
	passer:         Passer_State,

	// The developer's TELEPORT and TIMETRAVEL, behind --dev: the game's
	// words for its rooms and its day. See dev.odin.
	dev:            Dev,

	// Who has been called into sight to speak to her, and the game's word on
	// which lines are voices off. See sight.odin.
	sight:          Sight,
}

destroy_world :: proc(w: ^World) {
	log_close(w)
	clear_world(w)
	clear_restore_points(w)
	delete(w.peep_lines)
	delete(w.script_hold)
	nodes_destroy(w)
	delete(w.node_lines)
	clear_flags(w)
	clear_awards(w)
	clear_notebook(w)
	clear_accusations(w)
	delete(w.notebook)
	delete(w.accusations)
	delete(w.scenes)
	stop_bed(w)
	stop_music(w)
	forget_heard(w)
	delete(w.heard)
	clear_cut_handoff(w)
	delete(w.sight.called)
	delete(w.sight.off)
	w.sight.called, w.sight.off = nil, nil
	delete(w.cut_handoff)
}

// Empties the world, ready for a new game: removes every scene and forgets
// messages, deaths and what was typed. Keeps the vocabulary, the command
// handlers, and the player's sprites and sounds. The game then adds its
// scenes again and puts the player somewhere.
clear_world :: proc(w: ^World) {
	if w.audio_started && w.audio_scene < len(w.scenes) do stop_scene_audio(&w.scenes[w.audio_scene])
	cutscene_stop(&w.cut) // its room is about to go
	for &s in w.scenes {
		if s.from_file do free_scene_strings(&s)
		for &o in s.objects do routine_destroy(&o.routine)
		delete(s.objects)
		delete(s.said)
		delete(s.exits)
		delete(s.triggers)
		delete(s.edges)
		delete(s.sides)
		delete(s.windows)
		if s.from_file {
			delete(s.walk_area)
			delete(s.scenery)
		}
		if s.debug_mask.id != 0 do rl.UnloadTexture(s.debug_mask)
		scene_maps_destroy(&s)
	}
	clear(&w.scenes)
	topics_destroy(w)
	delete(w.timers)
	w.timers = nil

	w.current = 0
	w.player.moving = false
	w.player.walking = false
	w.player.heading = {}
	w.approach = {}
	w.player.facing_left = false
	w.player.facing = .Right
	w.input_len = 0
	w.message_until = 0
	w.exit_grace = false
	w.bumped = false
	w.exit_passed = false
	w.door_walk = {}
	w.audio_started = false
	w.death = {}
	w.dead = false
	w.death_box = false
	w.restart = false
	w.shake = 0
}

current_scene :: proc(w: ^World) -> ^Scene {
	return &w.scenes[w.current]
}

// A room by name. Games should say which room they mean rather than which
// number it happened to be loaded as — the same reason exits go by name.
scene_index :: proc(w: ^World, name: string) -> (int, bool) {
	for sc, i in w.scenes do if sc.name == name do return i, true
	return 0, false
}

scene_named :: proc(w: ^World, name: string) -> ^Scene {
	if i, ok := scene_index(w, name); ok do return &w.scenes[i]
	return nil
}

// Put the player in another scene.
go_to :: proc(w: ^World, scene: int, arrive: [2]f32) {
	from: ^Scene = current_scene(w) if w.current >= 0 && w.current < len(w.scenes) && w.current != scene else nil
	// Nobody walks in a room nobody watches: whoever was going off or coming
	// on in the room she leaves is put where they were going; and whoever a
	// routine walked off from the room she enters is back (side.odin).
	if from != nil do people_settle(from)
	sight_clear(w) // whoever was called to her stays in that room's frame
	for &o in w.scenes[scene].objects do o.away = false
	w.current = scene
	if from != nil do refresh_scene(w, from) // a person called back, settled: gone or not, as their line says
	follow_light(w, from, &w.scenes[scene])
	refresh_scene(w, &w.scenes[scene])
	w.player.pos = arrive
	w.player.moving = false
	w.player.heading = {}
	w.exit_grace = true
	w.exit_passed = false
	w.door_walk = {} // its door was that room's
	cancel_approach(w) // what was over there is not in this room
	w.fresh_room = true // a trigger over the whole floor fires on the first frame
	actor_stop_anim(&w.player)
	w.after_anim = {}
	w.exit_walk = {}
	passer_enter(w) // whoever was going past the last room's window has gone; perhaps somebody here
}

// Something holding the screen over the world: a notebook, a map, a case of
// belongings laid out on a bed. Drawing it and working it are the game's; the
// engine's part is to stop the world underneath while it is up — nobody walks,
// nothing is typed at the prompt, the routines wait — and to draw it last.
//
//     ne.open_overlay(w, {update = notebook_update, draw = notebook_draw})
//
// `update` returns false to close. Esc is not handled for you: a notebook
// might want Esc to back out of a page before it closes, and only the game
// knows that.
Overlay :: struct {
	update: proc(w: ^World, dt: f32) -> (keep_open: bool),
	draw:   proc(w: ^World),
}

open_overlay :: proc(w: ^World, o: Overlay) {
	// One of the engine's screens gives way to an overlay of the game's.
	if o.update != screen_update do screen_forget(w)
	w.overlay = o
	// Whatever was being typed stays where it was. Clearing it would lose a
	// half-written command; leaving the keys queued would type them into it
	// when the overlay closes. So the queue is emptied and the line is kept.
	for rl.GetCharPressed() != 0 {}
}

close_overlay :: proc(w: ^World) {
	w.overlay = {}
	screen_forget(w)
	for rl.GetCharPressed() != 0 {}
}

overlay_open :: proc(w: ^World) -> bool {
	return w.overlay.update != nil
}

update :: proc(w: ^World, dt: f32) {
	// Whatever the frame did, the command's row in the play log ends once
	// nothing more is coming of it (playlog.odin).
	defer log_settle(w)
	// Before the play clock moves: reading the notebook is not playing, and
	// the people in the room are on routines keyed to that clock, so if it ran
	// on under an overlay they would all jump when it closed.
	if overlay_open(w) {
		if !w.overlay.update(w, dt) do close_overlay(w)
		// Keys the overlay did not read must not reach the prompt afterwards.
		for rl.GetCharPressed() != 0 {}
		update_audio(w)
		return
	}

	w.time += dt
	w.shake = max(w.shake - dt, 0)
	hold_deadlines(w, dt)
	if !w.dead do run_timers(w)
	if !w.dead do update_passer(w, dt) // something seen, whatever else holds the frame
	if rl.IsKeyPressed(.F1) do w.debug = !w.debug

	if w.dead {
		update_death(w, dt)
		if !w.death_box do update_audio(w)
		return
	}

	// An announcement already up holds even a cutscene: the game opened it
	// (announce_now) as the cut that brought her there started, and the body
	// comes before anybody speaks about it. None opens while one plays.
	if w.announcing != nil && update_announcement(w) {
		update_audio(w)
		return
	}

	// A cutscene holds it: nobody at the controls, the clock still, Escape
	// to skip to the end. See cutscene.odin.
	if update_cutscene(w, dt) {
		update_audio(w)
		return
	}

	// An announcement holds it first: the body before anybody speaks about it.
	if update_announcement(w) {
		update_audio(w)
		return
	}

	// A conversation holds the screen: no typing, no walking, no clicking
	// somewhere else. The player reads, and presses on.
	if update_conversation(w) {
		update_audio(w)
		return
	}

	// The screen is hers again: whoever came to say their lines goes, and
	// whoever she stopped goes on (sight.odin).
	sight_release(w)
	update_prompt(w)

	// A passenger does not walk. See ride.odin.
	if riding(w) {
		update_ride(w, dt)
		update_audio(w)
		return
	}

	// Anything due at this hour, in this room. See beat.odin.
	if play_beats(w) {
		update_audio(w)
		return
	}

	// A room the story has just shut on her: she says so and walks out of it
	// (keep_out.odin).
	keep_out_step(w)

	scene := current_scene(w)

	// The people in the room get on with what they are doing whether or not
	// the player is watching. See routine.odin. Nobody walks through anybody
	// (priority.odin): where she is, first.
	people_frame(w)
	update_people(w, scene, dt)
	sight_update(w, dt) // the called walking off (sight.odin)

	p := &w.player
	before := p.pos
	// In the middle of a gesture, the player's hands are busy: clicking and
	// the arrow keys wait until it is done. Typing does not.
	busy := actor_playing(p)

	// Clicking walks, unless the click was on the menu bar, which also has
	// its keys. Doing things is for the parser. See menubar.odin.
	if menu_bar_frame(w, dt, busy) {
		update_audio(w)
		return
	}

	// Arrow keys and the numpad, Sierra style: tap one to start walking that
	// way, tap it again to stop. Numpad 5 stops too. Walking also stops when
	// something's in the way, on a click, and in a new scene. (Not WASD: those
	// letters belong to the prompt.)
	//     7 8 9
	//     4 5 6
	//     1 2 3
	if dir, ok := direction_tapped(); ok && !busy {
		cancel_approach(w)
		w.exit_walk = {}
		w.door_walk = {}
		p.moving = false
		p.heading = {} if p.heading == dir else dir
	}
	if rl.IsKeyPressed(.KP_5) do p.heading = {}

	arrived := false
	if p.heading != {0, 0} {
		walk_heading(w, dt) // and over an edge, if there is one ahead (edge.odin)
	} else {
		arrived = actor_follow_target(p, dt, scene)
	}
	approach_step(w, arrived)
	// At the brink, after a click on the water: over (edge.odin).
	if edge_walk_step(w) {
		update_audio(w)
		return
	}
	// At the brink of a side, after a click or GO NORTH: across (side.odin).
	if side_walk_step(w) {
		update_audio(w)
		return
	}

	actor_tick(p, dt, before)
	if busy && !actor_playing(p) do run_after_anim(w)
	exit_walk_step(w)
	// Mid-climb she is standing in the exit: it is already being gone
	// through, and must not fire again under her.
	if actor_playing(p) || w.exit_walk.active {
		update_audio(w)
		return
	}
	if !check_triggers(w, before) do check_exits(w)
	update_audio(w)
}

// Runs the on_enter of any trigger the player has just stepped into.
check_triggers :: proc(w: ^World, before: [2]f32) -> (fired: bool) {
	// The first frame in a room: a trigger over the whole floor is the room
	// itself being walked into (bodies on a deck, a man at a post), wherever
	// the door put her. Other triggers still wait to be stepped into.
	if w.fresh_room {
		w.fresh_room = false
		sc := current_scene(w)
		for t in sc.triggers {
			if t.hidden || t.on_enter == nil || !whole_floor(sc, t.area) do continue
			t.on_enter(w)
			return true
		}
	}
	for t in current_scene(w).triggers {
		if t.hidden || t.on_enter == nil do continue // its `when=` is false, or nothing is bound to it
		if in_rect(w.player.pos, t.area) && !in_rect(before, t.area) {
			t.on_enter(w)
			return true
		}
	}
	return false
}

// A walk that means to go through one exit: GO TO it, ENTER it, a click in
// its doorway (head_for_exit, click_walk). Good while she is walking to
// `spot`, and stood where that walk ended; sent anywhere else, it is off.
Door_Walk :: struct {
	active: bool,
	exit:   string, // by name; the string is the scene's
	spot:   [2]f32, // where the walk ends
}

// Stepping into an open exit's area on purpose takes you through it.
// Stepping into a closed one, on purpose, shows its closed_text, once.
//
// On purpose, as in Sierra's games, is any of:
//
//   - a walk that means to go through it: GO TO it, ENTER it, GO EAST or GO
//     TO <room> when it is the way, a click in its doorway or on the door
//     above the floor's edge, GO TO or ENTER a thing whose spot is in its
//     doorway (`door_walk`);
//   - the arrow keys, walking her into it;
//   - being put in it, by the game or the harness, and standing there.
//
// A walk to somewhere else — a click on the floor beyond the door, an
// approach to a thing or a person, GO NORTH to a side — crosses an exit's
// patch and carries on; stopping in one is standing in a doorway, and she is
// through it only after stepping out and back in, or GO TO it. So a door on
// a yard's walking line is passed, not gone through.
//
// After arriving in a scene, exits stay quiet until the player has stepped
// out of every exit area, so arriving in a doorway doesn't bounce you back.
check_exits :: proc(w: ^World) -> (went: bool) {
	inside_any := false
	for e in current_scene(w).exits {
		if e.hidden do continue // its `when=` is false: not a way out right now
		if !in_rect(w.player.pos, e.area) do continue
		inside_any = true
		if w.exit_grace do continue
		// Walked onto on the way somewhere else: passed, not gone through.
		if !walking_through(w, e.name) && (w.exit_passed || passing_over(w)) {
			w.exit_passed = true
			continue
		}

		if e.closed {
			text := e.closed_text
			if g := gate_named(w, e.gate); text == "" && g != nil do text = g.text
			if !w.bumped && text != "" do say(w, text)
			w.bumped = true
			continue
		}
		// Into a room the story keeps her out of for now: told, as a shut
		// door tells her (keep_out.odin).
		if k := kept_out(w, e.to); k != nil {
			if !w.bumped && k.text != "" do say(w, k.text)
			w.bumped = true
			continue
		}
		// Walked into it while it was shut: opening it doesn't carry you
		// through. Stepping out and back in does, and so does head_for_exit.
		if w.bumped do continue
		// Through it as something she does: walk to the spot, do it, and the
		// room changes at the end. A part nobody has drawn is no part at all.
		if e.anim != "" && actor_part_secs(&w.player, e.anim) > 0 {
			start_exit_anim(w, e)
			return true
		}
		go_to(w, e.to, e.arrive)
		if w.on_arrive != nil do w.on_arrive(w)
		play_arrival(w, e.arrive_anim)
		return true
	}
	if !inside_any {
		w.exit_grace = false
		w.bumped = false
		w.exit_passed = false
	}
	return false
}

// On a walk that means to go through this exit (Door_Walk), or stood where
// it ended.
@(private)
walking_through :: proc(w: ^World, name: string) -> bool {
	d := w.door_walk
	return d.active && d.exit == name && w.player.target == d.spot
}

// A walk to `spot` that means to go through the exit whose doorway holds it,
// if one does (approach.odin: GO TO, ENTER a door).
@(private)
aim_for_door :: proc(w: ^World, scene: ^Scene, spot: [2]f32) {
	for e in scene.exits {
		if e.hidden || !in_rect(spot, e.area) do continue
		w.door_walk = {active = true, exit = e.name, spot = spot}
		return
	}
}

// On a walk somewhere (a click, an approach, a side's brink), or stood where
// one ended. Not the arrow keys, which take her wherever she is pointed; and
// not standing where the game or the harness put her.
@(private)
passing_over :: proc(w: ^World) -> bool {
	p := &w.player
	return p.heading == {} && (p.moving || p.pos == p.target)
}

// Walk the player to the exit with this name, and through it on getting
// there (check_exits). False if there isn't one here.
head_for_exit :: proc(w: ^World, name: string) -> bool {
	scene := current_scene(w)
	for e in scene.exits {
		if e.name != name || e.hidden do continue
		spot := clamp_to_polygon(rect_center(e.area), scene.walk_area)
		walk_to(&w.player, spot)
		w.door_walk = {active = true, exit = e.name, spot = spot}
		// Already standing in it: let it fire (or say it's closed) again.
		if in_rect(w.player.pos, e.area) {
			w.exit_grace = false
			w.bumped = false
			w.exit_passed = false
		}
		return true
	}
	// Or a side by its `name=` (side.odin).
	for s, i in scene.sides {
		if s.name != "" && s.name == name && !s.hidden do return head_for_side_at(w, i)
	}
	return false
}

// Close enough to touch? True when the player's feet are inside the object's
// reach shape. Objects without one fall back to "within 24 pixels of walk_to".
near :: proc(w: ^World, o: ^Object) -> bool {
	if o == nil do return false
	if o.reach.kind != .None do return in_shape(o.reach, o.pos, w.player.pos)
	return length(w.player.pos - o.walk_to) <= 24
}

@(private)
DIAGONAL :: 0.7071 // so walking diagonally isn't faster than walking straight

// The walking direction for whichever arrow or numpad key was just pressed.
@(private)
direction_tapped :: proc() -> (dir: [2]f32, ok: bool) {
	keys := [?]struct {
		key: rl.KeyboardKey,
		dir: [2]f32,
	} {
		{.UP, {0, -1}}, {.DOWN, {0, 1}}, {.LEFT, {-1, 0}}, {.RIGHT, {1, 0}},
		{.KP_8, {0, -1}}, {.KP_2, {0, 1}}, {.KP_4, {-1, 0}}, {.KP_6, {1, 0}},
		{.KP_7, {-DIAGONAL, -DIAGONAL}}, {.KP_9, {DIAGONAL, -DIAGONAL}},
		{.KP_1, {-DIAGONAL, DIAGONAL}}, {.KP_3, {DIAGONAL, DIAGONAL}},
	}
	for k in keys {
		if rl.IsKeyPressed(k.key) do return k.dir, true
	}
	return {}, false
}

// Is any numpad digit held? Then the digits it types are for walking, not
// for the prompt.
@(private)
numpad_down :: proc() -> bool {
	for k in rl.KeyboardKey.KP_0 ..= rl.KeyboardKey.KP_9 {
		if rl.IsKeyDown(k) do return true
	}
	return false
}

// Does this patch cover the room's whole floor? Every corner of the walk area
// inside it; a room with no floor drawn is covered by the whole canvas.
@(private)
whole_floor :: proc(sc: ^Scene, area: rl.Rectangle) -> bool {
	if len(sc.walk_area) == 0 do return area.x <= 0 && area.y <= 0 && area.x + area.width >= f32(WIDTH) && area.y + area.height >= f32(HEIGHT)
	for p in sc.walk_area {
		if p.x < area.x || p.y < area.y || p.x > area.x + area.width || p.y > area.y + area.height do return false
	}
	return true
}
