package main

import ne "../../"
import ac "../assetcache"
import ui "../ui"
import "core:fmt"
import "core:slice"
import rl "vendor:raylib"

// The room: drawn as the game draws it, in the light chosen, with the floor,
// the ways out and the selected thing's shapes over it, and every drag that
// changes them.

Drag_What :: enum {
	None,
	Pan,
	Object,     // its feet
	Walk_To,    // where she stands to use it
	Reach,      // the reach shape, moved
	Reach_Size, // ...or grown
	Block,
	Block_Size,
	Area,       // an exit's or trigger's patch of floor, moved
	Area_Size,  // ...or its far corner
	At,         // where an exit sends her before it plays its part
	Corner,     // a corner of the floor
	New_Area,   // dragging out an exit, a trigger or a window being added
	Glass,      // a window's glass, moved (and its feet line with it)
	Glass_Size, // ...or its far corner
	Feet,       // the line somebody outside it stands on
	Span,       // a side's span, moved along it
	Span_Lo,    // ...or its near end
	Span_Hi,    // ...or its far end
}

Drag :: struct {
	what:     Drag_What,
	from:     [2]f32, // where the pointer went down, in the room
	screen:   [2]f32, // ...and on the screen, for panning
	base:     [2]f32, // what was dragged, as it was
	rect:     [4]f32,
	shape:    ne.Shape,
	moved:    bool,
	cycle:    int, // objects under the click, when one was already selected: click again for the next
}

HANDLE :: f32(7) // how near a handle the pointer must be, in screen pixels

// --- Drawing ---

@(private = "file")
Item :: struct {
	depth: ne.Depth,
	y:     f32,
	i:     int,
}

// The objects in the order the game draws them: depth, then feet, then the
// order of the file.
@(private = "file")
draw_order :: proc(d: ^Doc) -> []Item {
	items := make([]Item, len(d.objects), context.temp_allocator)
	for o, i in d.objects do items[i] = {o.depth, o.pos.y + o.base, i}
	slice.sort_by(items, proc(a, b: Item) -> bool {
		if a.depth != b.depth do return a.depth < b.depth
		if a.y != b.y do return a.y < b.y
		return a.i < b.i
	})
	return items
}

// The picture an object is drawn with in the light being shown, and its frame.
object_art :: proc(e: ^Scene_Editor, o: ^Doc_Object) -> (s: ne.Sprite, frame: i32) {
	if o.person {
		part := o.pose if o.pose != "" else ne.facing_text(o.facing)
		s = ac.art_char_part(&e.art, o.char, part)
		if s.texture.id == 0 && part != "front" do s = ac.art_char_part(&e.art, o.char, "front")
	} else if o.sprite != "" {
		s, _ = ac.art_lit(&e.art, o.sprite, e.light)
	}
	if s.texture.id == 0 do return
	frame = o.frame
	if o.fps > 0 && s.frames > 1 do frame = i32(ui.now() * f64(o.fps)) % s.frames
	frame = clamp(frame, 0, max(s.frames - 1, 0))
	return
}

// Where an object's picture is on the screen; a small box at its feet when it
// has none.
object_bounds :: proc(e: ^Scene_Editor, o: ^Doc_Object, s: ne.Sprite) -> rl.Rectangle {
	at := ui.to_screen(e.view, o.pos)
	if s.texture.id == 0 do return {at.x - HANDLE, at.y - HANDLE, HANDLE * 2, HANDLE * 2}
	w := f32(s.frame_w) * e.view.zoom
	h := f32(s.frame_h) * e.view.zoom
	return {at.x - w / 2, at.y - h, w, h}
}

draw_room :: proc(e: ^Scene_Editor, area: rl.Rectangle) {
	rl.BeginScissorMode(i32(area.x), i32(area.y), i32(area.width), i32(area.height))
	defer rl.EndScissorMode()
	d := &e.doc

	origin := ui.to_screen(e.view, {0, 0})
	frame := rl.Rectangle{origin.x, origin.y, e.size.x * e.view.zoom, e.size.y * e.view.zoom}
	rl.DrawRectangleRec(frame, {16, 16, 22, 255})
	if d.bg >= 0 {
		bg, _ := ac.art_lit(&e.art, doc_head(d, d.bg, 0), e.light, images = true)
		if bg.texture.id != 0 {
			ne.draw_sprite_pro(bg, 0, frame)
		} else {
			ui.label(i32(frame.x) + 10, i32(frame.y) + 10, "no picture called that for this light", ui.DIM, ui.SMALL)
		}
	} else {
		ui.label(i32(frame.x) + 10, i32(frame.y) + 10, "no backdrop yet: Backdrop... in the panel", ui.DIM, ui.SMALL)
	}
	rl.DrawRectangleLinesEx(frame, 1, ui.EDGE)

	// The objects, back to front, as the game has them.
	for it in draw_order(d) {
		o := &d.objects[it.i]
		show := ac.showing(&e.flags, o.only)
		if show == .Hidden do continue
		s, f := object_art(e, o)
		if s.texture.id == 0 do continue
		ne.draw_sprite_pro(s, f, object_bounds(e, o, s), tint = DIMMED if show == .Dimmed else rl.WHITE)
	}

	// The floor.
	ac.draw_floor(d.walk[:], e.view, 3 if e.tool == .Floor else 2)
	if e.tool == .Floor {
		for p, i in d.walk {
			picked := e.sel.kind == .Corner && e.sel.i == i
			rl.DrawCircleV(ui.to_screen(e.view, p), 6 if picked else 4, ui.GOLD if picked else ac.FLOOR_INK)
		}
	}

	for x, i in d.exits {
		if !x.has_area do continue
		picked := e.sel.kind == .Exit && e.sel.i == i
		show := ac.showing(&e.flags, x.only)
		if show == .Hidden && !picked do continue
		ac.draw_area(x.area, e.view, faint(ac.EXIT_INK) if show != .Shown else ac.EXIT_INK, x.name, picked)
		if picked {
			handle(e, {x.area[0] + x.area[2], x.area[1] + x.area[3]}, ui.GOLD)
			if x.at != {} {
				at := ui.to_screen(e.view, x.at)
				rl.DrawLineV(at - {6, 0}, at + {6, 0}, ui.GOLD)
				rl.DrawLineV(at - {0, 6}, at + {0, 6}, ui.GOLD)
				ui.label(i32(at.x) + 6, i32(at.y) + 4, "at", ui.GOLD, ui.SMALL)
			}
		}
	}
	// The sides: a band along the brink, where the walk band crosses, an
	// arrow out, and where it goes (nengine side.odin).
	for s, i in d.sides {
		picked := e.sel.kind == .Side && e.sel.i == i
		show := ac.showing(&e.flags, s.only)
		if show == .Hidden && !picked do continue
		ink := ui.GOLD if picked else (faint(SIDE_INK) if show != .Shown else SIDE_INK)
		pts := side_points(d, s)
		for k in 1 ..< len(pts) do rl.DrawLineEx(ui.to_screen(e.view, pts[k - 1]), ui.to_screen(e.view, pts[k]), 4 if picked else 3, ink)
		if len(pts) == 0 do continue
		mid := pts[len(pts) / 2]
		tip := mid + ne.outward(s.dir) * 28
		rl.DrawLineEx(ui.to_screen(e.view, mid), ui.to_screen(e.view, tip), 2, ink)
		label := fmt.tprintf("%v> %v%v", ne.COMPASS_WORDS[s.dir][:1], s.to if s.to != "" else "?", fmt.tprintf(" [%v]", s.gate) if s.gate != "" else "")
		at := ui.to_screen(e.view, tip)
		ui.label(i32(at.x) + 4, i32(at.y) - 6, label, ink, ui.SMALL)
		if picked {
			handle(e, pts[0], ui.GOLD)
			handle(e, pts[len(pts) - 1], ui.GOLD)
		}
	}
	for t, i in d.triggers {
		picked := e.sel.kind == .Trigger && e.sel.i == i
		show := ac.showing(&e.flags, t.only)
		if show == .Hidden && !picked do continue
		ac.draw_area(t.area, e.view, faint(ac.TRIGGER_INK) if show != .Shown else ac.TRIGGER_INK, t.name, picked)
		if picked do handle(e, {t.area[0] + t.area[2], t.area[1] + t.area[3]}, ui.GOLD)
	}

	// The windows: the glass, the feet line of somebody outside, and a ghost
	// of them, as much as the glass shows.
	for w, i in d.windows {
		if !w.has_glass do continue
		picked := e.sel.kind == .Window && e.sel.i == i
		show := ac.showing(&e.flags, w.only)
		if show == .Hidden && !picked do continue
		draw_window(e, w, faint(ac.WINDOW_INK) if show != .Shown else ac.WINDOW_INK, picked)
	}

	// Every object's feet, marked; the selected one with its shapes.
	for &o, i in d.objects {
		picked := e.sel.kind == .Object && e.sel.i == i
		if !picked && ac.showing(&e.flags, o.only) == .Hidden do continue
		at := ui.to_screen(e.view, o.pos)
		s, _ := object_art(e, &o)
		if s.texture.id == 0 {
			draw_mark(&o, at, picked, 1.6)
		} else {
			rl.DrawCircleV(at, 2.5, ui.GOLD if picked else rl.Color{230, 230, 240, 200})
		}
		hovered := e.drag.what == .None && rl.CheckCollisionPointRec(ui.mouse(), {at.x - HANDLE, at.y - HANDLE, HANDLE * 2, HANDLE * 2})
		if picked || hovered || e.names {
			ui.label(i32(at.x) + 7, i32(at.y) + 3, o.name, ui.GOLD if picked else rl.Color{220, 220, 230, 170}, ui.SMALL)
		}
	}
	if e.sel.kind == .Object && e.sel.i < len(d.objects) {
		o := &d.objects[e.sel.i]
		s, _ := object_art(e, o)
		if s.texture.id != 0 do rl.DrawRectangleLinesEx(object_bounds(e, o, s), 1, {200, 168, 90, 160})
		draw_shape(e, o.reach, o.pos, {110, 190, 255, 40}, {110, 190, 255, 200})
		draw_shape(e, o.block, o.pos, {240, 120, 90, 60}, {240, 120, 90, 220})
		if o.walk_to != {} {
			wt := ui.to_screen(e.view, o.walk_to)
			rl.DrawLineV(ui.to_screen(e.view, o.pos), wt, {230, 220, 120, 140})
			rl.DrawCircleLinesV(wt, HANDLE, {230, 220, 120, 255})
			ui.label(i32(wt.x) + 9, i32(wt.y) - 6, "walk to", {230, 220, 120, 255}, ui.SMALL)
		}
	}

	// The patch being dragged out right now.
	if e.drag.what == .New_Area {
		r := rect_between(e.drag.from, ui.to_content(e.view, ui.mouse()))
		ac.draw_area(r, e.view, ui.INK, "")
	}
}

// A window: its glass, the ghost of a person standing outside on its feet
// line (as much of them as the glass shows), and the line itself, dashed
// while it is the default.
@(private = "file")
draw_window :: proc(e: ^Scene_Editor, w: Doc_Window, ink: rl.Color, picked: bool) {
	g := w.glass
	feet := doc_window_feet(w)
	cx := g[0] + g[2] / 2
	// The ghost: a person's box at the middle of the glass, cut to the glass.
	half := PERSON_H / 4
	top := max(feet - PERSON_H, g[1])
	bottom := min(feet, g[1] + g[3])
	if bottom > top {
		a := ui.to_screen(e.view, {max(cx - half, g[0]), top})
		b := ui.to_screen(e.view, {min(cx + half, g[0] + g[2]), bottom})
		rl.DrawRectangleRec({a.x, a.y, b.x - a.x, b.y - a.y}, {ink.r, ink.g, ink.b, 70})
	}
	ac.draw_area(g, e.view, ink, w.name, picked)
	l := ui.to_screen(e.view, {g[0] - 12, feet})
	r := ui.to_screen(e.view, {g[0] + g[2] + 12, feet})
	if w.feet != 0 {
		rl.DrawLineEx(l, r, 2 if picked else 1, ui.GOLD if picked else ink)
	} else {
		for x := l.x; x < r.x; x += 10 do rl.DrawLineEx({x, l.y}, {min(x + 5, r.x), l.y}, 2 if picked else 1, ui.GOLD if picked else ink)
	}
	if picked || e.names {
		ui.label(i32(r.x) + 4, i32(r.y) - 7, "feet" if w.feet != 0 else "feet (default)", ui.GOLD if picked else ink, ui.SMALL)
	}
	if picked {
		handle(e, {g[0] + g[2], g[1] + g[3]}, ui.GOLD)
		handle(e, {cx, feet}, ui.GOLD)
	}
}

SIDE_INK :: rl.Color{80, 230, 230, 255}

// A side's brink, every 8 px along its span, ends included: where the floor
// ends coming in from that border (ne.side_brink), so the editor draws what
// the game will cross at.
side_points :: proc(d: ^Doc, s: Doc_Side) -> [][2]f32 {
	room := ne.Scene{walk_area = d.walk[:]}
	out := make([dynamic][2]f32, context.temp_allocator)
	for c := s.span[0]; ; c += 8 {
		v := min(c, s.span[1])
		if b, ok := ne.side_brink(&room, s.dir, v); ok do append(&out, b)
		if v >= s.span[1] do break
	}
	return out[:]
}

// What a thing whose when= does not hold under the flags shown is drawn as.
DIMMED :: rl.Color{255, 255, 255, 64}

@(private = "file")
faint :: proc(c: rl.Color) -> rl.Color {
	return {c.r, c.g, c.b, 90}
}

@(private = "file")
handle :: proc(e: ^Scene_Editor, p: [2]f32, ink: rl.Color) {
	at := ui.to_screen(e.view, p)
	rl.DrawRectangleRec({at.x - 4, at.y - 4, 8, 8}, ink)
	rl.DrawRectangleLinesEx({at.x - 4, at.y - 4, 8, 8}, 1, {0, 0, 0, 200})
}

// A shape on the floor, with a handle at its middle to move it and one on its
// right-hand edge to size it.
@(private = "file")
draw_shape :: proc(e: ^Scene_Editor, s: ne.Shape, origin: [2]f32, fill, edge: rl.Color) {
	if s.kind == .None do return
	c := ui.to_screen(e.view, origin + s.offset)
	size := s.size * e.view.zoom
	#partial switch s.kind {
	case .Box:
		r := rl.Rectangle{c.x - size.x / 2, c.y - size.y / 2, size.x, size.y}
		rl.DrawRectangleRec(r, fill)
		rl.DrawRectangleLinesEx(r, 1, edge)
	case .Oval:
		rl.DrawEllipse(i32(c.x), i32(c.y), size.x / 2, size.y / 2, fill)
		rl.DrawEllipseLines(i32(c.x), i32(c.y), size.x / 2, size.y / 2, edge)
	}
	handle(e, origin + s.offset, edge)
	handle(e, origin + s.offset + {s.size.x / 2, s.size.y / 2 if s.kind == .Box else 0}, edge)
}

rect_between :: proc(a, b: [2]f32) -> [4]f32 {
	return {f32(i32(min(a.x, b.x))), f32(i32(min(a.y, b.y))), f32(i32(abs(b.x - a.x))), f32(i32(abs(b.y - a.y)))}
}

// --- The mouse ---

canvas_input :: proc(e: ^Scene_Editor, area: rl.Rectangle, status: ^ui.Status) {
	over := rl.CheckCollisionPointRec(ui.mouse(), area) && !ui.split_hot()
	if over && e.drag.what == .None do ui.pan_and_zoom(&e.view)
	at := ui.to_content(e.view, ui.mouse())

	if over && ui.mouse_pressed(.LEFT) && !ui.typing(&e.text) {
		press(e, at, status)
	}
	if e.drag.what != .None {
		if ui.mouse_down(.LEFT) {
			drag_to(e, at)
		} else {
			release(e, at, status)
		}
	}
}

@(private = "file")
near :: proc(e: ^Scene_Editor, a, b: [2]f32) -> bool {
	d := (a - b) * e.view.zoom
	return d.x * d.x + d.y * d.y <= HANDLE * HANDLE * 1.6
}

@(private = "file")
in_area :: proc(p: [2]f32, r: [4]f32) -> bool {
	return p.x >= r[0] && p.y >= r[1] && p.x <= r[0] + r[2] && p.y <= r[1] + r[3]
}

@(private = "file")
press :: proc(e: ^Scene_Editor, at: [2]f32, status: ^ui.Status) {
	d := &e.doc
	e.drag = {from = at, screen = ui.mouse()}

	// Putting something new in.
	if e.adding != .None {
		if !e.placing {
			ui.say(status, "name it first, then Enter")
			return
		}
		switch e.adding {
		case .Exit, .Trigger, .Window, .Side:
			e.drag.what = .New_Area
		case .None, .Scenery:
		case .Object, .Person, .Peep:
			place(e, at, {}, status)
		}
		return
	}

	if e.tool == .Floor {
		for p, i in d.walk do if near(e, p, at) {
			mark(e)
			e.sel = {.Corner, i}
			e.drag.what, e.drag.base = .Corner, p
			return
		}
		// Nothing there: a new corner on the nearest edge.
		mark(e)
		pts := make([dynamic][2]f32, context.temp_allocator)
		append(&pts, ..d.walk[:])
		where_ := len(pts)
		if len(pts) >= 2 {
			best_d := max(f32)
			for p, i in pts {
				q := pts[(i + 1) % len(pts)]
				dist := distance_to_segment(at, p, q)
				if dist < best_d {
					best_d = dist
					where_ = i + 1
				}
			}
		}
		snapped := [2]f32{f32(i32(at.x)), f32(i32(at.y))}
		inject_at(&pts, where_, snapped)
		doc_set_walk(d, pts[:])
		changed(e)
		e.sel = {.Corner, where_}
		e.drag.what, e.drag.base, e.drag.moved = .Corner, snapped, true
		return
	}

	// The selected thing's handles come first: they sit on top.
	#partial switch e.sel.kind {
	case .Object:
		o := d.objects[e.sel.i]
		if o.walk_to != {} && near(e, o.walk_to, at) {
			mark(e)
			e.drag.what, e.drag.base = .Walk_To, o.walk_to
			return
		}
		for which in ([2]Drag_What{.Reach, .Block}) {
			s := o.reach if which == .Reach else o.block
			if s.kind == .None do continue
			edge := o.pos + s.offset + {s.size.x / 2, s.size.y / 2 if s.kind == .Box else 0}
			if near(e, edge, at) {
				mark(e)
				e.drag.what = .Reach_Size if which == .Reach else .Block_Size
				e.drag.shape = s
				return
			}
			if near(e, o.pos + s.offset, at) && !near(e, o.pos, at) {
				mark(e)
				e.drag.what, e.drag.shape = which, s
				return
			}
		}
	case .Exit:
		x := d.exits[e.sel.i]
		if near(e, {x.area[0] + x.area[2], x.area[1] + x.area[3]}, at) {
			mark(e)
			e.drag.what, e.drag.rect = .Area_Size, x.area
			return
		}
		if x.at != {} && near(e, x.at, at) {
			mark(e)
			e.drag.what, e.drag.base = .At, x.at
			return
		}
	case .Side:
		s := d.sides[e.sel.i]
		pts := side_points(d, s)
		if len(pts) > 0 {
			if near(e, pts[0], at) {
				mark(e)
				e.drag.what, e.drag.base = .Span_Lo, s.span
				return
			}
			if near(e, pts[len(pts) - 1], at) {
				mark(e)
				e.drag.what, e.drag.base = .Span_Hi, s.span
				return
			}
		}
	case .Trigger:
		t := d.triggers[e.sel.i]
		if near(e, {t.area[0] + t.area[2], t.area[1] + t.area[3]}, at) {
			mark(e)
			e.drag.what, e.drag.rect = .Area_Size, t.area
			return
		}
	case .Window:
		w := d.windows[e.sel.i]
		if near(e, {w.glass[0] + w.glass[2], w.glass[1] + w.glass[3]}, at) {
			mark(e)
			e.drag.what, e.drag.rect = .Glass_Size, w.glass
			return
		}
		if near(e, {w.glass[0] + w.glass[2] / 2, doc_window_feet(w)}, at) {
			mark(e)
			e.drag.what, e.drag.base = .Feet, {0, doc_window_feet(w)}
			return
		}
	}

	// Then a side, by its brink, before the pictures: a side is a thin line
	// at the floor's edge, and a bush's picture is usually over it. A drag
	// moves its span along it.
	for s, i in d.sides {
		if ac.showing(&e.flags, s.only) == .Hidden do continue
		for p in side_points(d, s) do if near(e, p, at) {
			e.sel = {.Side, i}
			mark(e)
			e.drag.what, e.drag.base = .Span, s.span
			return
		}
	}

	// Then objects, front to back: a click on their feet first, then on
	// their picture — except a light, or anything nearly the size of the
	// room, which would otherwise be under every click there is.
	hits := make([dynamic]int, context.temp_allocator)
	order := draw_order(d)
	gone :: proc(e: ^Scene_Editor, o: ^Doc_Object) -> bool {
		return ac.showing(&e.flags, o.only) == .Hidden
	}
	#reverse for it in order do if near(e, d.objects[it.i].pos, at) && !gone(e, &d.objects[it.i]) do append(&hits, it.i)
	// A window's glass, before the pictures: its frame is over it, and the
	// frame is a thing to reach by its feet or the room's list.
	if len(hits) == 0 {
		best, best_size := -1, max(f32)
		for w, i in d.windows {
			if !w.has_glass || !in_area(at, w.glass) || ac.showing(&e.flags, w.only) == .Hidden do continue
			if w.glass[2] * w.glass[3] < best_size do best, best_size = i, w.glass[2] * w.glass[3]
		}
		if best >= 0 {
			w := d.windows[best]
			e.sel = {.Window, best}
			mark(e)
			e.drag.what, e.drag.rect, e.drag.base = .Glass, w.glass, {0, w.feet}
			return
		}
	}
	#reverse for it in order {
		o := &d.objects[it.i]
		if o.glow || near(e, o.pos, at) || gone(e, o) do continue
		s, _ := object_art(e, o)
		if s.texture.id == 0 || f32(s.frame_w) * f32(s.frame_h) > e.size.x * e.size.y / 4 do continue
		if rl.CheckCollisionPointRec(ui.mouse(), object_bounds(e, o, s)) do append(&hits, it.i)
	}
	if len(hits) > 0 {
		pick := hits[0]
		for h, n in hits do if e.sel.kind == .Object && e.sel.i == h {
			pick = h
			// Click again, without moving, for whatever is under it.
			e.drag.cycle = hits[(n + 1) % len(hits)] + 1 if len(hits) > 1 else 0
		}
		e.sel = {.Object, pick}
		mark(e)
		e.drag.what, e.drag.base = .Object, d.objects[pick].pos
		return
	}

	// Then the patches of floor, the smallest first.
	best, best_kind, best_size := -1, Sel_Kind.Room, max(f32)
	for x, i in d.exits do if x.has_area && in_area(at, x.area) && x.area[2] * x.area[3] < best_size && ac.showing(&e.flags, x.only) != .Hidden {
		best, best_kind, best_size = i, .Exit, x.area[2] * x.area[3]
	}
	for t, i in d.triggers do if in_area(at, t.area) && t.area[2] * t.area[3] < best_size && ac.showing(&e.flags, t.only) != .Hidden {
		best, best_kind, best_size = i, .Trigger, t.area[2] * t.area[3]
	}
	if best >= 0 {
		e.sel = {best_kind, best}
		mark(e)
		e.drag.what = .Area
		e.drag.rect = d.exits[best].area if best_kind == .Exit else d.triggers[best].area
		return
	}

	// Nothing: the room itself, and a drag pans it.
	e.sel = {}
	e.drag.what = .Pan
	e.drag.base = e.view.origin
}

@(private = "file")
distance_to_segment :: proc(p, a, b: [2]f32) -> f32 {
	ab := b - a
	l := ab.x * ab.x + ab.y * ab.y
	t := clamp(((p - a).x * ab.x + (p - a).y * ab.y) / l, 0, 1) if l > 0 else 0
	q := a + ab * t
	return (p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y)
}

@(private = "file")
drag_to :: proc(e: ^Scene_Editor, at: [2]f32) {
	dg := &e.drag
	if dg.what == .Pan {
		e.view.origin = dg.base + (ui.mouse() - dg.screen)
		return
	}
	if dg.what == .New_Area do return
	delta := at - dg.from
	if !dg.moved {
		// A few pixels of wobble on a click is not a drag.
		if abs(delta.x) * e.view.zoom < 3 && abs(delta.y) * e.view.zoom < 3 do return
		dg.moved = true
	}
	whole :: proc(v: [2]f32) -> [2]f32 {
		return {f32(i32(v.x + (0.5 if v.x >= 0 else -0.5))), f32(i32(v.y + (0.5 if v.y >= 0 else -0.5)))}
	}
	d := &e.doc
	switch dg.what {
	case .None, .Pan, .New_Area:
	case .Object:
		doc_set_field(d, d.objects[e.sel.i].line, "pos", vec(whole(dg.base + delta)))
	case .Walk_To:
		doc_set_field(d, d.objects[e.sel.i].line, "walk_to", vec(whole(dg.base + delta)))
	case .Reach, .Block:
		s := dg.shape
		s.offset = whole(s.offset + delta)
		doc_set_field(d, d.objects[e.sel.i].line, "reach" if dg.what == .Reach else "block", ne.shape_text(s))
	case .Reach_Size, .Block_Size:
		s := dg.shape
		if s.kind == .Box {
			s.size = {max(abs(s.size.x / 2 + delta.x) * 2, 2), max(abs(s.size.y / 2 + delta.y) * 2, 2)}
			s.size = whole(s.size)
		} else {
			w := f32(i32(max(abs(s.size.x / 2 + delta.x) * 2, 2)))
			s = ne.circle(w, s.offset)
		}
		doc_set_field(d, d.objects[e.sel.i].line, "reach" if dg.what == .Reach_Size else "block", ne.shape_text(s))
	case .Area:
		r := dg.rect
		p := whole({r[0], r[1]} + delta)
		r[0], r[1] = p.x, p.y
		set_area(e, r)
	case .Area_Size:
		r := dg.rect
		sz := whole({r[2], r[3]} + delta)
		r[2], r[3] = max(sz.x, 2), max(sz.y, 2)
		set_area(e, r)
	case .At:
		doc_set_field(d, d.exits[e.sel.i].line, "at", vec(whole(dg.base + delta)))
	case .Glass:
		r := dg.rect
		p := whole({r[0], r[1]} + delta)
		r[0], r[1] = p.x, p.y
		line := d.windows[e.sel.i].line
		doc_set_field(d, line, "glass", rect_text(r))
		// A feet line that was set goes with its glass; the default follows anyway.
		if dg.base.y != 0 do doc_set_field(d, line, "feet", num(whole({0, dg.base.y + p.y - dg.rect[1]}).y))
	case .Glass_Size:
		r := dg.rect
		sz := whole({r[2], r[3]} + delta)
		r[2], r[3] = max(sz.x, 2), max(sz.y, 2)
		doc_set_field(d, d.windows[e.sel.i].line, "glass", rect_text(r))
	case .Feet:
		doc_set_field(d, d.windows[e.sel.i].line, "feet", num(whole(dg.base + delta).y))
	case .Span, .Span_Lo, .Span_Hi:
		if e.sel.kind != .Side || e.sel.i >= len(d.sides) do break
		dv := ne.along(d.sides[e.sel.i].dir, delta)
		span := dg.base
		#partial switch dg.what {
		case .Span_Lo: span[0] = snap_span(span[0] + dv)
		case .Span_Hi: span[1] = snap_span(span[1] + dv)
		case:          span = {snap_span(span[0] + dv), snap_span(span[1] + dv)}
		}
		if span[1] - span[0] < 16 do break
		doc_set_side_span(d, e.sel.i, span)
	case .Corner:
		if e.sel.i < len(d.walk) {
			pts := make([dynamic][2]f32, context.temp_allocator)
			append(&pts, ..d.walk[:])
			pts[e.sel.i] = whole(dg.base + delta)
			doc_set_walk(d, pts[:])
		}
	}
	changed(e)
}

@(private = "file")
set_area :: proc(e: ^Scene_Editor, r: [4]f32) {
	#partial switch e.sel.kind {
	case .Exit:    doc_set_field(&e.doc, e.doc.exits[e.sel.i].line, "area", rect_text(r))
	case .Trigger: doc_set_field(&e.doc, e.doc.triggers[e.sel.i].line, "area", rect_text(r))
	}
}

@(private = "file")
release :: proc(e: ^Scene_Editor, at: [2]f32, status: ^ui.Status) {
	dg := e.drag
	e.drag = {}
	switch dg.what {
	case .None, .Pan:
	case .New_Area:
		r := rect_between(dg.from, at)
		if r[2] * e.view.zoom < 4 || r[3] * e.view.zoom < 4 {
			ui.say(status, "drag out an area for it")
			return
		}
		place(e, at, r, status)
	case .Object, .Walk_To, .Reach, .Reach_Size, .Block, .Block_Size, .Area, .Area_Size, .At, .Corner, .Glass, .Glass_Size, .Feet, .Span, .Span_Lo, .Span_Hi:
		// A click that moved nothing leaves nothing to undo.
		if !dg.moved {
			ui.history_drop_last(&e.history)
			if dg.what == .Object && dg.cycle > 0 do e.sel = {.Object, dg.cycle - 1}
		}
	}
}
