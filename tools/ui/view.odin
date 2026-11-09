package ui

import rl "vendor:raylib"

// Panning and zooming a document that is bigger than the window: the pixel
// grids in nart, the room in nscene.

View :: struct {
	origin: [2]f32, // top-left of the content, in screen pixels
	zoom:   f32,
}

to_screen :: proc(v: View, p: [2]f32) -> [2]f32 {
	return v.origin + p * v.zoom
}

to_content :: proc(v: View, p: [2]f32) -> [2]f32 {
	return (p - v.origin) / max(v.zoom, 0.0001)
}

// Middle-drag to pan, wheel to zoom about the pointer.
pan_and_zoom :: proc(v: ^View) {
	if mouse_down(.MIDDLE) do v.origin += mouse_delta()
	if wheel := wheel(); wheel != 0 {
		before := to_content(v^, mouse())
		v.zoom = clamp(v.zoom * (1.15 if wheel > 0 else 1 / 1.15), 0.2, 64)
		after := to_content(v^, mouse())
		v.origin += (after - before) * v.zoom
	}
}

// Fits `size` content pixels into `area`, centred.
fit_view :: proc(size: [2]f32, area: rl.Rectangle, pad: f32 = 20) -> View {
	if size.x <= 0 || size.y <= 0 do return {{area.x, area.y}, 1}
	zoom := min((area.width - pad * 2) / size.x, (area.height - pad * 2) / size.y)
	origin := [2]f32{
		area.x + (area.width - size.x * zoom) / 2,
		area.y + (area.height - size.y * zoom) / 2,
	}
	return {origin, zoom}
}

