package nengine

import "core:fmt"
import rl "vendor:raylib"

// A conversation: a list of lines, each with somebody to say it.
//
// The player steps through with Enter or a click. Whoever is speaking has
// their portrait beside the box, and because two speakers usually sit on
// opposite sides, the picture swaps ends as the turn passes — which is the
// whole of what a reader needs to follow who is talking.
//
//     ada := ne.Speaker{name = "Ada", portrait = face, fps = 7, side = .Left}
//     crawford := ne.Speaker{name = "Crawford", portrait = his_face, fps = 6, side = .Right}
//     lines := []ne.Talk_Line{
//         {who = &ada, text = "You were on the path at eleven."},
//         {who = &crawford, text = "I was on the step. There's a difference."},
//         {who = &ada, text = "Not to the man who's dead.", thinking = true},
//     }
//     ne.begin_conversation(w, &chat, lines)
//
// A close-up: a line with a `shot` shows that picture over the whole room
// while it is up — a painted two-shot of the faces, which a room at walking
// scale cannot be. The speaker is named on the box rather than pictured
// beside it, because their face is already the picture. One sheet holds the
// shot's frames (who is talking, who is listening), so a line picks one:
//
//     {who = &boss, text = "Don't break it.", shot = &two_shot, frame = 2},
//
// A card: a line with `card` is the words alone, on a dark ground, with no
// room, no box and no face — an epilogue, "four days later", the paragraph
// out of a newspaper. It fades in and waits for the reader like any line; a
// title card of words, inside the flow of a scene (a picture alone is a
// Splash, splash.odin).
//
//     {text = "Mora, four days later.", card = true},

Talk_Line :: struct {
	who:      ^Speaker,
	text:     string,
	thinking: bool,    // shown as a thought, not spoken aloud
	shot:     ^Sprite, // a close-up over the whole room while this line is up
	frame:    i32,     // which frame of the shot
	card:     bool,    // the words alone on a dark ground: no room, no box
}

Conversation :: struct {
	lines:   []Talk_Line,
	at:      int,
	running: bool,
	started: f32, // world time this line went up
	on_end:  proc(w: ^World),
	// Escape ends any conversation, and then `on_end` runs as if it had been
	// read. A scene told in several conversations, each starting the next
	// from its `on_end`, wants Escape to skip all of it: `on_skip` is where
	// that goes, instead of `on_end`, when the reader skips.
	on_skip: proc(w: ^World),
}

begin_conversation :: proc(w: ^World, c: ^Conversation, lines: []Talk_Line, on_end: proc(w: ^World) = nil, on_skip: proc(w: ^World) = nil) {
	if len(lines) == 0 do return
	c^ = {lines = lines, running = true, on_end = on_end, on_skip = on_skip}
	w.talk = c
	show_line(w, c)
}

// True while a conversation is holding the screen — the game should not act
// on walking or commands during one.
talking :: proc(w: ^World) -> bool {
	return w.talk != nil && w.talk.running
}

// Moves to the next line. The player does this with Enter or a click; a
// game can also do it on a timer.
advance_conversation :: proc(w: ^World) {
	c := w.talk
	if c == nil || !c.running do return
	c.at += 1
	if c.at >= len(c.lines) {
		end_conversation(w)
		return
	}
	show_line(w, c)
}

end_conversation :: proc(w: ^World) {
	c := w.talk
	if c == nil do return
	c.running = false
	w.talk = nil
	w.message_until = 0
	w.message_who = nil
	if c.on_end != nil do c.on_end(w)
}

// What the reader's Escape does: the rest of the conversation unread, and
// `on_skip` instead of `on_end` if there is one.
skip_conversation :: proc(w: ^World) {
	c := w.talk
	if c == nil do return
	if c.on_skip == nil {
		end_conversation(w)
		return
	}
	c.running = false
	w.talk = nil
	w.message_until = 0
	w.message_who = nil
	c.on_skip(w)
}

// The close-up the current line wants, if it wants one.
conversation_shot :: proc(w: ^World) -> (shot: ^Sprite, frame: i32, ok: bool) {
	if !talking(w) do return nil, 0, false
	line := w.talk.lines[w.talk.at]
	if line.shot == nil || line.shot.texture.id == 0 do return nil, 0, false
	return line.shot, line.frame, true
}

// The card the current line is, if it is one, and how far it has faded in
// (0 to 1, over CARD_FADE seconds of play).
conversation_card :: proc(w: ^World) -> (text: string, alpha: f32, ok: bool) {
	if !talking(w) do return "", 0, false
	line := w.talk.lines[w.talk.at]
	if !line.card do return "", 0, false
	return line.text, clamp((w.time - w.talk.started) / CARD_FADE, 0, 1), true
}

CARD_FADE :: 0.8

@(private)
show_line :: proc(w: ^World, c: ^Conversation) {
	line := c.lines[c.at]
	c.started = w.time
	// A card is drawn by itself (draw_card), not in the box.
	if line.card {
		log_line(w, fmt.tprintf("[card] %v", line.text))
		w.message_len = 0
		w.message_who = nil
		w.message_until = max(f32(1e9), w.message_until)
		return
	}
	text := line.text
	// A speaker with no portrait is named on the box instead: somebody whose
	// art is not drawn yet, or a voice through a wall, which is "A woman" and
	// never has a face.
	// So is everybody in a close-up: the face is the picture.
	who := line.who
	// And so is everybody heard at an aperture: the split close-up is the
	// picture. See peep.odin.
	pictured := (line.shot != nil && line.shot.texture.id != 0) || w.peeping.active
	if who != nil && who.name != "" && (who.portrait.texture.id == 0 || pictured) {
		text = fmt.tprintf("%v: %v", who.name, line.text)
	}
	if pictured do who = nil
	if line.thinking {
		think(w, who, text)
	} else {
		say_as(w, who, text)
	}
	// Who it is, even with no face beside the box (look.odin).
	w.message_speaker = line.who
	// In sight while it is said: anybody walking on has arrived, and a
	// speaker not in the room comes to her (sight.odin).
	people_arrive(w)
	call_into_sight(w, line)
	// A line in a conversation waits for the reader, not for a timer.
	w.message_until = max(f32(1e9), w.message_until)
}

@(private)
update_conversation :: proc(w: ^World) -> bool {
	if !talking(w) do return false
	// A moment's grace, so the keypress that started it doesn't skip line one.
	if w.time - w.talk.started < 0.15 do return true
	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.SPACE) || rl.IsMouseButtonPressed(.LEFT) {
		advance_conversation(w)
	}
	if rl.IsKeyPressed(.ESCAPE) do skip_conversation(w)
	return true
}
