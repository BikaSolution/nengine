package nengine

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

// In sight: nobody speaks to her from out of the picture.
//
// The parser's "here" is a person's line in the scene file whose when= holds
// (object_here). The eye's is more: a picture for the pose they are in, and
// that picture inside the room's frame. With frames running the two came
// apart, and she was seen talking to nobody (Nick's playthrough, 24 Oct):
//
// - Somebody whose answer spent a turn, and the turn took them away: gone
//   from the picture before their first word. Now a person who goes at once
//   (no `leaves=`) is gone to the parser at once and stays in the picture
//   until the screen is hers again (side.odin, person_pop); one who walks
//   off waits for it too, as everybody does under a conversation.
// - Somebody walking on through a side when a line of a conversation went up
//   was held off the screen for the length of it. Now everybody walking on in
//   her room arrives when a line goes up (show_line, people_arrive).
// - Somebody she speaks to while they walk off stops, turns to her, and is
//   there to be spoken to (call_back); they go on their way once she has
//   finished with them (sight_release).
// - A line said to her face by somebody with no line in the room at all (a
//   beat written for a room they are not drawn in): they are called into
//   sight beside her for as long as the screen is held, and walk off after
//   (call_into_sight). A voice that is not to her face (through a net, from
//   somewhere in the dark, at the top of a ladder) is the game's to say:
//   World.sight.voice_off.
//
// And the check: `!autoplay <script>` (autoplay.odin) plays a script in real
// frames in the harness and lists every ghost — a person spoken to, or saying
// a line to her face, who is not in sight.

// The verbs that speak to somebody, for call_back and the watch. A game with
// other words for it sets its own.
TALK_VERBS := [?]string{"talk to", "ask", "tell", "show", "give"}
talk_verbs: []string = TALK_VERBS[:]

// Somebody called into sight to say their lines (call_into_sight).
Called :: struct {
	who:     ^Speaker,
	actor:   Actor,
	leaving: bool, // walking off through a side, now the screen is hers
}

// World.sight: who has been called into sight in the room she is in, and the
// game's word on which lines are voices off.
Sight :: struct {
	called:     [dynamic]Called,
	// True for a line not said to her face: heard from another screen,
	// through something, from the dark. nil: every line is to her face.
	// Asked of a speaker's first line while the screen is held; their later
	// lines are off too, until the screen is hers again (`off`).
	voice_off:  proc(w: ^World, line: Talk_Line) -> bool,
	off:        [dynamic]^Speaker,
	// The screen hers again since this world time (freed), for SIGHT_LINGER.
	free_since: f32,
	freed:      bool,
}

// How long the screen is hers before the people who came to speak go: a
// beat's next conversation, a moment later, finds them still there.
SIGHT_LINGER :: f32(0.5)

// Is this line's speaker a voice off, while the screen is held?
@(private)
voice_is_off :: proc(w: ^World, line: Talk_Line) -> bool {
	for s in w.sight.off do if s == line.who do return true
	if w.sight.voice_off == nil || !w.sight.voice_off(w, line) do return false
	append(&w.sight.off, line.who)
	return true
}

// Why somebody is not in sight, or "" when they are.
person_unseen :: proc(w: ^World, sc: ^Scene, o: ^Object) -> string {
	// Going (walking off, or gone at once and still in the picture until the
	// screen is hers) is gone to the parser, and drawn.
	if o.hidden && !o.going do return "gone"
	if !o.walks {
		// A person drawn as a still picture, or a voice the room places
		// behind a door (no picture at all, on purpose).
		if o.sprite_name == "" do return ""
		sprite := o.sprite
		if o.lit.painted != {} do sprite = o.lit.by[room_light(w, sc)]
		if sprite.texture.id == 0 do return fmt.tprintf("no picture %q in this light", o.sprite_name)
		r, _ := sprite_grid_box(sprite, o.pos)
		return box_unseen(sc, {r.x, r.y, r.width, r.height})
	}
	return actor_unseen(sc, o.actor, o.char_name)
}

@(private = "file")
actor_unseen :: proc(sc: ^Scene, a: Actor, char_name: string) -> string {
	s, _, _ := actor_picture(a)
	if s.texture.id == 0 {
		pose := a.pose if a.pose != "" else facing_part(a.facing, a.walking)
		return fmt.tprintf("no art for %v's pose %q", char_name, pose)
	}
	if a.sink > 0 && a.pos.y < a.sink do return "sunk behind the brink"
	fw, fh := f32(s.frame_w), f32(s.frame_h)
	return box_unseen(sc, {f32(i32(a.pos.x - fw / 2)), f32(i32(a.pos.y - fh)), fw, fh})
}

// The canvas, or a usual one where there is none yet (a test).
@(private = "file")
screen_size :: proc() -> [2]f32 {
	return {f32(WIDTH) if WIDTH > 0 else 1024, f32(HEIGHT) if HEIGHT > 0 else 640}
}

// Less than a third of the picture inside the room's frame is not in sight.
@(private = "file")
box_unseen :: proc(sc: ^Scene, b: [4]f32) -> string {
	if b[2] <= 0 || b[3] <= 0 do return "no picture"
	x0, y0 := max(b[0], 0), max(b[1], 0)
	size := screen_size()
	h := room_height(sc) if HEIGHT > 0 else size.y
	x1, y1 := min(b[0] + b[2], size.x), min(b[1] + b[3], h)
	inside := max(x1 - x0, 0) * max(y1 - y0, 0) / (b[2] * b[3])
	if inside < 0.34 do return fmt.tprintf("off the screen (%.0f,%.0f, %.0f%% inside)", b[0] + b[2] / 2, b[1] + b[3], inside * 100)
	return ""
}

// The person called `name` here, in sight: the first line of theirs that is.
// `why` says what is wrong otherwise; "not here" if no line of theirs holds.
person_in_sight :: proc(w: ^World, sc: ^Scene, name: string) -> (o: ^Object, why: string) {
	why = "not here"
	for &obj in sc.objects {
		if obj.name != name || (obj.hidden && !obj.going) do continue
		if r := person_unseen(w, sc, &obj); r != "" {
			why = r
			continue
		}
		return &obj, ""
	}
	return nil, why
}

// Is `name` somebody: a person's line in this room, whatever its when=, or
// a speaker the game has?
@(private)
is_person_name :: proc(w: ^World, sc: ^Scene, name: string) -> bool {
	if name == "" do return false
	for o in sc.objects do if o.name == name && o.walks do return true
	return speaker_named(w, name) != nil
}

// Who a command speaks to, if it speaks to anybody: TALK TO X, ASK X ABOUT,
// TELL X; SHOW (or GIVE) THING TO X.
@(private)
addressed :: proc(w: ^World, sc: ^Scene, cmd: Command) -> string {
	speaks := false
	for v in talk_verbs do if v == cmd.verb do speaks = true
	if !speaks do return ""
	if cmd.prep != "about" && is_person_name(w, sc, cmd.noun2) do return cmd.noun2
	if is_person_name(w, sc, cmd.noun) do return cmd.noun
	return ""
}

// Is this person's line one the speaker speaks for: by its name, or by its
// character's (a line called lucy_shed, char=lucy)?
@(private = "file")
speaks_as :: proc(w: ^World, o: ^Object, s: ^Speaker) -> bool {
	return speaker_named(w, o.name) == s || (o.char_name != "" && speaker_named(w, o.char_name) == s)
}

// --- Spoken to while walking off ---

// TALK TO (ASK, SHOW...) somebody walking off through a side, in sight: they
// stop where they are and turn to her, and are here to be spoken to until she
// has finished with them (sight_release). Before the command is dispatched.
@(private)
call_back :: proc(w: ^World, sc: ^Scene, cmd: Command) {
	who := addressed(w, sc, cmd)
	if who == "" || object_here(sc, who) != nil do return
	for &o in sc.objects {
		if o.name != who || !o.walks || !o.going do continue
		if person_unseen(w, sc, &o) != "" do continue
		o.going = false
		o.held = true
		o.hidden = false
		o.actor.moving = false
		o.actor.walking = false
		o.actor.legs_len = 0
		o.actor.straight = false
		o.actor.sink = 0
		o.actor.pose = "" // standing, whatever their line had them doing
		o.pos = o.actor.pos
		face_towards(&o.actor, w.player.pos - o.actor.pos)
		return
	}
}

// --- Called into sight ---

// A line going up (show_line): said to her face by somebody with no line in
// this room that holds, they come into sight beside her for as long as the
// screen is held. Not a line in a close-up, at an aperture, in a ride or a
// cut, a thought, a card, her own, or one the game calls a voice off.
@(private)
call_into_sight :: proc(w: ^World, line: Talk_Line) {
	s := line.who
	w.sight.freed = false
	if s == nil || line.card || line.thinking || (line.shot != nil && line.shot.texture.id != 0) do return
	if len(w.scenes) == 0 || w.current < 0 || w.dead || peeping(w) || riding(w) || cutting(w) do return
	sc := current_scene(w)
	// Here already: a line of theirs that holds (drawn, or a voice the room
	// puts behind a door), or called in for an earlier line.
	for &o in sc.objects do if (!o.hidden || o.going) && speaks_as(w, &o, s) do return
	for &c in w.sight.called do if c.who == s {
		if c.leaving {
			// Back for another word.
			c.leaving = false
			c.actor.moving = false
			c.actor.walking = false
			c.actor.legs_len = 0
			c.actor.straight = false
			c.actor.sink = 0
			face_towards(&c.actor, w.player.pos - c.actor.pos)
		}
		return
	}
	if voice_is_off(w, line) do return
	art, speed := speaker_art(w, s)
	if art == nil || art == w.player.character do return
	at := beside_her(w, sc)
	a := Actor {
		pos       = at,
		speed     = speed if speed > 0 else 120,
		character = art,
		idle_fps  = 4,
		walk_fps  = 8,
	}
	face_towards(&a, w.player.pos - at)
	append(&w.sight.called, Called{who = s, actor = a})
	face_towards(&w.player, at - w.player.pos)
}

// The character art a speaker is drawn with: any person's line, in any room,
// that is theirs.
@(private = "file")
speaker_art :: proc(w: ^World, s: ^Speaker) -> (art: ^Character_Art, speed: f32) {
	for &sc in w.scenes do for &o in sc.objects {
		if o.walks && o.actor.character != nil && speaks_as(w, &o, s) do return o.actor.character, o.actor.speed
	}
	return nil, 0
}

// How far apart, along the floor, she and the people called to her stand.
CALLED_APART :: f32(64)

// A place beside her on the floor: towards the middle of the room first, then
// the other side, then further out; not on top of anybody in sight.
@(private = "file")
beside_her :: proc(w: ^World, sc: ^Scene) -> [2]f32 {
	p := w.player.pos
	inward := f32(1) if p.x < screen_size().x / 2 else -1
	first := p + {inward * CALLED_APART, 0}
	for k in 1 ..= 4 {
		for side in ([2]f32{inward, -inward}) {
			at := clamp_to_polygon(p + {side * CALLED_APART * f32(k), 0}, sc.walk_area)
			if length(at - p) < CALLED_APART * 0.6 do continue
			if !crowded(w, sc, at) do return at
		}
	}
	return clamp_to_polygon(first, sc.walk_area)
}

@(private = "file")
crowded :: proc(w: ^World, sc: ^Scene, at: [2]f32) -> bool {
	near :: proc(a, b: [2]f32) -> bool {return abs(a.x - b.x) < CALLED_APART * 0.75 && abs(a.y - b.y) < 40}
	for c in w.sight.called do if near(c.actor.pos, at) do return true
	for o in sc.objects do if o.walks && (!o.hidden || o.going) && near(o.actor.pos, at) do return true
	return false
}

// The screen is hers again (update), and has been for SIGHT_LINGER: whoever
// was called into sight walks off through the nearest side, or goes at once
// in a room with none; whoever was called back from walking off goes on
// their way, unless she is still on her way to them.
@(private)
sight_release :: proc(w: ^World) {
	if !w.sight.freed {
		w.sight.freed = true
		w.sight.free_since = w.time
	}
	if w.time - w.sight.free_since < SIGHT_LINGER do return
	sight_release_now(w)
}

@(private = "file")
sight_release_now :: proc(w: ^World) {
	clear(&w.sight.off)
	if len(w.scenes) == 0 || w.current < 0 do return
	sc := current_scene(w)
	released := false
	for &o in sc.objects {
		if !o.held do continue
		if approaching(w) && w.approach.object == o.name do continue
		o.held = false
		released = true
	}
	if released {
		// Off they go, as a flag turned in front of her sends them (person_moves).
		w.flag_live = true
		refresh_scene(w, sc)
		w.flag_live = false
	}
	for i := len(w.sight.called) - 1; i >= 0; i -= 1 {
		c := &w.sight.called[i]
		if c.leaving do continue
		if !walk_off(sc, &c.actor) do ordered_remove(&w.sight.called, i)
		else do c.leaving = true
	}
}

// Off through the side nearest them, as person_leave walks a person off.
// False if the room has no side to go by.
@(private = "file")
walk_off :: proc(sc: ^Scene, a: ^Actor) -> bool {
	best, far := -1, f32(1e30)
	for s, i in sc.sides {
		b, _, ok := side_beyond(sc, s, along(s.dir, a.pos))
		if !ok do continue
		if d := length(b - a.pos); d < far do best, far = i, d
	}
	if best < 0 do return false
	s := sc.sides[best]
	b, beyond, _ := side_beyond(sc, s, along(s.dir, a.pos))
	walk_legs(a, []Leg{{b, false}, {beyond, true}})
	a.sink = b.y if s.dir == .North else 0
	return true
}

// Once a frame, with the people (update): the called walking off.
@(private)
sight_update :: proc(w: ^World, dt: f32) {
	if len(w.scenes) == 0 || w.current < 0 do return
	sc := current_scene(w)
	for i := len(w.sight.called) - 1; i >= 0; i -= 1 {
		c := &w.sight.called[i]
		if !c.leaving do continue
		before := c.actor.pos
		actor_follow_target(&c.actor, dt, sc)
		actor_tick(&c.actor, dt, before)
		if !c.actor.moving do ordered_remove(&w.sight.called, i)
	}
}

// Nobody called into sight any more: a new room, or the harness between two
// lines (the frames after it would have walked them off).
@(private)
sight_clear :: proc(w: ^World) {
	clear(&w.sight.called)
	clear(&w.sight.off)
}

// The harness, after a line: what the frames after it would do once the
// screen is hers — the called gone, the called-back on their way, and anybody
// gone at once out of the picture (person_pop).
@(private)
sight_settle :: proc(w: ^World) {
	if talking(w) || announcing(w) || cutting(w) do return
	sight_release_now(w)
	sight_clear(w)
	if len(w.scenes) == 0 || w.current < 0 do return
	for &o in current_scene(w).objects do if o.going && o.actor.legs_len == 0 && !o.actor.moving do settle_going(&o)
}

// --- The watch a frames run keeps ---

// What a frames run found: everybody spoken to who was not in sight, and
// every line a person said to her face from out of it.
Sight_Watch :: struct {
	on:      bool,
	lines:   int, // lines that went up
	checked: int, // commands to a person, seen
	heard:   int, // lines said by a person in the room, seen
	called:  int, // lines said by somebody called into sight
	ghosts:  [dynamic]string,
	snaps:   string, // a folder: a picture of the frame at every ghost
	snap_n:  int,
}

sight_watch: Sight_Watch

@(private)
sight_watch_reset :: proc() {
	for g in sight_watch.ghosts do delete(g)
	delete(sight_watch.ghosts)
	sight_watch = {}
}

// At a command's dispatch: a person spoken to, here as the parser has it
// (is_here) and not in sight, is a ghost.
@(private)
sight_check_command :: proc(w: ^World, sc: ^Scene, cmd: Command) {
	who := addressed(w, sc, cmd)
	if who == "" do return
	sight_watch.checked += 1
	if !is_here(sc, who) do return // the game says they are not here
	if _, why := person_in_sight(w, sc, who); why != "" {
		n := sight_snap(w)
		append(&sight_watch.ghosts, fmt.aprintf("%03d\t%v\t%v\t%v %v %v\tspoken to: %v",
			n, clock_face(clock_minute(w)), sc.name, cmd.verb, cmd.noun, cmd.noun2, why))
	}
}

// A line up (autoplay_bang, once a line): said by a person to her face, and
// they are not in sight, is a ghost — a line of theirs here that holds and is
// not drawn, or none here and nobody called in. Voices off, close-ups,
// apertures, rides and cuts are not to her face.
@(private)
sight_check_line :: proc(w: ^World, l: Talk_Line) {
	sight_watch.lines += 1
	s := l.who
	if s == nil || l.card || l.thinking || (l.shot != nil && l.shot.texture.id != 0) do return
	if riding(w) || cutting(w) || peeping(w) || w.dead do return
	for off in w.sight.off do if off == s do return // a voice off (voice_is_off)
	sc := current_scene(w)
	text := l.text if len(l.text) < 60 else l.text[:60]
	after := string(w.last_input[:w.last_len])
	holds := false
	why := ""
	for &o in sc.objects {
		if !speaks_as(w, &o, s) || (o.hidden && !o.going) do continue
		holds = true
		why = person_unseen(w, sc, &o) if o.walks else ""
		if why == "" do break
	}
	if holds {
		sight_watch.heard += 1
		if why == "" do return
	} else {
		for c in w.sight.called do if c.who == s {
			sight_watch.called += 1
			if r := actor_unseen(sc, c.actor, s.name); r == "" do return
		}
		art, _ := speaker_art(w, s)
		if art == nil || art == w.player.character do return // a voice, a call: nobody with a picture
		why = "not in this room"
	}
	n := sight_snap(w)
	append(&sight_watch.ghosts, fmt.aprintf("%03d\t%v\t%v\t%v: %v\tsays a line: %v [after %q]",
		n, clock_face(clock_minute(w)), sc.name, s.name, text, why, after))
}

// The watch's report: how much it saw, and every ghost.
@(private)
sight_report :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%v lines, %v spoken to, %v said in sight, %v by somebody called into sight, %v ghost(s)",
		sight_watch.lines, sight_watch.checked, sight_watch.heard, sight_watch.called, len(sight_watch.ghosts))
	for g in sight_watch.ghosts do fmt.sbprintf(&b, "\n    ghost\t%v", g)
	return strings.to_string(b)
}

@(private = "file")
sight_target: rl.RenderTexture2D

// A picture of the frame as the window would show it (draw_canvas), for the
// ghost just found; its number, or 0 with no folder to put it in.
@(private = "file")
sight_snap :: proc(w: ^World) -> int {
	if sight_watch.snaps == "" || riding(w) do return 0
	sight_watch.snap_n += 1
	if sight_target.id == 0 do sight_target = rl.LoadRenderTexture(WIDTH, HEIGHT)
	ride_draw_setup() // shaders made inside a texture mode unbind it: first
	rl.BeginTextureMode(sight_target)
	rl.ClearBackground(rl.BLACK)
	draw_canvas(w)
	rl.EndTextureMode()
	img := rl.LoadImageFromTexture(sight_target.texture)
	rl.ImageFlipVertical(&img)
	rl.ExportImage(img, fmt.ctprintf("%v/ghost_%03d.png", sight_watch.snaps, sight_watch.snap_n))
	rl.UnloadImage(img)
	return sight_watch.snap_n
}
