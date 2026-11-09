package nengine

import rl "vendor:raylib"

// A title card: one picture, alone on a coloured ground, fading in, holding,
// and fading out. The studio logo before the menu, a chapter heading, "three
// weeks earlier".
//
// This is deliberately not a cutscene. A cutscene is people moving about a
// room on a clock and needs a World, a scene and a cast; a card needs a
// picture and a stopwatch. Putting the logo through the cutscene machinery
// would mean inventing a room for it to happen in.
//
// The picture is drawn at a whole-number scale, as large as will fit with a
// margin, because a logo drawn at 3.7x has soft edges and the whole point of
// pixel art is that it doesn't.

Splash :: struct {
	picture:  Sprite,
	ground:   rl.Color,
	fade_in:  f32, // seconds
	hold:     f32,
	fade_out: f32,
	margin:   f32, // fraction of the screen to leave around the picture

	t:        f32,
	skipped:  bool,
}

// Sensible timings for a logo, so a game only has to name the picture.
splash_new :: proc(picture: Sprite, ground := rl.Color{10, 9, 12, 255}) -> Splash {
	return Splash{
		picture  = picture,
		ground   = ground,
		fade_in  = 0.9,
		hold     = 1.4,
		fade_out = 0.9,
		margin   = 0.22,
	}
}

splash_length :: proc(s: ^Splash) -> f32 {
	return s.fade_in + s.hold + s.fade_out
}

// How visible the picture is now, 0 to 1.
splash_alpha :: proc(s: ^Splash) -> f32 {
	switch {
	case s.t < s.fade_in:
		return s.fade_in <= 0 ? 1 : s.t / s.fade_in
	case s.t < s.fade_in + s.hold:
		return 1
	case:
		left := splash_length(s) - s.t
		return clamp(s.fade_out <= 0 ? 0 : left / s.fade_out, 0, 1)
	}
}

// Runs the clock. False when the card is finished and the game should move on.
//
// Any key or click skips it — not straight to the end, but into the fade-out,
// so a skipped logo still leaves the way it would have. Skipping twice cuts it
// short, because the second press means it.
splash_update :: proc(s: ^Splash, dt: f32) -> bool {
	s.t += dt
	if pressed_anything() {
		if s.skipped do return false
		s.skipped = true
		s.t = max(s.t, s.fade_in + s.hold)
	}
	return s.t < splash_length(s)
}

@(private = "file")
pressed_anything :: proc() -> bool {
	return rl.GetKeyPressed() != .KEY_NULL || rl.IsMouseButtonPressed(.LEFT)
}

splash_draw :: proc(s: ^Splash) {
	begin_canvas()
	rl.ClearBackground(s.ground)
	defer end_canvas()

	if s.picture.texture.id == 0 do return
	w := f32(s.picture.frame_w)
	h := f32(s.picture.frame_h)
	if w <= 0 || h <= 0 do return

	// The largest whole-number scale that still leaves the margin.
	room := [2]f32{f32(WIDTH) * (1 - s.margin), f32(HEIGHT) * (1 - s.margin)}
	scale := max(f32(int(min(room.x / w, room.y / h))), 1)
	dst := rl.Rectangle{
		(f32(WIDTH) - w * scale) / 2,
		(f32(HEIGHT) - h * scale) / 2,
		w * scale,
		h * scale,
	}

	a := u8(clamp(splash_alpha(s), 0, 1) * 255)
	draw_sprite_pro(s.picture, 0, dst, tint = {255, 255, 255, a})
}
