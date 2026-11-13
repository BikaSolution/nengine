package nengine

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// Saving and restoring.
//
// A save is a text file, like everything else here — `key value` a line, so a
// broken save can be read, diffed and fixed by hand rather than being an
// opaque brick. It diffs well, which matters when a save stops loading and
// you want to know what changed.
//
// Ten slots:
//
//   AUTOSAVE           written whenever the game says so
//   AUTOSAVE_PREVIOUS  the one before that, kept automatically
//   1 to 8             the player's own, overwritten as they like
//
// The autosave rolls: every `autosave` moves the old one down to
// AUTOSAVE_PREVIOUS first, so a game that autosaves on entering a room always
// leaves one step further back to go to. Without that, autosaving on the way
// into the trap overwrites the only save from before the trap.
//
// The engine saves what the engine owns: which scene, where the player is
// standing, which way they face, the clock, what "it" refers to. Everything
// else is the game's, and the game puts it in and takes it out through two
// hooks. The engine has no idea what a game's flags mean and does not try.
//
//     w.save_name = "my-game"     // the folder saves live in
//     w.on_save   = write_my_state
//     w.on_load   = read_my_state
//
//     write_my_state :: proc(w: ^ne.World, s: ^ne.Save) {
//         ne.save_put_bool(s, "has_key", state.has_key)
//         ne.save_put_int(s, "lucidity", state.lucidity)
//     }
//     read_my_state :: proc(w: ^ne.World, s: ^ne.Save) {
//         state.has_key  = ne.save_bool(s, "has_key")
//         state.lucidity = ne.save_int(s, "lucidity", 100)
//     }

SAVE_SLOTS :: 8

// The two slots that aren't the player's. Negative so they can't be confused
// with a numbered one, and so `for slot in 1..=SAVE_SLOTS` means what it says.
AUTOSAVE :: -1
AUTOSAVE_PREVIOUS :: -2

// One save, in memory. A game only ever sees this inside its two hooks.
Save :: struct {
	values: [dynamic]Save_Value,
}

Save_Value :: struct {
	key:  string,
	text: string,
}

save_destroy :: proc(s: ^Save) {
	for v in s.values {
		delete(v.key)
		delete(v.text)
	}
	delete(s.values)
	s^ = {}
}

// --- What a game puts in and takes out ---

save_put :: proc(s: ^Save, key, value: string) {
	// One entry per key: writing twice replaces rather than appends, so a
	// save file never has two answers to the same question.
	for &v in s.values do if v.key == key {
		delete(v.text)
		v.text = strings.clone(value)
		return
	}
	append(&s.values, Save_Value{strings.clone(key), strings.clone(value)})
}

save_put_int :: proc(s: ^Save, key: string, value: int) {
	save_put(s, key, fmt.tprintf("%v", value))
}

save_put_f32 :: proc(s: ^Save, key: string, value: f32) {
	save_put(s, key, fmt.tprintf("%v", value))
}

save_put_bool :: proc(s: ^Save, key: string, value: bool) {
	save_put(s, key, "true" if value else "false")
}

// The stored text, or `fallback`. Borrowed from the save, which lives as long
// as the hook that is reading it.
save_text :: proc(s: ^Save, key: string, fallback := "") -> string {
	for v in s.values do if v.key == key do return v.text
	return fallback
}

save_has :: proc(s: ^Save, key: string) -> bool {
	for v in s.values do if v.key == key do return true
	return false
}

save_int :: proc(s: ^Save, key: string, fallback := 0) -> int {
	if v, ok := strconv.parse_int(save_text(s, key)); ok do return v
	return fallback
}

save_f32 :: proc(s: ^Save, key: string, fallback: f32 = 0) -> f32 {
	if v, ok := strconv.parse_f32(save_text(s, key)); ok do return v
	return fallback
}

save_bool :: proc(s: ^Save, key: string, fallback := false) -> bool {
	switch save_text(s, key) {
	case "true", "1", "yes": return true
	case "false", "0", "no": return false
	}
	return fallback
}

// --- Writing and reading a slot ---

// Writes the world, and whatever the game adds, into `slot` (1..SAVE_SLOTS,
// or AUTOSAVE). `title` is what a save menu will show; "" uses the scene's
// name, which is better than nothing and usually enough.
save_game :: proc(w: ^World, slot: int, title := "") -> bool {
	dir := save_dir(w)
	if dir == "" || !make_dirs(dir) do return false

	s: Save
	defer save_destroy(&s)
	save_world(w, &s, title)
	return write_data_file(save_path(w, slot), save_text_of(&s))
}

// Everything a save holds, into `s`: the engine's own state, then the game's
// through `on_save`. A slot and a restore point are the same save.
@(private)
save_world :: proc(w: ^World, s: ^Save, title: string) {
	// What the engine owns. The scene goes in by name: a save that survives
	// the scenes being reordered is worth the lookup.
	scene := current_scene(w)
	save_put(s, "title", title if title != "" else scene.name)
	save_put(s, "when", now_text())
	if w.save_version != 0 do save_put_int(s, "version", w.save_version)
	save_put_f32(s, "played", w.time)
	save_put(s, "scene", scene.name)
	save_put(s, "x", fmt.tprintf("%v", int(w.player.pos.x)))
	save_put(s, "y", fmt.tprintf("%v", int(w.player.pos.y)))
	save_put(s, "facing", facing_text(w.player.facing))
	if w.last_noun != "" do save_put(s, "last_noun", w.last_noun)
	if f := flags_text(w); f != "" do save_put(s, "flags", f)
	if e := earned_text(w); e != "" do save_put(s, "earned", e)
	save_put_int(s, "score", score(w))
	save_put_int(s, "clock", w.clock_ticks)
	notebook_save(w, s)
	ride_save(w, s)

	if w.on_save != nil do w.on_save(w, s)
}

// Rolls the autosave and writes a new one. Call it where the game reaches a
// point worth coming back to: a room entered, a chapter turned, a body found.
autosave :: proc(w: ^World, title := "") -> bool {
	dir := save_dir(w)
	if dir == "" do return false
	// The old autosave becomes the previous one first, so there is always a
	// step further back than the last thing that happened.
	if os.exists(save_path(w, AUTOSAVE)) {
		prev := save_path(w, AUTOSAVE_PREVIOUS)
		os.remove(prev)
		if os.rename(save_path(w, AUTOSAVE), prev) != nil {
			// Couldn't roll it. Better to lose the older one than to fail to
			// save at all, so carry on.
		}
	}
	return save_game(w, AUTOSAVE, title)
}

// Puts the world back. The game's on_load hook runs after the engine's own
// state is in place, so it can rely on being in the right scene.
load_game :: proc(w: ^World, slot: int) -> bool {
	text, ok := read_data_file(save_path(w, slot))
	if !ok do return false
	return load_world(w, text)
}

// A save's text, put back into the world: a slot's or a restore point's.
@(private)
load_world :: proc(w: ^World, text: string) -> bool {
	s := parse_save(text)
	defer save_destroy(&s)

	// A save from another version of the world is refused, and nothing in
	// this one changes: its rooms and flags may not be these.
	w.old_save = save_stale(w, &s)
	if w.old_save do return false

	if name := save_text(&s, "scene"); name != "" {
		for sc, i in w.scenes do if sc.name == name {
			go_to(w, i, {save_f32(&s, "x"), save_f32(&s, "y")})
			break
		}
	}
	w.player.pos = {save_f32(&s, "x", w.player.pos.x), save_f32(&s, "y", w.player.pos.y)}
	w.player.facing = parse_facing(save_text(&s, "facing", "front"))
	w.player.facing_left = w.player.facing == .Left
	w.player.moving = false
	w.player.heading = {}
	w.time = save_f32(&s, "played", w.time)
	w.last_noun = ""
	// Only a noun the vocabulary still knows: a save from an older build
	// shouldn't leave "it" pointing at a word that has since gone.
	if n := save_text(&s, "last_noun"); n != "" && vocab_knows(w.vocab, n) do w.last_noun = n
	set_flags_text(w, save_text(&s, "flags"))
	// The score is written into the save for a menu to read without loading
	// it; what actually restores it is the list of what was found.
	set_earned_text(w, save_text(&s, "earned"))
	notebook_load(w, &s)
	ride_load(w, &s)
	// The music was the moment, and the moment is gone, a cue over it too;
	// before the clock, so that `on_clock` says what plays at the hour
	// restored to (a bed under the night), and it is not stopped after.
	stop_over(w)
	stop_music(w)
	// After the flags, so `on_clock` sets its own on top of what the save
	// restored rather than being overwritten by it.
	set_clock(w, save_int(&s, "clock"))

	// The clock can jump backwards when a save is restored, which would leave
	// every routine waiting for a moment that has already gone. Start them
	// again rather than have people stand about forever.
	for &sc in w.scenes {
		for &o in sc.objects do if o.walks do routine_restart(&o.routine)
		// Nobody half way off through a side, or walked off by a routine.
		people_settle(&sc)
		for &o in sc.objects do o.away = false
	}
	clear_cut_handoff(w)
	refresh_world(w)

	// A save is not a death, and restoring is how you stop being dead.
	w.dead, w.death_box, w.death_time = false, false, 0
	w.message_until = 0
	// And none of the moment it was restored in comes with it: not a drug
	// twenty seconds from landing, not a question waiting for an answer, not
	// a conversation half read.
	clear(&w.timers)
	w.pending = ""
	if talking(w) do end_conversation(w)
	abandon_cutscene(w) // and not a cutscene half played
	close_overlay(w)

	if w.on_load != nil do w.on_load(w, &s)
	close_announcement(w) // one showing belongs to the game being left
	actor_stop_anim(&w.player) // and so does a gesture, and what it was for
	w.after_anim = {}
	w.exit_walk = {}
	w.peeping = {}
	relight(w) // a restore is a cut: the light is the hour's
	return true
}

// --- Restore points ---
//
// A death's own way back. The autosave is the newest save, and a game that
// autosaves on entering a room writes one on the way into every trap; so
// Restore after a death goes to wherever she last walked in. For a death that
// was a long time coming, or that happens a room away from its cause, that is
// the wrong place: the one save the game promised was rolled away by the
// rooms she crossed since. A restore point is a save kept under a name, and a
// Death that names it goes back there, whatever was saved after:
//
//     ne.restore_point(w, "the question")                 // here, now
//     ne.restore_point(w, "the gap", "the_gap", {760, 470}) // now, but standing there
//     ne.die(w, {reason = "...", restore = "the gap"})
//
// A point can put her somewhere other than where she stands (`scene`, `at`):
// the death on the path restores to the gate she should have taken the lamp
// from. Writing a point again replaces it.
//
// Restore points are in memory, for this game: a new game forgets them, and
// so does quitting. A Death whose point was never made goes back to the
// newest save, as one with no point does.

restore_point :: proc(w: ^World, name: string, scene := "", at: [2]f32 = {}) -> bool {
	if name == "" || len(w.scenes) == 0 do return false
	s: Save
	defer save_destroy(&s)
	save_world(w, &s, name)
	if scene != "" {
		if _, found := scene_index(w, scene); !found do return false
		save_put(&s, "scene", scene)
		save_put(&s, "x", fmt.tprintf("%v", int(at.x)))
		save_put(&s, "y", fmt.tprintf("%v", int(at.y)))
	}
	text := strings.clone(save_text_of(&s))
	if old, had := w.restore_points[name]; had {
		delete(old)
		w.restore_points[name] = text
	} else {
		w.restore_points[strings.clone(name)] = text
	}
	return true
}

has_restore_point :: proc(w: ^World, name: string) -> bool {
	return name != "" && name in w.restore_points
}

// Puts the world back as it was at the point. False if there is none.
load_restore_point :: proc(w: ^World, name: string) -> bool {
	text, has := w.restore_points[name]
	if !has do return false
	return load_world(w, text)
}

// Forgets them all: a new game, or the world going away.
clear_restore_points :: proc(w: ^World) {
	for k, v in w.restore_points {
		delete(k)
		delete(v)
	}
	delete(w.restore_points)
	w.restore_points = nil
}

// --- Looking at what's there, without loading it ---

Save_Info :: struct {
	slot:   int,
	used:   bool,
	title:  string, // owned by the caller
	saved_at: string, // owned by the caller
	scene:  string, // owned by the caller
	played: f32,
	stale:  bool,   // from another version of the game (World.save_version): it will not load
}

// Is this save from another version of the world than the game's? Never,
// for a game that keeps no version.
save_stale :: proc(w: ^World, s: ^Save) -> bool {
	return w.save_version != 0 && save_int(s, "version") != w.save_version
}

// Could this slot be restored? There, and not from another version.
@(private = "file")
slot_usable :: proc(w: ^World, slot: int) -> bool {
	if !save_exists(w, slot) do return false
	if w.save_version == 0 do return true
	text, ok := read_data_file(save_path(w, slot), context.temp_allocator)
	if !ok do return false
	s := parse_save(text)
	defer save_destroy(&s)
	return !save_stale(w, &s)
}

save_info_destroy :: proc(infos: []Save_Info) {
	for i in infos {
		delete(i.title)
		delete(i.saved_at)
		delete(i.scene)
	}
	delete(infos)
}

// Every slot, in the order a menu would show them: the two autosaves, then
// 1 to 8. Empty slots come back with `used` false rather than being left out,
// because a save window wants to draw the empty ones too.
save_infos :: proc(w: ^World, allocator := context.allocator) -> []Save_Info {
	out := make([]Save_Info, SAVE_SLOTS + 2, allocator)
	slots := make([]int, SAVE_SLOTS + 2, context.temp_allocator)
	slots[0], slots[1] = AUTOSAVE, AUTOSAVE_PREVIOUS
	for i in 0 ..< SAVE_SLOTS do slots[i + 2] = i + 1

	for slot, i in slots {
		out[i] = Save_Info{slot = slot}
		text, ok := read_data_file(save_path(w, slot))
		if !ok do continue
		s := parse_save(text)
		defer save_destroy(&s)
		out[i].used = true
		out[i].title = strings.clone(save_text(&s, "title"), allocator)
		out[i].saved_at = strings.clone(save_text(&s, "when"), allocator)
		out[i].scene = strings.clone(save_text(&s, "scene"), allocator)
		out[i].played = save_f32(&s, "played")
		out[i].stale = save_stale(w, &s)
	}
	return out
}

save_exists :: proc(w: ^World, slot: int) -> bool {
	return os.exists(save_path(w, slot))
}

// True if there is anything at all to restore, which is what a Restore button
// needs to know before it offers itself.
any_save :: proc(w: ^World) -> bool {
	if slot_usable(w, AUTOSAVE) || slot_usable(w, AUTOSAVE_PREVIOUS) do return true
	for slot in 1 ..= SAVE_SLOTS do if slot_usable(w, slot) do return true
	return false
}

// The newest save there is, or 0 if there are none. What a death box's
// Restore should reach for.
newest_save :: proc(w: ^World) -> int {
	best, best_when := 0, ""
	check :: proc(w: ^World, slot: int, best: ^int, best_when: ^string) {
		text, ok := read_data_file(save_path(w, slot))
		if !ok do return
		s := parse_save(text)
		defer save_destroy(&s)
		if save_stale(w, &s) do return // it would not load
		// The timestamp sorts as text, which is the point of writing it that
		// way round: 2026-09-24 08:15:31.
		if stamp := save_text(&s, "when"); stamp > best_when^ {
			best^, best_when^ = slot, strings.clone(stamp, context.temp_allocator)
		}
	}
	check(w, AUTOSAVE, &best, &best_when)
	check(w, AUTOSAVE_PREVIOUS, &best, &best_when)
	for slot in 1 ..= SAVE_SLOTS do check(w, slot, &best, &best_when)
	return best
}

save_delete :: proc(w: ^World, slot: int) -> bool {
	if !save_exists(w, slot) do return false
	return os.remove(save_path(w, slot)) == nil
}

// --- The files ---

// Where saves live.
//
// A plain name — "my-game" — puts them where the rest of a person's
// data goes, because a save is the player's and not the project's. A name
// with a slash in it is taken as the folder itself, which is how a portable
// build keeps its saves beside it, and how a test keeps them out of the way.
save_dir :: proc(w: ^World, allocator := context.temp_allocator) -> string {
	name := w.save_name if w.save_name != "" else "nengine"
	if strings.contains(name, "/") do return strings.clone(name, allocator)
	if base := os.get_env("XDG_DATA_HOME", context.temp_allocator); base != "" {
		return join3(base, name, "saves", allocator)
	}
	if home := os.get_env("HOME", context.temp_allocator); home != "" {
		share := join3(home, ".local", "share", context.temp_allocator)
		return join3(share, name, "saves", allocator)
	}
	return ""
}

save_path :: proc(w: ^World, slot: int, allocator := context.temp_allocator) -> string {
	dir := save_dir(w, context.temp_allocator)
	if dir == "" do return ""
	return strings.concatenate({dir, "/", slot_file(slot), ".save"}, allocator)
}

// What to call a slot in a message or a menu. The autosaves have names
// rather than numbers, because "slot -1" is not a thing anybody has.
slot_name :: proc(slot: int) -> string {
	switch slot {
	case AUTOSAVE:          return "the autosave"
	case AUTOSAVE_PREVIOUS: return "the previous autosave"
	}
	return fmt.tprintf("slot %v", slot)
}

@(private = "file")
slot_file :: proc(slot: int) -> string {
	switch slot {
	case AUTOSAVE:          return "autosave"
	case AUTOSAVE_PREVIOUS: return "autosave_previous"
	}
	return fmt.tprintf("slot%v", clamp(slot, 1, SAVE_SLOTS))
}

@(private = "file")
join3 :: proc(a, b, c: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({a, "/", b, "/", c}, allocator)
}

// Every level of `path`, not just the last one. A save folder is two levels
// below a home directory that may have neither of them yet, and
// os.make_directory only ever makes one.
@(private = "file")
make_dirs :: proc(path: string) -> bool {
	if path == "" do return false
	if os.is_dir(path) do return true
	for i in 1 ..< len(path) {
		if path[i] != '/' do continue
		part := path[:i]
		if part == "" || os.is_dir(part) do continue
		os.make_directory(part) // a level somebody else owns is fine
	}
	os.make_directory(path)
	return os.is_dir(path)
}

// --- The text of a save ---

save_text_of :: proc(s: ^Save, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "# nengine save\n")
	for v in s.values {
		strings.write_string(&b, v.key)
		strings.write_byte(&b, ' ')
		strings.write_string(&b, v.text)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// `key value`, the value running to the end of the line so a title can have
// spaces in it.
parse_save :: proc(text: string) -> (s: Save) {
	for raw in data_lines(text) {
		space := strings.index_byte(raw, ' ')
		if space <= 0 {
			// A key with no value is still a key, and losing it silently
			// would turn a saved empty string into a missing one.
			append(&s.values, Save_Value{strings.clone(raw), strings.clone("")})
			continue
		}
		key := raw[:space]
		value := strings.trim_space(raw[space + 1:])
		append(&s.values, Save_Value{strings.clone(key), strings.clone(value)})
	}
	return
}

@(private = "file")
now_text :: proc() -> string {
	y, m, d := time.date(time.now())
	h, min, sec := time.clock_from_time(time.now())
	return fmt.tprintf("%4d-%02d-%02d %02d:%02d:%02d", y, int(m), d, h, min, sec)
}
