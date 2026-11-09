package nengine

import rl "vendor:raylib"

// A patch of floor around an object, measured from its feet. Objects use two:
//   block  where the player's feet can't go: they walk around the cat, not through it.
//   reach  where the player can stand to be near() it: anywhere round the crate, not one spot.
//          It is also the ring for walking over to do things: see approach.odin.
//
// Floors are seen at an angle, so a circle on the floor looks like an oval
// twice as wide as it is deep. circle() makes that shape for you.

Shape_Kind :: enum {
	None,
	Box,
	Oval,
}

Shape :: struct {
	kind:   Shape_Kind,
	size:   [2]f32, // width and height
	offset: [2]f32, // centre, relative to the object's feet
}

// A rectangle of floor, centred on the feet (plus offset).
box :: proc(width, height: f32, offset := [2]f32{}) -> Shape {
	return {.Box, {width, height}, offset}
}

// A circle on the floor, `width` across. Drawn as an oval half as deep,
// because that's what a circle looks like on a floor seen at an angle.
circle :: proc(width: f32, offset := [2]f32{}) -> Shape {
	return {.Oval, {width, width / 2}, offset}
}

// Is p inside shape s, for an object whose feet are at origin?
in_shape :: proc(s: Shape, origin, p: [2]f32) -> bool {
	d := p - (origin + s.offset)
	half := s.size / 2
	switch s.kind {
	case .None:
		return false
	case .Box:
		return abs(d.x) <= half.x && abs(d.y) <= half.y
	case .Oval:
		if half.x <= 0 || half.y <= 0 do return false
		n := d / half
		return n.x * n.x + n.y * n.y <= 1
	}
	return false
}

@(private)
draw_shape :: proc(s: Shape, origin: [2]f32, fill, edge: rl.Color) {
	c := origin + s.offset
	switch s.kind {
	case .None:
	case .Box:
		r := rl.Rectangle{c.x - s.size.x / 2, c.y - s.size.y / 2, s.size.x, s.size.y}
		rl.DrawRectangleRec(r, fill)
		rl.DrawRectangleLinesEx(r, 1, edge)
	case .Oval:
		rl.DrawEllipse(i32(c.x), i32(c.y), s.size.x / 2, s.size.y / 2, fill)
		rl.DrawEllipseLines(i32(c.x), i32(c.y), s.size.x / 2, s.size.y / 2, edge)
	}
}
