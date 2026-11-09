package nengine

import "core:fmt"
import "core:os"
import "core:strings"

// The play log: every command typed, and everything the game said back.
//
//     mygame --log play.log            (or NENGINE_LOG=play.log in the environment)
//
// One row per command, as TSV, written and flushed as each one is over, so a
// crash or a closed window keeps everything up to the last command. In normal
// play, under --play and in the harness (--script) alike:
//
//     time   room   status   input   route   gap   response
//
//   time      the story clock when it was typed (HH:MM), or the play clock
//             (+M:SS) in a game without one
//   room      the scene and where she stood, `tent_row (50,612)`; `room>host`
//             while riding, `room@aperture` at a peep
//   status    World.on_status, or the light and what she carries
//   input     exactly as typed
//   route     how it was handled: `parse:unknown <word>`, `parse:no-antecedent`,
//             `answer`, `ride`, `walk`, `out-of-reach`, `peep:<object>`,
//             `object:<name>.<verb>`, `object:<name>.look` (its description),
//             `scene`, `game`, `ignored:cutscene`, `unanswered`. A walk over
//             to a thing is recorded as what happened when she got there.
//   gap       empty when the game answered on purpose; otherwise why not. The
//             engine marks its own (`unknown-word`, `no-antecedent`,
//             `talk-shrug`, `show-shrug`, `ride-refused`, `unanswered`, and
//             `silent` for a command that showed nothing at all); a game marks
//             its own fallbacks with `log_gap(w, reason)`.
//   response  every line shown because of it, until the next command: the
//             message box, a conversation's lines (`Name: text`), an
//             announcement (`Title: text`), a cutscene's lines, a peep's, a
//             card (`[card] text`), a death (`[death] reason`), joined with
//             ` / `.
//
// Lines nobody typed for — a beat at an hour, a timer, a ride's next glance —
// get a row of their own, input `(beat)`, `(timer)` or `(ride)` and route
// `story`, so the log is the whole of a session. A harness `!` line gets a row
// too, route `harness`, for what it set going.
//
// A row ends when the command has nothing more coming: no conversation,
// cutscene, announcement, walk, gesture or ride handover still under way. The
// harness ends one after each of its lines.

LOG_HEADER :: "time\troom\tstatus\tinput\troute\tgap\tresponse\n"

Play_Log :: struct {
	file:     ^os.File,
	tried:    bool, // looked for a path once; nothing to open is not looked for again
	// The row being written.
	open:     bool,
	walked:   bool, // its command set her walking: it is not over till she stops
	time:     string,
	room:     string,
	status:   string,
	input:    string,
	route:    string,
	gap:      string,
	response: strings.Builder,
	last:     string, // the last line added, so one shown twice running is one
	// Who is speaking when no command is: "(timer)" while a timer fires,
	// "(ride)" while a ride looks round by itself.
	source:   string,
}

// Where --log asked for it to go (launch_flags). A World opens it the first
// time it has something to write, or as the harness or the loop starts.
@(private)
launch_log: string

// Opens a log at `path`, starting it afresh with the header row. True if it
// could be written.
log_open :: proc(w: ^World, path: string) -> bool {
	log_close(w)
	w.log.tried = true
	f, err := os.create(path)
	if err != nil {
		fmt.eprintfln("nengine: cannot write the play log %v: %v", path, err)
		return false
	}
	w.log.file = f
	os.write_string(f, LOG_HEADER)
	os.flush(f)
	return true
}

// Finishes the row under way and closes the file.
log_close :: proc(w: ^World) {
	log_end(w)
	if w.log.file != nil do os.close(w.log.file)
	w.log.file = nil
	strings.builder_destroy(&w.log.response)
	w.log.response = {}
}

// The game's own fallback said this: a reply that is there because nothing
// better was written. `reason` is short and the same every time for the same
// kind of gap — `no-verb`, `no-object`, `talk-shrug` — so they can be counted.
// The first one marked in a row stands.
log_gap :: proc(w: ^World, reason: string) {
	if !w.log.open || w.log.gap != "" do return
	log_set(&w.log.gap, reason)
}

// A line shown to the player, for the log. The engine calls it for every
// message, line, announcement and card; a game calls it for something it
// shows itself (a score screen's line).
log_line :: proc(w: ^World, text: string) {
	if !log_ready(w) do return
	clean := log_clean(text)
	if clean == "" do return
	if !w.log.open {
		input := w.log.source if w.log.source != "" else "(beat)"
		log_begin(w, input)
		log_route(w, "story")
	}
	if clean == w.log.last do return
	log_set(&w.log.last, clean)
	if strings.builder_len(w.log.response) > 0 do strings.write_string(&w.log.response, " / ")
	strings.write_string(&w.log.response, clean)
}

// The engine's own status line: the light she sees, and what she carries.
default_status :: proc(w: ^World) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprint(&b, w.light)
	first := true
	for it in carried(w) {
		strings.write_string(&b, "; " if first else ",")
		strings.write_string(&b, it.name)
		first = false
	}
	return strings.to_string(b)
}

// --- Inside the engine ---

// The file, if there is one to write to, opened the first time it is asked.
@(private)
log_ready :: proc(w: ^World) -> bool {
	if w.log.file != nil do return true
	if w.log.tried do return false
	w.log.tried = true
	path := launch_log
	if path == "" do path = os.get_env("NENGINE_LOG", context.temp_allocator)
	if path == "" do return false
	return log_open(w, path)
}

// A row starts: a command typed, or the story speaking by itself. Whatever
// row was under way is over.
@(private)
log_begin :: proc(w: ^World, input: string) {
	if !log_ready(w) do return
	log_end(w)
	l := &w.log
	l.open = true
	l.walked = false
	log_set(&l.time, log_time(w))
	log_set(&l.room, log_room(w))
	status := w.on_status(w) if w.on_status != nil else default_status(w)
	log_set(&l.status, log_clean(status))
	log_set(&l.input, log_clean(input))
	strings.builder_reset(&l.response)
}

// How the command was handled. The last word on it stands: a walk becomes
// what was done at the end of it.
@(private)
log_route :: proc(w: ^World, route: string) {
	if !w.log.open do return
	log_set(&w.log.route, route)
}

// A command that turned out to be nothing (an empty line): no row.
@(private)
log_discard :: proc(w: ^World) {
	if !w.log.open do return
	log_free_row(w)
}

// The row is over: written, flushed, and forgotten.
@(private)
log_end :: proc(w: ^World) {
	l := &w.log
	if !l.open do return
	if l.file != nil {
		// A command that showed nothing at all is a gap of its own, unless
		// what it did was open something to read, or move a ride on.
		if l.gap == "" && strings.builder_len(l.response) == 0 && l.route != "story" && l.route != "ride" && l.route != "harness" && !overlay_open(w) {
			log_set(&l.gap, "silent")
		}
		row := fmt.tprintf("%v\t%v\t%v\t%v\t%v\t%v\t%v\n", l.time, l.room, l.status, l.input, l.route, l.gap, strings.to_string(l.response))
		os.write_string(l.file, row)
		os.flush(l.file)
	}
	log_free_row(w)
}

@(private = "file")
log_free_row :: proc(w: ^World) {
	l := &w.log
	for s in ([]^string{&l.time, &l.room, &l.status, &l.input, &l.route, &l.gap, &l.last}) do log_set(s, "")
	strings.builder_reset(&l.response)
	l.open = false
	l.walked = false
}

// Once a frame, and after anything that may have finished a row: ends it if
// nothing more is coming of it.
@(private)
log_settle :: proc(w: ^World) {
	if !w.log.open || !log_quiet(w) do return
	log_end(w)
}

// Nothing under way that would show more of this row: no conversation,
// cutscene or announcement up or due, no walk or gesture or handover, no
// first frame in a room not yet run, no beat about to start.
@(private = "file")
log_quiet :: proc(w: ^World) -> bool {
	if talking(w) || cutting(w) || announcing(w) || w.peeping.active do return false
	if approaching(w) || w.after_anim.active || w.exit_walk.active || actor_playing(&w.player) do return false
	if w.log.walked && w.player.moving do return false
	if riding(w) && w.ride.phase != .Riding do return false
	if w.dead && !w.death_box do return false
	if len(w.scenes) == 0 do return true
	if w.fresh_room && !overlay_open(w) do return false
	if announcement_due(w) != nil do return false
	if !riding(w) && !overlay_open(w) && !w.dead && beat_due(w) != nil do return false
	return true
}

// The story clock, or the play clock in a game that has none.
@(private = "file")
log_time :: proc(w: ^World) -> string {
	if w.clock_start != 0 || w.clock_step != 0 || w.clock_turns do return clock_face(clock_minute(w))
	secs := int(w.time)
	return fmt.tprintf("+%v:%02v", secs / 60, secs % 60)
}

// The scene, and whose eyes or which aperture.
@(private = "file")
log_room :: proc(w: ^World) -> string {
	if len(w.scenes) == 0 || w.current < 0 || w.current >= len(w.scenes) do return "-"
	room := current_scene(w).name
	if riding(w) do return fmt.tprintf("%v>%v", room, ride_host(w).name)
	if w.peeping.active do return fmt.tprintf("%v@%v", room, w.peeping.object)
	// Where she stood when she typed it: what tells a walk that failed in a
	// window from one that worked in the harness.
	return fmt.tprintf("%v (%v,%v)", room, int(w.player.pos.x), int(w.player.pos.y))
}

// A field of the row: its own copy of the words, and the old one freed. Only
// ever a copy is kept, so an empty one is the only kind that was never made.
@(private = "file")
log_set :: proc(field: ^string, value: string) {
	if len(field^) > 0 do delete(field^)
	field^ = strings.clone(value) if value != "" else ""
}

// One line of a TSV field: no tabs, no newlines, plain text.
@(private = "file")
log_clean :: proc(text: string) -> string {
	out := plain_text(text)
	if strings.index_any(out, "\t\n\r") < 0 do return strings.trim_space(out)
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)out {
		switch c {
		case '\t', '\n', '\r': strings.write_byte(&b, ' ')
		case: strings.write_byte(&b, c)
		}
	}
	return strings.trim_space(strings.to_string(b))
}
