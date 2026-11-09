package nengine

import "core:fmt"
import rl "vendor:raylib"

// The debug view (F1). What the colours mean:
//   green tint    floor the player can walk on
//   red tint      blocked
//   yellow box    an object, labelled with the noun the parser knows it by.
//                 Yellow oval/box on the floor: its reach — the ring. From
//                 inside it, doing something to the object walks you to the
//                 red dot first; from outside, it is too far. Red: its block
//                 (solid, can't walk through). Red dot: the interaction point.
//   blue box      exit: step into it to leave. Labelled with its noun and
//                 where it goes. Grey when closed.
//   orange box    trigger: something happens when you step into it.
//   pink outline  edge: off the floor, beside it; stepping over is an event
//                 (water off a jetty). Grey when its `when=` is false.
//   white cross   the player's feet. Blue dot: where they're walking to.
// The bar above the prompt shows the scene name and the feet position, handy
// when placing things. Everything here is laid out for a 320-wide canvas and
// scaled by ui()/uf()/ufont() for whatever size the game actually uses.

// The green/red shading. Drawn straight after the background.
@(private)
draw_debug_floor :: proc(scene: ^Scene) {
	if scene.debug_mask.id == 0 do scene.debug_mask = build_walk_mask(scene.walk_area, scene)
	rl.DrawTexture(scene.debug_mask, 0, 0, rl.WHITE)
}

// Everything else. Drawn on top of the sprites.
@(private)
draw_debug :: proc(w: ^World) {
	scene := current_scene(w)
	p := w.player
	fs := ufont(10)
	dot := uf(1.5)

	area := scene.walk_area
	for i in 0 ..< len(area) {
		rl.DrawLineV(area[i], area[(i + 1) % len(area)], rl.GREEN)
	}

	for o in scene.objects {
		draw_shape(o.reach, o.pos, {255, 255, 0, 30}, {255, 255, 0, 150})
		draw_shape(o.block, o.pos, {255, 0, 0, 90}, rl.RED)
	}
	for o in scene.objects {
		b := sprite_bounds(o.sprite, o.pos)
		rl.DrawRectangleLinesEx(b, uf(1), rl.YELLOW)
		if o.walk_to != {} do rl.DrawCircleV(o.walk_to, dot, rl.RED)
		rl.DrawText(fmt.ctprintf("%v", o.name), i32(b.x) + ui(2), i32(b.y) + ui(2), fs, rl.YELLOW)
	}

	exit_blue := rl.Color{90, 160, 255, 255}
	for e in scene.exits {
		color := rl.GRAY if e.closed else exit_blue
		rl.DrawRectangleRec(e.area, {color.r, color.g, color.b, 110})
		rl.DrawRectangleLinesEx(e.area, uf(1), color)

		label := fmt.ctprintf("%v> %v%v", e.name, w.scenes[e.to].name, " (shut)" if e.closed else "")
		lx := clamp(i32(e.area.x), ui(2), WIDTH - rl.MeasureText(label, fs) - ui(4))
		ly := clamp(i32(e.area.y + e.area.height) + ui(1), 0, HEIGHT - ui(34))
		rl.DrawText(label, lx, ly, fs, color)
	}

	for t in scene.triggers {
		rl.DrawRectangleRec(t.area, {255, 140, 0, 60})
		rl.DrawRectangleLinesEx(t.area, uf(1), rl.ORANGE)
		rl.DrawText("trigger", i32(t.area.x) + ui(2), i32(t.area.y) + ui(2), fs, rl.ORANGE)
	}
	draw_debug_edges(scene, fs) // pink outline: an edge, off the floor (edge.odin)
	draw_debug_sides(w, scene, fs) // cyan along the brink: a side, walked across (side.odin)

	cross := uf(3)
	rl.DrawLineV(p.pos - {cross, 0}, p.pos + {cross, 0}, rl.WHITE)
	rl.DrawLineV(p.pos - {0, cross}, p.pos + {0, cross}, rl.WHITE)
	if p.moving do rl.DrawCircleV(p.target, dot, rl.SKYBLUE)

	// Info bar, just above the prompt: where we are, then a colour key.
	y := HEIGHT - ui(23)
	rl.DrawRectangle(0, y - ui(1), WIDTH, ui(11), {0, 0, 0, 200})
	at := fmt.ctprintf("%v %.0f,%.0f", scene.name, p.pos.x, p.pos.y)
	rl.DrawText(at, ui(2), y, fs, rl.RAYWHITE)

	// Whatever the game wants on the bar: the hour, which act it thinks it is,
	// how drunk somebody is. It goes here rather than the game drawing its own
	// because this is the overlay that already never ships, and a second
	// debug layer is a second thing to remember to turn off.
	// The story clock, if the game keeps one, and then whatever else the game
	// wants on the bar. The player is never told the hour; whoever is building
	// the thing has to be.
	extra := ""
	if w.clock_step > 0 do extra = fmt.tprintf("%v  %v ticks", clock_face(clock_minute(w)), w.clock_ticks)
	if w.on_debug_text != nil {
		if mine := w.on_debug_text(w); mine != "" do extra = fmt.tprintf("%v  %v", extra, mine) if extra != "" else mine
	}
	if extra != "" {
		rl.DrawText(fmt.ctprintf("%v", extra), ui(2) + rl.MeasureText(at, fs) + ui(10), y, fs, rl.SKYBLUE)
	}

	key := [5]struct {
		text:  cstring,
		color: rl.Color,
	}{{"walk", rl.GREEN}, {"blocked", rl.RED}, {"thing", rl.YELLOW}, {"exit", exit_blue}, {"trigger", rl.ORANGE}}
	x := WIDTH - ui(2)
	#reverse for k in key {
		x -= rl.MeasureText(k.text, fs) + ui(6)
		rl.DrawText(k.text, x, y, fs, k.color)
	}
}

// Shades every pixel green if the player may stand there, red if not.
// Worked out once per scene and kept, since the walk area doesn't change.
@(private)
build_walk_mask :: proc(area: [][2]f32, sc: ^Scene = nil) -> rl.Texture2D {
	img := rl.GenImageColor(WIDTH, HEIGHT, rl.BLANK)
	defer rl.UnloadImage(img)
	for y in 0 ..< i32(HEIGHT) {
		for x in 0 ..< i32(WIDTH) {
			p := [2]f32{f32(x) + 0.5, f32(y) + 0.5}
			inside := point_in_polygon(p, area)
			c := rl.Color{0, 255, 0, 40} if inside else rl.Color{255, 0, 0, 40}
			if inside && sc != nil && solid_at(sc, p) do c = {255, 0, 255, 90} // the solid map's taken floor
			rl.ImageDrawPixel(&img, x, y, c)
		}
	}
	return rl.LoadTextureFromImage(img)
}
