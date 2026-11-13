package nengine

import "core:strings"
import "core:testing"

// A cutscene in the middle of play: the room she is in, the cook who is
// already standing in it, a stranger brought on for it, and her.

@(private = "file")
YARD :: `scene yard
walk 0,0 1000,0 1000,600 0,600

obj cook pos=300,400 char=cook facing=front
text cook He is scraping a pan.
routine cook loop
step cook walk_to 700,400
step cook walk_to 300,400
`

@(private = "file")
MEETING :: `cut meeting scene=yard
cast ada at=100,300 facing=right
cast cook char=cook
cast stranger char=stranger at=600,300 facing=left

0.0 ada walk_to 200,300
0.0 cook walk_to 400,300
0.5 stranger say Who's there?
1.0 cook say Only me.
1.5 narrate The lamp went out.
2.0 ada face back
3.0 end
`

@(private = "file")
Yard :: struct {
	w:      World,
	assets: Assets,
	cook:   Speaker,
	moore:  Speaker,
	ada:    Speaker,
	voices: [3]^Speaker,
	thens:  int,
}

@(private = "file")
open_yard :: proc(t: ^testing.T, y: ^Yard) {
	s, ok := parse_scene(YARD, nil)
	testing.expect(t, ok)
	append(&y.w.scenes, s)
	refresh_world(&y.w)

	y.assets.chars = make(map[string]Character_Art)
	y.assets.chars["ada"] = {}
	y.assets.chars["cook"] = {}
	y.assets.chars["stranger"] = {}
	y.assets.cuts = make(map[string]Cutscene)
	c, good := parse_cutscene(MEETING)
	testing.expect(t, good)
	y.assets.cuts["meeting"] = c

	y.w.assets = &y.assets
	y.w.player = {pos = {500, 500}, speed = 120, character = &y.assets.chars["ada"]}
	// "the cook" answers to `cook`, and has no portrait: named on the box.
	y.cook = Speaker{name = "the cook"}
	y.moore = Speaker{name = "Moore"}
	y.ada = Speaker{name = "Ada"}
	y.voices = {&y.cook, &y.moore, &y.ada}
	y.w.speakers = y.voices[:]
	y.w.user = y
}

@(private = "file")
shut_yard :: proc(y: ^Yard) {
	w := &y.w
	cutscene_stop(&w.cut)
	for &o in w.scenes[0].objects do routine_destroy(&o.routine)
	free_scene_strings(&w.scenes[0])
	delete(w.scenes[0].objects)
	delete(w.scenes[0].exits)
	delete(w.scenes[0].triggers)
	delete(w.scenes[0].walk_area)
	delete(w.scenes[0].scenery)
	delete(w.scenes[0].said)
	delete(w.scenes)
	clear_flags(w)
	nodes_destroy(w)
	delete(w.node_lines)
	for _, &c in y.assets.cuts do cutscene_destroy(&c)
	delete(y.assets.cuts)
	delete(y.assets.chars)
}

@(private = "file")
count_then :: proc(w: ^World) {
	(cast(^Yard)w.user).thens += 1
}

// Frames, as the game loop runs them while a cutscene holds the screen.
@(private = "file")
frames :: proc(w: ^World, seconds: f32, step: f32 = 1.0 / 60) {
	for t := f32(0); t < seconds; t += step {
		w.time += step
		cut_tick(w, step)
	}
}

@(test)
a_cutscene_plays_in_the_room_she_is_in :: proc(t: ^testing.T) {
	y := new(Yard)
	defer free(y)
	open_yard(t, y)
	defer shut_yard(y)
	w := &y.w
	cook := find_object(&w.scenes[0], "cook")

	testing.expect(t, play_cutscene(w, "meeting", count_then))
	testing.expect(t, cutting(w))
	// Who is who: her, the cook who was standing there, and a stranger.
	testing.expect_value(t, w.cut.roles[0], Cast_Role.Player)
	testing.expect_value(t, w.cut.roles[1], Cast_Role.Person)
	testing.expect_value(t, w.cut.roles[2], Cast_Role.Extra)
	// She is put where the cut says; the cook, written without at=, starts
	// where he stands.
	testing.expect_value(t, w.player.pos, [2]f32{100, 300})
	testing.expect_value(t, cook.pos, [2]f32{300, 400})
	testing.expect_value(t, w.cut.actors[2].pos, [2]f32{600, 300})

	// Nobody is at the controls: a typed command is not a command.
	run_command(w, "xyzzy")
	testing.expect_value(t, message(w), "")

	frames(w, 1.2)
	// The cook's line, by the World's speaker of that name.
	testing.expect_value(t, message(w), "the cook: Only me.")
	frames(w, 0.5)
	testing.expect_value(t, message(w), "The lamp went out.")
	testing.expect_value(t, w.player.pos, [2]f32{200, 300})
	testing.expect_value(t, cook.pos, [2]f32{400, 300})
	testing.expect_value(t, y.thens, 0)
	// The story clock does not move for it.
	testing.expect_value(t, w.clock_ticks, 0)

	frames(w, 1.5)
	testing.expect(t, !cutting(w))
	testing.expect_value(t, y.thens, 1)
	// She is left where it put her, turned the way it turned her, at her
	// own pace again.
	testing.expect_value(t, w.player.pos, [2]f32{200, 300})
	testing.expect_value(t, w.player.facing, Facing.Back)
	testing.expect_value(t, w.player.speed, f32(120))
	// The cook goes back to what his own lines say: where he was.
	testing.expect_value(t, cook.pos, [2]f32{300, 400})
	testing.expect_value(t, cook.actor.pos, [2]f32{300, 400})
	testing.expect_value(t, cook.actor.speed, f32(120))
	// And the stranger is gone.
	testing.expect_value(t, len(w.cut.actors), 0)

	// `then` once, and only once.
	frames(w, 2)
	testing.expect_value(t, y.thens, 1)
	testing.expect(t, !w.cut.running)
}

@(test)
escape_skips_a_cutscene_to_its_end :: proc(t: ^testing.T) {
	y := new(Yard)
	defer free(y)
	open_yard(t, y)
	defer shut_yard(y)
	w := &y.w
	cook := find_object(&w.scenes[0], "cook")

	play_cutscene(w, "meeting", count_then)
	frames(w, 0.1)
	skip_cutscene(w)
	testing.expect(t, !cutting(w))
	testing.expect_value(t, y.thens, 1)
	// Every walk walked and every turn turned, at once...
	testing.expect_value(t, w.player.pos, [2]f32{200, 300})
	testing.expect_value(t, w.player.facing, Facing.Back)
	// ...and nothing more said.
	testing.expect_value(t, message(w), "")
	testing.expect_value(t, cook.pos, [2]f32{300, 400})
}

@(test)
the_harness_reads_a_cutscene_out :: proc(t: ^testing.T) {
	y := new(Yard)
	defer free(y)
	open_yard(t, y)
	defer shut_yard(y)
	w := &y.w

	play_cutscene(w, "meeting", count_then)
	out := cutscene_aloud(w)
	testing.expect_value(t, out, `  [cutscene meeting]
  stranger: Who's there?
  the cook: Only me.
  The lamp went out.
  [end meeting]
`)
	testing.expect(t, !cutting(w))
	testing.expect_value(t, y.thens, 1)
	testing.expect_value(t, w.player.pos, [2]f32{200, 300})

	listing := bang(w, "cuts", nil)
	testing.expect(t, strings.has_prefix(listing, "1 cutscene(s)"))
	testing.expect(t, strings.contains(listing, "meeting: 3s in yard, 3 cast, 7 cue(s), 3 line(s)"))
}

@(test)
a_missing_cutscene_plays_nothing_and_goes_on :: proc(t: ^testing.T) {
	y := new(Yard)
	defer free(y)
	open_yard(t, y)
	defer shut_yard(y)
	w := &y.w

	testing.expect(t, !play_cutscene(w, "not_drawn_yet", count_then))
	testing.expect(t, !cutting(w))
	testing.expect_value(t, y.thens, 1)

	// And with no assets at all.
	w.assets = nil
	testing.expect(t, !play_cutscene(w, "meeting", count_then))
	testing.expect_value(t, y.thens, 2)
}

@(test)
a_cast_line_without_a_place_keeps_none :: proc(t: ^testing.T) {
	c, ok := parse_cutscene("cut x\ncast ada\ncast heir char=heir at=10,20 facing=left\n")
	testing.expect(t, ok)
	defer cutscene_destroy(&c)
	testing.expect(t, c.people[0].keep_place && c.people[0].keep_facing)
	testing.expect(t, !c.people[1].keep_place && !c.people[1].keep_facing)
	again, good := parse_cutscene(cutscene_text(&c))
	testing.expect(t, good)
	defer cutscene_destroy(&again)
	testing.expect(t, again.people[0].keep_place && again.people[0].keep_facing)
	testing.expect_value(t, again.people[1].at, [2]f32{10, 20})
}

// The words live in the writers' nodes; a cut says which of them, and when.

@(private = "file")
NODES :: `### A2.GT.FENCE · the fence
MOORE: One.
(He turns the key.)
ADA: Two.
MOORE: Three.

### A4.3D.PERCY · the bath house
ADA: Untagged first.
[percy] MOORE: Percy's telling.
[other] MOORE: The other telling.
ADA: Untagged last.
`

@(private = "file")
FENCE :: `cut fence
0.0 line A2.GT.FENCE 2-4
0.5 line A2.GT.FENCE 9
1.0 line NO.SUCH.NODE 1
20.0 line A4.3D.PERCY 2-3 tag=percy
30.0 end
`

@(private = "file")
open_fence :: proc(t: ^testing.T, y: ^Yard) {
	open_yard(t, y)
	testing.expect_value(t, parse_nodes(&y.w, NODES), 2)
	c, ok := parse_cutscene(FENCE)
	testing.expect(t, ok)
	y.assets.cuts["fence"] = c
}

@(test)
a_line_cue_says_a_nodes_lines_on_the_cuts_clock :: proc(t: ^testing.T) {
	y := new(Yard)
	defer free(y)
	open_fence(t, y)
	defer shut_yard(y)
	w := &y.w

	testing.expect(t, play_cutscene(w, "fence"))
	frames(w, 0.1)
	// A stage direction is narration.
	testing.expect_value(t, message(w), "(He turns the key.)")
	// The next when the first has had its reading time.
	gap := line_secs("(He turns the key.)")
	frames(w, gap)
	testing.expect_value(t, message(w), "Ada: Two.") // no portrait: named on the box
	frames(w, line_secs("Two."))
	testing.expect_value(t, message(w), "Moore: Three.")
	// Only said: the node is not played, and sets nothing.
	testing.expect(t, !node_said(w, "A2.GT.FENCE"))
	frames(w, 20.5 - w.cut.t) // the telling asked for: untagged lines, and percy's
	testing.expect_value(t, message(w), "Moore: Percy's telling.")
	frames(w, line_secs("Percy's telling."))
	testing.expect_value(t, message(w), "Ada: Untagged last.")
}

@(test)
the_harness_reads_a_line_cue_out_and_says_what_is_missing :: proc(t: ^testing.T) {
	y := new(Yard)
	defer free(y)
	open_fence(t, y)
	defer shut_yard(y)
	w := &y.w

	play_cutscene(w, "fence")
	testing.expect_value(t, cutscene_aloud(w), `  [cutscene fence]
  (He turns the key.)
  [no line A2.GT.FENCE 9]
  [no line NO.SUCH.NODE 1]
  Ada: Two.
  Moore: Three.
  Moore: Percy's telling.
  Ada: Untagged last.
  [end fence]
`)
}

@(test)
skipping_a_line_cue_says_none_of_the_rest :: proc(t: ^testing.T) {
	y := new(Yard)
	defer free(y)
	open_fence(t, y)
	defer shut_yard(y)
	w := &y.w

	play_cutscene(w, "fence")
	frames(w, 0.1)
	skip_cutscene(w)
	testing.expect(t, !cutting(w))
	testing.expect_value(t, message(w), "")
	frames(w, 10)
	testing.expect_value(t, message(w), "")
}

@(test)
a_line_cue_survives_being_written_and_read :: proc(t: ^testing.T) {
	c, ok := parse_cutscene(`cut x
1.0 line A4.3D.PERCY 1-2 tag=percy
2.0 line A2.GT.FENCE 3
3.0 line A2.GT.FENCE 0
4.0 line A2.GT.FENCE 5-2
5.0 line A2.GT.FENCE
`)
	testing.expect(t, ok)
	defer cutscene_destroy(&c)
	// The last three are not lines anybody could mean, and are dropped.
	testing.expect_value(t, len(c.cues), 2)
	testing.expect_value(t, c.cues[0].action, Cue_Action.Line)
	testing.expect_value(t, c.cues[0].text, "A4.3D.PERCY")
	testing.expect_value(t, c.cues[0].lines, [2]int{1, 2})
	testing.expect_value(t, c.cues[0].tag, "percy")
	testing.expect_value(t, c.cues[1].lines, [2]int{3, 3})
	text := cutscene_text(&c)
	testing.expect(t, strings.contains(text, "1.00 line A4.3D.PERCY 1-2 tag=percy\n"))
	testing.expect(t, strings.contains(text, "2.00 line A2.GT.FENCE 3\n"))
	again, good := parse_cutscene(text)
	testing.expect(t, good)
	defer cutscene_destroy(&again)
	testing.expect_value(t, again.cues[0].lines, [2]int{1, 2})
	testing.expect_value(t, again.cues[0].tag, "percy")
}

// Enter: on to the next thing said, with the staging where it would be.

@(private = "file")
PACE :: `cut pace
cast ada at=100,300 facing=right
cast heir char=heir at=500,300 facing=left
0.0 ada walk_to 1900,300
0.5 narrate First.
4.0 heir face back
5.0 sound bell
5.5 line NO.SUCH.NODE 1
6.0 narrate Second.
8.0 narrate Third.
10.0 end
`

@(test)
enter_jumps_a_cutscene_to_its_next_line :: proc(t: ^testing.T) {
	y := new(Yard)
	defer free(y)
	open_yard(t, y)
	defer shut_yard(y)
	w := &y.w
	c, ok := parse_cutscene(PACE)
	testing.expect(t, ok)
	y.assets.cuts["pace"] = c

	testing.expect(t, play_cutscene(w, "pace", count_then))
	frames(w, 0.6)
	testing.expect_value(t, message(w), "First.")

	advance_cutscene(w)
	// The clock is at the next line (a missing node's says nothing, and is
	// not stopped for), and everything between has been done...
	testing.expect(t, abs(w.cut.t - 6.0) < 0.01)
	// ...the walk as far as it would have got by then, and no further...
	testing.expect(t, abs(w.player.pos.x - (100 + CUT_SPEED * 6.0)) < 4)
	testing.expect(t, w.player.moving)
	// ...the turn turned, and the sound between not played.
	testing.expect_value(t, w.cut.actors[1].facing, Facing.Back)
	testing.expect_value(t, len(w.heard), 0)

	// The line itself goes up on the next frame.
	frames(w, 1.0 / 60)
	testing.expect_value(t, message(w), "Second.")
	advance_cutscene(w)
	frames(w, 1.0 / 60)
	testing.expect_value(t, message(w), "Third.")
	testing.expect_value(t, y.thens, 0)

	// The last line before the end: Enter goes to the end.
	advance_cutscene(w)
	testing.expect(t, !cutting(w))
	testing.expect_value(t, y.thens, 1)
	testing.expect(t, abs(w.player.pos.x - (100 + CUT_SPEED * 9.47)) < 4)
	delete(w.heard)
}

@(test)
enter_steps_through_a_line_range :: proc(t: ^testing.T) {
	y := new(Yard)
	defer free(y)
	open_fence(t, y)
	defer shut_yard(y)
	w := &y.w

	play_cutscene(w, "fence")
	frames(w, 0.1)
	testing.expect_value(t, message(w), "(He turns the key.)")
	advance_cutscene(w)
	testing.expect(t, abs(w.cut.t - line_secs("(He turns the key.)")) < 0.01)
	frames(w, 1.0 / 60)
	testing.expect_value(t, message(w), "Ada: Two.")
	advance_cutscene(w)
	frames(w, 1.0 / 60)
	testing.expect_value(t, message(w), "Moore: Three.")
	// Then on to the next cue that says something, at 20.
	advance_cutscene(w)
	testing.expect(t, abs(w.cut.t - 20) < 0.01)
}

// A cut that starts by itself while she walks (a beat on the mid deck as she
// heads for the starboard rail) gives her walk back when it ends, if it left
// her where she stood; one that moved her does not.
@(test)
a_cutscene_gives_back_the_walk_it_interrupted :: proc(t: ^testing.T) {
	y := new(Yard)
	defer free(y)
	open_yard(t, y)
	defer shut_yard(y)
	w := &y.w

	still, ok := parse_cutscene("cut still scene=yard\ncast cook char=cook\n0.5 cook say Only me.\n1.0 end\n")
	testing.expect(t, ok)
	y.assets.cuts["still"] = still

	walk_to(&w.player, {900, 500})
	testing.expect(t, play_cutscene(w, "still", count_then))
	testing.expect(t, !w.player.moving, "the cut has her hands")
	skip_cutscene(w)
	testing.expect_value(t, y.thens, 1)
	testing.expect(t, w.player.moving, "and gives the walk back")
	testing.expect_value(t, w.player.target, [2]f32{900, 500})

	// MEETING puts her at 100,300 and walks her: nothing to give back.
	walk_to(&w.player, {900, 500})
	testing.expect(t, play_cutscene(w, "meeting", count_then))
	skip_cutscene(w)
	testing.expect(t, !w.player.moving)
}

// An extra written without `at=` is brought on: it waits just off the side of
// the room nearer where it first walks to, at that height, and walks in on
// its first walk_to. One that never walks waits off the side nearer the
// middle of the floor. Nobody appears in the middle of the floor from nowhere.
@(test)
an_extra_without_a_place_walks_in_from_the_edge :: proc(t: ^testing.T) {
	y := new(Yard)
	defer free(y)
	open_yard(t, y)
	defer shut_yard(y)
	w := &y.w
	c, good := parse_cutscene(`cut brought scene=yard
cast stranger char=stranger
cast visitor char=stranger
0.5 stranger walk_to 700,350
6.0 end
`)
	testing.expect(t, good)
	y.assets.cuts["brought"] = c

	room_w := f32(WIDTH) if WIDTH > 0 else 1024
	testing.expect(t, play_cutscene(w, "brought"))
	testing.expect_value(t, w.cut.roles[0], Cast_Role.Extra)
	testing.expect_value(t, w.cut.actors[0].pos, [2]f32{room_w + CUT_OFFSTAGE, 350})
	// The floor's middle is 500,300: the left is nearer.
	testing.expect_value(t, w.cut.actors[1].pos, [2]f32{-CUT_OFFSTAGE, 300})
	frames(w, 4)
	testing.expect_value(t, w.cut.actors[0].pos, [2]f32{700, 350})
	testing.expect_value(t, w.cut.actors[1].pos, [2]f32{-CUT_OFFSTAGE, 300})
	skip_cutscene(w)

	testing.expect_value(t, offstage_start({100, 420}, 1024), [2]f32{-CUT_OFFSTAGE, 420})
	testing.expect_value(t, offstage_start({900, 420}, 1024), [2]f32{1024 + CUT_OFFSTAGE, 420})
}


@(test)
a_cutscene_starts_from_where_their_lines_put_people :: proc(t: ^testing.T) {
	y := new(Yard)
	defer free(y)
	open_yard(t, y)
	defer shut_yard(y)
	w := &y.w
	cook := find_object(&w.scenes[0], "cook")
	// Half way on through a side when the cut starts (a flag turned on the
	// same tick as the beat that plays it).
	cook.coming = true
	cook.coming_to = {300, 400}
	cook.actor.pos = {-60, 400}
	cook.pos = {-60, 400}
	testing.expect(t, play_cutscene(w, "meeting", count_then))
	// Settled at his place, and cast from there: one cook, not two.
	testing.expect_value(t, w.cut.roles[1], Cast_Role.Person)
	testing.expect(t, !cook.coming)
	testing.expect_value(t, cook.pos, [2]f32{300, 400})
	frames(w, 3.5)
	testing.expect(t, !cutting(w))
	// And put back there after it, not walking on again.
	testing.expect(t, !cook.coming)
	testing.expect_value(t, cook.actor.pos, [2]f32{300, 400})
}

// A painted shot during a cutscene's lines: a `shot` cue puts one up, a `line`
// cue's `shot=` another, with its frame for each line in turn, and `shot off`
// takes it down.

@(private = "file")
ROAD_NODES :: `### A1.ROAD · on the road
ADA: One.
COOK: Two.
ADA: Three.
COOK: Four.
`

@(private = "file")
SHOTS :: `cut shots
0.0 shot road_wide 1
1.0 line A1.ROAD 1-4 shot=road_close frames=2,0,1
30.0 shot off
31.0 end
`

@(private = "file")
open_shots :: proc(t: ^testing.T, y: ^Yard) {
	open_yard(t, y)
	testing.expect_value(t, parse_nodes(&y.w, ROAD_NODES), 1)
	c, ok := parse_cutscene(SHOTS)
	testing.expect(t, ok)
	y.assets.cuts["shots"] = c
}

@(private = "file")
expect_shot :: proc(t: ^testing.T, w: ^World, name: string, frame: i32, loc := #caller_location) {
	got, f, ok := cutscene_shot(w)
	testing.expectf(t, ok && got == name && f == frame, "shot %v %v, wanted %v %v", got, f, name, frame, loc = loc)
}

@(test)
a_cutscene_shows_each_line_in_its_frame_of_the_shot :: proc(t: ^testing.T) {
	y := new(Yard)
	defer free(y)
	open_shots(t, y)
	defer shut_yard(y)
	w := &y.w

	testing.expect(t, play_cutscene(w, "shots"))
	frames(w, 0.1)
	expect_shot(t, w, "road_wide", 1)
	frames(w, 1.0 - w.cut.t + 0.05)
	testing.expect_value(t, message(w), "Ada: One.")
	expect_shot(t, w, "road_close", 2)
	frames(w, line_secs("One."))
	testing.expect_value(t, message(w), "the cook: Two.")
	expect_shot(t, w, "road_close", 0)
	frames(w, line_secs("Two."))
	testing.expect_value(t, message(w), "Ada: Three.")
	expect_shot(t, w, "road_close", 1)
	frames(w, line_secs("Three."))
	testing.expect_value(t, message(w), "the cook: Four.")
	expect_shot(t, w, "road_close", 1) // the last frame given repeats
	frames(w, 30.05 - w.cut.t)
	_, _, up := cutscene_shot(w)
	testing.expect(t, !up)
}

// Enter keeps the frames: the line it jumps to goes up in its own.
@(test)
enter_keeps_a_shots_frames_with_their_lines :: proc(t: ^testing.T) {
	y := new(Yard)
	defer free(y)
	open_shots(t, y)
	defer shut_yard(y)
	w := &y.w

	play_cutscene(w, "shots")
	frames(w, 0.1)
	advance_cutscene(w) // to the first line, at 1.0
	frames(w, 1.0 / 60)
	testing.expect_value(t, message(w), "Ada: One.")
	expect_shot(t, w, "road_close", 2)
	advance_cutscene(w)
	frames(w, 1.0 / 60)
	advance_cutscene(w)
	frames(w, 1.0 / 60)
	testing.expect_value(t, message(w), "Ada: Three.")
	expect_shot(t, w, "road_close", 1)
	// The end takes it down with everything else.
	skip_cutscene(w)
	_, _, up := cutscene_shot(w)
	testing.expect(t, !up)
}

@(test)
the_harness_says_when_a_shot_goes_up_and_comes_down :: proc(t: ^testing.T) {
	y := new(Yard)
	defer free(y)
	open_shots(t, y)
	defer shut_yard(y)
	w := &y.w

	play_cutscene(w, "shots")
	testing.expect_value(t, cutscene_aloud(w), `  [cutscene shots]
  [shot road_wide]
  [shot road_close]
  Ada: One.
  the cook: Two.
  Ada: Three.
  the cook: Four.
  [shot off]
  [end shots]
`)
}

// `speed=` on the cast: the player, somebody in the room and an extra each
// walk at their own, and the two who were here walk at theirs again after.
@(private = "file")
SPEEDS :: `cut speeds
cast ada at=100,300 facing=right speed=40
cast cook char=cook at=300,400 speed=50
cast cart char=stranger at=0,200 speed=60
0.0 ada walk_to 900,300
0.0 cook walk_to 900,400
0.0 cart walk_to 900,200
5.0 end
`

@(test)
a_cast_member_walks_at_their_own_speed :: proc(t: ^testing.T) {
	y := new(Yard)
	defer free(y)
	open_yard(t, y)
	defer shut_yard(y)
	w := &y.w
	c, ok := parse_cutscene(SPEEDS)
	testing.expect(t, ok)
	y.assets.cuts["speeds"] = c

	testing.expect(t, play_cutscene(w, "speeds"))
	frames(w, 2.0)
	cook := &w.scenes[0].objects[0]
	testing.expectf(t, abs(w.player.pos.x - (100 + 40 * 2)) < 3, "she is at %v", w.player.pos.x)
	testing.expectf(t, abs(cook.actor.pos.x - (300 + 50 * 2)) < 3, "the cook is at %v", cook.actor.pos.x)
	testing.expectf(t, abs(w.cut.actors[2].pos.x - 60 * 2) < 3, "the cart is at %v", w.cut.actors[2].pos.x)
	testing.expect_value(t, w.cut.actors[2].speed, f32(60))
	skip_cutscene(w)
	testing.expect_value(t, w.player.speed, f32(120))
	testing.expect_value(t, cook.actor.speed, f32(120))
}
