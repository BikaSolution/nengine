package nengine

import "core:strings"
import "core:testing"

// Holding a pose while walking (actor.odin, the walk pair): what each walk
// the engine starts does to a held pose, and which picture carries it.

@(private = "file")
Fake_Part :: struct {
	name:   string,
	step:   f32,
	faces:  Maybe(Facing),
	mirror: bool,
}

// Character art with the ten standard parts and these extras drawn, each on
// its own texture id, so a test can tell which one is up.
@(private = "file")
fake_char :: proc(a: ^Character_Art, extras: ..Fake_Part) {
	a.parts = make(map[string]Part_Art)
	id: u32 = 1
	for p in CHAR_PARTS {
		a.parts[p] = Part_Art {
			sprite = {texture = {id = id}, frame_w = 40, frame_h = 100, frames = 4},
			step   = 10 if strings.has_prefix(p, "walk_") else 0,
		}
		id += 1
	}
	for f in extras {
		a.parts[f.name] = Part_Art {
			sprite = {texture = {id = id}, frame_w = 40, frame_h = 100, frames = 4},
			step   = f.step,
			faces  = f.faces,
			mirror = f.mirror,
		}
		id += 1
	}
}

// Which part actor_picture puts up, by its texture, and whether flipped.
@(private = "file")
shown :: proc(a: Actor) -> (name: string, flip: bool) {
	s, _, f := actor_picture(a)
	for k, p in a.character.parts do if p.sprite.texture.id == s.texture.id do return k, f
	return "?", f
}

// Every way a carried thing is drawn in these tests.
@(private = "file")
CARRIES :: []Fake_Part {
	{name = "box", step = 10, faces = Facing.Left},     // said: drawn facing left
	{name = "box_front", step = 10},
	{name = "bag", step = 10},                           // with bag_right beside it: so facing left
	{name = "bag_right", step = 10},
	{name = "pail", step = 10, faces = Facing.Left, mirror = true}, // two pails: the same both ways
	{name = "pack", step = 10},                          // nobody has said which way
	{name = "crate", step = 10, faces = Facing.Back},
	{name = "tray_left", step = 10, mirror = true},      // only a version, flippable
	{name = "coat"},                                     // a stand ...
	{name = "coat_walk", step = 8},                      // ... and its walk, by name
	{name = "coat_walk_right", step = 8},
	{name = "sit"},
	{name = "rifle"},
	{name = "rifle_march", step = 12},
	{name = "sack_walk_right", step = 12},
	{name = "jug", step = 10},                          // with only jug_left beside it: so facing right
	{name = "jug_left", step = 10},
	{name = "lamp", step = 10},                         // a walk, with a _walk beside it too:
	{name = "lamp_walk", step = 10},                    // the pose itself wins
}

@(test)
a_held_pose_finds_the_walk_it_is_carried_in :: proc(t: ^testing.T) {
	art: Character_Art
	fake_char(&art, ..CARRIES)
	defer delete(art.parts)
	Case :: struct {
		pose, walk_pose, want: string,
	}
	cases := []Case {
		{"bag", "", "bag"},                   // a walk is its own pair
		{"coat", "", "coat_walk"},            // <pose>_walk
		{"rifle", "rifle_march", "rifle_march"}, // the line's walk=
		{"coat", "lost_walk", "coat_walk"},   // a walk= nobody drew: as if unsaid
		{"rifle", "", ""},                    // a stand with no walk
		{"sit", "", ""},
		{"sack_walk", "", "sack_walk"},       // drawn only for one side: still a walk
		{"", "rifle_march", ""},              // nothing held
		{"lamp", "", "lamp"},                 // a walk wins over a _walk beside it
	}
	for c in cases {
		a := Actor{character = &art, pose = c.pose, walk_pose = c.walk_pose, walk_for = c.pose}
		got, ok := pose_walk(a)
		testing.expectf(t, got == c.want && ok == (c.want != ""), "%v walk=%v: %q, want %q", c.pose, c.walk_pose, got, c.want)
		// Set off on a walk: a pose with a walk stays, any other is put down.
		walk_keeps_pair(&a)
		testing.expectf(t, a.pose == (c.pose if c.want != "" else ""), "%v set off holding %q", c.pose, a.pose)
	}
	// The line's walk= is for the line's own pose: holding anything else, its own walk.
	held := Actor{character = &art, pose = "coat", walk_pose = "rifle_march", walk_for = "rifle"}
	got, _ := pose_walk(held)
	testing.expect_value(t, got, "coat_walk")
}

@(test)
a_carry_turns_in_the_classic_engines_order :: proc(t: ^testing.T) {
	art: Character_Art
	fake_char(&art, ..CARRIES)
	defer delete(art.parts)
	Case :: struct {
		walk:        string,
		facing:      Facing,
		facing_left: bool, // the side last faced
		want:        string,
		flip:        bool,
	}
	cases := []Case {
		{"box", .Front, true, "box_front", false},  // 1. that way's own version, first
		{"box", .Left, false, "box", false},        // 2. drawn that way (faces=)
		{"box", .Right, false, "", false},          // nothing that way, no mirror: the plain walk
		{"bag", .Left, false, "bag", false},        // 2. drawn that way (the other side is drawn beside it)
		{"bag", .Right, false, "bag_right", false},
		{"bag", .Back, false, "bag_right", false},  // 3. up the screen: the side last faced ...
		{"bag", .Back, true, "bag", false},
		{"box", .Back, false, "box", false},        // ... then the other side
		{"tray", .Front, false, "tray_left", true},  // the right side as walked: tray_left flipped
		{"jug", .Front, false, "jug", false},       // last faced right: the base, drawn that way
		{"jug", .Back, true, "jug_left", false},
		{"pack", .Front, false, "pack", false},     // ... then as drawn, when nobody said
		{"crate", .Back, false, "crate", false},
		{"crate", .Front, true, "", false},         // a back view never walks towards her
		{"pail", .Right, false, "pail", true},      // 4. sideways: the other side flipped, if mirror=ok
		{"tray", .Right, false, "tray_left", true},
		{"sack_walk", .Left, false, "", false},     // ... and never one that does not say so
		{"pail", .Left, false, "pail", false},
		{"pack", .Right, false, "pack", false},     // ... or as drawn, when nobody said
		{"pack", .Left, false, "pack", false},
	}
	for c in cases {
		a := Actor{character = &art, facing = c.facing, facing_left = c.facing_left}
		name, flip, ok := pair_turned(a, c.walk)
		testing.expectf(t, name == c.want && flip == c.flip && ok == (c.want != ""),
			"%v going %v (last faced %v): %q flip=%v, want %q flip=%v", c.walk, c.facing, "left" if c.facing_left else "right", name, flip, c.want, c.flip)
	}
}

@(test)
only_a_walk_draws_the_pair :: proc(t: ^testing.T) {
	art: Character_Art
	fake_char(&art, ..CARRIES)
	defer delete(art.parts)
	// On a walk, holding a coat: its walk, turned.
	a := Actor{character = &art, pose = "coat", facing = .Right, moving = true, walking = true, speed = 60}
	name, flip := shown(a)
	testing.expect_value(t, name, "coat_walk_right")
	testing.expect(t, !flip)
	// Two pails going right: the left-hand drawing, flipped.
	a.pose = "pail"
	name, flip = shown(a)
	testing.expect_value(t, name, "pail")
	testing.expect(t, flip)
	a.walking = false // stopped a moment on the way: still the right way round
	name, flip = shown(a)
	testing.expect_value(t, name, "pail")
	testing.expect(t, flip)
	a.walking = true
	// A box going right, with nothing drawn that way: the plain walk.
	a.pose = "box"
	name, flip = shown(a)
	testing.expect_value(t, name, "walk_right")
	testing.expect(t, !flip)
	// Stopped for a moment on the way: still the box.
	a.walking = false
	a.facing = .Left
	name, _ = shown(a)
	testing.expect_value(t, name, "box")
	// Standing on their line: the pose as drawn, never turned or mirrored.
	a.moving = false
	a.pose = "pail"
	a.facing = .Right
	name, flip = shown(a)
	testing.expect_value(t, name, "pail")
	testing.expect(t, !flip)
	a.pose = "coat"
	name, _ = shown(a)
	testing.expect_value(t, name, "coat")
	// Moved by the game's own code in a pose with no walk: as it was.
	a.moving = true
	a.pose = "sit"
	name, _ = shown(a)
	testing.expect_value(t, name, "sit")
}

// A yard with a side either end; a porter in a coat and a man in a chair,
// each coming on from the west and going off to the east.
@(private = "file")
PAIR_YARD :: `scene yard
walk 0,100 1000,100 1000,400 0,400
side east to=yard span=100,400
side west to=yard span=100,400
obj porter pos=500,150 char=porter pose=coat facing=left when=porter_here enters=west leaves=east
obj sitter pos=500,260 char=sitter pose=sit when=sitter_here enters=west leaves=east
obj seated pos=300,200 char=seated pose=sit when=seated_here
`

@(private = "file", thread_local)
pair_art: Character_Art

@(private = "file")
pair_world :: proc(t: ^testing.T, text: string) -> World {
	fake_char(&pair_art, ..CARRIES)
	w: World
	s, ok := parse_scene(text, nil)
	testing.expect(t, ok)
	append(&w.scenes, s)
	problem, good := resolve_exits(&w)
	testing.expectf(t, good, "resolve: %v", problem)
	for &o in w.scenes[0].objects do if o.walks do o.actor.character = &pair_art
	refresh_world(&w)
	w.player = {pos = {500, 390}, speed = 120, character = &pair_art}
	w.player_name = "ada"
	w.time = 1
	return w
}

@(private = "file")
pair_tidy :: proc(w: ^World) {
	cutscene_stop(&w.cut)
	destroy_world(w)
	delete(pair_art.parts)
	pair_art = {}
}

@(private = "file")
pair_frames :: proc(w: ^World, secs: f32) {
	for _ in 0 ..< int(secs * 60) {
		w.time += 1.0 / 60
		update_people(w, current_scene(w), 1.0 / 60)
	}
}

@(test)
a_routine_walk_carries_the_pair_and_puts_a_chair_down :: proc(t: ^testing.T) {
	w := pair_world(t, `scene yard
walk 0,100 1000,100 1000,400 0,400
obj porter pos=100,150 char=porter pose=coat facing=left
routine porter
step porter walk_to 600,150
step porter play box 1
obj sitter pos=100,280 char=sitter pose=sit
routine sitter
step sitter walk_to 600,280
step sitter wait 9
`)
	defer pair_tidy(&w)
	sc := current_scene(&w)
	porter, sitter := &sc.objects[0], &sc.objects[1]
	pair_frames(&w, 1)
	testing.expect(t, porter.actor.moving && sitter.actor.moving)
	testing.expect_value(t, porter.actor.pose, "coat")
	name, _ := shown(porter.actor)
	testing.expect_value(t, name, "coat_walk_right")
	testing.expect_value(t, sitter.actor.pose, "")
	name, _ = shown(sitter.actor)
	testing.expect_value(t, name, "walk_right")
	pair_frames(&w, 5)
	testing.expect(t, !porter.actor.moving && !sitter.actor.moving)
	testing.expect_value(t, sitter.actor.pose, "sit") // the next step gives it back
	testing.expect_value(t, porter.actor.pose, "coat") // done: the line's pose back, not the last play's
}

@(test)
a_person_comes_and_goes_carrying_and_sits_down_on_arrival :: proc(t: ^testing.T) {
	w := pair_world(t, PAIR_YARD)
	defer pair_tidy(&w)
	sc := current_scene(&w)
	porter, sitter := &sc.objects[0], &sc.objects[1]

	set_flag(&w, "porter_here")
	set_flag(&w, "sitter_here")
	testing.expect(t, porter.coming && sitter.coming)
	pair_frames(&w, 0.5)
	testing.expect_value(t, porter.actor.pose, "coat")
	name, _ := shown(porter.actor)
	testing.expect_value(t, name, "coat_walk_right")
	// Never slid on in a chair: walked on, and seated on arrival.
	testing.expect_value(t, sitter.actor.pose, "")
	name, _ = shown(sitter.actor)
	testing.expect_value(t, name, "walk_right")
	pair_frames(&w, 10)
	testing.expect(t, !porter.coming && !sitter.coming)
	testing.expect_value(t, sitter.actor.pose, "sit")
	testing.expect_value(t, porter.actor.pose, "coat")
	name, _ = shown(porter.actor)
	testing.expect_value(t, name, "coat") // standing on the line, facing left, as drawn

	set_flag(&w, "porter_here", false)
	set_flag(&w, "sitter_here", false)
	testing.expect(t, porter.going && sitter.going)
	pair_frames(&w, 0.5)
	testing.expect_value(t, porter.actor.pose, "coat")
	name, _ = shown(porter.actor)
	testing.expect_value(t, name, "coat_walk_right")
	testing.expect_value(t, sitter.actor.pose, "")
	pair_frames(&w, 10)
	testing.expect(t, !porter.going && !sitter.going)
	testing.expect_value(t, sitter.actor.pose, "sit") // for whenever he is here again
}

@(test)
spoken_to_on_the_way_out_they_keep_what_they_carry :: proc(t: ^testing.T) {
	w := pair_world(t, PAIR_YARD)
	defer pair_tidy(&w)
	sc := current_scene(&w)
	porter, seated := &sc.objects[0], &sc.objects[2]
	set_flag(&w, "porter_here")
	set_flag(&w, "seated_here")
	pair_frames(&w, 10)

	set_flag(&w, "porter_here", false)
	pair_frames(&w, 0.3)
	call_back(&w, sc, Command{verb = "talk to", noun = "porter"})
	testing.expect(t, porter.held)
	testing.expect_value(t, porter.actor.pose, "coat")

	// Gone at once from his chair (no leaves=), and called back before he
	// is out of the picture: standing to speak.
	set_flag(&w, "seated_here", false)
	testing.expect(t, seated.going)
	testing.expect_value(t, seated.actor.pose, "sit")
	call_back(&w, sc, Command{verb = "talk to", noun = "seated"})
	testing.expect(t, seated.held)
	testing.expect_value(t, seated.actor.pose, "")
}

@(test)
a_cut_walks_people_in_what_they_hold :: proc(t: ^testing.T) {
	w := pair_world(t, PAIR_YARD)
	defer pair_tidy(&w)
	sc := current_scene(&w)
	porter, sitter := &sc.objects[0], &sc.objects[1]
	set_flag(&w, "porter_here")
	set_flag(&w, "sitter_here")
	pair_frames(&w, 10)
	w.player.pose = "sit"

	cut, ok := parse_cutscene(`cut carry scene=yard
cast ada
cast porter
cast sitter
cast hand char=porter at=100,200 facing=right
0.0 porter walk_to 800,150
0.0 sitter walk_to 700,260
0.0 hand hold coat
0.1 hand walk_to 400,200
0.0 ada hold coat
0.1 ada walk_to 300,380
2.0 hand hold -
3.0 porter leave east
4.0 end
`)
	defer cutscene_destroy(&cut)
	testing.expect(t, ok)
	testing.expect_value(t, cue_body_text(cut.cues[2]), "hand hold coat")
	testing.expect_value(t, cue_body_text(cut.cues[len(cut.cues) - 3]), "hand hold -")
	testing.expect(t, start_cutscene(&w, &cut))
	testing.expect_value(t, w.cut.roles[1], Cast_Role.Person)
	hand := &w.cut.actors[3]
	hand.character = &pair_art // an extra's art is the game's assets; none here
	for _ in 0 ..< 60 do cutscene_update(&w.cut, &w, 1.0 / 60)
	testing.expect_value(t, porter.actor.pose, "coat")
	name, _ := shown(porter.actor)
	testing.expect_value(t, name, "coat_walk_right")
	testing.expect_value(t, sitter.actor.pose, "") // nobody walks sitting down
	testing.expect_value(t, hand.pose, "coat")
	name, _ = shown(hand^)
	testing.expect_value(t, name, "coat_walk_right")
	testing.expect_value(t, w.player.pose, "coat")
	for _ in 0 ..< 70 do cutscene_update(&w.cut, &w, 1.0 / 60)
	testing.expect_value(t, hand.pose, "") // put down
	for _ in 0 ..< 60 do cutscene_update(&w.cut, &w, 1.0 / 60)
	testing.expect(t, porter.actor.moving)
	testing.expect_value(t, porter.actor.pose, "coat") // and off through the side with it
	skip_cutscene(&w)
	// After it: each as their line, or she, had them.
	testing.expect_value(t, porter.actor.pose, "coat")
	testing.expect_value(t, sitter.actor.pose, "sit")
	testing.expect_value(t, w.player.pose, "sit")
}

@(test)
a_cut_that_holds_nothing_leaves_her_pose_as_its_walks_left_it :: proc(t: ^testing.T) {
	w := pair_world(t, PAIR_YARD)
	defer pair_tidy(&w)
	w.player.pose = "sit"
	cut, ok := parse_cutscene("cut plain scene=yard\ncast ada\n0.0 ada walk_to 700,280\n2.0 end\n")
	defer cutscene_destroy(&cut)
	testing.expect(t, ok)
	testing.expect(t, start_cutscene(&w, &cut))
	skip_cutscene(&w)
	testing.expect_value(t, w.player.pose, "") // as before there were pairs

	// Nor one that only turns her.
	w.player.pose = "sit"
	turn, good := parse_cutscene("cut turn scene=yard\ncast ada\n0.0 ada face left\n1.0 end\n")
	defer cutscene_destroy(&turn)
	testing.expect(t, good)
	testing.expect(t, start_cutscene(&w, &turn))
	skip_cutscene(&w)
	testing.expect_value(t, w.player.pose, "sit")
}

@(test)
faces_mirror_and_walk_survive_their_files :: proc(t: ^testing.T) {
	c, ok := parse_character(`character porter
size 2 2
pal # 10,20,30,255
part pail frames=1 step=10 faces=left mirror=ok
frame 0
##
##
part sack frames=1 faces=sideways
frame 0
##
##
`)
	testing.expect(t, ok)
	defer character_destroy(&c)
	p := character_part(&c, "pail")
	testing.expect(t, p != nil && p.mirror)
	f, said := p.faces.?
	testing.expect(t, said && f == .Left)
	_, said = character_part(&c, "sack").faces.?
	testing.expect(t, !said, "a word that is not a facing says nothing")
	text := character_text(&c)
	testing.expect(t, strings.contains(text, "part pail frames=1 step=10 faces=left mirror=ok\n"), text)
	copied := character_copy_part(&c, "pail", "pails")
	testing.expect(t, copied != nil && copied.mirror)

	s, good := parse_scene("scene yard\nobj porter pos=1,2 char=porter pose=coat walk=coat_march\n", nil)
	testing.expect(t, good)
	w: World
	append(&w.scenes, s)
	defer destroy_world(&w)
	testing.expect_value(t, w.scenes[0].objects[0].actor.walk_pose, "coat_march")
	testing.expect(t, strings.contains(scene_text(&w.scenes[0]), " pose=coat walk=coat_march"))
}

// --- Round 2: review 1's and review 2's steps, and the fixes they asked for ---

// A cut's `hold` on somebody whose line names its own walk (walk=): the held
// part is what they carry, not the line's walk; after the cut, the line's again.
@(test)
a_hold_beats_the_lines_walk :: proc(t: ^testing.T) {
	w := pair_world(t, `scene yard
walk 0,100 1000,100 1000,400 0,400
side east to=yard span=100,400
obj guard pos=300,150 char=guard pose=rifle walk=rifle_march facing=right
`)
	defer pair_tidy(&w)
	guard := &current_scene(&w).objects[0]
	walk, paired := pose_walk(guard.actor) // the line's own pose, in the line's walk
	testing.expect(t, paired && walk == "rifle_march")
	cut, ok := parse_cutscene("cut c scene=yard\ncast ada\ncast guard\n0.0 guard hold coat\n0.1 guard walk_to 800,150\n3.0 end\n")
	defer cutscene_destroy(&cut)
	testing.expect(t, ok)
	testing.expect(t, start_cutscene(&w, &cut))
	for _ in 0 ..< 40 do cutscene_update(&w.cut, &w, 1.0 / 60)
	testing.expect(t, guard.actor.moving)
	testing.expect_value(t, guard.actor.pose, "coat")
	name, _ := shown(guard.actor)
	testing.expect_value(t, name, "coat_walk_right")
	skip_cutscene(&w)
	testing.expect_value(t, guard.actor.pose, "rifle")
	testing.expect_value(t, guard.actor.walk_pose, "rifle_march")
}

// A chain: the first cut gives her something to hold; its `then` starts a
// second that walks her. Her pose is hers again in the second.
@(private = "file", thread_local) chain_second: ^Cutscene
@(private = "file")
chain_then :: proc(w: ^World) {start_cutscene(w, chain_second)}

@(test)
a_hold_does_not_outlive_its_cut_in_a_chain :: proc(t: ^testing.T) {
	w := pair_world(t, PAIR_YARD)
	defer pair_tidy(&w)
	w.player.pose = "sit"
	first, ok := parse_cutscene("cut a scene=yard\ncast ada\n0.0 ada hold coat\n0.1 ada walk_to 600,380\n1.0 end\n")
	defer cutscene_destroy(&first)
	second, good := parse_cutscene("cut b scene=yard\ncast ada\n0.0 ada walk_to 300,380\n1.0 end\n")
	defer cutscene_destroy(&second)
	testing.expect(t, ok && good)
	chain_second = &second
	testing.expect(t, start_cutscene(&w, &first, chain_then))
	for _ in 0 ..< 30 do cutscene_update(&w.cut, &w, 1.0 / 60)
	testing.expect_value(t, w.player.pose, "coat")
	skip_cutscene(&w) // Escape: the first ends, its then starts the second
	testing.expect(t, cutting(&w))
	testing.expect(t, !w.cut.player_held)
	for _ in 0 ..< 10 do cutscene_update(&w.cut, &w, 1.0 / 60)
	testing.expect_value(t, w.player.pose, "") // walked: put down, as before pairs
	skip_cutscene(&w)
	testing.expect_value(t, w.player.pose, "")
}

// Somebody whose line faces left, coming on from the south (up the screen):
// a carry drawn for both sides goes up in the side their line faces.
@(test)
up_the_screen_first_in_the_side_their_line_faces :: proc(t: ^testing.T) {
	w := pair_world(t, `scene yard
walk 0,100 1000,100 1000,400 0,400
side south to=yard span=0,1000
obj carrier pos=500,150 char=carrier pose=bag facing=left when=here enters=south
`)
	defer pair_tidy(&w)
	carrier := &current_scene(&w).objects[0]
	set_flag(&w, "here")
	testing.expect(t, carrier.coming)
	pair_frames(&w, 0.3)
	testing.expect_value(t, carrier.actor.facing, Facing.Back)
	name, _ := shown(carrier.actor)
	testing.expect_value(t, name, "bag") // bag faces left (bag_right beside it)
}

// Only her own hold gives her pose back; somebody else's does not.
@(test)
only_her_own_hold_gives_her_pose_back :: proc(t: ^testing.T) {
	w := pair_world(t, PAIR_YARD)
	defer pair_tidy(&w)
	w.player.pose = "sit"
	cut, ok := parse_cutscene("cut c scene=yard\ncast ada\ncast hand char=porter at=100,200 facing=right\n0.0 hand hold coat\n0.0 ada walk_to 700,280\n2.0 end\n")
	defer cutscene_destroy(&cut)
	testing.expect(t, ok)
	testing.expect(t, start_cutscene(&w, &cut))
	skip_cutscene(&w)
	testing.expect_value(t, w.player.pose, "")
}

// Two holds on her in one cut: what she held before the cut comes back.
@(test)
two_holds_on_her_give_back_what_she_had :: proc(t: ^testing.T) {
	w := pair_world(t, PAIR_YARD)
	defer pair_tidy(&w)
	w.player.pose = "sit"
	cut, ok := parse_cutscene("cut two scene=yard\ncast ada\n0.0 ada hold coat\n0.5 ada hold -\n1.0 end\n")
	defer cutscene_destroy(&cut)
	testing.expect(t, ok)
	testing.expect(t, start_cutscene(&w, &cut))
	for _ in 0 ..< 45 do cutscene_update(&w.cut, &w, 1.0 / 60)
	testing.expect_value(t, w.player.pose, "")
	skip_cutscene(&w)
	testing.expect_value(t, w.player.pose, "sit")
}

// A hold over a part being played: the hold shows at once.
@(test)
a_hold_stops_what_is_being_played :: proc(t: ^testing.T) {
	w := pair_world(t, PAIR_YARD)
	defer pair_tidy(&w)
	cut, ok := parse_cutscene("cut c scene=yard\ncast hand char=porter at=100,200 facing=right\n0.0 hand play sit 5\n0.5 hand hold coat\n3.0 end\n")
	defer cutscene_destroy(&cut)
	testing.expect(t, ok)
	testing.expect(t, start_cutscene(&w, &cut))
	w.cut.actors[0].character = &pair_art
	for _ in 0 ..< 45 do cutscene_update(&w.cut, &w, 1.0 / 60)
	testing.expect_value(t, w.cut.actors[0].anim, "")
	testing.expect_value(t, w.cut.actors[0].pose, "coat")
}

// A bare `hold` is no cue (`hold -` puts it down).
@(test)
a_hold_must_name_a_part_or_a_dash :: proc(t: ^testing.T) {
	cut, ok := parse_cutscene("cut c scene=yard\ncast hand\n0.0 hand hold\n0.5 hand hold -\n1.0 end\n")
	defer cutscene_destroy(&cut)
	testing.expect(t, ok)
	testing.expect_value(t, len(cut.cues), 2) // the dash and the end
	testing.expect_value(t, cut.cues[0].action, Cue_Action.Hold)
	testing.expect_value(t, cut.cues[0].text, "")
}

// A carry mirrored going right, then down the screen: the side last faced, as
// it was walked (still flipped), not a turn on the spot.
@(test)
down_the_screen_after_a_mirrored_side_keeps_the_mirror :: proc(t: ^testing.T) {
	art: Character_Art
	fake_char(&art, ..CARRIES)
	defer delete(art.parts)
	a := Actor{character = &art, facing = .Front, facing_left = false}
	name, flip, ok := pair_turned(a, "pail")
	testing.expectf(t, ok && name == "pail" && flip, "pail down, last faced right: %q flip=%v", name, flip)
	a.facing_left = true
	name, flip, ok = pair_turned(a, "pail")
	testing.expectf(t, ok && name == "pail" && !flip, "pail down, last faced left: %q flip=%v", name, flip)
}

// What the speaker's balloon measures is what is drawn (look.odin actor_sprite).
@(test)
the_speaker_box_is_the_drawn_sprite :: proc(t: ^testing.T) {
	art: Character_Art
	fake_char(&art, ..CARRIES)
	defer delete(art.parts)
	p := art.parts["rifle_march"]
	p.sprite.frame_h = 140 // taller than the stand, to tell them apart
	art.parts["rifle_march"] = p
	a := Actor{character = &art, pose = "rifle", walk_pose = "rifle_march", walk_for = "rifle", facing = .Right, moving = true, walking = true, speed = 60}
	s, _, _ := actor_picture(a)
	testing.expect_value(t, s.frame_h, i32(140))
	testing.expect_value(t, actor_sprite(a).frame_h, s.frame_h)
}

// Holding a carry with nothing drawn that way and no plain walk that way:
// standing that way, as the plain walk would.
@(test)
no_plain_walk_that_way_stands_that_way :: proc(t: ^testing.T) {
	art: Character_Art
	fake_char(&art, ..CARRIES)
	defer delete(art.parts)
	delete_key(&art.parts, "walk_right")
	a := Actor{character = &art, pose = "box", facing = .Right, moving = true, walking = true, speed = 60}
	name, _ := shown(a)
	testing.expect_value(t, name, "right")
}

// A walk by the arrow keys (a heading, no target) draws the pair as a walk to a spot does.
@(test)
a_walk_by_the_keys_carries_the_pair :: proc(t: ^testing.T) {
	art: Character_Art
	fake_char(&art, ..CARRIES)
	defer delete(art.parts)
	a := Actor{character = &art, pose = "coat", facing = .Right, heading = {1, 0}, walking = true, speed = 60}
	name, _ := shown(a)
	testing.expect_value(t, name, "coat_walk_right")
	a.heading = {}
	a.walking = false
	name, _ = shown(a)
	testing.expect_value(t, name, "coat") // stopped: the stand
}

// A .char part as the game loads it keeps its facing and its mirror.
@(test)
a_loaded_part_keeps_its_facing_and_mirror :: proc(t: ^testing.T) {
	c, ok := parse_character("character porter\nsize 2 2\npal # 10,20,30,255\npart pail frames=1 step=10 faces=left mirror=ok\nframe 0\n##\n##\npart pails frames=1\nframe 0\n##\n##\n")
	testing.expect(t, ok)
	defer character_destroy(&c)
	p := part_art_of(character_part(&c, "pail"), Sprite{})
	defer delete(p.holds)
	f, said := p.faces.?
	testing.expect(t, said && f == .Left && p.mirror && p.step == 10)
	q := part_art_of(character_part(&c, "pails"), Sprite{})
	defer delete(q.holds)
	_, said = q.faces.?
	testing.expect(t, !said && !q.mirror)
	copied := character_copy_part(&c, "pail", "pail_copy")
	testing.expect(t, copied != nil)
	f, said = copied.faces.?
	testing.expect(t, said && f == .Left)
}

// Every part a world names is drawn: pose=, walk=, a routine's play, a cut's hold and play.
@(test)
a_part_nobody_drew_is_named :: proc(t: ^testing.T) {
	s, ok := parse_scene(`scene yard
walk 0,100 1000,100 1000,400 0,400
obj porter pos=100,150 char=porter pose=coat walk=coat_march
routine porter
step porter play wave 1
step porter play kick 1
obj ghost pos=200,150 char=nobody pose=anything
obj porter2 pos=300,150 char=porter pose=coats
obj guard pos=400,150 char=porter
`, nil)
	testing.expect(t, ok)
	w: World
	append(&w.scenes, s)
	defer destroy_world(&w)
	c, good := parse_character("character porter\nsize 2 2\npal # 10,20,30,255\npart coat frames=1\nframe 0\n##\n##\npart coat_walk_right frames=1 step=8\nframe 0\n##\n##\npart kick_left frames=1\nframe 0\n##\n##\n")
	testing.expect(t, good)
	defer character_destroy(&c)
	chars := make(map[string]Character, allocator = context.temp_allocator)
	chars["porter"] = c
	cut, fine := parse_cutscene("cut c scene=yard\ncast porter\ncast hand char=porter\ncast guard\n0.0 hand hold coat\n0.1 hand hold coats\n0.2 porter play waves 1\n0.3 hand hold -\n0.4 guard hold coatz\n1.0 end\n")
	testing.expect(t, fine)
	defer cutscene_destroy(&cut)
	cuts := []Cutscene{cut}
	faults := part_faults(w.scenes[:], cuts, chars)
	want := []string {
		"yard: porter walk=coat_march: porter.char has no such part",
		"yard: step porter play wave: porter.char has no such part",
		"yard: porter2 pose=coats: porter.char has no such part",
		"c.cut: hand hold coats: porter.char has no such part",
		"c.cut: porter play waves: porter.char has no such part",
		"c.cut: guard hold coatz: porter.char has no such part", // wears the room line's char
	}
	testing.expectf(t, len(faults) == len(want), "%v", faults[:])
	for f, i in faults do if i < len(want) do testing.expect_value(t, f, want[i])
}
