package nengine

import "core:fmt"
import "core:strconv"
import "core:strings"

// People who are doing something.
//
// A person in a room is an object that walks. That is the whole design, and
// it is the reason there is no second kind of thing to look up: a person has
// a name the parser knows, a description, verbs of its own and a condition,
// exactly like a lamp does, because it *is* an object — one that happens to
// carry character art and a routine.
//
//     obj elena pos=300,470 char=elena speed=120 when=act2
//     text elena She is wiping down the bar, again.
//     on elena look      She looks up, and keeps wiping.
//     on elena talk to   "Evening, miss. You'll want the far tent."
//     routine elena loop
//     step elena walk_to 520,470
//     step elena play cleaning 4     # round and round for four seconds
//     step elena play wave once      # once through, from its first frame (or 3x)
//     step elena walk_to 300,470
//     step elena wait 2
//
// A routine is a list of steps run in order and, if it loops, started again
// at the end. Each step finishes in its own time — a walk when the walking is
// done, a pose when its seconds are up — which is what makes it a routine
// rather than a cutscene. A cutscene is cues on a clock and everybody obeys
// it; a routine is one person getting on with something while the game
// happens around them.

Step_Kind :: enum {
	Walk_To, // go there, however long it takes
	Play,    // stand still in a named pose for a while
	Wait,    // stand still
	Face,    // turn on the spot
	Say,     // a line, if anybody is there to hear it
	Leave,   // off through a side of the room, and gone until it is next entered (side.odin)
}

Routine_Step :: struct {
	kind:   Step_Kind,
	to:     [2]f32, // Walk_To
	pose:   string, // Play: which part of the character art
	secs:   f32,    // Play, Wait, Say
	times:  int,    // Play: how many times through, and the step waits for it; 0 is for `secs`
	facing: Facing, // Face
	text:   string, // Say
	dir:    Compass, // Leave
}

Routine :: struct {
	steps: [dynamic]Routine_Step,
	loop:  bool,

	// Where it has got to. `until` is a world time, so a routine does not
	// need its own clock and survives the game being paused by a box.
	at:    int,
	until: f32,
	begun: bool,
	done:  bool,
}

routine_destroy :: proc(r: ^Routine) {
	for s in r.steps {
		delete(s.pose)
		delete(s.text)
	}
	delete(r.steps)
	r^ = {}
}

// Back to the beginning. A person who has been hidden for two acts should not
// come back half way through wiping a table.
routine_restart :: proc(r: ^Routine) {
	r.at, r.until, r.begun, r.done = 0, 0, false, false
}

// Runs every person in the scene for a frame.
@(private)
update_people :: proc(w: ^World, scene: ^Scene, dt: f32) {
	for &o in scene.objects {
		if !o.walks do continue
		// Spoken to while walking off (sight.odin): standing, turned to her.
		if o.held {
			o.actor.walking = false
			face_towards(&o.actor, w.player.pos - o.actor.pos)
			continue
		}
		// Going off through a side, or coming on through one (side.odin):
		// walked, not run; and going, already gone to anything but the eye.
		if o.going || o.coming {
			before := o.actor.pos
			actor_follow_target(&o.actor, dt, scene)
			actor_tick(&o.actor, dt, before)
			o.pos = o.actor.pos
			if !o.actor.moving {
				if o.going do settle_going(&o)
				else do settle_coming(&o)
			}
			continue
		}
		if o.hidden {
			// Not here: stop walking and forget where they had got to.
			o.actor.moving = false
			actor_stop_anim(&o.actor)
			routine_restart(&o.routine)
			continue
		}
		run_routine(w, &o, dt, scene)
		before := o.actor.pos
		actor_follow_target(&o.actor, dt, scene)
		actor_tick(&o.actor, dt, before)
		// The object's own position is what everything else reads: drawing
		// order, blocking, how near the player is. The actor does the moving
		// and the object keeps the answer.
		o.pos = o.actor.pos
	}
}

@(private = "file")
run_routine :: proc(w: ^World, o: ^Object, dt: f32, scene: ^Scene) {
	r := &o.routine
	if len(r.steps) == 0 || r.done do return

	if !r.begun {
		begin_step(w, o, scene)
		r.begun = true
		return
	}

	step := r.steps[r.at]
	finished := false
	switch step.kind {
	case .Walk_To:
		// Done when they stop, which is arriving or giving up on something in
		// the way. Either way, standing there forever is worse.
		finished = !o.actor.moving
	case .Play:
		finished = !actor_playing(&o.actor) if step.times > 0 else w.time >= r.until
	case .Wait, .Say:
		finished = w.time >= r.until
	case .Face, .Leave:
		finished = true
	}
	if !finished do return

	r.at += 1
	if r.at >= len(r.steps) {
		if !r.loop {
			r.done = true
			o.actor.pose = o.rest_pose
			return
		}
		r.at = 0
	}
	begin_step(w, o, scene)
}

@(private = "file")
begin_step :: proc(w: ^World, o: ^Object, scene: ^Scene) {
	r := &o.routine
	step := r.steps[r.at]
	o.actor.pose = o.rest_pose // a pose lasts for its own step and no longer
	actor_stop_anim(&o.actor)

	switch step.kind {
	case .Walk_To:
		walk_to(&o.actor, step.to)
	case .Play:
		// From its first frame. `once` and `3x` wait for it to finish; a number
		// of seconds goes round until they are up. See anim.odin.
		o.actor.moving = false
		if step.times > 0 {
			actor_play(&o.actor, step.pose, times = step.times)
		} else {
			o.actor.pose = step.pose
			o.actor.anim_time = 0
			r.until = w.time + max(step.secs, 0.1)
		}
	case .Wait:
		o.actor.moving = false
		r.until = w.time + max(step.secs, 0.1)
	case .Face:
		o.actor.facing = step.facing
		o.actor.facing_left = step.facing == .Left
	case .Say:
		// Only if the player is in the room to hear it. A routine talking to
		// an empty room would steal the message box from whatever the player
		// is actually doing.
		if step.text != "" && current_scene(w) == scene do say(w, step.text)
		r.until = w.time + max(step.secs, 2)
	case .Leave:
		// Gone, and seen to go if she is here to see it.
		o.away = true
		o.hidden = true
		if current_scene(w) == scene do person_leave(scene, o, step.dir)
	}
}

// --- Reading a step out of a scene file ---

// `step elena walk_to 520,470`, `step elena play cleaning 4`, and so on. The
// object's name is the first word so that steps can be written anywhere in
// the file, next to the person they belong to.
@(private)
parse_step :: proc(l: Line, raw: string) -> (s: Routine_Step, ok: bool) {
	if len(l.words) < 2 do return {}, false
	switch l.words[1] {
	case "walk_to", "go":
		if len(l.words) < 3 do return {}, false
		p, good := parse_vec2(l.words[2])
		if !good do return {}, false
		return Routine_Step{kind = .Walk_To, to = p, pose = strings.clone(""), text = strings.clone("")}, true
	case "play":
		if len(l.words) < 3 do return {}, false
		// `play wave 4` is four seconds of it; `play wave once` and `play wave
		// 3x` are that many times through, however long that takes.
		secs, times := f32(2), 0
		if len(l.words) > 3 {
			times = play_times(l.words[3])
			if times == 0 do secs = step_secs(l.words[3], 2)
		}
		return Routine_Step {
			kind  = .Play,
			pose  = strings.clone(l.words[2]),
			secs  = secs,
			times = times,
			text  = strings.clone(""),
		}, true
	case "wait":
		secs := f32(2)
		if len(l.words) > 2 do secs = step_secs(l.words[2], 2)
		return Routine_Step{kind = .Wait, secs = secs, pose = strings.clone(""), text = strings.clone("")}, true
	case "face":
		f := Facing.Front
		if len(l.words) > 2 do f = parse_facing(l.words[2])
		return Routine_Step{kind = .Face, facing = f, pose = strings.clone(""), text = strings.clone("")}, true
	case "leave":
		if len(l.words) < 3 do return {}, false
		d, good := compass_of(l.words[2])
		if !good do return {}, false
		return Routine_Step{kind = .Leave, dir = d, pose = strings.clone(""), text = strings.clone("")}, true
	case "say":
		return Routine_Step {
			kind = .Say,
			text = strings.clone(line_rest(raw, 3)),
			secs = 2.5,
			pose = strings.clone(""),
		}, true
	}
	return {}, false
}

@(private)
step_text :: proc(s: Routine_Step, name: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "step ")
	strings.write_string(&b, name)
	switch s.kind {
	case .Walk_To:
		fmt.sbprintf(&b, " walk_to %v,%v", s.to.x, s.to.y)
	case .Play:
		if s.times == 1 do fmt.sbprintf(&b, " play %v once", s.pose)
		else if s.times > 1 do fmt.sbprintf(&b, " play %v %vx", s.pose, s.times)
		else do fmt.sbprintf(&b, " play %v %v", s.pose, s.secs)
	case .Wait:
		fmt.sbprintf(&b, " wait %v", s.secs)
	case .Face:
		strings.write_string(&b, " face ")
		strings.write_string(&b, facing_text(s.facing))
	case .Say:
		strings.write_string(&b, " say ")
		strings.write_string(&b, s.text)
	case .Leave:
		strings.write_string(&b, " leave ")
		strings.write_string(&b, COMPASS_WORDS[s.dir])
	}
	return strings.to_string(b)
}

@(private = "file")
step_secs :: proc(word: string, fallback: f32) -> f32 {
	if v, ok := strconv.parse_f32(word); ok do return v
	return fallback
}

// `once` is 1, `3x` is 3, and anything else is 0: a number of seconds.
play_times :: proc(word: string) -> int {
	if word == "once" do return 1
	if len(word) > 1 && word[len(word) - 1] == 'x' {
		n, ok := strconv.parse_int(word[:len(word) - 1])
		if ok && n > 0 do return n
	}
	return 0
}
