package nengine

// Animation: which frame a part shows, and playing one once.
//
// A part plays at its `fps`, one tick per frame by default. A frame can hold
// for more ticks than one, which is how a gesture gets its weight without
// drawing the same picture twice:
//
//     part pick_up frames=4 fps=8
//     frame 0
//     frame 1 hold=2     # the reach, held
//     frame 2
//     frame 3 hold=4     # the cup, up, held for half a second
//
// A part a person *stands in* loops for as long as they stand in it. A part a
// person *does* plays once, from its first frame, and hands back whatever they
// were doing before:
//
//     actor_play(&w.player, "pick_up")        // once, then back to standing
//     actor_play(&o.actor, "wave", times = 3) // three times
//     actor_play(&o.actor, "cleaning", secs = 4) // round and round, four seconds
//     actor_playing(&w.player)                // still at it?
//
// In a scene file, an object's verb can carry one, and the player walks over,
// does it, and only then does the verb happen:
//
//     on cup take anim=pick_up action=take_cup You pick up the cup.
//
// A routine plays one with `step elena play wave once` (or `3x`), and a
// cutscene with `2.50 elena play wave once`. A part nobody has drawn yet
// plays for no time at all, so a half-finished character never holds the
// game up.

// Total ticks a part lasts: the sum of its holds.
anim_ticks :: proc(frames: i32, holds: []i32) -> i32 {
	total := i32(0)
	for f in 0 ..< max(frames, 1) do total += hold_at(holds, f)
	return total
}

// Seconds a part takes to play once. Zero when it does not animate.
anim_secs :: proc(frames: i32, fps: f32, holds: []i32) -> f32 {
	if fps <= 0 do return 0
	return f32(anim_ticks(frames, holds)) / fps
}

// Which frame shows `t` seconds in. Looping, it goes round; not looping, it
// stops on the last frame and says it is done.
anim_frame :: proc(t, fps: f32, frames: i32, holds: []i32, loop := true) -> (frame: i32, done: bool) {
	if fps <= 0 do return 0, !loop
	n := max(frames, 1)
	total := anim_ticks(n, holds)
	tick := i32(max(t, 0) * fps)
	if tick >= total {
		if !loop do return n - 1, true
		tick %= total
	}
	for f in 0 ..< n {
		h := hold_at(holds, f)
		if tick < h do return f, false
		tick -= h
	}
	return n - 1, false
}

@(private)
hold_at :: proc(holds: []i32, f: i32) -> i32 {
	if f < 0 || int(f) >= len(holds) do return 1
	return max(holds[f], 1)
}

// --- Playing a part on somebody ---

// Plays `part` from its first frame. `times` is how many times through (0 is
// until stopped, or until `secs` runs out); `secs`, if set, stops it after
// that long whatever `times` says. Replaces anything already playing.
actor_play :: proc(a: ^Actor, part: string, times := 1, secs: f32 = 0) {
	a.anim = part
	a.anim_t = 0
	a.anim_times = max(times, 0)
	a.anim_secs = secs
	a.moving = false
	a.heading = {}
}

// Stops whatever is playing, and the pose underneath shows again.
actor_stop_anim :: proc(a: ^Actor) {
	a.anim = ""
	a.anim_t = 0
}

actor_playing :: proc(a: ^Actor) -> bool {
	return a.anim != ""
}

// How long `part` takes to play once on this actor, in seconds. Zero for a
// part that is not drawn, or does not animate.
actor_part_secs :: proc(a: ^Actor, part: string) -> f32 {
	if a.character == nil do return 0
	p, has := a.character.parts[part]
	if !has || p.sprite.texture.id == 0 do return 0
	return anim_secs(p.sprite.frames, p.fps, p.holds)
}

// Once a frame for anybody on the floor: whether they walked, the clock their
// standing and walking poses run on, and whatever they are playing. `before`
// is where they stood at the start of the frame.
actor_tick :: proc(a: ^Actor, dt: f32, before: [2]f32) {
	a.walking = a.pos != before
	a.anim_time += dt
	if a.anim == "" do return
	a.anim_t += dt
	if a.anim_secs > 0 && a.anim_t >= a.anim_secs {
		actor_stop_anim(a)
		return
	}
	if a.anim_times == 0 do return // until stopped, or until secs
	once := actor_part_secs(a, a.anim)
	if a.anim_t >= once * f32(a.anim_times) do actor_stop_anim(a)
}

// --- The player ---

// What the player is waiting to finish before something happens.
After_Anim :: struct {
	active: bool,
	cmd:    Command,          // an object's verb, run again without its anim
	object: string,           // the object it was aimed at, by name
	then:   proc(w: ^World),  // or a procedure the game gave player_play

	// Or a room to go to: an exit gone through as something she does.
	go:          bool,
	to:          int,
	arrive:      [2]f32,
	arrive_anim: string, // played in the new room
	exit:        bool,   // came through an exit, so the game's on_arrive runs
}

// Plays `part` on the player and then calls `then`, from game code:
//
//     ne.player_play(w, "kneel", proc(w: ^ne.World) { ne.say(w, "Nothing under the cot.") })
//
// A part that is not drawn yet calls `then` straight away.
player_play :: proc(w: ^World, part: string, then: proc(w: ^World) = nil, times := 1) {
	if actor_part_secs(&w.player, part) <= 0 {
		if then != nil do then(w)
		return
	}
	actor_play(&w.player, part, times = times)
	w.after_anim = {active = true, then = then}
}

// The gesture is over: do what it was for.
run_after_anim :: proc(w: ^World) {
	a := w.after_anim
	w.after_anim = {}
	if !a.active do return
	if a.then != nil {
		a.then(w)
		return
	}
	if a.go {
		go_to(w, a.to, a.arrive)
		if a.exit && w.on_arrive != nil do w.on_arrive(w)
		play_arrival(w, a.arrive_anim)
		return
	}
	o := object_here(current_scene(w), a.object)
	if o == nil do return
	if it := object_interaction(w, o, a.cmd); it != nil do run_interaction(w, o, it, a.cmd)
}

// For the harness, which does not wait for gestures: ends whatever the player
// is playing and does what it was for. Returns the part's name, or "".
finish_player_anim :: proc(w: ^World) -> (part: string) {
	if !actor_playing(&w.player) do return ""
	part = w.player.anim
	actor_stop_anim(&w.player)
	run_after_anim(w)
	return
}

// --- Through a door, up a ladder ---
//
// An exit can be gone through as something she does rather than walked
// through:
//
//     exit ladder area=400,280,40,40 to=loft arrive=300,420 anim=climb_up at=420,320 face=back arrive_anim=climb_off
//
// Stepping into it (or GO TO LADDER, or a click there) walks her to `at`, turns
// her to `face`, plays `climb_up`, and changes the room at the end of it; in
// the loft she plays `climb_off` where she arrives. Each part is optional, and
// a part nobody has drawn plays for no time, so an exit with art still to come
// is an ordinary exit until it arrives.
//
// From game code, for a way out that is not an exit (ENTER TENT, a trapdoor):
//
//     ne.go_to_after(w, "duck_in", tent_scene, {300, 420}, arrive_part = "stand_up")

// Walking to an exit's `at` before going through it.
Exit_Walk :: struct {
	active: bool,
	exit:   Exit, // a copy; its strings belong to the scene, which outlives it
	// Or a walk to the brink of an edge, to go over it on arriving: kept here
	// so that whatever calls off the one calls off the other. See edge.odin.
	edge:   Edge_Walk,
	// Or to the brink of a side, to cross it on arriving (side.odin).
	side:   Side_Walk,
}

@(private)
start_exit_anim :: proc(w: ^World, e: Exit) {
	p := &w.player
	cancel_approach(w)
	p.heading = {}
	if e.at != {} && length(p.pos - e.at) > 1 {
		w.exit_walk = {active = true, exit = e}
		walk_to(p, e.at)
		return
	}
	play_exit(w, e)
}

// Once a frame: arrived at the spot, so do it.
@(private)
exit_walk_step :: proc(w: ^World) {
	if !w.exit_walk.active || w.player.moving do return
	e := w.exit_walk.exit
	w.exit_walk = {}
	play_exit(w, e)
}

@(private)
play_exit :: proc(w: ^World, e: Exit) {
	p := &w.player
	if f, has := e.face.?; has {
		p.facing = f
		p.facing_left = f == .Left
	}
	actor_play(p, e.anim)
	w.after_anim = {active = true, go = true, to = e.to, arrive = e.arrive, arrive_anim = e.arrive_anim, exit = true}
}

// In the new room: whatever she does on arriving, if it is drawn.
@(private)
play_arrival :: proc(w: ^World, part: string) {
	if part != "" && actor_part_secs(&w.player, part) > 0 do actor_play(&w.player, part)
}

// Plays `part`, then goes to `scene` and plays `arrive_part` there. Neither
// part drawn, and it is go_to.
go_to_after :: proc(w: ^World, part: string, scene: int, arrive: [2]f32, arrive_part := "") {
	if actor_part_secs(&w.player, part) <= 0 {
		go_to(w, scene, arrive)
		play_arrival(w, arrive_part)
		return
	}
	actor_play(&w.player, part)
	w.after_anim = {active = true, go = true, to = scene, arrive = arrive, arrive_anim = arrive_part}
}
