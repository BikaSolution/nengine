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

// One person in two costumes, a line in each of two rooms (char= one way by
// day, another in the evening), and a third room with no line of hers.
@(private = "file")
SEEN_DAY :: `scene day_room
walk 0,100 1000,100 1000,200 0,200
obj lucy pos=100,150 char=lucy when=!evening
`

@(private = "file")
SEEN_EVENING :: `scene evening_room
walk 0,100 1000,100 1000,200 0,200
obj lucy pos=100,150 char=lucy_evening speed=90 when=evening
`

@(private = "file")
SEEN_ELSEWHERE :: `scene elsewhere
walk 0,100 1000,100 1000,200 0,200
`

// A porch where she sits in the day dress whenever a_porch holds, evening or not.
@(private = "file")
SEEN_PORCH :: `scene porch
walk 0,100 1000,100 1000,200 0,200
obj lucy pos=100,150 char=lucy when=a_porch
`

@(private = "file", thread_local)
lucy_day_art: Character_Art

@(private = "file", thread_local)
lucy_evening_art: Character_Art

@(private = "file", thread_local)
seen_people: [2]Speaker

@(private = "file", thread_local)
seen_speakers: [2]^Speaker

@(private = "file")
seen_world :: proc(t: ^testing.T) -> World {
	fake_art(&ada_art)
	fake_art(&lucy_day_art)
	fake_art(&lucy_evening_art)
	lucy_day_art.name, lucy_evening_art.name = "lucy", "lucy_evening"
	w: World
	for text in ([]string{SEEN_DAY, SEEN_EVENING, SEEN_ELSEWHERE, SEEN_PORCH}) {
		s, ok := parse_scene(text, nil)
		testing.expect(t, ok)
		append(&w.scenes, s)
	}
	for &sc in w.scenes do for &o in sc.objects do if o.walks {
		o.actor.character = &lucy_evening_art if o.char_name == "lucy_evening" else &lucy_day_art
	}
	seen_people = {{name = "Ada"}, {name = "Lucy"}}
	for &s, i in seen_people do seen_speakers[i] = &s
	w.speakers = seen_speakers[:]
	w.player = {pos = {500, 150}, speed = 120, character = &ada_art}
	w.current = 2
	refresh_world(&w)
	w.time = 1
	return w
}

@(private = "file")
seen_tidy :: proc(w: ^World) {
	destroy_world(w)
	delete(ada_art.parts)
	delete(lucy_day_art.parts)
	delete(lucy_evening_art.parts)
	ada_art, lucy_day_art, lucy_evening_art = {}, {}, {}
}

// Lucy says a line to her face in the room with no line of hers: what is she
// called in wearing, and at what pace? Then she is sent off again.
@(private = "file")
called_in_as :: proc(t: ^testing.T, w: ^World) -> (art: ^Character_Art, speed: f32) {
	c: Conversation
	lines := make([]Talk_Line, 1, context.temp_allocator)
	lines[0] = {who = seen_speakers[1], text = "Lovely evening."}
	begin_conversation(w, &c, lines)
	if !testing.expect_value(t, len(w.sight.called), 1) do return nil, 0
	art, speed = w.sight.called[0].actor.character, w.sight.called[0].actor.speed
	for talking(w) do advance_conversation(w)
	sight_clear(w)
	return
}

@(test)
a_call_in_wears_what_she_last_saw_them_in :: proc(t: ^testing.T) {
	w := seen_world(t)
	defer seen_tidy(&w)

	// Never seen: the first line in the room order, as it always was.
	art, _ := called_in_as(t, &w)
	testing.expect(t, art == &lucy_day_art, "never seen: the first line's art")

	// Seen in the evening room, in the evening costume: called in so, at its pace.
	set_flag(&w, "evening")
	go_to(&w, 1, {500, 150})
	go_to(&w, 2, {500, 150})
	speed: f32
	art, speed = called_in_as(t, &w)
	testing.expect(t, art == &lucy_evening_art, "as last seen: the evening costume")
	testing.expect_value(t, speed, f32(90))

	// A room she is in but not drawn in (her line's when= is off) records nothing.
	go_to(&w, 0, {500, 150})
	go_to(&w, 2, {500, 150})
	art, _ = called_in_as(t, &w)
	testing.expect(t, art == &lucy_evening_art, "not drawn in the day room tonight: unchanged")

	// Seen by day again: the day costume.
	set_flag(&w, "evening", false)
	go_to(&w, 0, {500, 150})
	go_to(&w, 2, {500, 150})
	art, _ = called_in_as(t, &w)
	testing.expect(t, art == &lucy_day_art, "seen by day since: the day costume")

	// Into a save and out again, whatever the record became in between.
	set_flag(&w, "evening")
	go_to(&w, 1, {500, 150})
	go_to(&w, 2, {500, 150})
	s: Save
	defer save_destroy(&s)
	save_world(&w, &s, "")
	testing.expect_value(t, save_text(&s, "seen_as.0"), "Lucy\tlucy_evening\t90")
	text := strings.clone(save_text_of(&s))
	defer delete(text)
	w.sight.seen_as[seen_speakers[1]] = {&lucy_day_art, 120}
	testing.expect(t, load_world(&w, text))
	art, speed = called_in_as(t, &w)
	testing.expect(t, art == &lucy_evening_art, "restored: what she had seen when she saved")
	testing.expect_value(t, speed, f32(90))

	// Saved in a room that draws her by day but not tonight: the restore's
	// half-restored rooms must not overwrite what was saved.
	set_flag(&w, "evening")
	go_to(&w, 1, {500, 150})
	go_to(&w, 0, {500, 150})
	s2: Save
	defer save_destroy(&s2)
	save_world(&w, &s2, "")
	text2 := strings.clone(save_text_of(&s2))
	defer delete(text2)
	set_flag(&w, "evening", false)
	testing.expect(t, load_world(&w, text2))
	go_to(&w, 2, {500, 150})
	art, _ = called_in_as(t, &w)
	testing.expect(t, art == &lucy_evening_art, "restored in a room that drew her otherwise before the load")

	// Saved with a record that no line beginning on the way back gives: her
	// evening line began, then her porch line in the day dress. Restored, the
	// lines begin again in flag order (a_porch, then evening), and only the
	// saved record says the day dress.
	go_to(&w, 2, {500, 150})
	set_flag(&w, "evening")
	set_flag(&w, "a_porch")
	s3: Save
	defer save_destroy(&s3)
	save_world(&w, &s3, "")
	text3 := strings.clone(save_text_of(&s3))
	defer delete(text3)
	set_flag(&w, "a_porch", false)
	set_flag(&w, "evening", false)
	testing.expect(t, load_world(&w, text3))
	art, _ = called_in_as(t, &w)
	testing.expect(t, art == &lucy_day_art, "restored: the saved record, not the lines begun on the way back")
	set_flag(&w, "a_porch", false)

	// A line that begins to hold, in a room she is not in, is what she wears
	// from then: the evening comes while she is elsewhere, and goes again.
	set_flag(&w, "evening", false)
	go_to(&w, 0, {500, 150})
	go_to(&w, 2, {500, 150})
	set_flag(&w, "evening")
	art, _ = called_in_as(t, &w)
	testing.expect(t, art == &lucy_evening_art, "her evening line began, unseen: the evening costume")
	set_flag(&w, "evening", false)
	art, _ = called_in_as(t, &w)
	testing.expect(t, art == &lucy_day_art, "her day line began again, unseen: the day costume")

	// A save from before anybody was seen restores no record.
	clear(&w.sight.seen_as)
	empty: Save
	defer save_destroy(&empty)
	save_world(&w, &empty, "")
	testing.expect(t, !save_has(&empty, "seen_as.0"))
	w.sight.seen_as[seen_speakers[1]] = {&lucy_evening_art, 90}
	testing.expect(t, load_world(&w, save_text_of(&empty)))
	art, _ = called_in_as(t, &w)
	testing.expect(t, art == &lucy_day_art, "an empty record restored: the first line again")

	// A new game forgets what the last one's people wore.
	w.sight.seen_as[seen_speakers[1]] = {&lucy_evening_art, 90}
	reset_story(&w)
	testing.expect_value(t, len(w.sight.seen_as), 0)
}


// Review 2: the same save restored twice, once over a world
// where a routine had walked her porch line off (away), gives two call-ins.
@(test)
a_call_in_restore_depends_on_the_world_replaced :: proc(t: ^testing.T) {
	w := seen_world(t)
	defer seen_tidy(&w)
	set_flag(&w, "a_porch")
	set_flag(&w, "evening") // began last: the evening costume
	s: Save
	defer save_destroy(&s)
	save_world(&w, &s, "")
	testing.expect_value(t, save_text(&s, "seen_as.0"), "Lucy\tlucy_evening\t90")
	text := strings.clone(save_text_of(&s))
	defer delete(text)

	// Restored over the same world: the saved record.
	testing.expect(t, load_world(&w, text))
	art, _ := called_in_as(t, &w)
	testing.expect(t, art == &lucy_evening_art, "restored over a still world: evening")

	// A routine walks her porch line off (routine.odin .Leave), then the same save is restored.
	for &o in w.scenes[3].objects do if o.walks {o.away = true; o.hidden = true}
	testing.expect(t, load_world(&w, text))
	art, _ = called_in_as(t, &w)
	testing.expect(t, art == &lucy_evening_art, "restored over a world where she had walked off: still evening")
}

// Review 2: a peep's tick (peep.odin play_window ticks after
// peeping.active is set) turns the evening on; her evening line begins then.
@(test)
a_call_in_a_line_begun_during_a_peep :: proc(t: ^testing.T) {
	w := seen_world(t)
	defer seen_tidy(&w)
	w.peeping.active = true // play_window: active, then tick(w, win.cost)
	set_flag(&w, "evening")  // what the tick's on_clock does at the hour
	w.peeping.active = false // end_window
	art, _ := called_in_as(t, &w)
	testing.expect(t, art == &lucy_evening_art, "her evening line began during a peep: the evening costume")
}

// Review 2: her room last. She stands in the evening room
// looking at Lucy in the evening costume when the porch line (day dress, a
// room later in the order) begins: what she sees wins.
@(test)
a_call_in_her_room_noted_last :: proc(t: ^testing.T) {
	w := seen_world(t)
	defer seen_tidy(&w)
	set_flag(&w, "evening")
	go_to(&w, 1, {500, 150})
	set_flag(&w, "a_porch")
	go_to(&w, 2, {500, 150}) // leaving notes nothing: go_to moves w.current first
	art, _ := called_in_as(t, &w)
	testing.expect(t, art == &lucy_evening_art, "seen in the evening costume as the porch line began: evening")
}
