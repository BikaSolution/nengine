package nengine

import "core:fmt"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

// Cutscenes: the game playing itself for a while.
//
// A cutscene is a room, a cast, and a list of cues on a clock. It runs in a
// real scene with real character art, so the moment it ends the player is
// standing where the cutscene left them and nothing has to be handed over.
//
//     cut arrival scene=veranda
//     cast ada  char=ada  at=240,470 facing=right
//     cast heir char=heir at=700,470 facing=left
//     0.0  ada   walk_to 420,470
//     1.6  heir  face left
//     2.0  heir  say You're the agency girl.
//     3.4  ada   think He knows my name.
//     4.0  line  A2.GT.FENCE 3-5
//     5.0  camera shake 0.4
//     6.0  end
//
// The times are seconds from the start and the file is kept in that order.
// A cue fires when the clock passes it; nothing waits for anything else, which
// means a cutscene is a thing you time rather than a thing you program. That
// is the whole design: an author can read the left-hand column and know what
// happens when, and the editor can draw it as a timeline because it is one.
//
// What a cue may do is deliberately small — walk, turn, play a part, speak,
// think, a line of narration, a dialogue node's lines, a shake, a sound, and end. Everything else the engine can do
// is a trigger's job, not a cutscene's.

Cue_Action :: enum {
	Walk_To, // walk to a spot, in their own time
	Face,    // turn on the spot
	Play,    // play a part of their character: once, a few times, or for a while
	Say,     // a speech box, with their portrait
	Think,   // a thought box
	Narrate, // a plain message with nobody's portrait
	Line,    // lines of a dialogue node, by their own speakers (nodes.odin)
	Shake,   // the camera
	Sound,   // play a named sound
	Leave,   // off through a side of the room and out of sight (side.odin)
	End,     // stop here, whatever the last cue's time was
}

Cue :: struct {
	at:     f32,    // seconds from the start
	who:    string,  // a cast name; "" for narration, the camera and sounds
	action: Cue_Action,
	to:     [2]f32, // Walk_To
	facing: Facing, // Face
	text:   string, // Say, Think, Narrate, the sound's name for Sound, the node's id for Line
	amount: f32,    // Shake: how long. Play: seconds, when it is not `times`
	times:  int,    // Play: how many times through; 0 is for `amount` seconds
	lines:  [2]int, // Line: the first and last of the node's lines, counted from 1
	tag:    string, // Line: which telling (play_node's `tag`); "" is the untagged lines only
	dir:    Compass, // Leave
}

Cast_Member :: struct {
	name:      string, // what the cues call them
	character: string, // which .char they wear
	at:        [2]f32, // where they stand when it starts
	facing:    Facing,
	// Written without `at=`, or without `facing=`: somebody already in the
	// room (or the player) starts where she stands, or facing her own way.
	// Played in a World only; see play_cutscene.
	keep_place:  bool,
	keep_facing: bool,
	// `enter=west`: brought on through that side of the room, from where
	// they went off in the last cut (side.odin).
	enter:       Maybe(Compass),
}

Cutscene :: struct {
	name:  string,
	scene: string, // the room it plays in
	people: [dynamic]Cast_Member, // `cast` in the file; `cast` is a keyword here
	cues:  [dynamic]Cue,
}

cutscene_new :: proc(name: string) -> Cutscene {
	return Cutscene{name = strings.clone(name), scene = strings.clone("")}
}

cutscene_destroy :: proc(c: ^Cutscene) {
	delete(c.name)
	delete(c.scene)
	for m in c.people {
		delete(m.name)
		delete(m.character)
	}
	delete(c.people)
	for q in c.cues {
		delete(q.who)
		delete(q.text)
		delete(q.tag)
	}
	delete(c.cues)
	c^ = {}
}

// When the last thing happens. An `end` cue sets it outright; otherwise it's
// the last cue plus a breath, so a cutscene never cuts off mid-sentence.
cutscene_length :: proc(c: ^Cutscene) -> f32 {
	last := f32(0)
	for q in c.cues {
		if q.action == .End do return q.at
		last = max(last, q.at)
	}
	return last + 2
}

cutscene_member :: proc(c: ^Cutscene, name: string) -> int {
	for m, i in c.people do if m.name == name do return i
	return -1
}

// Cues are kept in time order, because the file is read in order and the
// player walks it forwards. Insertion sort: a cutscene has tens of cues, not
// thousands, and one has usually just moved a little.
cutscene_sort :: proc(c: ^Cutscene) {
	for i in 1 ..< len(c.cues) {
		q := c.cues[i]
		j := i - 1
		for j >= 0 && c.cues[j].at > q.at {
			c.cues[j + 1] = c.cues[j]
			j -= 1
		}
		c.cues[j + 1] = q
	}
}

// --- Reading and writing ---

load_cutscene :: proc(path: string) -> (c: Cutscene, ok: bool) {
	text := read_data_file(path) or_return
	return parse_cutscene(text)
}

parse_cutscene :: proc(text: string) -> (c: Cutscene, ok: bool) {
	c.name = strings.clone("")
	c.scene = strings.clone("")
	for raw in data_lines(text) {
		l := parse_line(raw)
		switch l.key {
		case "cut":
			if len(l.words) > 0 {
				delete(c.name)
				c.name = strings.clone(l.words[0])
			}
			if s, has := field(l, "scene"); has {
				delete(c.scene)
				c.scene = strings.clone(s)
			}

		case "cast":
			_, has_at := field(l, "at")
			_, has_facing := field(l, "facing")
			m := Cast_Member {
				name        = strings.clone(l.words[0] if len(l.words) > 0 else "?"),
				character   = strings.clone(field_or(l, "char", "")),
				at          = field_point(l, "at"),
				facing      = parse_facing(field_or(l, "facing", "front")),
				keep_place  = !has_at,
				keep_facing = !has_facing,
			}
			if e, has := field(l, "enter"); has {
				if d, good := compass_of(e); good do m.enter = d
			}
			append(&c.people, m)

		case:
			// Anything else has to start with a number, or it's not a cue.
			at, is_time := strconv.parse_f32(l.key)
			if !is_time do continue
			if q, good := parse_cue(raw, at); good do append(&c.cues, q)
		}
	}
	cutscene_sort(&c)
	return c, true
}

// `<time> <who> <action> <rest>`, or `<time> end`.
@(private = "file")
parse_cue :: proc(raw: string, at: f32) -> (q: Cue, ok: bool) {
	l := parse_line(raw)
	if len(l.words) == 0 do return {}, false
	q.at = at

	// Who the cue is aimed at, and what it asks for. Three shapes:
	//
	//   <t> end                    nobody, nothing after it
	//   <t> narrate <text>         nobody; the word itself is the verb
	//   <t> sound <name>
	//   <t> line <node> <n>[-<m>] [tag=<telling>]
	//   <t> camera shake <secs>    nobody, but the verb is the SECOND word
	//   <t> <who> <verb> <rest>    everybody else
	//
	// `skip` is how many words of the raw line to step over to reach the free
	// text, for the verbs that end in some.
	first := l.words[0]
	verb, who, skip := first, "", 2
	if first == "end" {
		q.action = .End
		q.who = strings.clone("")
		q.text = strings.clone("")
		return q, true
	}
	if len(l.words) < 2 do return {}, false
	switch first {
	case "narrate", "sound", "line":
		verb, skip = first, 2
	case "camera":
		// "camera" names no one; the verb is what it is being asked to do.
		verb, skip = l.words[1], 3
	case:
		who, verb, skip = first, l.words[1], 3
	}
	q.who = strings.clone(who)

	switch verb {
	case "walk_to":
		q.action = .Walk_To
		q.to = word_point(l.words[skip - 1] if len(l.words) >= skip else "")
		q.text = strings.clone("")
	case "face":
		q.action = .Face
		q.facing = parse_facing(l.words[skip - 1] if len(l.words) >= skip else "front")
		q.text = strings.clone("")
	case "play":
		// `play wave once`, `play wave 3x`, or `play chair 3` for three seconds.
		q.action = .Play
		q.text = strings.clone(l.words[skip - 1] if len(l.words) >= skip else "")
		if len(l.words) > skip {
			q.times = play_times(l.words[skip])
			if q.times == 0 do q.amount = number(l.words[skip], 2)
		} else {
			q.times = 1
		}
	case "leave":
		// `4.0 margaret leave east`: off through that side (side.odin).
		d, good := compass_of(l.words[skip - 1] if len(l.words) >= skip else "")
		if !good {
			delete(q.who)
			return {}, false
		}
		q.action = .Leave
		q.dir = d
		q.text = strings.clone("")
	case "say":
		q.action = .Say
		q.text = strings.clone(line_tail(raw, skip))
	case "think":
		q.action = .Think
		q.text = strings.clone(line_tail(raw, skip))
	case "narrate":
		q.action = .Narrate
		q.text = strings.clone(line_tail(raw, skip))
	case "shake":
		q.action = .Shake
		q.amount = number(l.words[skip - 1] if len(l.words) >= skip else "0.4", 0.4)
		q.text = strings.clone("")
	case "sound":
		q.action = .Sound
		q.text = strings.clone(l.words[skip - 1] if len(l.words) >= skip else "")
	case "line":
		// `line A2.GT.FENCE 3`, `line A2.GT.FENCE 3-5`, `... tag=percy`.
		if len(l.words) < 3 do return {}, false
		span, good := parse_line_range(l.words[2])
		if !good do return {}, false
		q.action = .Line
		q.text = strings.clone(l.words[1])
		q.lines = span
		q.tag = strings.clone(field_or(l, "tag", ""))
	case:
		delete(q.who)
		return {}, false
	}
	return q, true
}

cutscene_text :: proc(c: ^Cutscene, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "# nengine cutscene\n")
	fmt.sbprintf(&b, "cut %v", c.name)
	if c.scene != "" do fmt.sbprintf(&b, " scene=%v", c.scene)
	strings.write_string(&b, "\n\n")

	for m in c.people {
		strings.write_string(&b, cast_text(m, context.temp_allocator))
		strings.write_byte(&b, '\n')
	}
	if len(c.people) > 0 do strings.write_string(&b, "\n")

	for q in c.cues {
		strings.write_string(&b, cue_text(q, context.temp_allocator))
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// One `cast` line, as cutscene_text writes it. An editor that keeps a file's
// own lines (the cutscene editor) writes a line it changed with this.
cast_text :: proc(m: Cast_Member, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "cast %v", m.name)
	if m.character != "" do fmt.sbprintf(&b, " char=%v", m.character)
	if !m.keep_place do fmt.sbprintf(&b, " at=%v,%v", int(m.at.x), int(m.at.y))
	if !m.keep_facing do fmt.sbprintf(&b, " facing=%v", facing_text(m.facing))
	if d, has := m.enter.?; has do fmt.sbprintf(&b, " enter=%v", COMPASS_WORDS[d])
	return strings.to_string(b)
}

// One cue's line: its time, then cue_body_text.
cue_text :: proc(q: Cue, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%.2f %v", q.at, cue_body_text(q, context.temp_allocator), allocator = allocator)
}

// A cue's line after its time: `moore walk_to 330,452`, `camera shake 0.40`,
// `end`.
cue_body_text :: proc(q: Cue, allocator := context.temp_allocator) -> string {
	switch q.action {
	case .End:
		return fmt.aprint("end", allocator = allocator)
	case .Walk_To:
		return fmt.aprintf("%v walk_to %v,%v", q.who, int(q.to.x), int(q.to.y), allocator = allocator)
	case .Face:
		return fmt.aprintf("%v face %v", q.who, facing_text(q.facing), allocator = allocator)
	case .Play:
		if q.times == 1 do return fmt.aprintf("%v play %v once", q.who, q.text, allocator = allocator)
		if q.times > 1 do return fmt.aprintf("%v play %v %vx", q.who, q.text, q.times, allocator = allocator)
		return fmt.aprintf("%v play %v %.2f", q.who, q.text, q.amount, allocator = allocator)
	case .Say:
		return fmt.aprintf("%v say %v", q.who, q.text, allocator = allocator)
	case .Think:
		return fmt.aprintf("%v think %v", q.who, q.text, allocator = allocator)
	case .Narrate:
		return fmt.aprintf("narrate %v", q.text, allocator = allocator)
	case .Shake:
		return fmt.aprintf("camera shake %.2f", q.amount, allocator = allocator)
	case .Sound:
		return fmt.aprintf("sound %v", q.text, allocator = allocator)
	case .Leave:
		return fmt.aprintf("%v leave %v", q.who, COMPASS_WORDS[q.dir], allocator = allocator)
	case .Line:
		if q.tag != "" do return fmt.aprintf("line %v %v tag=%v", q.text, line_range_text(q.lines), q.tag, allocator = allocator)
		return fmt.aprintf("line %v %v", q.text, line_range_text(q.lines), allocator = allocator)
	}
	return ""
}

save_cutscene :: proc(c: ^Cutscene, path: string) -> bool {
	return write_data_file(path, cutscene_text(c))
}

// --- Bits of parsing ---

// `3` is {3, 3}; `3-5` is {3, 5}. Lines count from 1, and the last is never
// before the first.
parse_line_range :: proc(s: string) -> (span: [2]int, ok: bool) {
	a, b := s, s
	if dash := strings.index_byte(s, '-'); dash >= 0 do a, b = s[:dash], s[dash + 1:]
	first, ok_a := strconv.parse_int(a)
	last, ok_b := strconv.parse_int(b)
	if !ok_a || !ok_b || first < 1 || last < first do return {}, false
	return {first, last}, true
}

// The other way: {3, 3} is `3`, {3, 5} is `3-5`. Kept well formed, so a cue
// whose numbers were never set still writes something that reads back.
line_range_text :: proc(span: [2]int, allocator := context.temp_allocator) -> string {
	first := max(span[0], 1)
	last := max(span[1], first)
	if last == first do return fmt.aprintf("%v", first, allocator = allocator)
	return fmt.aprintf("%v-%v", first, last, allocator = allocator)
}

@(private = "file")
field_or :: proc(l: Line, name, fallback: string) -> string {
	if s, has := field(l, name); has do return s
	return fallback
}

@(private = "file")
field_point :: proc(l: Line, name: string) -> [2]f32 {
	s, has := field(l, name)
	if !has do return {}
	return word_point(s)
}

@(private = "file")
word_point :: proc(s: string) -> [2]f32 {
	comma := strings.index_byte(s, ',')
	if comma <= 0 do return {}
	return {number(s[:comma], 0), number(s[comma + 1:], 0)}
}

// sound_file.odin has one of these but keeps it to itself.
@(private = "file")
number :: proc(s: string, fallback: f32) -> f32 {
	if v, ok := strconv.parse_f32(s); ok do return v
	return fallback
}

parse_facing :: proc(s: string) -> Facing {
	switch s {
	case "back":  return .Back
	case "left":  return .Left
	case "right": return .Right
	}
	return .Front
}

facing_text :: proc(f: Facing) -> string {
	switch f {
	case .Back:  return "back"
	case .Left:  return "left"
	case .Right: return "right"
	case .Front: return "front"
	}
	return "front"
}

// --- Playing one ---
//
// Two ways. By itself, with its own cast (cutscene_start, cutscene_update,
// cutscene_draw): every cast member is a fresh Actor. Or in the World, in
// the middle of play (play_cutscene): the cut takes the room the player is
// in, borrows the people already standing in it and the player herself, and
// brings on whoever else it names for as long as it lasts.
//
// Either way a walk is a straight line at CUT_SPEED, ignoring the floor:
// that is what the cutscene editor draws and times, so what an author times
// there is what happens in the game, and somebody can walk in from off the
// edge of the floor, which a player never can.

CUT_SPEED :: f32(190)

// Who a cast member is, played in a World.
Cast_Role :: enum {
	Extra,  // brought on for the cutscene, and gone after it
	Person, // somebody already in the room (an object with `char=`)
	Player, // the protagonist
}

Cutscene_Player :: struct {
	cut:     ^Cutscene,
	actors:  [dynamic]Actor, // one per cast member, in the same order (an extra's own)
	t:       f32,            // seconds since it started
	next:    int,            // the next cue to fire
	running: bool,
	// A `line` cue's later lines, each waiting for its moment. In time order.
	queued:  [dynamic]Queued_Line,
	said_at: f32, // `t` when the last line went up, for Enter's grace

	// Played in a World (play_cutscene) rather than by itself. `roles` is
	// empty by itself, and everybody is an extra.
	world:        bool,
	roles:        [dynamic]Cast_Role,
	objs:         [dynamic]int,   // a Person's index among the room's objects
	saved:        [dynamic]Actor, // and how they stood before it, to put back
	player_speed: f32,
	scene:        int,            // the room it is playing in
	then:         proc(w: ^World),
	// What she was on her way to do when it began: given back when it ends,
	// if it left her where she stood (see finish_cutscene).
	resume:       Cut_Resume,
}

// A walk a cutscene interrupted. A cut that starts by itself (a beat, an
// arrival) while she walks to the starboard rail must not eat GO STARBOARD:
// when it ends with her where it found her, in the same room, she carries on.
Cut_Resume :: struct {
	active:    bool,
	room:      int,
	pos:       [2]f32,
	moving:    bool,
	target:    [2]f32,
	approach:  Approach,
	exit_walk: Exit_Walk,
}

Queued_Line :: struct {
	at:   f32,
	line: Talk_Line, // borrowed from the node, which outlives the cutscene
}

// How a cue's words go out: in boxes, not at all (a skip), or to the harness.
@(private = "file")
Cut_Mode :: enum {
	Play,
	Quiet,
	Aloud,
}

// Puts the cast on the floor and starts the clock. `assets` is where the
// character art comes from; a cast member whose .char is missing still walks,
// just invisibly, which is better than refusing to play.
cutscene_start :: proc(p: ^Cutscene_Player, c: ^Cutscene, assets: ^Assets, speed: f32 = CUT_SPEED) {
	cutscene_stop(p)
	p.cut = c
	p.t, p.next, p.running = 0, 0, true
	for m in c.people {
		a := Actor {
			pos      = m.at,
			speed    = speed,
			idle_fps = 4,
			walk_fps = 8,
			facing   = m.facing,
		}
		if art, has := &assets.chars[m.character]; has do a.character = art
		append(&p.actors, a)
	}
}

cutscene_stop :: proc(p: ^Cutscene_Player) {
	delete(p.actors)
	delete(p.queued)
	delete(p.roles)
	delete(p.objs)
	delete(p.saved)
	p^ = {}
}

// True while it is still going. Cues fire when the clock passes them, so a
// slow frame fires everything it stepped over rather than dropping it.
cutscene_update :: proc(p: ^Cutscene_Player, w: ^World, dt: f32) -> bool {
	if !p.running || p.cut == nil do return false
	if !cut_frame(p, w, dt, .Play, nil) do p.running = false
	return p.running
}

// One frame: the cues it passes, then everybody's steps. False at the end.
@(private = "file")
cut_frame :: proc(p: ^Cutscene_Player, w: ^World, dt: f32, mode: Cut_Mode, out: ^strings.Builder) -> bool {
	p.t += dt
	// The cues it passes, and the queued lines, in the order of their times.
	for {
		cue_due := p.next < len(p.cut.cues) && p.cut.cues[p.next].at <= p.t
		line_due := len(p.queued) > 0 && p.queued[0].at <= p.t
		if line_due && (!cue_due || p.queued[0].at <= p.cut.cues[p.next].at) {
			l := p.queued[0].line
			ordered_remove(&p.queued, 0)
			cut_talk_line(w, l, mode, out)
			if mode == .Play do p.said_at = p.t
			continue
		}
		if !cue_due do break
		q := p.cut.cues[p.next]
		p.next += 1
		if !cue_fire(p, w, q, mode, out) do return false
	}
	for i in 0 ..< len(p.actors) {
		a := cast_actor(p, w, i)
		if a == nil do continue
		before := a.pos
		cut_walk(a, dt)
		actor_tick(a, dt, before)
		// The object's own position is what everything else reads.
		if o := cast_object(p, w, i); o != nil do o.pos = a.pos
	}
	if p.t < cutscene_length(p.cut) do return true
	// Without an `end`, a `line` cue's last lines are waited for: the file
	// cannot know how long a node's lines take to read.
	if len(p.queued) == 0 do return false
	for q in p.cut.cues do if q.action == .End do return false
	return true
}

// A straight line, at the actor's speed. See the top of this section.
@(private = "file")
cut_walk :: proc(a: ^Actor, dt: f32) {
	if !a.moving do return
	d := a.target - a.pos
	dist := length(d)
	if dist <= a.speed * dt || dist < 0.5 {
		a.pos = a.target
		if next_leg(a) do return
		a.moving = false
		return
	}
	face_towards(a, d)
	a.pos += d / dist * a.speed * dt
}

// The actor a cast member is: their own, a room person's, or the player.
@(private = "file")
cast_actor :: proc(p: ^Cutscene_Player, w: ^World, i: int) -> ^Actor {
	if i < 0 || i >= len(p.actors) do return nil
	if i < len(p.roles) {
		switch p.roles[i] {
		case .Player:
			return &w.player
		case .Person:
			if o := cast_object(p, w, i); o != nil do return &o.actor
			return nil
		case .Extra:
		}
	}
	return &p.actors[i]
}

@(private = "file")
cast_object :: proc(p: ^Cutscene_Player, w: ^World, i: int) -> ^Object {
	if i < 0 || i >= len(p.roles) || p.roles[i] != .Person do return nil
	if p.scene < 0 || p.scene >= len(w.scenes) do return nil
	objects := &w.scenes[p.scene].objects
	if p.objs[i] < 0 || p.objs[i] >= len(objects) do return nil
	return &objects[p.objs[i]]
}

// Does one cue. False means the cutscene is over.
@(private = "file")
cue_fire :: proc(p: ^Cutscene_Player, w: ^World, q: Cue, mode: Cut_Mode, out: ^strings.Builder) -> bool {
	actor := cast_actor(p, w, cutscene_member(p.cut, q.who))

	switch q.action {
	case .End:
		return false
	case .Walk_To:
		if actor != nil {
			walk_to(actor, q.to)
			actor.pose = "" // nobody walks sitting down
			actor_stop_anim(actor)
		}
	case .Face:
		if actor != nil {
			actor.facing = q.facing
			actor.facing_left = q.facing == .Left
		}
	case .Play:
		if actor != nil {
			if q.times > 0 do actor_play(actor, q.text, times = q.times)
			else do actor_play(actor, q.text, times = 0, secs = max(q.amount, 0.1))
		}
	case .Say, .Think, .Narrate:
		cut_line(w, q, mode, out)
		if mode == .Play do p.said_at = p.t
	case .Line:
		cut_node_lines(p, w, q, mode, out)
		if mode == .Play do p.said_at = p.t
	case .Shake:
		if mode == .Play do w.shake = max(w.shake, q.amount)
	case .Sound:
		if mode != .Quiet do play_sound(w, q.text)
	case .Leave:
		if actor != nil {
			sc: ^Scene = nil
			if p.world && w != nil && p.scene >= 0 && p.scene < len(w.scenes) do sc = &w.scenes[p.scene]
			cut_leave(w if p.world else nil, sc, q.who, actor, q.dir)
		}
	}
	return true
}

// A line, said as a conversation says one: by the World's speaker of that
// name, so a portrait comes with it, or named on the box when there is no
// face to show (and by the cast name, when there is no speaker at all).
@(private = "file")
cut_line :: proc(w: ^World, q: Cue, mode: Cut_Mode, out: ^strings.Builder) {
	who := speaker_named(w, q.who) if q.who != "" else nil
	name := who.name if who != nil else q.who
	switch mode {
	case .Quiet:
	case .Aloud:
		// Not through the message box, so into the play log by hand.
		if q.action == .Narrate || name == "" {
			fmt.sbprintfln(out, "  %v", q.text)
			log_line(w, q.text)
		} else {
			fmt.sbprintfln(out, "  %v: %v", name, q.text)
			log_line(w, fmt.tprintf("%v: %v", name, q.text))
		}
	case .Play:
		if q.action == .Narrate {
			say(w, q.text)
			return
		}
		text := q.text
		if name != "" && (who == nil || who.portrait.texture.id == 0) do text = fmt.tprintf("%v: %v", name, q.text)
		if q.action == .Think do think(w, who, text)
		else do say_as(w, who, text)
	}
}

// A `line` cue: the node's lines it names, out of the telling it names (every
// untagged line, and those tagged `tag`, numbered within that, as play_node
// would play them). The first is said now and each of the rest when the one
// before has had its reading time (line_secs). They are only said: the node
// is not played, so nothing it `sets` is set and it is not marked said.
@(private = "file")
cut_node_lines :: proc(p: ^Cutscene_Player, w: ^World, q: Cue, mode: Cut_Mode, out: ^strings.Builder) {
	first := max(q.lines[0], 1)
	last := max(q.lines[1], first)
	tag := fmt.tprintf(" tag=%v", q.tag) if q.tag != "" else ""
	n, has := node(w, q.text)
	if !has {
		if mode == .Aloud do fmt.sbprintfln(out, "  [no line %v %v%v]", q.text, line_range_text(q.lines), tag)
		return
	}
	at := q.at
	number := 0
	for l, i in n.lines {
		t := n.tags[i] if i < len(n.tags) else ""
		if t != "" && (q.tag == "" || t != q.tag) do continue
		number += 1
		if number < first do continue
		if number > last do break
		if number == first {
			cut_talk_line(w, l, mode, out)
		} else {
			// In time order among any already waiting.
			j := len(p.queued)
			for j > 0 && p.queued[j - 1].at > at do j -= 1
			inject_at(&p.queued, j, Queued_Line{at = at, line = l})
		}
		at += line_secs(l.text)
	}
	if mode == .Aloud do for k in max(number + 1, first) ..= last do fmt.sbprintfln(out, "  [no line %v %v%v]", q.text, k, tag)
}

// One of a node's lines, as a conversation shows it: by its own speaker, with
// the portrait, named on the box when there is no face; a stage direction (no
// speaker) as narration.
@(private = "file")
cut_talk_line :: proc(w: ^World, l: Talk_Line, mode: Cut_Mode, out: ^strings.Builder) {
	name := l.who.name if l.who != nil else ""
	switch mode {
	case .Quiet:
	case .Aloud:
		if name != "" {
			fmt.sbprintfln(out, "  %v: %v", name, l.text)
			log_line(w, fmt.tprintf("%v: %v", name, l.text))
		} else {
			fmt.sbprintfln(out, "  %v", l.text)
			log_line(w, l.text)
		}
	case .Play:
		if l.who == nil {
			say(w, l.text)
			return
		}
		text := l.text
		if name != "" && l.who.portrait.texture.id == 0 do text = fmt.tprintf("%v: %v", name, l.text)
		if l.thinking do think(w, l.who, text)
		else do say_as(w, l.who, text)
	}
}

// Draws the cutscene's own cast, by itself. Call it where the game draws its
// own actors. (Played in a World, the room draws them.)
cutscene_draw :: proc(p: ^Cutscene_Player) {
	if !p.running do return
	for &a, i in p.actors {
		if i < len(p.roles) && p.roles[i] != .Extra do continue
		draw_actor(a)
	}
}

// --- In the middle of play ---
//
//     ne.play_cutscene(w, "the_cow")
//     ne.play_cutscene(w, "the_fence", then = proc(w: ^ne.World) { ne.play_node(w, "A2.GT.KEY") })
//
// Found by name among the loaded assets (`the_cow.cut`, wherever it sits) and
// played in the room the player is in now. A cast member named like a person
// standing in the room (an object with `char=`, shown) is that person; one
// named like the protagonist is her; anybody else is brought on for the
// length of it. While it plays nobody is at the controls — no typing, no
// walking, no clock — and Escape skips to the end. When it ends, `then` runs.

// Plays a loaded cutscene by name. A name with no cutscene behind it plays
// nothing and runs `then` at once, so a game never hangs on art not made yet.
// False if there was no such cutscene.
play_cutscene :: proc(w: ^World, name: string, then: proc(w: ^World) = nil) -> bool {
	if w.assets != nil {
		if c, has := &w.assets.cuts[name]; has do return start_cutscene(w, c, then)
	}
	if then != nil do then(w)
	return false
}

// The same, for a cutscene the game has in hand. It must outlive its playing.
start_cutscene :: proc(w: ^World, c: ^Cutscene, then: proc(w: ^World) = nil) -> bool {
	if c == nil || len(w.scenes) == 0 {
		if then != nil do then(w)
		return false
	}
	// One at a time: a cutscene started over another finishes that one first.
	if cutting(w) do skip_cutscene(w)

	p := &w.cut
	cutscene_stop(p)
	p.cut, p.world, p.running = c, true, true
	p.scene, p.then = w.current, then
	p.player_speed = w.player.speed

	// Her hands are the cutscene's now: whatever she was walking to is off,
	// and kept, to give back if the cut leaves her where she stands.
	p.resume = {
		active    = w.player.moving || approaching(w) || w.exit_walk.active,
		room      = w.current,
		pos       = w.player.pos,
		moving    = w.player.moving,
		target    = w.player.target,
		approach  = w.approach,
		exit_walk = w.exit_walk,
	}
	cancel_approach(w)
	w.exit_walk = {}
	w.player.moving = false
	w.player.heading = {}

	scene := current_scene(w)
	// Anybody still walking on or off through a side (a flag turned on the
	// tick that started this) is put where their lines say first, as leaving
	// the room would: a cut casts people where they are, and nobody finishes
	// a walk after it that the cut has already staged.
	people_settle(scene)
	claimed := make([]bool, len(scene.objects), context.temp_allocator)
	for m in c.people {
		role, obj := Cast_Role.Extra, -1
		if is_protagonist(w, m) {
			role = .Player
		} else if obj = cast_person(scene, m, claimed); obj >= 0 {
			role = .Person
			claimed[obj] = true
		}
		append(&p.roles, role)
		append(&p.objs, obj)

		switch role {
		case .Player:
			cast_place(&w.player, m)
			w.player.speed = CUT_SPEED
			actor_stop_anim(&w.player)
			append(&p.actors, Actor{})
			append(&p.saved, Actor{})
		case .Person:
			o := &scene.objects[obj]
			append(&p.saved, o.actor) // as they stood, to put back after
			cast_place(&o.actor, m)
			o.actor.speed = CUT_SPEED
			o.actor.moving = false
			actor_stop_anim(&o.actor)
			o.pos = o.actor.pos
			append(&p.actors, Actor{})
		case .Extra:
			a := Actor{pos = m.at, speed = CUT_SPEED, idle_fps = 4, walk_fps = 8, facing = m.facing, facing_left = m.facing == .Left}
			if m.keep_place do a.pos = extra_start(c, m, scene)
			a.character = cast_art(w, scene, m)
			append(&p.actors, a)
			append(&p.saved, Actor{})
		}
		// Brought on through a side: just out of sight beyond it, where they
		// went off in the last cut, for their first walk to bring them on.
		if d, has := m.enter.?; has && role != .Player {
			last := len(p.actors) - 1
			if a := cast_actor(p, w, last); a != nil {
				cut_enter(w, scene, m, a, d)
				if o := cast_object(p, w, last); o != nil do o.pos = a.pos
			}
		}
	}
	return true
}

// Is a cutscene playing in the World?
cutting :: proc(w: ^World) -> bool {
	return w.cut.world && w.cut.running
}

// What Escape does: the rest of it at once, in silence — every walk walked,
// every turn turned, nothing more said — and then `then`.
skip_cutscene :: proc(w: ^World) {
	if !cutting(w) do return
	run_to_end(w, .Quiet, nil)
	w.message_until = 0
	w.message_who = nil
	finish_cutscene(w)
}

// What Enter does: on to the next thing said, at the reader's own speed.
// The cutscene's clock jumps to the next `say`, `think`, `narrate`, `line`
// cue (one that says something), or the next line of a `line` range, and
// everything between is done as Escape does it — walks walked as far as they
// would have got by then, turns turned, parts played, sounds and shakes not —
// so the staging is where it would have been had the reader waited. The
// line itself goes up on the next frame. With nothing more to say before the
// end, it goes to the end: skip_cutscene.
advance_cutscene :: proc(w: ^World) {
	if !cutting(w) do return
	p := &w.cut
	at, speaks := next_speech(p, w)
	if !speaks {
		skip_cutscene(w)
		return
	}
	// Up to a hair short of it, so the line fires in play and not in silence.
	for _ in 0 ..< 60 * 60 * 60 {
		left := at - p.t
		if left <= 0.0002 do break
		if !cut_frame(p, w, min(1.0 / 60, left - 0.0001), .Quiet, nil) {
			w.message_until = 0
			w.message_who = nil
			finish_cutscene(w)
			return
		}
	}
}

// When the next line is said: a speech cue that says something, or a queued
// line of a range, whichever comes first — unless the end comes before both.
@(private = "file")
next_speech :: proc(p: ^Cutscene_Player, w: ^World) -> (at: f32, ok: bool) {
	at, ok = max(f32), false
	if len(p.queued) > 0 do at, ok = p.queued[0].at, true
	for i in p.next ..< len(p.cut.cues) {
		q := p.cut.cues[i]
		if q.at >= at do break
		#partial switch q.action {
		case .End:
			return 0, false
		case .Say, .Think, .Narrate:
			return q.at, true
		case .Line:
			if line_cue_speaks(w, q) do return q.at, true
		}
	}
	return
}

// Does a `line` cue name a line that is there? A missing one says nothing,
// and Enter does not stop for it.
@(private = "file")
line_cue_speaks :: proc(w: ^World, q: Cue) -> bool {
	n, has := node(w, q.text)
	if !has do return false
	number := 0
	for _, i in n.lines {
		t := n.tags[i] if i < len(n.tags) else ""
		if t != "" && (q.tag == "" || t != q.tag) do continue
		number += 1
	}
	return number >= max(q.lines[0], 1)
}

// Enter, Space and a click are read as a conversation reads them; this long
// after a line goes up, so a held key does not race through.
CUT_ADVANCE_GRACE :: f32(0.15)

// A frame of play. True while a cutscene holds the screen.
@(private)
update_cutscene :: proc(w: ^World, dt: f32) -> bool {
	if !cutting(w) do return false
	// A moment's grace, so the Escape that ended a conversation and started
	// this does not skip it too.
	if rl.IsKeyPressed(.ESCAPE) && w.cut.t >= 0.15 {
		skip_cutscene(w)
		return true
	}
	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.SPACE) || rl.IsMouseButtonPressed(.LEFT) {
		if w.cut.t - w.cut.said_at >= CUT_ADVANCE_GRACE {
			advance_cutscene(w)
			return true
		}
	}
	cut_tick(w, dt)
	return true
}

// The clock moved on by `dt`, and the end if it came.
@(private)
cut_tick :: proc(w: ^World, dt: f32) {
	if !cutting(w) do return
	if !cut_frame(&w.cut, w, dt, .Play, nil) do finish_cutscene(w)
}

// For the harness: the whole of it at once, the lines it says written down as
// a conversation's are, and then `then`. See script.odin.
@(private)
cutscene_aloud :: proc(w: ^World) -> string {
	if !cutting(w) do return ""
	b := strings.builder_make(context.temp_allocator)
	name := strings.clone(w.cut.cut.name, context.temp_allocator)
	fmt.sbprintfln(&b, "  [cutscene %v]", name)
	// run_to_end, with the harness's `!cutsnap` looking at it (probe.odin).
	for _ in 0 ..< 60 * 60 * 60 {
		if !cut_frame(&w.cut, w, 1.0 / 60, .Aloud, &b) do break
		probe_cut_frame(w)
	}
	probe_cut_frame(w, last = true)
	fmt.sbprintfln(&b, "  [end %v]", name)
	before := strings.clone(message(w), context.temp_allocator)
	finish_cutscene(w)
	// Whatever `then` said in a box, unless it went on into something the
	// harness reads out itself.
	if m := message(w); m != "" && m != before && !talking(w) && !cutting(w) do fmt.sbprintfln(&b, "  %v", m)
	return strings.to_string(b)
}

// Played on, a frame at a time and undrawn, to its end. Capped at an hour.
@(private = "file")
run_to_end :: proc(w: ^World, mode: Cut_Mode, out: ^strings.Builder) {
	for _ in 0 ..< 60 * 60 * 60 {
		if !cut_frame(&w.cut, w, 1.0 / 60, mode, out) do break
	}
}

// The end of it. The player stays where it left her; the people of the room
// go back to what their own lines say they are doing, since the state of the
// world is its flags and not the last cutscene; the extras go.
@(private = "file")
finish_cutscene :: proc(w: ^World, run_then := true) {
	p := &w.cut
	then := p.then
	for role, i in p.roles {
		switch role {
		case .Player:
			w.player.moving = false
			w.player.heading = {}
			w.player.walking = false
			w.player.speed = p.player_speed
			w.player.sink = 0
			w.player.legs_len = 0
			w.player.straight = false
			actor_stop_anim(&w.player)
		case .Person:
			if o := cast_object(p, w, i); o != nil {
				o.actor = p.saved[i]
				o.pos = o.actor.pos
			}
		case .Extra:
		}
	}
	scene := p.scene
	resume := p.resume
	cutscene_stop(p)
	if scene >= 0 && scene < len(w.scenes) do refresh_scene(w, &w.scenes[scene])
	if run_then && then != nil do then(w)
	// Back to what she was doing, if the cut and its `then` left her where she
	// was: same room, same spot, and nothing else has taken over.
	if run_then && resume.active && w.current == resume.room && !cutting(w) &&
	   length(w.player.pos - resume.pos) < 2 && !w.dead {
		w.approach = resume.approach
		w.exit_walk = resume.exit_walk
		if resume.moving do walk_to(&w.player, resume.target)
	}
}

// Stops one without its `then`: a restore, or a new game.
@(private)
abandon_cutscene :: proc(w: ^World) {
	if cutting(w) do finish_cutscene(w, run_then = false)
	else do cutscene_stop(&w.cut)
}

// The protagonist: a cast name the game said means her (World.player_name),
// or one whose .char — named, or by the cast name itself — is the one she wears.
@(private = "file")
is_protagonist :: proc(w: ^World, m: Cast_Member) -> bool {
	if w.player_name != "" && strings.equal_fold(m.name, w.player_name) do return true
	if w.player.character == nil || w.assets == nil do return false
	for key in ([]string{m.character, m.name}) {
		if key == "" do continue
		if art, has := &w.assets.chars[key]; has && art == w.player.character do return true
	}
	return false
}

// Somebody standing in the room who answers to this cast member: an object
// with `char=` that is here now, by name, or failing that by the .char worn.
@(private = "file")
cast_person :: proc(scene: ^Scene, m: Cast_Member, claimed: []bool) -> int {
	for o, i in scene.objects {
		if o.walks && !o.hidden && !claimed[i] && o.name == m.name do return i
	}
	if m.character == "" do return -1
	for o, i in scene.objects {
		if o.walks && !o.hidden && !claimed[i] && o.char_name == m.character do return i
	}
	return -1
}

// What an extra wears: its `char=`, or the .char of a person by that name who
// is not in the room just now, or a .char by the cast name itself.
@(private = "file")
cast_art :: proc(w: ^World, scene: ^Scene, m: Cast_Member) -> ^Character_Art {
	if w.assets == nil do return nil
	key := m.character
	if key == "" {
		for o in scene.objects {
			if o.walks && o.name == m.name && o.char_name != "" {
				key = o.char_name
				break
			}
		}
	}
	if key == "" do key = m.name
	if art, has := &w.assets.chars[key]; has do return art
	return nil
}

@(private = "file")
cast_place :: proc(a: ^Actor, m: Cast_Member) {
	if !m.keep_place do a.pos = m.at
	if !m.keep_facing {
		a.facing = m.facing
		a.facing_left = m.facing == .Left
	}
}

// How far past the side of the room an extra with no `at=` waits.
CUT_OFFSTAGE :: f32(60)

// Where an extra written without `at=` starts: just off the side of the room
// nearer `goes` — the first place it walks to, or the middle of the floor for
// one that never walks — at that place's height. An extra is brought on, so
// it walks in from the edge on its first walk_to rather than appearing in the
// middle of the floor out of nowhere; one that never walks waits out of sight.
// The cutscene editor puts them in the same place, by this.
offstage_start :: proc(goes: [2]f32, room_w: f32) -> [2]f32 {
	x := -CUT_OFFSTAGE if goes.x < room_w / 2 else room_w + CUT_OFFSTAGE
	return {x, goes.y}
}

// The first place cast member `name` walks to, in time order.
cutscene_first_walk :: proc(c: ^Cutscene, name: string) -> (to: [2]f32, ok: bool) {
	first := max(f32)
	for q in c.cues do if q.action == .Walk_To && q.who == name && q.at < first {
		first, to, ok = q.at, q.to, true
	}
	return
}

@(private = "file")
extra_start :: proc(c: ^Cutscene, m: Cast_Member, scene: ^Scene) -> [2]f32 {
	goes, walks := cutscene_first_walk(c, m.name)
	if !walks do goes = floor_middle(scene)
	room_w := f32(scene.background.frame_w) if scene.background.texture.id != 0 else f32(WIDTH)
	if room_w <= 0 do room_w = 1024
	return offstage_start(goes, room_w)
}

@(private = "file")
floor_middle :: proc(sc: ^Scene) -> [2]f32 {
	mid := [2]f32{}
	for pt in sc.walk_area do mid += pt
	if len(sc.walk_area) > 0 do mid /= f32(len(sc.walk_area))
	if len(sc.walk_area) >= 3 do mid = clamp_to_polygon(mid, sc.walk_area)
	return mid
}
