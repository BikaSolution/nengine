package nengine

import "core:slice"
import rl "vendor:raylib"

// One screen: a background, the floor you can walk on, things in it, and ways out.
Scene :: struct {
	name:        string,

	// What LOOK on its own says, right now. For a scene from a file this is a
	// view into `said` and is chosen by refresh_scene, so reading it is
	// always right and there is no accessor to remember. A scene built in
	// code sets it directly and keeps it.
	description: string,
	background:  Sprite,
	background_name: string, // which asset it came from. Set when loaded from a file.
	// The backdrop in each light, fallbacks filled in, and which were
	// painted. `background` is day's. See light.odin.
	backdrop:         [Light]Sprite,
	backdrop_painted: bit_set[Light],
	// Layers that drift sideways over the backdrop, back to front in the
	// order the file gives them: clouds, a river's water. See Drift.
	drifts:           [dynamic]Drift,
	// A room with a roof: the light outside changes only while the player is
	// in one of these, or going through its door. See light.odin.
	indoors:     bool,
	walk_area:   [][2]f32,
	objects:     [dynamic]Object,
	exits:       [dynamic]Exit,
	triggers:    [dynamic]Trigger,
	// Where the floor stops and something can still be stepped into: water
	// off a jetty. See edge.odin.
	edges:       [dynamic]Edge,
	// Its borders, and the neighbour across each: walked straight into. See
	// side.odin.
	sides:       [dynamic]Side,
	scenery:     []Scenery,
	// Openings onto the outside, each with its glass: where somebody going
	// past outside can be seen. See passer.odin.
	windows:     [dynamic]Window,
	ambience:    ^Loop,  // background sound. Scenes can share one. See audio.odin.
	ambience_name: string, // which asset it came from. Set when loaded from a file.
	// Ambiences that only apply sometimes, like `said`: `ambience when=night
	// camp_night`. refresh_scene chooses: the last line whose condition holds.
	// The generator stopping is a flag, and the room's sound changes with it.
	ambiences:   [dynamic]Scene_Ambience,
	// Footsteps on this floor: `footstep step_boards`. None: the player's own.
	step:        rl.Sound,
	step_name:   string,

	// The scene's own command handler. Return true if it dealt with the
	// command; false passes it on to World.on_command.
	on_command:  proc(w: ^World, cmd: Command) -> bool,

	debug_mask:  rl.Texture2D, // walk area shaded for the debug view, built on first use

	// Sierra's priority and control screens, if the room has them: a depth
	// map (who is hidden behind what is painted) and a solid map (where the
	// painted floor is taken), per art pixel at map_scale. See priority.odin.
	depth_map:     Depth_Map, // the backdrop's: Assets own it
	solid_map:     Solid_Map, // the room's own copy, cleared at its exits and walk_tos
	map_scale:     f32,       // canvas px per art px of both: the backdrop's
	depth_name:    string,    // `depth_map <name>` ("none": no map); else the backdrop's own
	solid_name:    string,
	depth_named:   bool,
	solid_named:   bool,
	owns_solid:    bool,
	depth_live:    Depth_Map, // the backdrop's with things' own depth stamped in (scene_depth_now)
	depth_stamped: [][3]f32,  // what depth_live has stamped in it
	// People are solid (priority.odin): who is walking now, and where she
	// stands if she is in this room. Set by the world and round each step.
	mover:         Mover,
	player_pos:    [2]f32,
	player_in:     bool,

	// Descriptions that only apply sometimes, tried in order before falling
	// back to `description`. A room that reads differently in act four is the
	// same room, not a second copy of it.
	//
	//     desc            Lamps, and a great deal of talking.
	//     desc when=act4  Cold.
	said:        [dynamic]Said,

	// Set by load_scene: this scene's names and descriptions are cloned
	// strings it owns, so clear_world frees them. Scenes built in code use
	// string literals instead, which must not be freed.
	from_file:   bool,
}

// A layer of the picture that drifts left and repeats sideways, as the title
// screen's do (Layer, menu.odin):
//
//     drift clouds speed=6 y=0
//     drift river speed=24 y=300 fps=5
//
// It is drawn over the backdrop and under everything standing in the room, so
// people and things are never behind it. Its left and right edges should join
// up, as a title layer's do. A layer of several frames plays them at `fps`:
// moving water. It is painted for each light as a backdrop is (light.odin):
// `clouds.night` beside `clouds` is the night's; a light it was not painted
// for borrows another and is shown through the room's tint.
Drift :: struct {
	name:  string,     // the sprite it came from
	layer: Layer,      // speed, y and fps; its sprite is the day's
	lit:   Lit_Sprite, // the layer in each light it was painted in
}

// What an object does when a verb lands on it.
//
// An object that can only be looked at is a picture with a caption; an object
// that carries its own verbs is a thing. Putting them here rather than in a
// switch means a scene file says everything about the room it describes, and
// the scene's on_command is left holding only what is genuinely scene-wide.
//
//     on door look    You have never seen it shut before.
//     on door open    The door swings inward.
//     on door unlock with=key action=unlock_door  The lock gives.
//
// `with` matches the second noun, so LOOK AT BOOTS and LOOK AT BOOTS WITH
// MONOCLE can be different answers. `only` is a condition, so a door can say
// something different once the act has turned.
Interaction :: struct {
	verb:   string, // the verb from the Command, e.g. "open"
	with:   string, // the second noun it needs, or "" for none in particular
	only:   string, // condition; see flags.odin
	text:   string, // what to say
	action: string, // a name the game binds a procedure to
	anim:   string, // a part the player plays first; the rest waits for it. See anim.odin
	on_do:  proc(w: ^World, o: ^Object),
}

// Which layer a thing is drawn in, before feet are considered at all.
//
// Almost everything is Normal and sorts by where it stands. The two overrides
// are for the things that aren't really standing anywhere: a rug or a painted
// shadow, which nothing should ever be hidden behind, and a bush or a doorway
// frame at the very front of the shot, which everything should pass behind.
Depth :: enum {
	Back,   // always behind everyone
	Normal, // sorted by its feet
	Front,  // always in front of everyone
}

// Anything drawn in a scene: furniture, props, animals.
//   - static:    fps = 0. Shows `frame`, which the game can change, e.g. a door
//                that's open or shut.
//   - animated:  fps > 0. Loops through all its frames.
//
// `only` decides whether it is here at all right now: an object whose
// condition fails is not drawn, cannot be looked at, and does not block the
// floor. That is how one room file covers five acts.
Object :: struct {
	name:        string, // the noun the parser uses for it
	description: string, // what LOOK AT says
	pos:         [2]f32, // feet. Also decides draw order: lower on screen = in front.
	sprite:      Sprite,
	sprite_name: string, // which asset the sprite came from. Set when loaded from a file.
	lit:         Lit_Sprite, // the sprite in each light it was painted in; see light.odin
	fps:         f32,
	frame:       i32,
	walk_to:     [2]f32, // the interaction point: where the player stands to do anything to it. See approach.odin
	block:       Shape,  // floor the player can't walk through. See shape.odin.
	reach:       Shape,  // the ring: near() it, and close enough to walk over and do things

	// Sound. See audio.odin.
	loop:        ^Loop,                // hum, hiss, purr: louder the closer you are
	tick:        rl.Sound,             // played when the animation reaches...
	tick_frames: bit_set[0 ..< 32],    // ...any of these frames
	last_frame:  i32,                  // engine's own

	// Which assets the sprite and sounds came from. Set when loaded from a
	// file, so the scene can be written back out without losing them.
	loop_name:   string,
	tick_name:   string,

	only:        string,                // condition; see flags.odin
	on:          [dynamic]Interaction,  // what it does when a verb lands on it

	// A person is an object that walks. With `walks` set, the object is drawn
	// from character art with the pose chosen by the way it faces, and moved
	// by its routine; `pos` is kept up to date from the actor, so drawing
	// order, blocking and nearness all carry on reading the same field they
	// always did. See routine.odin.
	walks:       bool,
	char_name:   string,
	actor:       Actor,
	routine:     Routine,
	// `pose=sit`: the part a person holds when nothing else is asking for one —
	// a guest in a chair, a man on a step. A routine's `play` borrows the
	// actor's pose for its own step and gives this back.
	rest_pose:   string,
	// `facing=`: the way they face standing on their line, turned back to when
	// they arrive from walking on (side.odin), whichever way they walked.
	rest_facing: Facing,

	// Drawing order. `pos.y` is where the thing meets the floor and is what
	// sorts it; `base` shifts that line without moving the sprite, for art
	// whose bottom edge isn't where it touches the ground — a hanging lamp,
	// a sign, a table drawn with a skirt below its legs.
	depth:       Depth,
	base:        f32,
	glow:        bool, // a light: drawn as painted, whatever World.tint is doing to the room
	show:        bool, // can be shown to people without being carried: a photograph on a wall. See show_thing
	// `whole=true`: never hidden by the room's depth map (priority.odin): an
	// overlay that repaints part of the backdrop, whatever stands nearer.
	whole:       bool,
	// Its sprite's own depth (`<sprite>.depth`), if it has one: drawn whole
	// at its farthest feet line and stamped into the room's. See priority.odin.
	own_depth:   ^Depth_Map,

	// An aperture: a net, a vent, a hatch, a window. A `peep` line in a scene
	// file makes one; it is an object in every other way. See peep.odin.
	peep:        Peep_Info,

	// Worked out from `only` whenever the flags change, so that drawing,
	// walking and looking can ask a bool instead of parsing a condition sixty
	// times a second. Zero means shown, so an object built in code with no
	// condition at all is simply here. See refresh_world.
	hidden:      bool,

	// A person coming and going through a side (side.odin): `enters=` and
	// `leaves=` from the file. `going`: walking off, and already gone as far
	// as anything but drawing can tell. `coming`: walking on, the routine
	// waiting. `away`: walked off by a routine's `leave`, until the room is
	// next entered.
	enters:      Maybe(Compass),
	leaves:      Maybe(Compass),
	going:       bool,
	going_from:  [2]f32,
	coming:      bool,
	coming_to:   [2]f32,
	away:        bool,
	// Spoken to while walking off (sight.odin, call_back): stopped, turned
	// to her, and here until she has finished with them, whatever when= says.
	held:        bool,
}

// Things painted into the background that you can still look at: the
// window, the floor, the moon.
Scenery :: struct {
	name:        string,
	description: string,
	only:        string, // condition; see flags.odin
	hidden:      bool,   // worked out from `only`; see refresh_world
}

// An opening onto the outside: a window's glass, an open door's gap. What is
// out there is painted in the backdrop; the frame, bars and sill are an
// object of their own, drawn over whatever stands outside. The engine does
// one thing with it: a passer (passer.odin) walks across it, clipped to the
// glass, drawn just under the frame.
//
//     window back glass=445,176,138,122 feet=380 frame=win_hut_back when=night
//
// `glass` is x,y,w,h on the canvas. `feet` is the line a figure out there
// stands on; 0 says the default, the glass's foot plus half a figure, so it
// shows from the waist up (window_feet). `frame` names the object it is drawn
// just under; none, and it goes after everything at depth=back.
Window :: struct {
	name:   string,
	glass:  rl.Rectangle,
	feet:   f32,
	frame:  string,
	only:   string, // condition; see flags.odin
	hidden: bool,   // worked out from `only`; see refresh_world
}

// A way into another scene. Standing in `area` takes the player to scene
// `to`, at `arrive`, unless it's closed.
Exit :: struct {
	name:        string,       // noun for GO: "door", "east"
	area:        rl.Rectangle, // patch of floor that triggers it
	to:          int,          // index into World.scenes
	to_name:     string,       // or the scene's name, which is how files say it — see resolve_exits
	arrive:      [2]f32,
	closed:      bool,
	closed_text: string,       // said when you walk into it while closed
	only:        string,       // condition; see flags.odin
	hidden:      bool,         // worked out from `only`; see refresh_world
	// One of the game's gates (side.odin): closed while it is shut, whatever
	// the file says; `closed_file` is what the file says.
	gate:        string,
	closed_file: bool,

	// Going through it as something you do: up a ladder, over a sill, through
	// a door that has to be opened. `anim` plays here, after she has walked to
	// `at` (if set) and turned to `face`; then the room changes and
	// `arrive_anim` plays in the new one. See anim.odin.
	anim:        string,
	arrive_anim: string,
	at:          [2]f32,
	face:        Maybe(Facing),
}

// A patch of floor that does something the moment the player steps onto it:
// a trap, a cutscene, a death.
//
// A trigger loaded from a file arrives with `action` set but `on_enter` nil:
// the file can say *that* the road runs you over, but the code that does it
// lives in the game. scene_bind_trigger joins the two up.
Trigger :: struct {
	area:     rl.Rectangle,
	name:     string,
	action:   string,
	only:     string, // condition; see flags.odin
	hidden:   bool,   // worked out from `only`; see refresh_world
	on_enter: proc(w: ^World),
}

// A line of description that only applies under some condition.
Said :: struct {
	only: string,
	text: string,
}

Scene_Ambience :: struct {
	only: string,
	name: string,
	loop: ^Loop,
}

// Which of a scene's descriptions applies now. A conditional one is preferred
// over the plain one whatever order they were written in, so a file can put
// the everyday text first and the act-four text after it, which is how anyone
// would write it.
scene_description :: proc(w: ^World, scene: ^Scene) -> string {
	for s in scene.said do if s.only != "" && condition_met(w, s.only) do return s.text
	for s in scene.said do if s.only == "" do return s.text
	return scene.description
}

// Works out what is here and what isn't, from the flags, and does it once.
//
// Conditions are read constantly — every frame for drawing, every step for
// walking, every command for looking — and change rarely, at a checkpoint. So
// they are evaluated when the flags change rather than when they are read,
// and everything else asks a bool.
//
// Call it after changing flags (set_flag does), after loading a scene, and
// after restoring a save. Doing it twice costs nothing.
refresh_scene :: proc(w: ^World, scene: ^Scene) {
	// A scene with no written descriptions keeps whatever it was given in
	// code; one from a file gets whichever of its lines applies.
	if len(scene.said) > 0 do scene.description = scene_description(w, scene)
	for a in scene.ambiences {
		if condition_met(w, a.only) {
			scene.ambience = a.loop
			scene.ambience_name = a.name
		}
	}
	// A flag set in front of her (set_flag, in the room she is in): a person
	// with `leaves=` or `enters=` walks off or on through that side rather
	// than going or coming at once (side.odin).
	live := w.flag_live && len(w.scenes) > 0 && scene == current_scene(w) && !cutting(w)
	// Who was in sight before this refresh: somebody who only changes lines
	// here (a pose, a chair, a doorway) swaps at once rather than walking off
	// one line and on the other (side.odin, person_stays).
	was: []bool
	if live {
		was = make([]bool, len(scene.objects), context.temp_allocator)
		for o, i in scene.objects do was[i] = o.walks && !o.hidden
	}
	for &o, i in scene.objects {
		now := (!condition_met(w, o.only) || o.away) && !o.held
		if live && o.walks && now != o.hidden && !person_stays(w, scene, i, now, was) do person_moves(scene, &o, now)
		o.hidden = now
	}
	for &sc in scene.scenery do sc.hidden = !condition_met(w, sc.only)
	for &e in scene.exits {
		e.hidden = !condition_met(w, e.only)
		if e.gate != "" do e.closed = e.closed_file || gate_shut(w, e.gate)
	}
	for &s in scene.sides do s.hidden = !condition_met(w, s.only)
	for &t in scene.triggers do t.hidden = !condition_met(w, t.only)
	for &e in scene.edges do e.hidden = !condition_met(w, e.only)
	for &win in scene.windows do win.hidden = !condition_met(w, win.only)
}

refresh_world :: proc(w: ^World) {
	for &s in w.scenes do refresh_scene(w, &s)
	note_open_awards(w)
}

// The object the player means, if it is here at all. The plain find_object
// below finds it either way, and is for the code that owns the scene:
// loading it, saving it, editing it.
object_here :: proc(scene: ^Scene, name: string) -> ^Object {
	for &o in scene.objects {
		if o.name == name && !o.hidden do return &o
	}
	return nil
}

// The interaction that answers this command, or nil.
//
// An interaction naming a second noun is tried before one that doesn't, so
// UNLOCK DOOR WITH KEY finds the specific answer and UNLOCK DOOR finds the
// general one — and a game can write both without ordering them carefully.
object_interaction :: proc(w: ^World, o: ^Object, cmd: Command) -> ^Interaction {
	general: ^Interaction
	for &it in o.on {
		if it.verb != cmd.verb || !condition_met(w, it.only) do continue
		if it.with != "" {
			if it.with == cmd.noun2 do return &it
			continue
		}
		if general == nil do general = &it
	}
	return general
}

find_object :: proc(scene: ^Scene, name: string) -> ^Object {
	for &o in scene.objects {
		if o.name == name do return &o
	}
	return nil
}

// The LOOK AT text for an object or a piece of scenery.
describe :: proc(scene: ^Scene, name: string) -> (text: string, ok: bool) {
	if o := object_here(scene, name); o != nil do return o.description, true
	for s in scene.scenery {
		if s.name == name && !s.hidden do return s.description, true
	}
	return "", false
}

// Is there anything by this name in the scene: an object, scenery or an exit?
is_here :: proc(scene: ^Scene, name: string) -> bool {
	if _, ok := describe(scene, name); ok do return true
	for e in scene.exits {
		if e.name == name && !e.hidden do return true
	}
	return false
}

in_rect :: proc(p: [2]f32, r: rl.Rectangle) -> bool {
	return p.x >= r.x && p.x < r.x + r.width && p.y >= r.y && p.y < r.y + r.height
}

rect_center :: proc(r: rl.Rectangle) -> [2]f32 {
	return {r.x + r.width / 2, r.y + r.height / 2}
}

@(private)
draw_world :: proc(w: ^World) {
	rl.ClearBackground(rl.BLACK)
	draw_room(w, current_scene(w), true)
	// The band under the picture stays black, whatever was drawn into it.
	band := i32(room_height(current_scene(w)))
	rl.DrawRectangle(0, band, WIDTH, HEIGHT - band, rl.BLACK)
	draw_world_top(w)
}

// Everything over the room: a death playing, the debug view, the boxes.
@(private)
draw_world_top :: proc(w: ^World) {
	if w.dead && w.death.draw != nil do w.death.draw(w, w.death_time)
	if w.debug do draw_debug(w)
	if w.death_box {
		draw_death_box(w)
	} else {
		draw_ui(w)
	}
	draw_announcement(w) // over everything, the boxes too
}

// One room, back to front, with the player in it or not. The room on screen
// has them; a room somebody else is looking into has them only if that is
// where they are.
//
// In the room's light (light.odin): the backdrop and every sprite as painted
// for it, and whatever was not painted for it — a fallback, a person —
// through the room's tint. Lights (`glow`) are always as painted.
// draw_room's item for the first of World.sight.called; far from a cut's
// extras (-2 down) and the passer (min(int)).
@(private)
SIGHT_ITEM :: min(int) / 2

// A drifting layer in the room's light: as painted for it, or another
// light's painting through the room's tint, as a backdrop is.
@(private)
draw_drift :: proc(d: Drift, light: Light, tint: Palette_Map, plain: bool, time: f32) {
	l := d.layer
	raw := plain
	if d.lit.painted != {} {
		l.sprite = d.lit.by[light]
		raw = raw || light in d.lit.painted
	}
	if l.sprite.texture.id == 0 do return
	if !raw do begin_tint(tint)
	draw_layer(l, time)
	if !raw do end_tint()
}

@(private)
draw_room :: proc(w: ^World, scene: ^Scene, player: bool) {
	light := room_light(w, scene)
	tint := room_tint(w, scene, light)
	plain := tint_is_plain(tint)
	if bg := scene.backdrop[light]; bg.texture.id != 0 {
		raw := plain || light in scene.backdrop_painted
		if !raw do begin_tint(tint)
		draw_sprite_at(bg, 0, 0, 0)
		if !raw do end_tint()
	} else if scene.background.texture.id != 0 {
		// A scene built in code: one backdrop, for every light.
		if !plain do begin_tint(tint)
		draw_sprite_at(scene.background, 0, 0, 0)
		if !plain do end_tint()
	}
	for d in scene.drifts do draw_drift(d, light, tint, plain, w.time)
	if w.debug && scene == current_scene(w) do draw_debug_floor(scene) // under the sprites, so they keep their colours

// Painter's algorithm: whoever's feet are lower on screen is nearer the
	// camera, so sort by feet and draw back to front. That is what lets
	// anybody walk behind the table and then in front of it, and it follows a
	// walking person for free because their feet are their position.
	//
	// Three things decide the order, in this order:
	//
	//   depth  a rug is always behind, a foreground bush always in front
	//   feet   pos.y, shifted by `base` for art that doesn't meet the floor
	//          at the bottom of its sprite
	//   index  so that two things standing on the same line keep whatever
	//          order the scene file gave them, every frame. Without it the
	//          sort is free to swap them and they flicker.
	Item :: struct {
		depth: Depth,
		y:     f32,
		i:     int,
		obj:   int,  // -1 = the player; -2 and below, a cutscene's extras; PASSER_ITEM, somebody outside
		pre:   bool, // drawn just before the item it ties with: the passer, under its window's frame
	}
	items := make([dynamic]Item, 0, len(scene.objects) + 2, context.temp_allocator)
	for &o, i in scene.objects {
		// A thing with depth of its own goes at its farthest line (priority.odin).
		y := own_depth_line(&o) if o.own_depth != nil else o.pos.y + o.base
		// Somebody walking off through a side is gone, but still drawn.
		if !o.hidden || o.going do append(&items, Item{o.depth, y, i, i, false})
	}
	if player do append(&items, Item{.Normal, w.player.pos.y, len(scene.objects), -1, false})
	// Whoever has been called into sight to speak to her (sight.odin).
	if player && scene == current_scene(w) {
		for c, i in w.sight.called do append(&items, Item{.Normal, c.actor.pos.y, len(scene.objects) + 1000 + i, SIGHT_ITEM + i, false})
	}
	// Whoever a cutscene playing here has brought on. See cutscene.odin.
	if cutting(w) && w.cut.scene >= 0 && w.cut.scene < len(w.scenes) && scene == &w.scenes[w.cut.scene] {
		for role, i in w.cut.roles {
			if role == .Extra do append(&items, Item{.Normal, w.cut.actors[i].pos.y, len(scene.objects) + 1 + i, -2 - i, false})
		}
	}
	// Somebody going past outside, if they are (passer.odin): just under the
	// window's frame, so the frame, the room and its people are over them.
	passing, passer_at := passer_shown(w, scene)
	if passing {
		key := passer_key(scene, &scene.windows[passer_at])
		append(&items, Item{key.depth, key.y, key.i, PASSER_ITEM, true})
	}
	slice.sort_by(items[:], proc(a, b: Item) -> bool {
		if a.depth != b.depth do return a.depth < b.depth
		if a.y != b.y do return a.y < b.y
		if a.i != b.i do return a.i < b.i
		return a.pre && !b.pre
	})

	// The room's depth (priority.odin): each person, and each thing at
	// depth=normal, is hidden behind every pixel of it nearer than their feet.
	dm: ^Depth_Map
	if !depth_maps_off && scene.depth_map.w > 0 do dm = scene_depth_now(scene)
	for it in items {
		if it.obj == PASSER_ITEM {
			draw_passer(w, &scene.windows[passer_at], tint, plain)
			continue
		}
		if it.obj >= SIGHT_ITEM && it.obj < SIGHT_ITEM + len(w.sight.called) {
			a := w.sight.called[it.obj - SIGHT_ITEM].actor
			depth_mask_actor(dm, scene.map_scale, a, it.y)
			if !plain do begin_tint(tint)
			draw_actor(a)
			if !plain do end_tint()
			depth_mask_end()
			continue
		}
		if it.obj <= -2 {
			depth_mask_actor(dm, scene.map_scale, w.cut.actors[-2 - it.obj], it.y)
			if !plain do begin_tint(tint)
			draw_actor(w.cut.actors[-2 - it.obj])
			if !plain do end_tint()
			depth_mask_end()
			continue
		}
		if it.obj < 0 {
			if w.dead do continue // while dying, the death draws them
			depth_mask_actor(dm, scene.map_scale, w.player, it.y)
			if !plain do begin_tint(tint)
			draw_actor(w.player)
			if !plain do end_tint()
			depth_mask_end()
			continue
		}
		o := scene.objects[it.obj]
		if o.walks {
			if it.depth == .Normal do depth_mask_actor(dm, scene.map_scale, o.actor, it.y)
			if !plain do begin_tint(tint)
			draw_actor(o.actor)
			if !plain do end_tint()
			depth_mask_end()
			continue
		}
		sprite, raw := o.sprite, plain || o.glow
		if o.lit.painted != {} {
			sprite = o.lit.by[light]
			raw = raw || light in o.lit.painted
		}
		if sprite.texture.id == 0 do continue // not painted for this light at all: a lamp by day
		frame := o.frame
		if o.fps != 0 {
			// Its own rhythm, with its frames' holds, and its own phase: two
			// bushes in one room do not sway in step.
			phase := f32(int(o.pos.x * 7 + o.pos.y * 13) % 97) / 9.7
			frame, _ = anim_frame(w.time + phase, o.fps, sprite.frames, sprite.holds)
		}
		if it.depth == .Normal && !o.whole && o.own_depth == nil do depth_mask_sprite(dm, scene.map_scale, sprite, o.pos, it.y)
		if !raw do begin_tint(tint)
		draw_sprite_on_grid(sprite, frame, o.pos) // on the backdrop's own grid: an overlay lands on its paint
		if !raw do end_tint()
		depth_mask_end()
	}
}

