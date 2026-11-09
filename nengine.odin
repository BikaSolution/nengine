// nengine: a small engine for Sierra-style adventure games.
//
// Everything is drawn into a canvas texture of whatever size the game asks
// for, which is then scaled up to fill the window with hard pixel edges.
// Game code works in canvas pixels (WIDTH x HEIGHT) and never has to think
// about the real window size — any canvas size works, the engine just
// upscales it. 1024x640 is the default. A game aimed at the
// original 320x200 still works, it's just a smaller canvas to upscale.
//
// **The window is resizable and the canvas is not.** Dragging the window
// bigger shows the same picture, larger — never more of the room. Scenes
// are laid out in canvas pixels, so a canvas that changed size would change
// where the furniture is. The picture keeps its shape and the leftover space
// becomes black bars. See viewport().
package nengine

import "core:fmt"
import "core:strings"
import "core:math"
import rl "vendor:raylib"

// Set once by init(), then read-only. Game code and the engine's own UI
// (message box, debug view, death box, menu) both size themselves off these.
WIDTH, HEIGHT: i32

@(private) target: rl.RenderTexture2D

// Where the canvas lands inside the window, worked out fresh every frame
// because the window can change size at any moment.
@(private)
Viewport :: struct {
	at:    [2]f32, // top-left of the picture, in window pixels
	size:  [2]f32,
	scale: f32,    // window pixels per canvas pixel
}

// NENGINE_HIDDEN=1 in the environment opens every window hidden: it renders,
// screenshots and runs scripts as usual, and never shows up or takes focus.
// For `just smoke`, while the person running it is doing something else.
window_flags :: proc(flags: rl.ConfigFlags) -> rl.ConfigFlags {
	out := flags
	if hidden() do out += {.WINDOW_HIDDEN}
	return out
}

// Nothing is heard from a hidden window (NENGINE_HIDDEN): 0, otherwise 1.
master_volume :: proc() -> f32 {
	return 0 if hidden() else 1
}

// canvas_width/canvas_height: the size of the texture game code draws into
// and addresses positions in. window_scale: how many window pixels each
// canvas pixel becomes (the window is canvas size * window_scale).
init :: proc(title: cstring, canvas_width: i32 = 1024, canvas_height: i32 = 640, window_scale: i32 = 1) {
	WIDTH, HEIGHT = canvas_width, canvas_height
	rl.SetTraceLogLevel(.WARNING)
	rl.SetConfigFlags(window_flags({.WINDOW_RESIZABLE}))
	hidden_guard() // hidden.odin: a hidden run dies with its parent
	rl.InitWindow(WIDTH * window_scale, HEIGHT * window_scale, title)
	rl.SetWindowMinSize(WIDTH / 4, HEIGHT / 4)
	rl.SetTargetFPS(60)
	rl.SetExitKey(.KEY_NULL) // Esc clears the prompt instead of quitting

	target = rl.LoadRenderTexture(WIDTH, HEIGHT)
	rl.SetTextureFilter(target.texture, .POINT) // no blur when scaling up

	rl.InitAudioDevice()
	if !rl.IsAudioDeviceReady() do fmt.eprintln("nengine: no audio device, carrying on without sound")
	// Hidden is silent too: everything loads and plays as usual (a smoke row
	// still proves every sound opens), at no volume, so a hidden run never
	// makes a noise at the person working beside it.
	rl.SetMasterVolume(master_volume())
}

shutdown :: proc() {
	ride_draw_shutdown()
	sprite_draw_shutdown()
	depth_draw_shutdown()
	look_shutdown()
	rl.UnloadRenderTexture(target)
	rl.CloseAudioDevice()
	rl.CloseWindow()
}

// How the canvas is placed in the window: as large as it will go with its
// shape kept, centred, and black either side of it or above and below.
//
// Whole numbers only, once the window is at least as big as the canvas: a
// canvas pixel becomes exactly 2, or 3, or 4 window pixels and never 3.5.
// A fractional scale makes some pixels bigger than their neighbours, which
// on a 320x200 canvas — where one pixel is a whole eyelash — shimmers as the
// character walks. Rounding down costs some screen area and buys pixels that
// are all the same size, which is the entire point of drawing this way.
//
// Below 1x there is nothing to round to, so a window smaller than the canvas
// shrinks smoothly rather than refusing to fit.
@(private)
viewport :: proc() -> Viewport {
	window := [2]f32{f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
	return fit_canvas(window, {f32(WIDTH), f32(HEIGHT)})
}

// Pulled out on its own so it can be tested without a window open.
@(private)
fit_canvas :: proc(window, canvas: [2]f32) -> Viewport {
	if canvas.x <= 0 || canvas.y <= 0 do return {{0, 0}, window, 1}
	scale := min(window.x / canvas.x, window.y / canvas.y)
	if scale > 1 do scale = math.floor(scale)
	size := canvas * scale
	return {(window - size) / 2, size, scale}
}

// Mouse position in canvas pixels (0..WIDTH, 0..HEIGHT), not window pixels.
// Everything the player clicks on — walking, the menu, the death box — goes
// through here, so this is the only place that has to know the window moved.
mouse_pos :: proc() -> [2]f32 {
	return canvas_point(rl.GetMousePosition(), viewport())
}

@(private)
canvas_point :: proc(p: [2]f32, v: Viewport) -> [2]f32 {
	return (p - v.at) / max(v.scale, 0.0001)
}

// The engine's own UI (message box, debug view, death box, menu) is laid out
// in pixel numbers tuned for a 320-wide canvas. This is how much to scale
// those numbers by for whatever canvas size the game actually asked for, so
// a button or a font size stays the same *proportion* of the screen.
@(private) REFERENCE_WIDTH :: 320
@(private)
ui_scale :: proc() -> f32 {
	return f32(WIDTH) / REFERENCE_WIDTH
}

// Scale a UI pixel measurement (position, size, line thickness).
@(private)
uf :: proc(v: f32) -> f32 {
	return v * ui_scale()
}
@(private)
ui :: proc(v: i32) -> i32 {
	return i32(f32(v) * ui_scale())
}

// Scale a font size, with a floor: raylib's default font turns to mush
// below about 6px, and a floor also keeps debug text legible on a small canvas.
@(private)
ufont :: proc(v: i32) -> i32 {
	return max(ui(v), 6)
}

// The same two, for a game's own UI: measurements given at the 320-wide
// reference size, scaled to whatever the canvas is. A notebook laid out in
// these lines up with the engine's speech boxes at any canvas size; one laid
// out in canvas pixels is right at exactly one.
ui_px :: proc(v: f32) -> f32 {
	return uf(v)
}

ui_font :: proc(size: i32) -> i32 {
	return ufont(size)
}

// Draws one frame: the current scene into the canvas, then the canvas
// stretched over the whole window.
draw :: proc(w: ^World) {
	comic_follow_light(w) // the comic's theme for this light, if it has one each (look.odin)
	if riding(w) {
		draw_ride(w)
		return
	}
	begin_canvas()
	draw_canvas(w)
	end_canvas(w.shake, w.time)
}

// Everything draw puts into the canvas when she is not riding: the room, a
// peep's split close-up, a card, a conversation's close-up, and what is over
// them. A frames run's picture of a ghost (sight.odin) draws it into a
// texture of its own.
@(private)
draw_canvas :: proc(w: ^World) {
	// At an aperture while a window plays: the split close-up. See peep.odin.
	if peeping(w) {
		rl.ClearBackground(rl.BLACK)
		if draw_peep(w) {
			draw_world_top(w)
			if w.overlay.draw != nil do w.overlay.draw(w)
			return
		}
	}
	// A card: the words alone, on a dark ground (conversation.odin).
	if text, alpha, ok := conversation_card(w); ok {
		rl.ClearBackground(CARD_GROUND)
		draw_card(text, alpha)
		if w.overlay.draw != nil do w.overlay.draw(w)
		return
	}
	// A close-up is a painted picture, already lit the way it wants to be:
	// not the room, and not tinted like it.
	if shot, frame, ok := conversation_shot(w); ok {
		rl.ClearBackground(rl.BLACK)
		draw_sprite(shot^, frame, {f32(WIDTH) / 2, f32(shot.frame_h)})
		draw_world_top(w)
		if w.overlay.draw != nil do w.overlay.draw(w)
		return
	}
	draw_world(w)
	draw_menu_bar(w) // over the room, while the pointer is at the top (menubar.odin)
	// Last, over the room and the prompt, inside the canvas so it scales and
	// letterboxes with everything else.
	if w.overlay.draw != nil do w.overlay.draw(w)
}

CARD_GROUND :: rl.Color{10, 9, 12, 255} // the Splash's ground
CARD_INK :: rl.Color{0xAA, 0xAA, 0xAA, 255}

// A card's words, centred in the middle two thirds of the canvas, fading in.
@(private)
draw_card :: proc(text: string, alpha: f32) {
	ink := CARD_INK
	ink.a = u8(f32(ink.a) * alpha)
	if the_look == .Comic {
		// Lettered, as everything else is.
		lines := wrap_measured(text, f32(WIDTH) * 2 / 3, letters_width)
		lh := letter_line() + letter_scale() * 2
		y := math.round((f32(HEIGHT) - lh * f32(len(lines))) / 2)
		for ln in lines {
			letters_draw(ln, math.round((f32(WIDTH) - letters_width(ln)) / 2), y, ink)
			y += lh
		}
		return
	}
	fs := ufont(8)
	width := i32(f32(WIDTH) * 2 / 3)
	lines := wrap(text, width, fs)
	line_h := fs + ui(3)
	y := (i32(HEIGHT) - line_h * i32(len(lines))) / 2
	for ln in lines {
		rl.DrawText(ln, (i32(WIDTH) - rl.MeasureText(ln, fs)) / 2, y, fs, ink)
		y += line_h
	}
}

// Everything between these two draws into the canvas. end_canvas stretches
// it over the window, shaking it if asked.
@(private)
begin_canvas :: proc() {
	rl.BeginTextureMode(target)
}

@(private)
end_canvas :: proc(shake: f32 = 0, time: f32 = 0) {
	rl.EndTextureMode()

	rl.BeginDrawing()
	rl.ClearBackground(rl.BLACK)
	v := viewport()
	src := rl.Rectangle{0, 0, f32(WIDTH), -f32(HEIGHT)} // negative: render textures are stored upside down
	dst := rl.Rectangle{v.at.x, v.at.y, v.size.x, v.size.y}
	if shake > 0 {
		wobble := min(shake, 0.5) * v.scale * 6
		dst.x += math.sin(time * 97) * wobble
		dst.y += math.cos(time * 83) * wobble
	}
	rl.DrawTexturePro(target.texture, src, dst, {0, 0}, 0, rl.WHITE)
	rl.EndDrawing()

	// Anything allocated with context.temp_allocator this frame is thrown away here.
	free_all(context.temp_allocator)
}

// A picture of the window, written where you asked for it.
//
// raylib's own TakeScreenshot glues the working directory onto whatever it is
// handed, so an absolute path becomes /home/you/project//tmp/shot.png and the
// write fails with a warning in a log nobody reads. Grabbing the frame and
// exporting it ourselves honours the path as typed.
save_screenshot :: proc(path: string) -> bool {
	img := rl.LoadImageFromScreen()
	defer rl.UnloadImage(img)
	ok := rl.ExportImage(img, strings.clone_to_cstring(path, context.temp_allocator))
	if !ok do fmt.eprintfln("could not write %v", path)
	return bool(ok)
}
