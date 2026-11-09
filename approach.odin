package nengine

import "core:fmt"

// Walking over to do something.
//
// OPEN DOOR from across the room does not open the door from across the room.
// The player walks to the door — to the spot in front of it the scene names —
// turns to face it, and *then* the door is opened. TALK TO ELENA walks over to
// stand beside her first, wherever she has got to. LOOK does not walk: you can
// see a thing from where you are.
//
//     obj door pos=600,420 sprite=door walk_to=600,450 reach=box:220,120
//
// Three things decide it, all on the object:
//
//   walk_to=   the interaction point: where the player stands to do anything
//              to it. Without one, the command runs where the player stands,
//              which is how an object behaved before this file existed.
//   reach=     the ring. From outside it, the thing is too far to deal with and
//              the game says so (`on_out_of_reach`); from inside it, the
//              player walks to walk_to and does it. Without one, the whole room
//              is inside the ring.
//   walks      a person. Their walk_to is ignored — they do not stay put — and
//              the player stands a little to one side of them instead, on
//              whichever side the player came from, re-aiming as they move.
//
// The command waits while the player walks, and runs on arrival through the
// same object → scene → world order as anything typed. Clicking somewhere, or
// an arrow key, or leaving the room, calls it off — the player has changed
// their mind. A new command that also needs a walk replaces it; one that does
// not (LOOK, the notebook) leaves it alone.
//
// GO TO <thing> is the same walk with nothing at the end of it, and GO TO
// <exit> heads for the exit. A game that answers "go" itself still can: the
// engine only takes it when there is a thing or an exit here by that name.

// How far to one side of a person the player stands to deal with them, in
// canvas pixels. A little more than the width of a body, so the two of them
// are not drawn on top of each other.
BESIDE :: f32(48)

// A person is near enough to talk to, show a thing to, or hand one over from
// a step or two away: someone else crossing the floor may stop her a little
// short of the spot beside them, and that is not a reason to give up.
@(private)
WITHIN_A_STEP :: f32(110)

// Blocked on the way and this close to the spot is close enough.
@(private)
CLOSE_ENOUGH :: f32(12)

// The verbs done from where the player stands, when a game does not give its
// own list.
@(private)
FAR_VERBS := [?]string{"look"}

// A command waiting for the player to get there. Its strings belong to the
// vocabulary, which outlives it, as last_noun's do.
Approach :: struct {
	active: bool,
	cmd:    Command,
	object: string, // the object walked to, by name: it may be gone on arrival
	only:   bool,   // GO TO: the walk is the whole of it
	tries:  int,    // set off again after being stopped short (APPROACH_TRIES)
}

// Stopped short — somebody crossing the floor stepped into her way — she sets
// off again from where she stands, round them, this many times before she
// says she can't get there. A wall does not move; a person does.
@(private)
APPROACH_TRIES :: 4

Out_Of_Reach :: enum {
	Too_Far, // outside the ring when it was asked
	Blocked, // set off, and something was in the way
}

// Held for a walk, or refused for distance. False means: run it now.
@(private)
approach_command :: proc(w: ^World, scene: ^Scene, cmd: Command) -> (held: bool) {
	// LEAVE, GO OUT, EXIT with nothing after it: out by the room's exit named
	// `out`, or by its only way out (a tent's flap, a hut's door).
	// (LEAVE on its own reads as DROP, whose other meaning, leave the lamp on
	// the gate, needs a noun; with none it is going out.)
	if (cmd.verb == "exit" || cmd.verb == "drop") && cmd.noun == "" {
		if head_for_exit(w, "out") {
			log_route(w, "walk")
			return true
		}
		only, count := "", 0
		for e in scene.exits do if !e.hidden && e.name != only {
			only = e.name
			count += 1
		}
		if count != 1 || !head_for_exit(w, only) do return false
		log_route(w, "walk")
		return true
	}
	if cmd.noun == "" do return false
	// LOOK is done from where she stands, except LOOK THROUGH an aperture,
	// which is done with an eye to it. See peep.odin.
	if is_far_verb(w, cmd.verb) && peep_command_here(w, scene, cmd) == nil do return false
	go := cmd.verb == "go"

	// UNLOCK DOOR WITH KEY walks to the door; GIVE PLATE TO CAT, where the
	// plate is in a pocket, walks to the cat. ASK ELENA ABOUT THE PHOTOGRAPH
	// walks nowhere near the photograph: after "about" it is a topic.
	o := object_here(scene, cmd.noun)
	if o == nil && cmd.noun2 != "" && cmd.prep != "about" do o = object_here(scene, cmd.noun2)
	if o == nil {
		if !go || !head_for_exit(w, cmd.noun) do return false
		log_route(w, "walk")
		return true
	}

	p := &w.player
	if !go && o.reach.kind != .None && !in_shape(o.reach, o.pos, p.pos) {
		log_route(w, "out-of-reach")
		refuse_approach(w, o, .Too_Far)
		return true
	}

	point, has := interaction_point(w, scene, o)
	if !has {
		if !go do return false
		point = clamp_to_polygon(o.pos, scene.walk_area) // no spot named: as near as the floor goes
	}

	p.heading = {}
	// GO TO or ENTER a thing whose spot is in a doorway (a door, a hut, the
	// gap): a walk into that doorway, and through it on getting there
	// (world.odin's check_exits). Any other verb done there (OPEN, KNOCK,
	// TAKE) leaves her standing in it.
	w.door_walk = {}
	if go || cmd.verb == "enter" do aim_for_door(w, scene, point)
	if length(p.pos - point) < 0.5 {
		// Already standing on the spot.
		face_towards(p, o.pos - p.pos)
		if w.door_walk.active {
			// Deciding to go through, from the doorway: as head_for_exit.
			p.target = point
			w.exit_grace, w.exit_passed, w.bumped = false, false, false
		}
		if go do log_route(w, "walk")
		return go
	}
	// What is done at the end of it is the command's route in the play log;
	// until then, and for GO TO, it is a walk.
	log_route(w, "walk")
	w.approach = {active = true, cmd = cmd, object = o.name, only = go}
	walk_to(p, point)
	return true
}

// Where the player stands to deal with this object. False if it has no spot.
interaction_point :: proc(w: ^World, scene: ^Scene, o: ^Object) -> (point: [2]f32, ok: bool) {
	if o.walks {
		side := f32(-1) if w.player.pos.x < o.pos.x else 1
		return clamp_to_polygon(o.pos + {side * BESIDE, 0}, scene.walk_area), true
	}
	if o.walk_to == {} do return {}, false
	return clamp_to_polygon(o.walk_to, scene.walk_area), true
}

// Called off: the player clicked somewhere, or pressed an arrow, or left.
cancel_approach :: proc(w: ^World) {
	w.approach = {}
}

approaching :: proc(w: ^World) -> bool {
	return w.approach.active
}

// Once a frame, after the player has moved. `arrived` is whether they reached
// the spot this frame.
@(private)
approach_step :: proc(w: ^World, arrived: bool) {
	a := &w.approach
	if !a.active do return
	p := &w.player
	scene := current_scene(w)

	o := object_here(scene, a.object)
	if o == nil {
		// Gone while we walked: they left, or it was hidden. Stop where we are.
		cancel_approach(w)
		p.moving = false
		return
	}
	point, _ := interaction_point(w, scene, o)
	if p.moving {
		// A person may have moved on. Follow them rather than arriving at
		// where they used to be.
		if o.walks do p.target = point
		return
	}

	cmd, only := a.cmd, a.only
	got_there := arrived || length(p.pos - point) <= CLOSE_ENOUGH
	if !got_there && o.reach.kind != .None do got_there = in_shape(o.reach, o.pos, p.pos)
	if !got_there && o.walks do got_there = length(p.pos - o.pos) <= WITHIN_A_STEP
	if !got_there && a.tries < APPROACH_TRIES {
		a.tries += 1
		walk_to(p, point)
		return
	}
	cancel_approach(w)
	if !got_there && !only {
		log_route(w, fmt.tprintf("out-of-reach: stopped at %v,%v for %v at %v,%v (%v at %v,%v)", int(p.pos.x), int(p.pos.y),
			o.name, int(point.x), int(point.y), "walks" if o.walks else "still", int(o.pos.x), int(o.pos.y)))
		refuse_approach(w, o, .Blocked)
		return
	}
	face_towards(p, o.pos - p.pos)
	if !only do dispatch_command(w, current_scene(w), cmd)
}

// Finishes a walk without drawing it, for the harness: the same steps update()
// takes, at sixty a second, for up to half a minute. The people in the room
// stand still while it happens.
//
// `at` is where the walk ended — before whatever was done there, which may
// have moved the player somewhere else entirely (ENTER TENT).
@(private)
finish_approach :: proc(w: ^World) -> (at: [2]f32) {
	for _ in 0 ..< 60 * 30 {
		if !w.approach.active do return
		before := w.player.pos
		arrived := actor_follow_target(&w.player, 1.0 / 60, current_scene(w))
		at = w.player.pos
		approach_step(w, arrived)
		exit_walk_step(w)
		if actor_playing(&w.player) || w.exit_walk.active do continue
		if !check_triggers(w, before) do check_exits(w)
	}
	cancel_approach(w)
	return
}

// A plain walk — GO TO an exit, a click — played out in real steps, undrawn,
// for the harness: until the player gets there, is stopped, or goes through
// an exit into another room.
finish_walk :: proc(w: ^World) -> (at: [2]f32) {
	from := w.current
	people_frame(w) // who is her, and where: people are solid (priority.odin)
	for _ in 0 ..< 60 * 30 {
		if !w.player.moving || w.current != from do break
		before := w.player.pos
		actor_follow_target(&w.player, 1.0 / 60, current_scene(w))
		// A click on the water, or the game's walk off an edge: over, at the
		// brink (edge.odin).
		if edge_walk_step(w) do break
		// At a side's brink: across (side.odin).
		if side_walk_step(w) do break
		// On the way to an exit's spot, to climb: no other exit fires, and on
		// arriving the climb starts (and the harness ends it; see script.odin).
		exit_walk_step(w)
		if actor_playing(&w.player) || w.exit_walk.active do continue
		if !check_triggers(w, before) do check_exits(w)
	}
	return w.player.pos
}

@(private = "file")
is_far_verb :: proc(w: ^World, verb: string) -> bool {
	far := w.far_verbs if w.far_verbs != nil else FAR_VERBS[:]
	for v in far do if v == verb do return true
	return false
}

@(private = "file")
refuse_approach :: proc(w: ^World, o: ^Object, why: Out_Of_Reach) {
	if w.on_out_of_reach != nil && w.on_out_of_reach(w, o, why) do return
	switch why {
	case .Too_Far:
		say(w, "You're not close enough.")
	case .Blocked:
		say(w, "You can't get there from here.")
	}
}
