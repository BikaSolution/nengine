package nengine

import rl "vendor:raylib"

// Which way someone is facing. Which pose of a character gets drawn.
Facing :: enum {
	Front, // towards you
	Back,  // away
	Left,
	Right,
}

// Something that walks around a scene. For now that's just the player.
//
// Draw it either way: a pair of sprites (idle and walk, mirrored when facing
// left), or a whole Character, which has a pose for each of the four
// directions and doesn't need mirroring. See char_file.odin.
Actor :: struct {
	pos:         [2]f32, // feet
	speed:       f32,    // pixels per second
	idle:        Sprite,
	walk:        Sprite,
	idle_fps:    f32,
	walk_fps:    f32,
	character:   ^Character_Art, // if set, used instead of idle/walk

	target:      [2]f32,
	moving:      bool,   // heading for target
	heading:     [2]f32, // walking this way until told to stop (arrow keys, numpad). Zero = not.
	walking:     bool,   // actually moved this frame (drives the animation)
	facing_left: bool,
	facing:      Facing,
	anim_time:   f32,

	step:        rl.Sound, // footstep. See audio.odin.
	last_step:   i32,      // engine's own

	// A named part to show instead of the one the direction would choose:
	// "cleaning", "reading". A routine sets it for the length of a step. See
	// routine.odin.
	pose:        string,

	// A part being played once (or a few times, or for a while) over the top
	// of the pose and the direction: picking up a cup, a wave. Started from
	// its first frame by actor_play and cleared when it ends. See anim.odin.
	anim:        string,
	anim_t:      f32, // seconds since it started
	anim_times:  int, // how many times through; 0 is until stopped
	anim_secs:   f32, // stop after this long, if set

	// The way to `target` round the corners of the floor (walk.odin), worked
	// out on the first step after walk_to.
	path:        [16][2]f32,
	path_len:    int,
	path_at:     int,
	path_ready:  bool,

	// What follows the walk to `target`, and whether that walk is a straight
	// line that ignores the floor: going off through a side and out of
	// sight, or coming on from beyond one (side.odin). `sink` is the brink
	// somebody sinks behind going north (and rises from coming south); 0 for
	// none. People never change size: they go behind the ground instead.
	legs:        [3]Leg,
	legs_len:    int,
	straight:    bool,
	sink:        f32,
	// A person of a room, who walks round her (priority.odin, people are
	// solid); how often the way has been worked out again since it was set,
	// and how long they have waited for her on a straight leg.
	npc:         bool,
	way_again:   int,
	waited:      f32,
}

// One more stretch of a walk, after the one to `target`.
Leg :: struct {
	to:       [2]f32,
	straight: bool, // a line, off the floor if need be; else round the floor's corners
}

// Walks the legs in order: the first now, the rest after it.
walk_legs :: proc(a: ^Actor, legs: []Leg) {
	if len(legs) == 0 do return
	walk_to(a, legs[0].to)
	a.straight = legs[0].straight
	n := min(len(legs) - 1, len(a.legs))
	for k in 0 ..< n do a.legs[k] = legs[k + 1]
	a.legs_len = n
}

// On to the next leg, if there is one.
@(private)
next_leg :: proc(a: ^Actor) -> bool {
	if a.legs_len == 0 {
		a.straight = false
		return false
	}
	l := a.legs[0]
	for k in 0 ..< a.legs_len - 1 do a.legs[k] = a.legs[k + 1]
	a.legs_len -= 1
	a.target = l.to
	a.moving = true
	a.path_ready = false
	a.straight = l.straight
	return true
}

// Start walking to a point.
walk_to :: proc(a: ^Actor, to: [2]f32) {
	a.target = to
	a.moving = true
	a.way_again = 0
	a.waited = 0
	a.heading = {}
	a.path_ready = false
	a.straight = false
	a.legs_len = 0
}

// Can feet at `from` move to `to`? Inside the walk area, and not stepping
// into anything solid. (Stepping *out* of something solid is always allowed,
// so nobody gets stuck if they start inside one.)
can_step :: proc(scene: ^Scene, from, to: [2]f32) -> bool {
	if !point_in_polygon(to, scene.walk_area) do return false
	for o in scene.objects {
		if o.hidden || o.block.kind == .None do continue
		if in_shape(o.block, o.pos, to) && !in_shape(o.block, o.pos, from) do return false
	}
	// Painted floor that is taken (priority.odin), the same way; and people.
	if solid_at(scene, to) && !solid_at(scene, from) do return false
	if people_in_way(scene, to, from) do return false
	return true
}

// Keep walking in a straight line along `heading` until something's in the
// way (the edge of the floor, or something solid), then stop. This is how the
// arrow keys and the numpad walk, as in Sierra games.
actor_follow_heading :: proc(a: ^Actor, dt: f32, scene: ^Scene) {
	if a.heading == {0, 0} do return
	was := scene.mover
	scene.mover = mover_of(a) // who stops whom (priority.odin)
	defer scene.mover = was
	next := a.pos + a.heading * a.speed * dt
	if next == a.pos do return // first frame, dt is 0
	if !can_step(scene, a.pos, next) {
		a.heading = {}
		return
	}
	face_towards(a, a.heading)
	a.pos = next
}

// Take one step toward the target. Returns true on the frame it gets there.
actor_follow_target :: proc(a: ^Actor, dt: f32, scene: ^Scene) -> (arrived: bool) {
	if !a.moving do return false
	was := scene.mover
	scene.mover = mover_of(a) // who stops whom: people are solid (priority.odin)
	defer scene.mover = was

	// A leg off the floor: a line, as a cutscene walks (side.odin).
	if a.straight {
		d := a.target - a.pos
		dist := length(d)
		// Somebody coming or going through a side, and her in the way: wait
		// a moment for her to move, then on regardless.
		if dist > 0.5 && a.waited < PERSON_WAIT && people_in_way(scene, a.pos + d / dist * max(a.speed * dt, 1), a.pos) {
			a.waited += dt
			return false
		}
		if dist <= a.speed * dt || dist < 0.5 {
			a.pos = a.target
			if next_leg(a) do return false
			a.moving = false
			return true
		}
		face_towards(a, d)
		a.pos += d / dist * a.speed * dt
		return false
	}

	// Round the corners of the floor, not through them.
	if !a.path_ready {
		a.path_ready = true
		a.path_at = 0
		a.path_len = scene_path(scene, a.pos, a.target, a.path[:]) if len(scene.walk_area) >= 3 else 0
		if a.path_len == 0 {
			a.path[0] = a.target // nowhere to go round: as far as a line goes
			a.path_len = 1
		}
	}
	step_to := a.path[a.path_at]
	last := a.path_at == a.path_len - 1

	to_step := step_to - a.pos
	dist := length(to_step)
	if dist < 0.5 {
		a.pos = step_to
		if !last {
			a.path_at += 1
			return false
		}
		a.pos = a.target
		if next_leg(a) do return false
		a.moving = false
		return true
	}

	dir := to_step / dist
	// A long frame (a stall, or the world run fast) is a long step, and a long
	// step can land inside a block that the spot it is heading for only
	// touches: shorter steps up to the edge before calling it blocked.
	step := min(a.speed * dt, dist)
	for _ in 0 ..< 6 {
		if try_move(a, a.pos + dir * step, scene) do return false
		step *= 0.5
		if step < 0.5 do break
	}
	// Something in the way the route did not know about — somebody who has
	// walked into it since: the way worked out again, round them, a few
	// times; then stop here.
	if a.way_again < WAY_AGAIN {
		a.way_again += 1
		a.path_ready = false
		return false
	}
	a.moving = false
	a.legs_len = 0
	return false
}

// Move to next if the player can stand there. If not, try sliding along just
// one axis, so walking into a wall at an angle slides along it instead of
// sticking.
try_move :: proc(a: ^Actor, next: [2]f32, scene: ^Scene) -> bool {
	// Not moving isn't being blocked. Happens on the first frame, when dt is 0.
	if next == a.pos do return true

	options := [3][2]f32{next, {next.x, a.pos.y}, {a.pos.x, next.y}}
	for o in options {
		if o != a.pos && can_step(scene, a.pos, o) {
			face_towards(a, o - a.pos)
			a.pos = o
			return true
		}
	}
	return false
}

// Which way a step is taking them. Sideways wins ties, because a character
// seen from the side reads better than one seen head-on.
@(private)
face_towards :: proc(a: ^Actor, delta: [2]f32) {
	if abs(delta.x) < 0.01 && abs(delta.y) < 0.01 do return
	if abs(delta.x) >= abs(delta.y) {
		a.facing = .Left if delta.x < 0 else .Right
		a.facing_left = delta.x < 0
	} else {
		a.facing = .Front if delta.y > 0 else .Back
	}
}

// The pose a character walks or stands in, facing this way.
@(private)
facing_part :: proc(f: Facing, walking: bool) -> string {
	switch f {
	case .Front: return "walk_front" if walking else "front"
	case .Back:  return "walk_back" if walking else "back"
	case .Left:  return "walk_left" if walking else "left"
	case .Right: return "walk_right" if walking else "right"
	}
	return "front"
}

draw_actor :: proc(a: Actor) {
	// Past a north brink: drawn lower the further they go, and only down to
	// the brink, so they sink behind it (side.odin).
	if a.sink > 0 && a.pos.y < a.sink {
		b := a
		b.sink = 0
		b.pos.y = a.sink + (a.sink - a.pos.y) * (SINK_DEPTH / SINK_OUT)
		draw_actor_above(b, a.sink)
		return
	}
	s, frame, flip := actor_picture(a)
	draw_sprite(s, frame, a.pos, flip)
}

// The picture draw_actor puts up for this actor now: the part being played,
// the pose, the way they face (walking or not), or the plain sprites. A
// texture of 0 is nothing drawn at all (person_unseen, sight.odin, asks).
actor_picture :: proc(a: Actor) -> (s: Sprite, frame: i32, flip: bool) {
	if a.character != nil {
		// Something being played once, from its own first frame, on its own
		// clock; it holds its last frame until actor_tick lets it go.
		if a.anim != "" {
			part := a.character.parts[a.anim]
			if part.sprite.texture.id != 0 {
				frame, _ = anim_frame(a.anim_t, part.fps, part.sprite.frames, part.holds, loop = a.anim_times == 0)
				return part.sprite, frame, false
			}
		}
		want := a.pose if a.pose != "" else facing_part(a.facing, a.walking)
		part := a.character.parts[want]
		// A walk nobody has drawn yet is the standing pose that way, sliding,
		// rather than nobody at all.
		if part.sprite.texture.id == 0 && a.pose == "" && a.walking do part = a.character.parts[facing_part(a.facing, false)]
		if part.sprite.texture.id != 0 {
			fps := part.fps if part.fps > 0 else (a.walk_fps if a.walking else a.idle_fps)
			frame, _ = anim_frame(a.anim_time, fps, part.sprite.frames, part.holds)
			return part.sprite, frame, false
		}
		// A pose that hasn't been drawn yet falls back to the sprites below,
		// so a half-finished character is still playable.
	}
	if a.walking do return a.walk, i32(a.anim_time * a.walk_fps), a.facing_left
	return a.idle, i32(a.anim_time * a.idle_fps), a.facing_left
}
