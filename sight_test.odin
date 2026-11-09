package nengine

import "core:strings"
import "core:testing"

// Nobody speaks to her from out of the picture (sight.odin): what real frames
// do to a person spoken to while they go, come or are somewhere else.

// A yard 1000 wide with a side east and west; Moore walks on from the west
// and off to the east, Otto comes and goes at once, Lucy has a line only in
// the next room.
@(private = "file")
SIGHT_YARD :: `scene yard
walk 0,100 1000,100 1000,200 0,200
side east to=yard span=120,180
side west to=yard span=120,180
obj moore pos=500,150 char=moore when=moore_here enters=west leaves=east
obj otto pos=300,150 char=otto when=otto_here
`

@(private = "file")
SIGHT_NEXT :: `scene next
walk 0,100 1000,100 1000,200 0,200
obj lucy pos=100,150 char=lucy when=lucy_next
`

// A picture for every pose, painted nowhere: enough for person_unseen.
@(private = "file", thread_local)
sight_art: Character_Art

@(private = "file", thread_local)
ada_art: Character_Art

@(private = "file", thread_local)
sight_people: [4]Speaker

@(private = "file", thread_local)
sight_speakers: [4]^Speaker

@(private = "file")
fake_art :: proc(a: ^Character_Art) {
	a.parts = make(map[string]Part_Art)
	for part in ([]string{"front", "back", "left", "right", "walk_front", "walk_back", "walk_left", "walk_right"}) {
		a.parts[part] = Part_Art{sprite = {texture = {id = 1}, frame_w = 40, frame_h = 100, frames = 1}}
	}
}

@(private = "file")
sight_world :: proc(t: ^testing.T) -> World {
	fake_art(&sight_art)
	fake_art(&ada_art)
	w: World
	for text in ([]string{SIGHT_YARD, SIGHT_NEXT}) {
		s, ok := parse_scene(text, nil)
		testing.expect(t, ok)
		append(&w.scenes, s)
	}
	_, ok := resolve_exits(&w)
	testing.expect(t, ok)
	for &sc in w.scenes do for &o in sc.objects do if o.walks do o.actor.character = &sight_art
	sight_people = {{name = "Ada"}, {name = "Moore"}, {name = "Otto"}, {name = "Lucy"}}
	for &s, i in sight_people do sight_speakers[i] = &s
	w.speakers = sight_speakers[:]
	refresh_world(&w)
	w.player = {pos = {200, 150}, speed = 120, character = &ada_art}
	w.time = 1
	return w
}

@(private = "file")
sight_tidy :: proc(w: ^World) {
	destroy_world(w)
	delete(sight_art.parts)
	delete(ada_art.parts)
	sight_art, ada_art = {}, {}
}

@(private = "file")
sight_frames :: proc(w: ^World, secs: f32) {
	for _ in 0 ..< int(secs * 60) do update(w, 1.0 / 60)
}

@(private = "file")
says :: proc(w: ^World, c: ^Conversation, who: int, text: string) {
	lines := make([]Talk_Line, 1, context.temp_allocator)
	lines[0] = {who = sight_speakers[who], text = text}
	begin_conversation(w, c, lines)
}

@(private = "file")
read_out :: proc(w: ^World) {
	for talking(w) do advance_conversation(w)
}

@(test)
somebody_gone_at_once_stays_in_the_picture_until_the_screen_is_hers :: proc(t: ^testing.T) {
	w := sight_world(t)
	defer sight_tidy(&w)
	sc := current_scene(&w)
	set_flag(&w, "otto_here")
	otto := &sc.objects[1]
	testing.expect(t, !otto.hidden && !otto.coming, "no enters=: here at once")

	// The answer that spends the turn that takes him away.
	set_flag(&w, "otto_here", false)
	c: Conversation
	says(&w, &c, 2, "Stoked at five.")
	testing.expect(t, object_here(sc, "otto") == nil, "gone, to the parser")
	_, why := person_in_sight(&w, sc, "otto")
	testing.expect_value(t, why, "")
	sight_frames(&w, 2)
	_, why = person_in_sight(&w, sc, "otto")
	testing.expect_value(t, why, "")
	read_out(&w)
	sight_frames(&w, 0.1)
	testing.expect(t, !otto.going)
	_, why = person_in_sight(&w, sc, "otto")
	testing.expect_value(t, why, "not here")
}

@(test)
somebody_walking_on_arrives_when_a_line_goes_up :: proc(t: ^testing.T) {
	w := sight_world(t)
	defer sight_tidy(&w)
	sc := current_scene(&w)
	moore := &sc.objects[0]
	set_flag(&w, "moore_here")
	testing.expect(t, moore.coming)
	_, why := person_in_sight(&w, sc, "moore")
	testing.expect(t, strings.has_prefix(why, "off the screen"), why)
	c: Conversation
	says(&w, &c, 1, "That's the plain.")
	testing.expect(t, !moore.coming, "arrived")
	_, why = person_in_sight(&w, sc, "moore")
	testing.expect_value(t, why, "")
	testing.expect(t, near_to_sight(moore.pos, {500, 150}))
}

@(test)
spoken_to_while_walking_off_they_stop_and_turn_to_her :: proc(t: ^testing.T) {
	w := sight_world(t)
	defer sight_tidy(&w)
	sc := current_scene(&w)
	moore := &sc.objects[0]
	set_flag(&w, "moore_here")
	sight_frames(&w, 10)
	testing.expect(t, !moore.coming && near_to_sight(moore.pos, {500, 150}))

	set_flag(&w, "moore_here", false)
	testing.expect(t, moore.going)
	sight_frames(&w, 0.5)
	testing.expect(t, moore.pos.x > 510, "on his way east")
	testing.expect(t, object_here(sc, "moore") == nil)

	talk := Command{verb = "talk to", noun = "moore"}
	call_back(&w, sc, talk)
	testing.expect(t, object_here(sc, "moore") == moore, "stopped, and here to be spoken to")
	testing.expect(t, moore.held && !moore.going && !moore.actor.moving)
	testing.expect_value(t, moore.actor.facing, Facing.Left) // she is west of him
	at := moore.pos
	refresh_world(&w) // any flag: he stays while she is with him
	testing.expect(t, !moore.hidden)

	c: Conversation
	says(&w, &c, 1, "Miss.")
	sight_frames(&w, 2)
	testing.expect(t, near_to_sight(moore.pos, at), "standing while he speaks")
	read_out(&w)
	sight_frames(&w, SIGHT_LINGER + 0.2)
	testing.expect(t, !moore.held && moore.going, "and on his way again")
	sight_frames(&w, 20)
	testing.expect(t, !moore.going && moore.hidden)

	// Gone: not to be spoken to, and nobody stops.
	call_back(&w, sc, talk)
	testing.expect(t, object_here(sc, "moore") == nil)
	_, why := person_in_sight(&w, sc, "moore")
	testing.expect_value(t, why, "not here")
}

@(private = "file")
off_through_the_net :: proc(w: ^World, line: Talk_Line) -> bool {
	return strings.has_prefix(line.text, "(through the net")
}

@(test)
a_speaker_from_another_room_is_called_into_sight_beside_her :: proc(t: ^testing.T) {
	w := sight_world(t)
	defer sight_tidy(&w)
	w.sight.voice_off = off_through_the_net
	c: Conversation
	says(&w, &c, 3, "Lucy. How long have you been doing this?")
	testing.expect_value(t, len(w.sight.called), 1)
	n := w.sight.called[0]
	testing.expect(t, n.who == sight_speakers[3])
	testing.expect(t, abs(n.actor.pos.x - w.player.pos.x) >= CALLED_APART * 0.6, "beside her, not on her")
	testing.expect(t, n.actor.pos.x > w.player.pos.x, "towards the middle of the room")
	testing.expect_value(t, n.actor.facing, Facing.Left)
	testing.expect_value(t, w.player.facing, Facing.Right) // and she turns to her
	// Her own lines call nobody.
	says(&w, &c, 0, "Nine days.")
	testing.expect_value(t, len(w.sight.called), 1)

	sight_frames(&w, 1)
	testing.expect_value(t, len(w.sight.called), 1)
	read_out(&w)
	sight_frames(&w, SIGHT_LINGER + 0.2)
	testing.expect(t, len(w.sight.called) == 1 && w.sight.called[0].leaving, "off through a side")
	sight_frames(&w, 20)
	testing.expect_value(t, len(w.sight.called), 0)

	// A voice off is nobody's to call, and nor are their later lines.
	says(&w, &c, 3, "(through the net, pleasant) Is that the laundry?")
	says(&w, &c, 3, "Leave it on the cot.")
	testing.expect_value(t, len(w.sight.called), 0)
}

@(test)
the_watch_finds_a_ghost_and_not_a_person_in_sight :: proc(t: ^testing.T) {
	w := sight_world(t)
	defer sight_tidy(&w)
	defer sight_watch_reset()
	sight_watch_reset()
	sc := current_scene(&w)
	set_flag(&w, "moore_here") // walking on, off the screen
	sight_check_line(&w, {who = sight_speakers[1], text = "That's the plain."})
	testing.expect_value(t, len(sight_watch.ghosts), 1)
	sight_frames(&w, 10)
	sight_check_line(&w, {who = sight_speakers[1], text = "That's the plain."})
	testing.expect_value(t, len(sight_watch.ghosts), 1)
	sight_check_command(&w, sc, Command{verb = "talk to", noun = "moore"})
	testing.expect_value(t, len(sight_watch.ghosts), 1)
	testing.expect_value(t, sight_watch.checked, 1)
}

@(private = "file")
near_to_sight :: proc(a, b: [2]f32, by: f32 = 3) -> bool {
	return abs(a.x - b.x) <= by && abs(a.y - b.y) <= by
}
