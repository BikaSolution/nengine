package cutscene

import ne "../../../"
import ac "../../assetcache"
import ui "../../ui"
import "core:fmt"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"

// The room, with the cast standing in it where they would be at the moment the
// playhead is on. Drag somebody to move where they start; drag the ring in
// front of them to move where a walk_to sends them.
//
// The room is drawn as the game draws it in the light chosen: the backdrop,
// and the things in it that are there under the flags turned on in the cut's
// panel (none, to start with: what is there whatever the flags say, and what
// a `when=!something` keeps until it happens). People in the room who are in
// the cast are drawn where the cut has them, the others where they stand.
//
// Nothing here runs the engine's own player: it works out a position for a
// time, which is what an editor needs and a game does not. Scrubbing backwards
// has to put people back, and a player that only goes forwards cannot.

// The same speed the engine gives a cutscene's walks (CUT_SPEED), so what you
// time here is what happens in the game.
WALK_SPEED :: f32(190)

// Who a cast member is, as the engine will work it out when it plays
// (cutscene.odin, start_cutscene): somebody standing in the room by that name,
// or failing that wearing that .char; what they wear; where they start.
Cast_View :: struct {
	char:    string, // the .char drawn; "" for none
	guessed: bool,   // the character is a guess from the name
	person:  int,    // the room's object they are, or -1
	player:  bool,   // the player, as far as the editor can tell (Editor.player)
	start:   [2]f32,
	placed:  bool,   // `start` is known: at=, the room person's place, or off stage
	waiting: bool,   // an extra with no at=: off the side of the room until they walk on
	facing:  ne.Facing,
}

cast_view :: proc(e: ^Editor, i: int) -> (v: Cast_View) {
	v.person = -1
	if i < 0 || i >= len(e.doc.people) do return
	m := e.doc.people[i].m
	if e.has_room {
		// Somebody here under the flags turned on first, as the engine takes
		// somebody who is here now; then anybody of that name.
		for pass in 0 ..< 2 {
			for o, n in e.room.objects {
				if !o.walks || (pass == 0 && !ac.condition_holds(&e.flags, o.only)) do continue
				if o.name == m.name || (m.character != "" && o.char_name == m.character) {
					v.person = n
					break
				}
			}
			if v.person >= 0 do break
		}
	}
	v.char = m.character
	if v.char == "" && v.person >= 0 do v.char = e.room.objects[v.person].char_name
	if v.char == "" && m.name in e.art.index.chars {
		v.char = m.name
		v.guessed = true
	}
	v.player = v.person < 0 && e.player != "" && (m.name == e.player || m.character == e.player)
	switch {
	case !m.keep_place:
		v.start, v.placed = m.at, true
	case v.person >= 0:
		v.start, v.placed = e.room.objects[v.person].pos, true
	case v.player:
		// Where she stands when it plays, which the editor cannot know.
		v.start = floor_middle(e)
	case:
		// An extra is brought on: off the side nearer where they first walk
		// to, as the engine puts them (ne.offstage_start).
		goes, walks := first_walk(e, m.name)
		if !walks do goes = floor_middle(e)
		v.start, v.placed, v.waiting = ne.offstage_start(goes, e.size.x), true, true
	}
	v.facing = m.facing
	if m.keep_facing do v.facing = e.room.objects[v.person].actor.facing if v.person >= 0 else .Front
	return
}

// The middle of the floor, as the engine finds it.
floor_middle :: proc(e: ^Editor) -> [2]f32 {
	if !e.has_room || len(e.room.walk_area) == 0 do return {ROOM_W / 2, ROOM_H * 0.8}
	mid := [2]f32{}
	for p in e.room.walk_area do mid += p
	mid /= f32(len(e.room.walk_area))
	if len(e.room.walk_area) >= 3 do mid = ne.clamp_to_polygon(mid, e.room.walk_area[:])
	return mid
}

// The first place somebody walks to, in the order the cues fire.
first_walk :: proc(e: ^Editor, name: string) -> (to: [2]f32, ok: bool) {
	for i in e.doc.order {
		q := e.doc.cues[i].q
		if q.action == .Walk_To && q.who == name do return q.to, true
	}
	return
}

// Where somebody is at time `t`: their starting spot, then every walk_to up to
// now, with the last one eased over the time it would take to get there. Also
// which way they are going, if they are.
person_at :: proc(e: ^Editor, who: int, t: f32) -> [2]f32 {
	p, _ := person_walk(e, who, t)
	return p
}

person_walk :: proc(e: ^Editor, who: int, t: f32) -> (pos: [2]f32, heading: [2]f32) {
	if who < 0 || who >= len(e.doc.people) do return
	name := e.doc.people[who].m.name
	pos = cast_view(e, who).start
	for i in e.doc.order {
		q := e.doc.cues[i].q
		if q.at > t do break
		if q.action != .Walk_To || q.who != name do continue
		took := rl.Vector2Length(q.to - pos) / WALK_SPEED
		if took <= 0.001 {
			pos = q.to
			continue
		}
		// How far along this walk the playhead is. Walks that finished
		// before now are simply done.
		gone := clamp((t - q.at) / took, 0, 1)
		heading = q.to - pos if gone < 1 else {}
		pos = pos + (q.to - pos) * gone
	}
	return
}

// The pose somebody is drawn in at time `t`, and which frame of it: a part
// being played, a walk, or standing the way they last turned.
person_pose :: proc(e: ^Editor, who: int, t: f32) -> (part: string, frame: f32) {
	v := cast_view(e, who)
	name := e.doc.people[who].m.name
	facing := v.facing
	playing := ""
	since := f32(0)
	for i in e.doc.order {
		q := e.doc.cues[i].q
		if q.at > t do break
		if q.who != name do continue
		#partial switch q.action {
		case .Face:
			facing = q.facing
			playing = ""
		case .Play:
			if t < q.at + play_secs(e, v.char, q) {
				playing, since = q.text, q.at
			} else if playing == q.text {
				playing = ""
			}
		}
	}
	_, heading := person_walk(e, who, t)
	if playing != "" do return playing, (t - since)
	if heading != {} {
		dir := "front"
		if abs(heading.x) > abs(heading.y) do dir = "right" if heading.x > 0 else "left"
		else do dir = "front" if heading.y > 0 else "back"
		return fmt.tprintf("walk_%v", dir), t
	}
	return ne.facing_text(facing), t
}

// How long a `play` cue holds its part: its seconds, or its times through
// the part at the part's own speed.
play_secs :: proc(e: ^Editor, char: string, q: ne.Cue) -> f32 {
	if q.times <= 0 do return q.amount
	c := ac.art_char_data(&e.art, char)
	if c == nil do return f32(q.times)
	p := ne.character_part(c, q.text)
	if p == nil || p.fps <= 0 do return f32(q.times)
	return f32(q.times) * f32(max(p.data.frames, 1)) / p.fps
}

// --- Drawing ---

draw_stage :: proc(e: ^Editor, area: rl.Rectangle) {
	rl.BeginScissorMode(i32(area.x), i32(area.y), i32(area.width), i32(area.height))
	defer rl.EndScissorMode()
	rl.DrawRectangleRec(area, {16, 16, 21, 255})

	tl := ui.to_screen(e.view, {0, 0})
	br := ui.to_screen(e.view, e.size)
	room := rl.Rectangle{tl.x, tl.y, br.x - tl.x, br.y - tl.y}

	drawn := false
	if e.has_room && e.room.background_name != "" {
		bg, _ := ac.art_lit(&e.art, e.room.background_name, e.light, images = true)
		if bg.texture.id != 0 {
			ne.draw_sprite_pro(bg, 0, room)
			drawn = true
		}
	}
	if !drawn {
		rl.DrawRectangleRec(room, {24, 24, 31, 255})
		msg := ""
		switch {
		case e.doc.scene == "": msg = "no room set: Room... in the panel"
		case !e.has_room:       msg = fmt.tprintf("no %v.scene in %v", e.doc.scene, ui.file_of(e.asset_dir))
		case:                   msg = fmt.tprintf("no picture called %v", e.room.background_name)
		}
		ui.label(i32(room.x) + 12, i32(room.y) + 12, msg, {200, 140, 120, 255}, ui.SMALL)
	}
	rl.DrawRectangleLinesEx(room, 1, ui.EDGE)

	handle_stage_mouse(e, area)

	// Everything standing in the room, and the cast, back to front by their
	// feet, as the game draws them.
	Item :: struct {
		depth: ne.Depth,
		y:     f32,
		obj:   int, // a room object, or -1
		member: int, // a cast member, or -1
	}
	items := make([dynamic]Item, context.temp_allocator)
	claimed := make([]bool, len(e.room.objects) if e.has_room else 0, context.temp_allocator)
	for _, i in e.doc.people {
		v := cast_view(e, i)
		if v.person >= 0 do claimed[v.person] = true
		append(&items, Item{.Normal, person_at(e, i, e.t).y, -1, i})
	}
	if e.has_room do for o, i in e.room.objects {
		if claimed[i] || ac.showing(&e.flags, o.only) == .Hidden do continue
		if o.sprite_name == "" && o.char_name == "" do continue
		append(&items, Item{o.depth, o.pos.y + o.base, i, -1})
	}
	slice.sort_by(items[:], proc(a, b: Item) -> bool {
		if a.depth != b.depth do return a.depth < b.depth
		return a.y < b.y
	})
	for it in items {
		if it.obj >= 0 do draw_object(e, &e.room.objects[it.obj])
		else do draw_person(e, it.member)
	}

	// The floor, so nobody is sent to walk through a wall.
	if e.has_room do ac.draw_floor(e.room.walk_area[:], e.view, 1)
	for _, i in e.doc.people do draw_walk_markers(e, i)
	for _, i in e.doc.people {
		at := person_at(e, i, e.t)
		picked := (e.sel.kind == .Cast && e.sel.i == i) || i == e.who
		ring := ui.GOLD if picked else rl.Color{150, 150, 170, 200}
		name := e.doc.people[i].m.name
		if tag, off := edge_tag(e, i, at); off {
			// Off the side of the room: a tag on its edge says who is
			// waiting there, and is where to take hold of them.
			fill := rl.Color{60, 54, 34, 230} if picked else rl.Color{36, 36, 46, 220}
			rl.DrawRectangleRec(tag, fill)
			rl.DrawRectangleLinesEx(tag, 1, ring)
			left := at.x < 0
			text := fmt.tprintf("< %v", name) if left else fmt.tprintf("%v >", name)
			ui.label(i32(tag.x) + 5, i32(tag.y) + 3, text, ring, ui.SMALL)
			continue
		}
		p := ui.to_screen(e.view, at)
		rl.DrawCircleLinesV(p, 7, ring)
		ui.label(i32(p.x) + 10, i32(p.y) - 6, name, ring, ui.SMALL)
	}
}

// Where somebody standing off the side of the room is shown: a tag just
// inside the room's edge at their height, on the side they are off. False
// for somebody in the room.
edge_tag :: proc(e: ^Editor, i: int, at: [2]f32) -> (tag: rl.Rectangle, off: bool) {
	if at.x >= 0 && at.x <= e.size.x do return {}, false
	name := e.doc.people[i].m.name
	w := f32(ui.measure(fmt.tprintf("< %v", name), ui.SMALL) + 10)
	edge := ui.to_screen(e.view, {0 if at.x < 0 else e.size.x, clamp(at.y, 0, e.size.y)})
	x := edge.x + 2 if at.x < 0 else edge.x - w - 2
	// Two waiting on one side at one height: the later one's tag goes above.
	y := edge.y - 20
	for j in 0 ..< i {
		other := person_at(e, j, e.t)
		if (other.x < 0) != (at.x < 0) || (other.x >= 0 && other.x <= e.size.x) do continue
		if abs(other.y - at.y) * e.view.zoom < 22 do y -= 22
	}
	return {x, y, w, 20}, true
}

// Where to take hold of somebody on the stage: their feet, or their tag on
// the edge when they are off it.
grip :: proc(e: ^Editor, i: int) -> (p: [2]f32, r: f32) {
	at := person_at(e, i, e.t)
	if tag, off := edge_tag(e, i, at); off do return {tag.x + tag.width / 2, tag.y + tag.height / 2}, max(tag.width / 2, 12)
	return ui.to_screen(e.view, at), 14
}

@(private = "file")
draw_object :: proc(e: ^Editor, o: ^ne.Object) {
	tint := rl.Color{255, 255, 255, 64} if ac.showing(&e.flags, o.only) == .Dimmed else rl.WHITE
	s: ne.Sprite
	frame := o.frame
	if o.char_name != "" {
		part := o.rest_pose if o.rest_pose != "" else ne.facing_text(o.actor.facing)
		s = ac.art_char_part(&e.art, o.char_name, part)
		if s.texture.id == 0 do s = ac.art_char_part(&e.art, o.char_name, "front")
		frame = 0
	} else {
		s, _ = ac.art_lit(&e.art, o.sprite_name, e.light)
		if o.fps > 0 && s.frames > 1 do frame = i32(ui.now() * f64(o.fps)) % s.frames
	}
	if s.texture.id == 0 do return
	at := ui.to_screen(e.view, o.pos)
	w := f32(s.frame_w) * e.view.zoom
	h := f32(s.frame_h) * e.view.zoom
	ne.draw_sprite_pro(s, clamp(frame, 0, max(s.frames - 1, 0)), {at.x - w / 2, at.y - h, w, h}, tint = tint)
}

@(private = "file")
draw_person :: proc(e: ^Editor, i: int) {
	v := cast_view(e, i)
	p := ui.to_screen(e.view, person_at(e, i, e.t))
	drawn := false
	if v.char != "" {
		part, secs := person_pose(e, i, e.t)
		s := ac.art_char_part(&e.art, v.char, part)
		fps := f32(8)
		if c := ac.art_char_data(&e.art, v.char); c != nil {
			if cp := ne.character_part(c, part); cp != nil && cp.fps > 0 do fps = cp.fps
		}
		if s.texture.id == 0 && strings.has_prefix(part, "walk_") do s = ac.art_char_part(&e.art, v.char, part[5:])
		if s.texture.id == 0 do s = ac.art_char_part(&e.art, v.char, "front")
		if s.texture.id != 0 {
			w := f32(s.frame_w) * e.view.zoom
			h := f32(s.frame_h) * e.view.zoom
			frame := i32(secs * fps) % max(s.frames, 1)
			ne.draw_sprite_pro(s, frame, {p.x - w / 2, p.y - h, w, h})
			drawn = true
		}
	}
	if !drawn {
		// No art: a block of the right height, so the timing still works.
		h := 52 * ROOM_SCALE * e.view.zoom
		w := 26 * ROOM_SCALE * e.view.zoom
		rl.DrawRectangleRec({p.x - w / 2, p.y - h, w, h}, {90, 90, 110, 200})
	}
}

// Where each of the selected person's walk_to cues sends them, as a ring you
// can drag. Only the selected person's, or the room fills up with rings.
@(private = "file")
draw_walk_markers :: proc(e: ^Editor, who: int) {
	if who != e.who do return
	name := e.doc.people[who].m.name
	for c, i in e.doc.cues {
		q := c.q
		if q.action != .Walk_To || q.who != name do continue
		p := ui.to_screen(e.view, q.to)
		picked := e.sel.kind == .Cue && e.sel.i == i
		col := ui.GOLD if picked else rl.Color{130, 180, 230, 180}
		rl.DrawCircleLinesV(p, 9, col)
		rl.DrawLineEx({p.x - 4, p.y}, {p.x + 4, p.y}, 1, col)
		rl.DrawLineEx({p.x, p.y - 4}, {p.x, p.y + 4}, 1, col)
		ui.label(i32(p.x) + 11, i32(p.y) - 6, fmt.tprintf("%.1fs", q.at), col, ui.SMALL)
	}
}

// Dragging people and their destinations about the room.
@(private = "file")
handle_stage_mouse :: proc(e: ^Editor, area: rl.Rectangle) {
	mouse := ui.mouse()
	over := rl.CheckCollisionPointRec(mouse, area)
	at := snap(ui.to_content(e.view, mouse))

	if ui.mouse_released(.LEFT) && (e.drag == .Person || e.drag == .Walk_To) {
		if !e.drag_moved do ui.history_drop_last(&e.history)
		else do changed(e)
		e.drag = .None
	}

	if over && ui.mouse_pressed(.LEFT) && !ui.split_hot() {
		// A walk-to ring first: it sits on top of whoever is walking to it.
		name := e.doc.people[e.who].m.name if e.who >= 0 && e.who < len(e.doc.people) else ""
		for c, i in e.doc.cues {
			if c.q.action != .Walk_To || c.q.who != name do continue
			if rl.Vector2Distance(ui.to_screen(e.view, c.q.to), mouse) <= 11 {
				mark(e)
				e.sel, e.drag, e.drag_moved = {.Cue, i}, .Walk_To, false
				return
			}
		}
		#reverse for _, i in e.doc.people {
			p, r := grip(e, i)
			if rl.Vector2Distance(p, mouse) <= r {
				mark(e)
				e.sel, e.who, e.drag, e.drag_moved = {.Cast, i}, i, .Person, false
				return
			}
		}
	}

	if !ui.mouse_down(.LEFT) do return
	#partial switch e.drag {
	case .Person:
		if e.sel.kind == .Cast && e.sel.i < len(e.doc.people) {
			// Moved where they start, which is where they are before their
			// first walk: an at= of their own, from now on.
			m := e.doc.people[e.sel.i].m
			if m.keep_place || m.at != at {
				doc_set_cast_field(&e.doc, e.sel.i, "at", fmt.tprintf("%v,%v", int(at.x), int(at.y)))
				e.drag_moved = true
				e.dirty = true
			}
		}
	case .Walk_To:
		if e.sel.kind == .Cue && e.sel.i < len(e.doc.cues) {
			q := e.doc.cues[e.sel.i].q
			if q.to != at {
				q.to = at
				doc_set_cue(&e.doc, e.sel.i, q)
				e.drag_moved = true
				e.dirty = true
			}
		}
	}
}
