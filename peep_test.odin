package nengine

import "core:strings"
import "core:testing"

// A tent row with a net into tent five, and a kitchen window. The clock runs
// a minute a tick from 17:00.
@(private = "file")
ROW :: `scene row
walk 0,0 640,0 640,480 0,480
peep net5 pos=600,300 into=tent dress=5 kind=net blind=lamp_in_5 walk_to=600,330
text net5 The mosquito net of tent five.
peep vent pos=100,200 into=tent kind=vent blind=always walk_to=100,230
`

@(private = "file")
ARGUE := [?]Talk_Line {
	{text = "You said you'd burnt it."},
	{text = "I said I would."},
	{text = "Then do it."},
	{text = "Not here."},
	{text = "Where, then?"},
}

@(private = "file")
open_row :: proc(t: ^testing.T, windows: []Peep_Window) -> World {
	s, ok := parse_scene(ROW, nil)
	testing.expect(t, ok)
	w: World
	@(static) words := [?]Word{{.Noun, "net5", "net"}, {.Noun, "vent", ""}}
	w.vocab = vocab_join(words[:], context.temp_allocator)
	append(&w.scenes, s)
	append(&w.scenes, Scene{name = "tent"})
	_, _ = resolve_exits(&w)
	refresh_world(&w)
	w.clock_start, w.clock_step = 17 * 60, 1
	w.player = {pos = {600, 330}, speed = 120}
	w.peep_windows = windows
	return w
}

@(private = "file")
shut_row :: proc(w: ^World) {
	free_scene_strings(&w.scenes[0])
	delete(w.scenes[0].objects)
	delete(w.scenes[0].exits)
	delete(w.scenes[0].triggers)
	delete(w.scenes[0].walk_area)
	delete(w.scenes[0].scenery)
	delete(w.scenes[0].said)
	delete(w.scenes)
	delete(w.peep_lines)
	clear_flags(w)
}

// Reads the playing window to its end, as Enter would.
@(private = "file")
read_it :: proc(w: ^World) -> int {
	n := 0
	for talking(w) {
		n += 1
		advance_conversation(w)
	}
	return n
}

// What a window's hooks saw, per test: the runner runs tests side by side,
// so this lives with the world (w.user), never in a global.
@(private = "file")
Heard :: struct {
	count:  int,    // on_play's lines heard; -1 until it runs
	caught: string, // on_caught's who
}

@(private = "file")
count_heard :: proc(w: ^World, lines: int) {
	(^Heard)(w.user).count = lines
}

@(private = "file")
note_catch :: proc(w: ^World, who: string) {
	(^Heard)(w.user).caught = who
}

@(test)
a_window_plays_once_in_its_hours :: proc(t: ^testing.T) {
	windows := [?]Peep_Window{{name = "argue", peep = "net5", from = 17 * 60 + 10, until = 17 * 60 + 20, lines = ARGUE[:]}}
	w := open_row(t, windows[:])
	defer shut_row(&w)
	net := object_here(&w.scenes[0], "net5")

	testing.expect_value(t, peep(&w, net), Peep_Outcome.Nobody) // 17:00: too early
	set_clock(&w, 12)
	testing.expect_value(t, peep(&w, net), Peep_Outcome.Played)
	testing.expect(t, flag(&w, "heard_argue"))
	testing.expect_value(t, read_it(&w), 5)
	testing.expect_value(t, peep(&w, net), Peep_Outcome.Already) // no second hearing
	set_clock(&w, 30)
	testing.expect_value(t, peep(&w, net), Peep_Outcome.Nobody) // and its hour is gone
}

@(test)
nobody_there_costs_nothing :: proc(t: ^testing.T) {
	w := open_row(t, nil)
	defer shut_row(&w)
	before := w.clock_ticks
	run_command(&w, "listen at net5")
	testing.expect_value(t, w.clock_ticks, before)
	testing.expect_value(t, message(&w), "Nobody is talking.")
}

@(test)
the_turn_catches_only_when_not_blind :: proc(t: ^testing.T) {
	windows := [?]Peep_Window{{name = "argue", peep = "net5", lines = ARGUE[:], turn = 3, turner = "Edmund", on_caught = note_catch}}
	// Not blind: no lamp inside, so he can see the net and the shape at it.
	w := open_row(t, windows[:])
	defer shut_row(&w)
	heard := Heard{count = -1}
	w.user = &heard
	peep(&w, object_here(&w.scenes[0], "net5"))
	testing.expect_value(t, read_it(&w), 3) // stops on the line he looks round
	testing.expect(t, flag(&w, "caught_net5_edmund"))
	testing.expect_value(t, heard.caught, "edmund")

	// Blind: a lamp inside, a dark row outside, and he looks at nothing.
	w2 := open_row(t, windows[:])
	defer shut_row(&w2)
	set_flag(&w2, "lamp_in_5")
	heard2 := Heard{count = -1}
	w2.user = &heard2
	peep(&w2, object_here(&w2.scenes[0], "net5"))
	testing.expect_value(t, read_it(&w2), 5)
	testing.expect(t, !flag(&w2, "caught_net5_edmund"))
	testing.expect_value(t, heard2.caught, "")
}

@(test)
the_passer_catches_through_a_blind_peep :: proc(t: ^testing.T) {
	windows := [?]Peep_Window{{name = "steam", peep = "vent", lines = ARGUE[:], turn = 2, passer = "Otto", passer_at = 4, on_caught = note_catch}}
	w := open_row(t, windows[:])
	defer shut_row(&w)
	w.player.pos = {100, 230}
	heard := Heard{count = -1}
	w.user = &heard
	peep(&w, object_here(&w.scenes[0], "vent")) // a vent is always blind: the turn never fires
	testing.expect_value(t, read_it(&w), 4)    // but the cook walking past does
	testing.expect(t, flag(&w, "caught_vent_otto"))
	testing.expect_value(t, heard.caught, "otto")
}

@(test)
leave_keeps_what_was_heard :: proc(t: ^testing.T) {
	windows := [?]Peep_Window{{name = "argue", peep = "net5", lines = ARGUE[:], passer = "Moore", passer_at = 5, on_play = count_heard, on_caught = note_catch}}
	w := open_row(t, windows[:])
	defer shut_row(&w)
	heard := Heard{count = -1}
	w.user = &heard
	peep(&w, object_here(&w.scenes[0], "net5"))
	advance_conversation(&w) // two lines read
	skip_conversation(&w)    // and she steps away before the passer comes
	testing.expect(t, !peeping(&w))
	testing.expect_value(t, heard.count, 2)
	testing.expect_value(t, heard.caught, "")
	testing.expect(t, !flag(&w, "caught_net5_moore"))
	testing.expect(t, flag(&w, "heard_argue")) // and that was the one hearing
	testing.expect_value(t, peep(&w, object_here(&w.scenes[0], "net5")), Peep_Outcome.Already)
}

@(test)
a_window_costs_its_ticks_once :: proc(t: ^testing.T) {
	windows := [?]Peep_Window{{name = "argue", peep = "net5", lines = ARGUE[:], cost = 2}}
	w := open_row(t, windows[:])
	defer shut_row(&w)
	before := w.clock_ticks
	run_command(&w, "listen at net5")
	testing.expect_value(t, w.clock_ticks, before + 2)
	read_it(&w)
	run_command(&w, "peep net5")
	testing.expect_value(t, w.clock_ticks, before + 2) // the second time is Already, and free
}

@(test)
blind_at_overrides_the_peep :: proc(t: ^testing.T) {
	// The net is not blind (no lamp), but this window says the far side is
	// looking the other way.
	windows := [?]Peep_Window{{name = "argue", peep = "net5", lines = ARGUE[:], turn = 2, turner = "Edmund", blind_at = "always"}}
	w := open_row(t, windows[:])
	defer shut_row(&w)
	peep(&w, object_here(&w.scenes[0], "net5"))
	testing.expect_value(t, read_it(&w), 5)
	testing.expect(t, !flag(&w, "caught_net5_edmund"))
}

@(test)
her_own_voice_keeps_its_face_at_a_blind_aperture :: proc(t: ^testing.T) {
	// A dark window, a shape inside, and the player saying what she sees to
	// herself: the shape is a voice, she is still herself.
	ada := Speaker{name = "Ada", side = .Left, unseen = "a woman"}
	shape := Speaker{name = "Edmund", side = .Right, unseen = "a man"}
	lines := [?]Talk_Line{{who = &shape, text = "Four. Five."}, {who = &ada, text = "Somebody loading a rifle."}}
	windows := [?]Peep_Window{{name = "loading", peep = "vent", lines = lines[:], near_who = &ada}}
	w := open_row(t, windows[:])
	defer shut_row(&w)
	w.player.pos = {100, 230}
	peep(&w, object_here(&w.scenes[0], "vent"))
	testing.expect_value(t, w.talk.lines[0].who.name, "a man")
	testing.expect(t, w.talk.lines[1].who == &ada)
}

@(test)
the_harness_can_leave_a_window_part_way :: proc(t: ^testing.T) {
	// `!leave 2`, then the peep: two lines read, Escape, the hearing kept.
	windows := [?]Peep_Window{{name = "argue", peep = "net5", lines = ARGUE[:], passer = "Moore", passer_at = 5, on_play = count_heard, on_caught = note_catch}}
	w := open_row(t, windows[:])
	defer shut_row(&w)
	heard := Heard{count = -1}
	w.user = &heard
	run_script(&w, "!leave 2; peep net5")
	testing.expect(t, !peeping(&w))
	testing.expect_value(t, heard.count, 2)
	testing.expect_value(t, heard.caught, "")
	testing.expect(t, flag(&w, "heard_argue"))
	testing.expect_value(t, w.script_leave_after, 0) // used once, then gone
}

@(test)
look_through_a_peep_walks_to_it_and_look_at_does_not :: proc(t: ^testing.T) {
	windows := [?]Peep_Window{{name = "argue", peep = "net5", lines = ARGUE[:]}}
	w := open_row(t, windows[:])
	defer shut_row(&w)
	w.player.pos = {300, 300}
	run_command(&w, "look at net5")
	testing.expect(t, !approaching(&w))
	testing.expect_value(t, message(&w), "The mosquito net of tent five.")
	run_command(&w, "look through net5")
	testing.expect(t, approaching(&w))
	finish_approach(&w)
	testing.expect(t, peeping(&w))
}

@(test)
peeps_lists_every_window_and_its_state :: proc(t: ^testing.T) {
	windows := [?]Peep_Window {
		{name = "argue", peep = "net5", from = 17 * 60, until = 17 * 60 + 30, lines = ARGUE[:]},
		{name = "steam", peep = "vent", from = 18 * 60, until = 18 * 60 + 15, lines = ARGUE[:]},
	}
	w := open_row(t, windows[:])
	defer shut_row(&w)
	got := bang(&w, "peeps", nil)
	testing.expect(t, strings.contains(got, "2 window(s)"))
	testing.expect(t, strings.contains(got, "argue at net5, 17:00-17:30 (open now)"))
	testing.expect(t, strings.contains(got, "steam at vent, 18:00-18:15"))
	peep(&w, object_here(&w.scenes[0], "net5"))
	read_it(&w)
	testing.expect(t, strings.contains(bang(&w, "peeps", nil), "argue at net5, 17:00-17:30 (heard)"))
}

// --- The split close-up ---

@(private = "file")
fake_sprite :: proc(id: u32) -> Sprite {
	return Sprite{texture = {id = id, width = 512, height = 640}, frame_w = 512, frame_h = 640, frames = 1}
}

@(private = "file")
dress_art :: proc(w: ^World, name: string) -> ^Object {
	o := object_here(&w.scenes[0], name)
	o.peep.frame_art = fake_sprite(7)
	o.peep.blind_art = fake_sprite(8)
	o.peep.near_art = {}
	for l in Light do o.peep.near_art.by[l] = fake_sprite(9)
	return o
}

@(test)
a_playing_window_draws_two_halves_and_a_frame :: proc(t: ^testing.T) {
	windows := [?]Peep_Window{{name = "argue", peep = "net5", lines = ARGUE[:]}}
	w := open_row(t, windows[:])
	defer shut_row(&w)
	net := dress_art(&w, "net5")

	_, showing := peep_view(&w)
	testing.expect(t, !showing, "nothing plays, nothing to draw")
	peep(&w, net)
	v, ok := peep_view(&w)
	testing.expect(t, ok)
	testing.expect_value(t, v.near.texture.id, u32(9))  // her side
	testing.expect_value(t, v.far_room, 1)              // the tent, through it
	testing.expect_value(t, v.dress, "tent_5")          // worn as tent five
	testing.expect_value(t, v.frame.texture.id, u32(7)) // the net's weave
	testing.expect(t, v.faces)
}

@(private = "file")
always_night :: proc(w: ^World) -> Light {
	return .Night
}

@(test)
the_far_half_is_in_the_far_rooms_light :: proc(t: ^testing.T) {
	windows := [?]Peep_Window{{name = "argue", peep = "net5", lines = ARGUE[:]}}
	w := open_row(t, windows[:])
	defer shut_row(&w)
	// Where she stands the light is latched at day; the tent behind the net
	// is in its own light, the clock's, which the game says is night.
	w.light = .Day
	w.on_light_now = always_night
	peep(&w, dress_art(&w, "net5"))
	v, _ := peep_view(&w)
	testing.expect_value(t, v.light, Light.Night)
}

@(test)
a_blind_window_draws_shapes_and_names_no_face :: proc(t: ^testing.T) {
	edmund := Speaker{name = "Edmund", unseen = "a man"}
	pickett := Speaker{name = "Pickett"}
	lines := [?]Talk_Line{{who = &edmund, text = "Not here."}, {who = &pickett, text = "Then where?"}, {who = &edmund, text = "After the walk."}}
	windows := [?]Peep_Window{{name = "pads", peep = "net5", lines = lines[:]}}
	w := open_row(t, windows[:])
	defer shut_row(&w)
	set_flag(&w, "lamp_in_5") // lamp inside: the net is blind
	peep(&w, dress_art(&w, "net5"))

	v, _ := peep_view(&w)
	testing.expect(t, !v.faces)
	testing.expect_value(t, v.frame.texture.id, u32(8)) // the blind weave
	// Voices, not names: each speaker keeps one voice, and nobody has a face.
	testing.expect_value(t, w.talk.lines[0].who.name, "a man")
	testing.expect_value(t, w.talk.lines[1].who.name, "a voice")
	testing.expect(t, w.talk.lines[2].who == w.talk.lines[0].who)
	testing.expect_value(t, w.talk.lines[0].who.portrait.texture.id, u32(0))
	testing.expect_value(t, message(&w), "a man: Not here.")
}

@(test)
a_missing_half_is_a_band_not_a_crash :: proc(t: ^testing.T) {
	windows := [?]Peep_Window{{name = "argue", peep = "net5", lines = ARGUE[:]}}
	w := open_row(t, windows[:])
	defer shut_row(&w)
	peep(&w, object_here(&w.scenes[0], "net5")) // no art loaded at all
	v, ok := peep_view(&w)
	testing.expect(t, ok)
	testing.expect_value(t, v.near.texture.id, u32(0))  // drawn as a band
	testing.expect_value(t, v.frame.texture.id, u32(0)) // no frame
	testing.expect_value(t, v.far_room, 1)              // the room is still there to draw
}

// Her side of the aperture is painted for the light she stands in: the net at
// night is not the net by day, and a light nobody painted borrows.
@(test)
her_half_is_drawn_in_her_own_light :: proc(t: ^testing.T) {
	windows := [?]Peep_Window{{name = "argue", peep = "net5", lines = ARGUE[:]}}
	w := open_row(t, windows[:])
	defer shut_row(&w)
	net := dress_art(&w, "net5")
	net.peep.near_art.by[.Night] = fake_sprite(10)
	net.peep.near_art.by[.Sunrise] = fake_sprite(9) // borrowed, as lit_sprite fills it

	w.light = .Night
	peep(&w, net)
	v, _ := peep_view(&w)
	testing.expect_value(t, v.near.texture.id, u32(10))
	w.light = .Day
	v, _ = peep_view(&w)
	testing.expect_value(t, v.near.texture.id, u32(9))
}

// Two rooms with an aperture of the same name (a grating seen from the deck
// and from the hold under it): a window that names its room plays only there.
@(test)
a_window_with_a_room_plays_only_in_that_room :: proc(t: ^testing.T) {
	windows := [?]Peep_Window{{name = "argue", peep = "net5", room = "the_deck", lines = ARGUE[:]}}
	w := open_row(t, windows[:])
	defer shut_row(&w)
	net := object_here(&w.scenes[0], "net5")
	w.player.pos = net.walk_to
	testing.expect_value(t, peep(&w, net), Peep_Outcome.Nobody) // the row is not the deck
	windows[0].room = w.scenes[0].name
	testing.expect_value(t, peep(&w, net), Peep_Outcome.Played)
}

// A window with a painted far half shows it through the plain frame even when
// the aperture is blind; the voices stay faceless.
@(test)
a_painted_far_half_wears_the_plain_frame :: proc(t: ^testing.T) {
	shot := fake_sprite(11)
	windows := [?]Peep_Window{{name = "argue", peep = "net5", lines = ARGUE[:], blind_at = "always", shot = &shot}}
	w := open_row(t, windows[:])
	defer shut_row(&w)
	net := dress_art(&w, "net5")
	peep(&w, net)
	v, _ := peep_view(&w)
	testing.expect(t, !v.faces)
	testing.expect_value(t, v.far_shot.texture.id, u32(11))
	testing.expect_value(t, v.frame.texture.id, u32(7)) // the net's own weave, not the dark one
}
