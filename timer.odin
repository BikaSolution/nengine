package nengine

// Something that happens in so many seconds of real time, unless it is called
// off. For the few moments a game wants the player's hands and not their
// clock: a drug landing in twenty-five seconds, a fuse, a door closing.
//
//     ne.after(w, "drug_lands", 25, drug_lands)
//     ne.cancel_timer(w, "drug_lands")   // she got away
//
// Real time is `World.time`, which does not run while an overlay or the
// death box holds the screen. The story clock is another thing entirely and
// a timer never touches it. A timer set again by the same name is reset.
//
// A **deadline** is a timer the player is racing: the seconds are hers to act
// in, and when they run out something happens to her. It runs like any other;
// the differences are that it waits while a conversation, an announcement or
// a cutscene holds the screen (reading is not playing; hold_deadlines), and
// that anything reading the screen for the player knows to hurry
// (autoplay.odin skims while one runs, as a person with a countdown does). A
// fuse somebody else lit, or an engine noise building, is `after`.
//
//     ne.deadline(w, "drug_lands", 25, drug_lands)
Timer :: struct {
	name:     string,
	at:       f32,
	fire:     proc(w: ^World),
	deadline: bool, // the player's seconds to act in, not the world's
}

after :: proc(w: ^World, name: string, secs: f32, fire: proc(w: ^World)) {
	cancel_timer(w, name)
	append(&w.timers, Timer{name = name, at = w.time + secs, fire = fire})
}

// `after`, for seconds the player is racing. See the top of the file.
deadline :: proc(w: ^World, name: string, secs: f32, fire: proc(w: ^World)) {
	cancel_timer(w, name)
	append(&w.timers, Timer{name = name, at = w.time + secs, fire = fire, deadline = true})
}

// Is the player racing a deadline right now?
racing :: proc(w: ^World) -> bool {
	for t in w.timers do if t.deadline do return true
	return false
}

cancel_timer :: proc(w: ^World, name: string) {
	for i := len(w.timers) - 1; i >= 0; i -= 1 {
		if w.timers[i].name == name do unordered_remove(&w.timers, i)
	}
}

// Seconds left, and whether it is running at all.
timer_left :: proc(w: ^World, name: string) -> (f32, bool) {
	for t in w.timers do if t.name == name do return max(t.at - w.time, 0), true
	return 0, false
}

// A deadline is the player's time, and reading is not playing: while a
// conversation, an announcement or a cutscene holds the screen, her seconds
// wait. Twenty-five seconds to crawl three yards means twenty-five seconds of
// her hands free, however long the lines that came first take to read.
@(private)
hold_deadlines :: proc(w: ^World, dt: f32) {
	if !(talking(w) || announcing(w) || cutting(w)) do return
	for &t in w.timers do if t.deadline do t.at += dt
}

// Fires whatever is due. Each is removed before it fires, so a timer can set
// itself again.
@(private)
run_timers :: proc(w: ^World) {
	for i := 0; i < len(w.timers); {
		t := w.timers[i]
		if w.time < t.at {
			i += 1
			continue
		}
		unordered_remove(&w.timers, i)
		// What a timer says, nobody typed for (playlog.odin).
		w.log.source = "(timer)"
		if t.fire != nil do t.fire(w)
		w.log.source = ""
	}
}
