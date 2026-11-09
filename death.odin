package nengine

import "core:math"
import "core:strings"
import rl "vendor:raylib"

// Dying, Sierra style. Something kills the player (usually a Trigger), the
// death plays out in the scene, then a box comes up: a picture of the
// aftermath, a line about what went wrong, and Restore / Restart / Quit.
//
// The game describes each way to die as a Death and calls die(). While it
// plays, the engine ignores input and doesn't draw the player: the death's
// own draw proc does that, however it likes. Flying through the air, say.

Death :: struct {
	reason:   string,       // the one-liner in the box
	portrait: Sprite,       // the aftermath, drawn in the box
	jingle:   rl.Sound,     // plays as the box opens

	// Called every frame while the death plays. t is seconds since it
	// started; last is what t was on the previous frame. Return true when
	// it's over and the box should open.
	update:   proc(w: ^World, t, last: f32) -> (done: bool),

	// Draws the death over the scene: after the sprites, before the text.
	draw:     proc(w: ^World, t: f32),

	// The restore point the box's Restore goes back to (save.odin's
	// `restore_point`). Empty, or a point never made: the newest save.
	restore:  string,
}

Death_Choice :: enum {
	Restore,
	Restart,
	Quit,
}

// Kill the player.
die :: proc(w: ^World, d: Death) {
	log_line(w, strings.concatenate({"[death] ", d.reason}, context.temp_allocator))
	w.death = d
	w.dead = true
	w.death_box = false
	w.death_time = 0
	w.death_pick = .Restart
	w.player.moving = false
	w.player.walking = false
	w.player.heading = {}
	w.message_until = 0
	w.input_len = 0
}

// What the buttons in the box do. Restart and Quit only set a flag: the game
// sees w.restart or w.quit in its main loop and acts on it.
death_choose :: proc(w: ^World, c: Death_Choice) {
	switch c {
	case .Restore:
		// The death's own restore point if it named one and it was made;
		// otherwise whichever save is newest, which is what someone who has
		// just died means by Restore. Picking a particular one is a save
		// window's job.
		if load_restore_point(w, w.death.restore) do return
		if slot := newest_save(w); slot != 0 do load_game(w, slot)
	case .Restart: w.restart = true
	case .Quit:    w.quit = true
	}
}

// Restore greys itself out when there is nothing saved to go back to.
death_choice_ready :: proc(w: ^World, c: Death_Choice) -> bool {
	if c == .Restore do return has_restore_point(w, w.death.restore) || any_save(w)
	return true
}

// Has `moment` (seconds into the death) just gone by this frame? For timing
// things in a death's update: if ne.just_passed(t, last, 0.5) do ne.play(honk)
just_passed :: proc(t, last, moment: f32) -> bool {
	return last < moment && t >= moment
}

// Shake the screen for a moment. Stronger the longer it lasts.
shake :: proc(w: ^World, seconds: f32) {
	w.shake = max(w.shake, seconds)
}

// Plays the death until it's done, then opens the box. No input involved,
// so it can be tested.
@(private)
advance_death :: proc(w: ^World, dt: f32) {
	if w.death_box do return
	last := w.death_time
	w.death_time += dt
	done := w.death.update == nil || w.death.update(w, w.death_time, last)
	if done {
		w.death_box = true
		stop_scene_audio(current_scene(w))
		play(w.death.jingle)
	}
}

@(private)
update_death :: proc(w: ^World, dt: f32) {
	for rl.GetCharPressed() != 0 {} // keys typed now shouldn't land in the prompt later
	advance_death(w, dt)
	if !w.death_box do return

	// Left and right move between the buttons, skipping ones that don't
	// work yet. Enter picks. R and Q are shortcuts. The mouse works too.
	step := 0
	if rl.IsKeyPressed(.LEFT) || rl.IsKeyPressed(.KP_4) do step = -1
	if rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressed(.KP_6) || rl.IsKeyPressed(.TAB) do step = 1
	if step != 0 {
		c := int(w.death_pick)
		for {
			c = (c + step + len(Death_Choice)) % len(Death_Choice)
			if death_choice_ready(w, Death_Choice(c)) do break
		}
		w.death_pick = Death_Choice(c)
	}

	mouse := mouse_pos()
	for c in Death_Choice {
		if !death_choice_ready(w, c) || !in_rect(mouse, death_button(w, c)) do continue
		if rl.GetMouseDelta() != {0, 0} do w.death_pick = c
		if rl.IsMouseButtonPressed(.LEFT) do death_choose(w, c)
	}

	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) || rl.IsKeyPressed(.SPACE) do death_choose(w, w.death_pick)
	if rl.IsKeyPressed(.R) do death_choose(w, .Restart)
	if rl.IsKeyPressed(.Q) do death_choose(w, .Quit)
}

// --- The box ---
// Margins tuned for a 320-wide canvas: 16px each side, 22 top, 26 bottom.
// Scaled by ui() at runtime for whatever canvas size the game actually uses.

@(private)
death_box_rect :: proc() -> rl.Rectangle {
	return {uf(16), uf(22), f32(WIDTH) - uf(32), f32(HEIGHT) - uf(48)}
}

@(private)
death_button :: proc(w: ^World, c: Death_Choice) -> rl.Rectangle {
	if the_look == .Comic do return death_panel(w).buttons[c]
	box := death_box_rect()
	bw, gap := uf(70), uf(12)
	row_w := f32(len(Death_Choice)) * bw + f32(len(Death_Choice) - 1) * gap
	x := box.x + (box.width - row_w) / 2 + f32(int(c)) * (bw + gap)
	return {x, box.y + box.height - uf(22), bw, uf(14)}
}

@(private)
draw_death_box :: proc(w: ^World) {
	if the_look == .Comic {
		draw_comic_death_box(w)
		return
	}
	gold := rl.Color{200, 168, 90, 255}
	box := death_box_rect()
	fs := ufont(10)

	rl.DrawRectangle(0, 0, WIDTH, HEIGHT, {0, 0, 0, 150}) // dim the scene behind
	rl.DrawRectangleRec(box, {18, 12, 20, 250})
	rl.DrawRectangleLinesEx(box, uf(1), gold)
	inset := uf(3)
	rl.DrawRectangleLinesEx({box.x + inset, box.y + inset, box.width - inset * 2, box.height - inset * 2}, uf(1), {110, 88, 48, 255})

	// The picture, framed: top left with the words beside it, or, when it
	// is wider than half the box (a scene, not a face), centred across the
	// top with the words under it.
	pad := ui(10)
	text_x := i32(box.x) + pad
	y := i32(box.y) + ui(11)
	if pic := w.death.portrait; pic.texture.id != 0 {
		pw, ph := pic.frame_w, pic.frame_h
		wide := f32(pw) > box.width / 2
		px := i32(box.x + (box.width - f32(pw)) / 2) if wide else i32(box.x) + pad
		py := i32(box.y) + pad
		rl.DrawRectangle(px - ui(2), py - ui(2), pw + ui(4), ph + ui(4), gold)
		draw_sprite_at(pic, 0, px, py)
		if wide do y = py + ph + pad
		else do text_x = px + pw + pad
	}

	// The words.
	text_w := i32(box.x + box.width) - pad - text_x
	line_h := fs + ui(1)
	rl.DrawText("You have died.", text_x, y, fs, {230, 80, 64, 255})
	y += ui(16)
	for line in wrap(w.death.reason, text_w, fs) {
		rl.DrawText(line, text_x, y, fs, rl.RAYWHITE)
		y += line_h
	}

	// The buttons.
	labels := [Death_Choice]cstring {
		.Restore = "Restore",
		.Restart = "Restart",
		.Quit    = "Quit",
	}
	for c in Death_Choice {
		b := death_button(w, c)
		ready := death_choice_ready(w, c)
		picked := ready && c == w.death_pick
		fill := gold if picked else rl.Color{40, 30, 36, 255}
		ink := rl.Color{18, 12, 20, 255} if picked else (rl.RAYWHITE if ready else rl.Color{100, 94, 100, 255})
		rl.DrawRectangleRec(b, fill)
		rl.DrawRectangleLinesEx(b, uf(1), gold if ready else rl.Color{80, 70, 60, 255})
		tw := rl.MeasureText(labels[c], fs)
		rl.DrawText(labels[c], i32(b.x) + (i32(b.width) - tw) / 2, i32(b.y) + ui(3), fs, ink)
	}
}

// --- The box, as a comic's last panel (look.odin) ---
// The picture framed heavily across the top, "You have died." in a caption
// over its corner, the reason in a second caption under it, and the three
// choices as small panels: the one picked yellow.

@(private)
Death_Panel :: struct {
	picture:  rl.Rectangle, // in grid pixels; zero when there is none
	title:    Caption,
	reason:   Caption,
	buttons:  [Death_Choice]rl.Rectangle, // on the canvas, for the mouse
}

@(private)
death_panel :: proc(w: ^World) -> Death_Panel {
	m := comic_metrics()
	gw, gh := m.grid_w, f32(HEIGHT) / m.scale
	p: Death_Panel
	top := f32(14)
	y := top
	if pic := w.death.portrait; pic.texture.id != 0 {
		pw, ph := f32(pic.frame_w) / m.scale, f32(pic.frame_h) / m.scale
		p.picture = {math.round((gw - pw) / 2), top, pw, ph}
		p.title = plan_caption("You have died.", m, p.picture.x - 14, top - 8, 80)
		y = top + ph + 10
	} else {
		p.title = plan_caption("You have died.", m, 0, top, 80)
		p.title.x = math.round((gw - p.title.w) / 2)
		y = top + p.title.h + 10
	}
	p.reason = plan_caption(w.death.reason, m, 0, y, 192, gw - 24)
	p.reason.x = math.round((gw - p.reason.w) / 2)
	by := min(max(f32(176), y + p.reason.h + 6), gh - 20)
	bx0 := math.round((gw - 180) / 2)
	for c in Death_Choice {
		bx := bx0 + f32(int(c)) * 64
		p.buttons[c] = {gx(bx), gx(by), gx(bx + 54) - gx(bx), gx(by + 16) - gx(by)}
	}
	return p
}

@(private)
draw_comic_death_box :: proc(w: ^World) {
	p := death_panel(w)
	grid_dither(the_comic.line)
	if p.picture != {} {
		r := p.picture
		draw_picture_frame(r.x, r.y, r.width, r.height)
		draw_sprite_at(w.death.portrait, 0, i32(gx(r.x)), i32(gx(r.y)))
	}
	draw_caption(p.reason)
	draw_caption(p.title)
	labels := [Death_Choice]string{.Restore = "Restore", .Restart = "Restart", .Quit = "Quit"}
	for c in Death_Choice {
		ready := death_choice_ready(w, c)
		draw_comic_button(p.buttons[c], labels[c], ready && c == w.death_pick, ready)
	}
}
