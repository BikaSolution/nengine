package nengine

import rl "vendor:raylib"

// Something that happens at an hour, in a room, once — whether or not the
// player is there to see it.
//
// A dinner is not a cutscene. The people are at the table on their routines,
// the player can walk about, and at twenty past eight a man leans over a
// woman's chair and says nine o'clock, the pool, bring the money. If the
// player is in the room and near enough, they hear it; if they are across the
// room they see it and hear nothing; if they are in the kitchen it happens
// without them. That is a beat.
//
//     w.beats = BEATS[:]
//
//     BEATS := [?]ne.Beat{
//         {name = "heard_appointment", room = "fire_pit", from = 20*60+20, until = 20*60+28,
//          area = {300, 480, 160, 80}, lines = APPOINTMENT[:], on_play = heard_it},
//         {name = "saw_appointment", room = "fire_pit", from = 20*60+20, until = 20*60+28,
//          only = "!heard_appointment", lines = SAW_IT[:]},
//     }
//
// The engine checks them every frame the world is running — not while a box,
// a ride, an overlay or a death holds the screen — and plays the first one
// that is due: its window is open on the story clock, the player is in its
// room (`room = ""` is any room), inside its `area` if it has one, and its
// `only=` condition holds. Playing it sets the flag `name`, so it is once and
// it saves; spends `cost` ticks; calls `on_play`, which is where awards and
// notes go; and opens its lines as a conversation. Several due at once play in
// the order they are declared, one after another.
//
// A beat the player was not there for is simply not played. Its flag stays
// off, and a later `when=` can tell that nobody saw it.
Beat :: struct {
	name:    string,
	room:    string,
	from:    int,
	until:   int,
	only:    string,
	area:    rl.Rectangle, // zero: anywhere in the room
	cost:    int,
	lines:   []Talk_Line,
	on_play: proc(w: ^World), // as it starts: awards, notes, moving the player
	on_end:  proc(w: ^World), // when its lines are over: whatever comes next
	sound:   string,          // played as it starts, by name: a shot, a bell, an engine stopping
}

// The beat that is due now, if any.
beat_due :: proc(w: ^World) -> ^Beat {
	here := current_scene(w).name
	m := clock_minute(w)
	for &b in w.beats {
		if flag(w, b.name) do continue
		if b.room != "" && b.room != here do continue
		if m < b.from || m >= b.until do continue
		if b.area != {} && !in_rect(w.player.pos, b.area) do continue
		if !condition_met(w, b.only) do continue
		return &b
	}
	return nil
}

// Plays whatever is due. True if something did.
play_beats :: proc(w: ^World) -> bool {
	if talking(w) || riding(w) || overlay_open(w) || cutting(w) || w.dead do return false
	b := beat_due(w)
	if b == nil do return false
	set_flag(w, b.name, true)
	tick(w, b.cost)
	play_sound(w, b.sound)
	if b.on_play != nil do b.on_play(w)
	if len(b.lines) > 0 {
		begin_conversation(w, &w.beat_talk, b.lines, b.on_end)
	} else if b.on_end != nil {
		b.on_end(w)
	}
	return true
}
