package nengine

import "core:fmt"
import "core:math"
import rl "vendor:raylib"

// Announcements: a discovery that stops the game.
//
// A body is not found in a line of a conversation. The first time the player
// is in a room while something holds — a body in the pool, a man dead in his
// chair — everything stops: a close-up, a title, and what they see, in a big
// box, until they press on. Then whatever was under way (the conversation the
// discovery started) carries on.
//
//     w.announcements = ANNOUNCEMENTS[:]
//
//     ANNOUNCEMENTS := [?]ne.Announcement{
//         {name = "an_pool", room = "pool_deck", only = "bodies_found",
//          shot = &pool_closeup, title = "The plunge pool",
//          text = "Lit from under the water, the way it is every night..."},
//     }
//
// Checked every frame the world runs, ahead of a conversation, so a scripted
// cut that lands the player in the room and opens the talk about it shows the
// announcement first. Showing one sets the flag `name`: once, and it saves.
// Like a beat, an announcement the player was never there for is never shown.
Announcement :: struct {
	name:  string, // its flag
	room:  string, // "" is any room
	only:  string, // condition; see flags.odin
	shot:  ^Sprite, // the close-up; nil for words alone
	frame: i32,
	title: string,
	text:  string,
	sound: string, // played as it opens, by name
	// Seen through somebody else's eyes: may open in the middle of a ride, over
	// the host's view, when a glance's on_look asks for it with announce_now.
	// Every other announcement waits until she is back in her own body.
	in_ride: bool,
	// As it opens, once: what the discovery writes down or awards (the game's
	// notebook lines). nil for nothing.
	on_play: proc(w: ^World),
}

// Opens the named announcement now, if it has not been shown and its
// condition holds: a glance that finds the body, from on_look. Only one marked
// `in_ride` opens while riding. True if it opened.
announce_now :: proc(w: ^World, name: string) -> bool {
	if w.announcing != nil || w.dead do return false
	for &a in w.announcements {
		if a.name != name || flag(w, a.name) do continue
		if riding(w) && !a.in_ride do return false
		if !condition_met(w, a.only) do return false
		set_flag(w, a.name, true)
		w.announcing = &a
		w.announced_at = w.time
		log_announcement(w, &a)
		play_sound(w, a.sound)
		if a.on_play != nil do a.on_play(w)
		return true
	}
	return false
}

// The announcement that is due here and now, if any.
announcement_due :: proc(w: ^World) -> ^Announcement {
	if len(w.scenes) == 0 do return nil
	// Not through somebody else's eyes: a ride draws its own frame, and the
	// body is found when she is back in hers.
	if riding(w) || cutting(w) || w.dead do return nil
	here := current_scene(w).name
	for &a in w.announcements {
		if flag(w, a.name) do continue
		if a.room != "" && a.room != here do continue
		if !condition_met(w, a.only) do continue
		return &a
	}
	return nil
}

// Opens whatever is due. True if one opened.
open_announcement :: proc(w: ^World) -> bool {
	if w.announcing != nil do return false
	a := announcement_due(w)
	if a == nil do return false
	set_flag(w, a.name, true)
	w.announcing = a
	w.announced_at = w.time
	log_announcement(w, a)
	play_sound(w, a.sound)
	if a.on_play != nil do a.on_play(w)
	return true
}

// Into the play log, as the box says it: the title, and what she sees.
@(private = "file")
log_announcement :: proc(w: ^World, a: ^Announcement) {
	if a.title == "" do log_line(w, a.text)
	else do log_line(w, fmt.tprintf("%v: %v", a.title, a.text))
}

// True while one holds the screen.
announcing :: proc(w: ^World) -> bool {
	return w.announcing != nil
}

close_announcement :: proc(w: ^World) {
	w.announcing = nil
}

// The frame's work: open one if it is due, and close it on a key. True while
// one is up, which is the world standing still.
@(private)
update_announcement :: proc(w: ^World) -> bool {
	if w.announcing == nil && !open_announcement(w) do return false
	// A moment's grace, so the key that brought it on does not take it off.
	if w.time - w.announced_at < 0.3 do return true
	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.SPACE) || rl.IsKeyPressed(.ESCAPE) || rl.IsMouseButtonPressed(.LEFT) {
		close_announcement(w)
	}
	for rl.GetCharPressed() != 0 {} // nothing it was not reading reaches the prompt
	return true
}

// Over everything: the room dimmed, the close-up framed at the top, and the
// title and words in a big box under it.
@(private)
draw_announcement :: proc(w: ^World) {
	a := w.announcing
	if a == nil do return
	if the_look == .Comic {
		draw_comic_announcement(w, a)
		return
	}
	style := style_for(w, .Narration)
	rl.DrawRectangle(0, 0, WIDTH, HEIGHT, {0, 0, 0, 200})

	margin := uf(8)
	y := margin
	if a.shot != nil && a.shot.texture.id != 0 {
		// The close-up at twice its painted size: 640 of 1024 at 320 wide.
		pw := f32(WIDTH) * 0.625
		ph := pw * f32(a.shot.frame_h) / f32(a.shot.frame_w)
		x := (f32(WIDTH) - pw) / 2
		frame := a.frame % max(a.shot.frames, 1)
		edge := uf(f32(max(style.border, 1)))
		rl.DrawRectangleRec({x - edge * 2, y - edge * 2, pw + edge * 4, ph + edge * 4}, style.edge)
		draw_sprite_pro(a.shot^, frame, {x, y, pw, ph})
		y += ph + margin * 1.5
	}

	// The box: the full width less a margin, down to the bottom of the screen.
	box := rl.Rectangle{margin * 2, y, f32(WIDTH) - margin * 4, f32(HEIGHT) - y - margin}
	rl.DrawRectangleRec(box, style.fill)
	rl.DrawRectangleLinesEx(box, uf(f32(max(style.border, 1))), style.edge)

	pad := uf(f32(style.pad) * 2)
	tx := i32(box.x + pad)
	ty := i32(box.y + pad)
	title_fs := ufont(style.font + 4)
	body_fs := ufont(style.font + 1)
	if a.title != "" {
		rl.DrawText(temp_cstring(a.title), tx, ty, title_fs, style.accent if style.accent.a > 0 else style.ink)
		ty += title_fs + ui(3)
	}
	for line in wrap(a.text, i32(box.width - pad * 2), body_fs) {
		rl.DrawText(line, tx, ty, body_fs, style.ink)
		ty += body_fs + ui(1)
	}
	// And how to go on, small, top right, level with the title — the words
	// can run to the bottom of the box.
	if w.time - w.announced_at >= 0.3 {
		hint := cstring("Enter")
		hs := ufont(style.font - 2)
		rl.DrawText(hint, i32(box.x + box.width - pad) - rl.MeasureText(hint, hs), i32(box.y + pad), hs, style.accent)
	}
}

// The comic's: the room behind dithered dark, the close-up framed heavily at
// the top, and the title and words in a caption under it, the title in red.
@(private = "file")
draw_comic_announcement :: proc(w: ^World, a: ^Announcement) {
	m := comic_metrics()
	gw, gh := m.grid_w, f32(HEIGHT) / m.scale
	grid_dither(the_comic.line)
	y := f32(10)
	if a.shot != nil && a.shot.texture.id != 0 {
		// The close-up at twice its painted size, as the boxes show it.
		pw := math.round(gw * 0.625)
		ph := math.round(pw * f32(a.shot.frame_h) / f32(a.shot.frame_w))
		x := math.round((gw - pw) / 2)
		draw_picture_frame(x, y, pw, ph)
		draw_sprite_pro(a.shot^, a.frame % max(a.shot.frames, 1), {gx(x), gx(y), gx(x + pw) - gx(x), gx(y + ph) - gx(y)})
		y += ph + 12
	}
	cap := plan_caption(a.text, m, 8, y, gw - 16, gw - 16, a.title)
	cap.w = gw - 16
	// A long one rises over the foot of the picture rather than off the screen.
	cap.y = max(EDGE, min(cap.y, gh - EDGE - 2 - cap.h))
	draw_caption(cap)
	// And how to go on, level with the title, at the right.
	if w.time - w.announced_at >= 0.3 {
		hint := "Enter"
		letters_draw(hint, gx(cap.x + cap.w - CAPTION_PAD) - letters_width(hint), gx(cap.y + 4), the_comic.caption.aside)
	}
}
