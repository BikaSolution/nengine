package nengine

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// Scene files.
//
//     scene parlour
//     desc A small parlour. There's a hole in the floor.
//     bg parlour
//     walk 24,122 318,122 318,186 4,186
//     obj lamp pos=232,158 sprite=lamp fps=6 walk_to=214,162 block=circle:10 reach=circle:48
//     text lamp A standing lamp. It flickers.
//     scenery window Night outside. A thin moon.
//     exit door area=256,122,30,4 to=street arrive=160,142 closed=true
//     shut door The door is closed.
//     trigger road area=0,157,320,43 action=run_over
//     edge pond action=drown 0,190 320,190 320,200 0,200
//     window back glass=100,60,40,36 feet=118 frame=window_frame when=night
//
// A loaded scene is data only: pictures come from an Assets table by name,
// and behaviour (what an object does when used, what a trigger fires)
// stays in game code, matched up by name afterwards. See scene_bind_trigger.

// Half the standard verbs are two words — "talk to", "look at", "turn on" —
// and a line like `on elena talk to Evening.` gives no way to tell where the
// verb stops and the sentence starts. So a verb is written as one word with
// underscores for the spaces: `on elena talk_to Evening.` It is ugly for
// about a second and unambiguous forever.
@(private = "file")
verb_phrase :: proc(word: string) -> string {
	return strings.replace_all(word, "_", " ") or_else strings.clone(word)
}

@(private = "file")
parse_depth :: proc(word: string) -> Depth {
	switch word {
	case "back", "behind": return .Back
	case "front":          return .Front
	}
	return .Normal
}

@(private = "file")
depth_text :: proc(d: Depth) -> string {
	switch d {
	case .Back:   return "back"
	case .Front:  return "front"
	case .Normal: return "normal"
	}
	return "normal"
}

@(private = "file")
field_or_text :: proc(l: Line, name, fallback: string) -> string {
	if v, has := field(l, name); has do return v
	return fallback
}

// A field's value as a string this scene owns, or "" if it wasn't given.
@(private = "file")
clone_field :: proc(l: Line, name: string) -> string {
	if v, has := field(l, name); has do return strings.clone(v)
	return strings.clone("")
}

load_scene :: proc(path: string, assets: ^Assets) -> (s: Scene, ok: bool) {
	text := read_data_file(path) or_return
	return parse_scene(text, assets)
}

parse_scene :: proc(text: string, assets: ^Assets) -> (s: Scene, ok: bool) {
	walk := make([dynamic][2]f32)
	scenery := make([dynamic]Scenery)

	for raw in data_lines(text) {
		l := parse_line(raw)
		switch l.key {
		case "scene":
			if len(l.words) > 0 do s.name = strings.clone(l.words[0])

		case "desc":
			// `desc when=act4 Cold.` is what the room says in act four; a
			// plain `desc` is what it says the rest of the time.
			// Every description goes in the list, conditional or not, and
			// refresh_scene picks the one that applies. `description` ends up
			// pointing at whichever that is.
			only, _ := field(l, "when")
			append(&s.said, Said{strings.clone(only), strings.clone(line_rest(raw, 1))})

		case "bg":
			// Either a .png, or a .sprite — a backdrop is painted in the
			// pixel editor like everything else, and `just bake` turns it
			// into the .png. Falling back to the sprite means a backdrop you
			// have only just drawn still shows up.
			if len(l.words) == 0 do continue
			s.background_name = strings.clone(l.words[0])
			// And the same in every light it was painted in (light.odin):
			// `pool_deck.night` beside `pool_deck`.
			if assets != nil {
				for light in Light {
					key := strings.concatenate({l.words[0], LIGHT_SUFFIX[light]}, context.temp_allocator)
					if tex, found := assets.images[key]; found {
						s.backdrop[light] = texture_sprite(tex)
					} else if sprite, drawn := assets.sprites[key]; drawn {
						s.backdrop[light] = sprite
					} else {
						continue
					}
					s.backdrop_painted += {light}
				}
				fill_fallbacks(&s.backdrop, s.backdrop_painted)
				s.background = s.backdrop[.Day]
			}

		case "depth_map", "solid_map":
			// Sierra's priority and control screens (priority.odin): found by
			// the backdrop's name unless the file names others, or `none`.
			if len(l.words) == 0 do continue
			if l.key == "depth_map" {
				s.depth_name = strings.clone(l.words[0])
				s.depth_named = true
			} else {
				s.solid_name = strings.clone(l.words[0])
				s.solid_named = true
			}

		case "indoors": // a roof: the light outside changes while she is under it
			s.indoors = true

		case "ambience":
			if len(l.words) == 0 do continue
			a := Scene_Ambience{only = clone_field(l, "when"), name = strings.clone(l.words[0])}
			if assets != nil do a.loop = assets_loop(assets, l.words[0])
			append(&s.ambiences, a)
			if a.only == "" {
				s.ambience_name = a.name
				s.ambience = a.loop
			}

		case "footstep":
			if len(l.words) == 0 do continue
			s.step_name = strings.clone(l.words[0])
			if assets != nil do s.step = assets_sound(assets, l.words[0])

		case "walk":
			for w in l.words {
				if p, good := parse_vec2(w); good do append(&walk, p)
			}

		case "obj", "peep":
			if len(l.words) == 0 do continue
			o := Object {
				name    = strings.clone(l.words[0]),
				pos     = field_vec2(l, "pos"),
				fps     = field_f32(l, "fps"),
				frame   = i32(field_int(l, "frame")),
				walk_to = field_vec2(l, "walk_to"),
				block   = field_shape(l, "block"),
				reach   = field_shape(l, "reach"),
				only    = clone_field(l, "when"),
				base    = field_f32(l, "base"),
				glow    = field_bool(l, "glow"),
				show    = field_bool(l, "show"),
				whole   = field_bool(l, "whole"),
				depth   = parse_depth(field_or_text(l, "depth", "normal")),
			}
			// Coming and going through a side: `enters=south leaves=east`.
			if v, has := field(l, "enters"); has {
				if d, good := compass_of(v); good do o.enters = d
			}
			if v, has := field(l, "leaves"); has {
				if d, good := compass_of(v); good do o.leaves = d
			}
			// A person: an object that walks, drawn from character art and
			// moved by its routine rather than standing where it was put.
			if char_name, is_person := field(l, "char"); is_person {
				o.walks = true
				o.char_name = strings.clone(char_name)
				o.actor = Actor {
					pos      = o.pos,
					speed    = field_f32(l, "speed", 120),
					idle_fps = 4,
					walk_fps = 8,
					facing   = parse_facing(field_or_text(l, "facing", "front")),
					npc      = true, // walks round her (priority.odin)
				}
				o.rest_pose = clone_field(l, "pose")
				o.actor.pose = o.rest_pose
				if assets != nil {
					if art, found := &assets.chars[char_name]; found do o.actor.character = art
				}
			}
			if sprite_name, has := field(l, "sprite"); has {
				o.sprite_name = strings.clone(sprite_name)
				if assets != nil {
					o.sprite = assets_sprite(assets, sprite_name)
					o.lit = lit_sprite(assets, sprite_name)
				}
			}
			if loop_name, has := field(l, "loop"); has {
				o.loop_name = strings.clone(loop_name)
				if assets != nil do o.loop = assets_loop(assets, loop_name)
			}
			if tick_name, has := field(l, "tick"); has {
				o.tick_name = strings.clone(tick_name)
				if assets != nil do o.tick = assets_sound(assets, tick_name)
			}
			for f in field_ints(l, "ticks") {
				if f >= 0 && f < 32 do o.tick_frames += {f}
			}
			// An aperture: `peep net5 pos=612,300 into=tent dress=5 kind=net
			// blind=lamp_in_5 walk_to=612,330 frame=net_frame`. See peep.odin.
			if l.key == "peep" {
				o.peep = Peep_Info {
					is    = true,
					into  = clone_field(l, "into"),
					dress = clone_field(l, "dress"),
					kind  = peep_kind_from_name(field_or_text(l, "kind", "window")),
					blind = clone_field(l, "blind"),
					frame = clone_field(l, "frame"),
					near  = clone_field(l, "near"),
				}
				peep_resolve_art(&o.peep, assets)
			}
			append(&s.objects, o)

		case "text": // description for an object named in the first word
			if len(l.words) == 0 do continue
			if o := latest_object(&s, l.words[0]); o != nil {
				o.description = strings.clone(line_rest(raw, 2))
			}

		case "routine": // `routine elena loop` — how the person's steps repeat
			if len(l.words) == 0 do continue
			if o := latest_object(&s, l.words[0]); o != nil {
				for word in l.words[1:] do if word == "loop" do o.routine.loop = true
			}

		case "step": // one step of a person's routine; see routine.odin
			if len(l.words) == 0 do continue
			o := latest_object(&s, l.words[0])
			if o == nil do continue
			if st, good := parse_step(l, raw); good do append(&o.routine.steps, st)

		case "on": // what an object does when a verb lands on it
			// on <object> <verb> [with=noun] [when=cond] [action=name] [anim=part] <text>
			if len(l.words) < 2 do continue
			o := latest_object(&s, l.words[0])
			if o == nil do continue
			append(&o.on, Interaction {
				verb   = verb_phrase(l.words[1]),
				with   = clone_field(l, "with"),
				only   = clone_field(l, "when"),
				action = clone_field(l, "action"),
				anim   = clone_field(l, "anim"),
				text   = strings.clone(line_rest(raw, 3)),
			})

		case "scenery":
			if len(l.words) == 0 do continue
			append(&scenery, Scenery {
				name        = strings.clone(l.words[0]),
				description = strings.clone(line_rest(raw, 2)),
				only        = clone_field(l, "when"),
			})

		case "exit":
			if len(l.words) == 0 do continue
			e := Exit {
				name   = strings.clone(l.words[0]),
				arrive = field_vec2(l, "arrive"),
				closed = field_bool(l, "closed"),
				only   = clone_field(l, "when"),
				gate   = clone_field(l, "gate"),
			}
			e.closed_file = e.closed
			// `to=admin` names the room; `to=2` is an index into the world's
			// scenes. By name is the one to write: an index makes the order the
			// game loads its rooms in load-bearing, and inserting a room then
			// quietly re-points every exit after it. A name is kept here and
			// turned into an index by resolve_exits once every room is loaded.
			//
			// This used to say "resolved by name below" and there was nothing
			// below: `to=admin` parsed as 0 and dropped the player in the first
			// room, without a word.
			if raw_to, has := field(l, "to"); has {
				if n, is_number := strconv.parse_int(raw_to); is_number {
					e.to = n
				} else {
					e.to_name = strings.clone(raw_to)
				}
			}
			if r := field_rect(l, "area"); r.ok {
				e.area = {r.rect[0], r.rect[1], r.rect[2], r.rect[3]}
			}
			// Going through as a thing she does: `anim=climb_up at=410,300
			// face=back arrive_anim=climb_off`. See anim.odin.
			e.anim = clone_field(l, "anim")
			e.arrive_anim = clone_field(l, "arrive_anim")
			e.at = field_vec2(l, "at")
			if f, has := field(l, "face"); has do e.face = parse_facing(f)
			append(&s.exits, e)

		case "shut": // closed_text for an exit named in the first word
			if len(l.words) == 0 do continue
			for &e in s.exits {
				if e.name == l.words[0] do e.closed_text = strings.clone(line_tail(raw, 2))
			}
			// `shut south ...`: what the sides that way say when their gate is shut.
			if d, is_dir := compass_of(l.words[0]); is_dir {
				for &sd in s.sides do if sd.dir == d {
					delete(sd.closed_text)
					sd.closed_text = strings.clone(line_tail(raw, 2))
				}
			}

		case "side":
			// `side north to=inside_path span=384,640 gate=g2 when=... name=path
			// arrive=x,y`: a border walked straight across. See side.odin.
			if len(l.words) == 0 do continue
			d, is_dir := compass_of(l.words[0])
			if !is_dir do continue
			span := field_vec2(l, "span")
			sd := Side {
				dir  = d,
				span = {min(span.x, span.y), max(span.x, span.y)},
				gate = clone_field(l, "gate"),
				name = clone_field(l, "name"),
				only = clone_field(l, "when"),
			}
			if raw_to, has := field(l, "to"); has {
				if n, is_number := strconv.parse_int(raw_to); is_number {
					sd.to = n
				} else {
					sd.to_name = strings.clone(raw_to)
				}
			}
			if _, has := field(l, "arrive"); has {
				sd.arrive = field_vec2(l, "arrive")
				sd.has_arrive = true
			}
			append(&s.sides, sd)

		case "window":
			// An opening onto the outside, for somebody to go past: `window
			// back glass=445,176,138,122 feet=380 frame=win_back when=night`.
			// See Window in scene.odin, and passer.odin.
			if len(l.words) == 0 do continue
			r := field_rect(l, "glass")
			if !r.ok do continue
			append(&s.windows, Window {
				name  = strings.clone(l.words[0]),
				glass = {r.rect[0], r.rect[1], r.rect[2], r.rect[3]},
				feet  = field_f32(l, "feet"),
				frame = clone_field(l, "frame"),
				only  = clone_field(l, "when"),
			})

		case "trigger":
			if len(l.words) == 0 do continue
			r := field_rect(l, "area")
			if !r.ok do continue
			action, _ := field(l, "action")
			append(&s.triggers, Trigger {
				area   = {r.rect[0], r.rect[1], r.rect[2], r.rect[3]},
				name   = strings.clone(l.words[0]),
				action = strings.clone(action),
				only   = clone_field(l, "when"),
			})

		case "edge":
			// `edge water action=drown when=... 716,446 1024,446 ...`: off the
			// floor, a polygon, and what stepping over is. See edge.odin.
			if len(l.words) == 0 do continue
			area := make([dynamic][2]f32)
			for word in l.words[1:] {
				if p, good := parse_vec2(word); good do append(&area, p)
			}
			action, _ := field(l, "action")
			append(&s.edges, Edge {
				name   = strings.clone(l.words[0]),
				area   = area[:],
				action = strings.clone(action),
				only   = clone_field(l, "when"),
			})
		}
	}

	s.walk_area = walk[:]
	s.scenery = scenery[:]
	s.from_file = true
	scene_attach_maps(&s, assets) // its depth and solid maps (priority.odin)
	// A freshly parsed scene reads as its everyday self. refresh_scene moves
	// it on to a conditional one once there are flags to test; until then a
	// caller that only parses — the room editor, a tool — sees the text the
	// file leads with rather than nothing at all.
	for said in s.said do if said.only == "" {
		s.description = said.text
		break
	}
	return s, true
}

save_scene :: proc(s: ^Scene, path: string) -> bool {
	return write_data_file(path, scene_text(s))
}

scene_text :: proc(s: ^Scene, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "# nengine scene\nscene %v\n", s.name)
	if len(s.said) == 0 {
		if s.description != "" do fmt.sbprintf(&b, "desc %v\n", s.description)
	} else {
		for said in s.said {
			if said.only == "" do fmt.sbprintf(&b, "desc %v\n", said.text)
		}
		for said in s.said {
			if said.only != "" do fmt.sbprintf(&b, "desc when=%v %v\n", said.only, said.text)
		}
	}
	if s.background_name != "" do fmt.sbprintf(&b, "bg %v\n", s.background_name)
	if s.indoors do strings.write_string(&b, "indoors\n")
	if s.depth_named do fmt.sbprintf(&b, "depth_map %v\n", s.depth_name)
	if s.solid_named do fmt.sbprintf(&b, "solid_map %v\n", s.solid_name)
	if len(s.ambiences) > 0 {
		for a in s.ambiences {
			if a.only == "" do fmt.sbprintf(&b, "ambience %v\n", a.name)
			else do fmt.sbprintf(&b, "ambience when=%v %v\n", a.only, a.name)
		}
	} else if s.ambience_name != "" {
		fmt.sbprintf(&b, "ambience %v\n", s.ambience_name)
	}
	if s.step_name != "" do fmt.sbprintf(&b, "footstep %v\n", s.step_name)

	if len(s.walk_area) > 0 {
		strings.write_string(&b, "walk")
		for p in s.walk_area do fmt.sbprintf(&b, " %v,%v", p.x, p.y)
		strings.write_byte(&b, '\n')
	}

	for o in s.objects {
		fmt.sbprintf(&b, "%v %v pos=%v,%v", "peep" if o.peep.is else "obj", o.name, o.pos.x, o.pos.y)
		if o.peep.is {
			if o.peep.into != "" do fmt.sbprintf(&b, " into=%v", o.peep.into)
			if o.peep.dress != "" do fmt.sbprintf(&b, " dress=%v", o.peep.dress)
			fmt.sbprintf(&b, " kind=%v", peep_kind_name(o.peep.kind))
			if o.peep.blind != "" do fmt.sbprintf(&b, " blind=%v", o.peep.blind)
			if o.peep.frame != "" do fmt.sbprintf(&b, " frame=%v", o.peep.frame)
			if o.peep.near != "" do fmt.sbprintf(&b, " near=%v", o.peep.near)
		}
		if o.sprite_name != "" do fmt.sbprintf(&b, " sprite=%v", o.sprite_name)
		// The frame a still object shows. A peep's `frame=` is the name of its
		// frame's art, written above, and is not this.
		if o.frame != 0 && !o.peep.is do fmt.sbprintf(&b, " frame=%v", o.frame)
		if o.fps != 0 do fmt.sbprintf(&b, " fps=%v", o.fps)
		if o.walk_to != {} do fmt.sbprintf(&b, " walk_to=%v,%v", o.walk_to.x, o.walk_to.y)
		if o.loop_name != "" do fmt.sbprintf(&b, " loop=%v", o.loop_name)
		if o.tick_name != "" {
			fmt.sbprintf(&b, " tick=%v", o.tick_name)
			if o.tick_frames != {} {
				strings.write_string(&b, " ticks=")
				first := true
				for f in 0 ..< 32 {
					if f not_in o.tick_frames do continue
					if !first do strings.write_byte(&b, ',')
					fmt.sbprintf(&b, "%v", f)
					first = false
				}
			}
		}
		if o.block.kind != .None do fmt.sbprintf(&b, " block=%v", shape_text(o.block))
		if o.reach.kind != .None do fmt.sbprintf(&b, " reach=%v", shape_text(o.reach))
		if o.walks {
			fmt.sbprintf(&b, " char=%v", o.char_name)
			if o.actor.speed != 0 do fmt.sbprintf(&b, " speed=%v", o.actor.speed)
			fmt.sbprintf(&b, " facing=%v", facing_text(o.actor.facing))
			if o.rest_pose != "" do fmt.sbprintf(&b, " pose=%v", o.rest_pose)
		}
		if o.base != 0 do fmt.sbprintf(&b, " base=%v", o.base)
		if o.glow do strings.write_string(&b, " glow=true")
		if o.show do strings.write_string(&b, " show=true")
		if o.whole do strings.write_string(&b, " whole=true")
		if o.depth != .Normal do fmt.sbprintf(&b, " depth=%v", depth_text(o.depth))
		if d, has := o.enters.?; has do fmt.sbprintf(&b, " enters=%v", COMPASS_WORDS[d])
		if d, has := o.leaves.?; has do fmt.sbprintf(&b, " leaves=%v", COMPASS_WORDS[d])
		if o.only != "" do fmt.sbprintf(&b, " when=%v", o.only)
		strings.write_byte(&b, '\n')
		if o.description != "" do fmt.sbprintf(&b, "text %v %v\n", o.name, o.description)
		if o.routine.loop do fmt.sbprintf(&b, "routine %v loop\n", o.name)
		for st in o.routine.steps do fmt.sbprintf(&b, "%v\n", step_text(st, o.name))
		for it in o.on {
			written, _ := strings.replace_all(it.verb, " ", "_", context.temp_allocator)
			fmt.sbprintf(&b, "on %v %v", o.name, written)
			if it.with != "" do fmt.sbprintf(&b, " with=%v", it.with)
			if it.only != "" do fmt.sbprintf(&b, " when=%v", it.only)
			if it.action != "" do fmt.sbprintf(&b, " action=%v", it.action)
			if it.anim != "" do fmt.sbprintf(&b, " anim=%v", it.anim)
			if it.text != "" do fmt.sbprintf(&b, " %v", it.text)
			strings.write_byte(&b, '\n')
		}
	}

	for win in s.windows {
		g := win.glass
		fmt.sbprintf(&b, "window %v glass=%v,%v,%v,%v", win.name, g.x, g.y, g.width, g.height)
		if win.feet != 0 do fmt.sbprintf(&b, " feet=%v", win.feet)
		if win.frame != "" do fmt.sbprintf(&b, " frame=%v", win.frame)
		if win.only != "" do fmt.sbprintf(&b, " when=%v", win.only)
		strings.write_byte(&b, '\n')
	}

	for sc in s.scenery {
		fmt.sbprintf(&b, "scenery %v", sc.name)
		if sc.only != "" do fmt.sbprintf(&b, " when=%v", sc.only)
		fmt.sbprintf(&b, " %v\n", sc.description)
	}

	for e in s.exits {
		// Written back the way it was read: a name stays a name, so the room
		// editor saving a file cannot turn `to=admin` into `to=2`.
		to := e.to_name if e.to_name != "" else fmt.tprintf("%v", e.to)
		fmt.sbprintf(&b, "exit %v area=%v,%v,%v,%v to=%v arrive=%v,%v", e.name,
			e.area.x, e.area.y, e.area.width, e.area.height, to, e.arrive.x, e.arrive.y)
		// A gate's closing is the gate's, not the file's.
		if e.closed_file || (e.gate == "" && e.closed) do strings.write_string(&b, " closed=true")
		if e.only != "" do fmt.sbprintf(&b, " when=%v", e.only)
		if e.gate != "" do fmt.sbprintf(&b, " gate=%v", e.gate)
		if e.anim != "" do fmt.sbprintf(&b, " anim=%v", e.anim)
		if e.at != {} do fmt.sbprintf(&b, " at=%v,%v", e.at.x, e.at.y)
		if f, has := e.face.?; has do fmt.sbprintf(&b, " face=%v", facing_text(f))
		if e.arrive_anim != "" do fmt.sbprintf(&b, " arrive_anim=%v", e.arrive_anim)
		strings.write_byte(&b, '\n')
		if e.closed_text != "" do fmt.sbprintf(&b, "shut %v %v\n", e.name, e.closed_text)
	}

	// Each direction's `shut` line once, after the first side that way: it is
	// what every side that way says.
	said: bit_set[Compass]
	for sd in s.sides {
		to := sd.to_name if sd.to_name != "" else fmt.tprintf("%v", sd.to)
		fmt.sbprintf(&b, "side %v to=%v span=%v,%v", COMPASS_WORDS[sd.dir], to, sd.span[0], sd.span[1])
		if sd.gate != "" do fmt.sbprintf(&b, " gate=%v", sd.gate)
		if sd.name != "" do fmt.sbprintf(&b, " name=%v", sd.name)
		if sd.only != "" do fmt.sbprintf(&b, " when=%v", sd.only)
		if sd.has_arrive do fmt.sbprintf(&b, " arrive=%v,%v", sd.arrive.x, sd.arrive.y)
		strings.write_byte(&b, '\n')
		if sd.closed_text != "" && sd.dir not_in said {
			fmt.sbprintf(&b, "shut %v %v\n", COMPASS_WORDS[sd.dir], sd.closed_text)
			said += {sd.dir}
		}
	}

	for t, i in s.triggers {
		name := t.name if t.name != "" else fmt.tprintf("t%v", i)
		fmt.sbprintf(&b, "trigger %v area=%v,%v,%v,%v", name, t.area.x, t.area.y, t.area.width, t.area.height)
		if t.action != "" do fmt.sbprintf(&b, " action=%v", t.action)
		if t.only != "" do fmt.sbprintf(&b, " when=%v", t.only)
		strings.write_byte(&b, '\n')
	}

	for e in s.edges {
		fmt.sbprintf(&b, "edge %v", e.name)
		if e.action != "" do fmt.sbprintf(&b, " action=%v", e.action)
		if e.only != "" do fmt.sbprintf(&b, " when=%v", e.only)
		for p in e.area do fmt.sbprintf(&b, " %v,%v", p.x, p.y)
		strings.write_byte(&b, '\n')
	}

	return strings.to_string(b)
}

// Attach game behaviour to a scene loaded from a file: the file says a
// trigger is called "road" and should "run_over"; this is where the game
// says what run_over actually is.
// Loads a game's rooms, in order, from `<dir>/<name>.scene`, and joins up the
// exits between them by name. Fails — loudly, with the reason — on a room that
// will not load or an exit that names a room nobody loaded, because both of
// those are otherwise silent: the first is a black screen, the second drops
// the player somewhere else.
// A room may sit in a folder of its own, with its paintings and the sprites
// only it uses — `scenes/banda/banda.scene` — or loose in `dir`. The folder is
// tried first. (The asset loader reads folders inside folders, and a file is
// known by its own name wherever it sits, so nothing else needs telling.)
load_scenes :: proc(w: ^World, dir: string, names: []string, assets: ^Assets) -> (problem: string, ok: bool) {
	for name in names {
		path := fmt.tprintf("%v/%v/%v.scene", dir, name, name)
		if !os.exists(path) do path = fmt.tprintf("%v/%v.scene", dir, name)
		room, loaded := load_scene(path, assets)
		if !loaded do return fmt.tprintf("could not load %v", path), false
		append(&w.scenes, room)
	}
	if bad, fine := resolve_exits(w); !fine do return bad, false
	return "", true
}

// Turns every exit's `to=<name>` into an index into World.scenes. Call it once
// every room is loaded; load_scenes does. Returns the first exit that names a
// room that is not there.
resolve_exits :: proc(w: ^World) -> (problem: string, ok: bool) {
	for &sc in w.scenes {
		for &e in sc.exits {
			if e.to_name == "" do continue
			found := false
			for other, i in w.scenes {
				if other.name == e.to_name {
					e.to, found = i, true
					break
				}
			}
			if !found {
				return fmt.tprintf("%v: exit %v goes to %v, and there is no room called that", sc.name, e.name, e.to_name), false
			}
		}
		for &sd in sc.sides {
			if sd.to_name == "" do continue
			found := false
			for other, i in w.scenes {
				if other.name == sd.to_name {
					sd.to, found = i, true
					break
				}
			}
			if !found {
				return fmt.tprintf("%v: side %v goes to %v, and there is no room called that", sc.name, COMPASS_WORDS[sd.dir], sd.to_name), false
			}
		}
		// A gate is the game's (World.gates), declared before its rooms load.
		for e in sc.exits do if e.gate != "" && gate_named(w, e.gate) == nil {
			return fmt.tprintf("%v: exit %v names gate %v, and the game declares no gate called that", sc.name, e.name, e.gate), false
		}
		for sd in sc.sides do if sd.gate != "" && gate_named(w, sd.gate) == nil {
			return fmt.tprintf("%v: side %v names gate %v, and the game declares no gate called that", sc.name, COMPASS_WORDS[sd.dir], sd.gate), false
		}
		// A peep's far room, by name, as an exit's is. See peep.odin.
		for &o in sc.objects {
			if !o.peep.is || o.peep.into == "" do continue
			o.peep.into_at = -1
			for other, i in w.scenes do if other.name == o.peep.into do o.peep.into_at = i
			if o.peep.into_at < 0 {
				return fmt.tprintf("%v: peep %v looks into %v, and there is no room called that", sc.name, o.name, o.peep.into), false
			}
		}
	}
	return "", true
}

scene_bind_trigger :: proc(s: ^Scene, action: string, on_enter: proc(w: ^World)) {
	for &t in s.triggers {
		if t.action == action do t.on_enter = on_enter
	}
}

// The same, for what an object does. The file says the door's UNLOCK is
// called "unlock_door"; this is where the game says what that is.
scene_bind_action :: proc(s: ^Scene, action: string, on_do: proc(w: ^World, o: ^Object)) {
	for &o in s.objects {
		for &it in o.on do if it.action == action do it.on_do = on_do
	}
}

// Frees everything load_scene cloned. Only for scenes that came from a file:
// scenes built in code hold string literals, which mustn't be freed.
free_scene_strings :: proc(s: ^Scene) {
	delete(s.name)
	// `description` is a view into `said` for a scene from a file, so it is
	// freed there and not here.
	if len(s.said) == 0 do delete(s.description)
	for said in s.said {
		delete(said.only)
		delete(said.text)
	}
	delete(s.background_name)
	delete(s.depth_name)
	delete(s.solid_name)
	// `ambience_name` is a view into `ambiences` for a scene from a file.
	if len(s.ambiences) == 0 do delete(s.ambience_name)
	for a in s.ambiences {
		delete(a.only)
		delete(a.name)
	}
	delete(s.ambiences)
	delete(s.step_name)
	for o in s.objects {
		delete(o.name)
		delete(o.description)
		delete(o.sprite_name)
		delete(o.loop_name)
		delete(o.tick_name)
		delete(o.only)
		delete(o.char_name)
		delete(o.rest_pose)
		delete(o.peep.into)
		delete(o.peep.dress)
		delete(o.peep.blind)
		delete(o.peep.frame)
		delete(o.peep.near)
		for it in o.on {
			delete(it.verb)
			delete(it.with)
			delete(it.only)
			delete(it.action)
			delete(it.anim)
			delete(it.text)
		}
		delete(o.on)
	}
	for e in s.exits {
		delete(e.name)
		delete(e.to_name)
		delete(e.closed_text)
		delete(e.only)
		delete(e.anim)
		delete(e.arrive_anim)
		delete(e.gate)
	}
	for sd in s.sides {
		delete(sd.to_name)
		delete(sd.gate)
		delete(sd.name)
		delete(sd.only)
		delete(sd.closed_text)
	}
	for t in s.triggers {
		delete(t.name)
		delete(t.action)
		delete(t.only)
	}
	for e in s.edges {
		delete(e.name)
		delete(e.action)
		delete(e.only)
		delete(e.area)
	}
	for sc in s.scenery {
		delete(sc.name)
		delete(sc.description)
		delete(sc.only)
	}
	for win in s.windows {
		delete(win.name)
		delete(win.frame)
		delete(win.only)
	}
}

// The object a `text`, `on`, `routine` or `step` line is about: the most
// recent one declared by that name. A room may hold two objects of one name
// under different conditions — the fire laid and the fire lit, the dog before
// it was kicked and after — and each one's lines follow its own `obj` line.
@(private = "file")
latest_object :: proc(s: ^Scene, name: string) -> ^Object {
	#reverse for &o in s.objects do if o.name == name do return &o
	return nil
}
