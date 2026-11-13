package nengine

import "core:strings"
import rl "vendor:raylib"

// The boxes: what the game says, what the protagonist thinks, and the line
// the player types into.
//
// All three are the same widget with a different style, so a game sets its
// look once and every box in it matches. One game is grey with a bar down
// the side; the next is green with cut corners; neither needs its own
// drawing code.
//
// A box may carry a **portrait** — usually a character's `face` part — on
// the left or the right. Two speakers with opposite sides is a conversation:
// the picture swaps ends as the speaker changes, which is all the reader
// needs to follow who is talking.

Box_Side :: enum {
	Left,
	Right,
}

// Decoration on the frame. Cheap, and the difference between "a rectangle"
// and "this game's rectangle".
Flourish :: enum {
	None,
	Corners,  // a mark at each corner
	Side_Bar, // a thick accent bar down one edge
	Notch,    // the corners cut away
	Beads,    // a dotted line inside the border
}

Box_Style :: struct {
	fill:     rl.Color,
	edge:     rl.Color,
	ink:      rl.Color,
	accent:   rl.Color, // the flourish
	border:   i32,      // in reference pixels; scaled with the canvas
	pad:      i32,
	font:     i32,
	flourish: Flourish,
	tail:     bool, // a pointer towards the speaker
	bubbles:  bool, // thought, rather than speech
}

// Somewhere to start. A game overrides these on the World.
BOX_PLAIN :: Box_Style {
	fill = {0, 0, 0, 220}, edge = {230, 230, 230, 255}, ink = {235, 235, 235, 255},
	accent = {150, 150, 150, 255}, border = 1, pad = 4, font = 10, flourish = .None,
}

BOX_SPEECH :: Box_Style {
	fill = {26, 26, 30, 235}, edge = {200, 200, 205, 255}, ink = {240, 240, 240, 255},
	accent = {170, 170, 175, 255}, border = 1, pad = 4, font = 10,
	flourish = .Side_Bar, tail = true,
}

BOX_THOUGHT :: Box_Style {
	fill = {18, 20, 34, 230}, edge = {120, 130, 190, 255}, ink = {205, 210, 240, 255},
	accent = {90, 100, 160, 255}, border = 1, pad = 4, font = 10,
	flourish = .Beads, bubbles = true,
}

// Who is speaking, and what they look like while they do it.
// A speaker puts on a character part as their portrait: the picture, and the
// part's own animation rate when it has one, so a face with talk frames talks.
// A speaker whose frame the game holds (fps 0 and `frame`, a meter) sets that
// after, as before.
speaker_wears :: proc(sp: ^Speaker, part: Part_Art) {
	sp.portrait = part.sprite
	if part.fps > 0 do sp.fps = part.fps
}

Speaker :: struct {
	name:     string,
	portrait: Sprite, // a character's "face" part, or any sprite
	fps:      f32,    // how fast the portrait animates while the box is up
	frame:    i32,    // with fps 0: which frame to hold. A face can be a meter —
	                  // the game picks the frame, and says nothing about why
	side:     Box_Side,
	style:    ^Box_Style, // nil: the world's speech style
	// Heard and not seen (through a vent, a blind net): who they are named as,
	// "a man", "a woman". "" is "a voice". See peep.odin.
	unseen:   string,
	// Dead: shown a thing or asked anything, they are Gone. See show_thing.
	gone:     bool,
}

// --- Drawing ---

// Draws a box with `text` in it, and a portrait beside it if there is one.
// `at_top` puts it under the top edge; otherwise it sits above the prompt.
draw_box :: proc(style: Box_Style, text: string, who: ^Speaker = nil, time: f32 = 0, at_top := true) {
	margin := uf(4)
	pad := uf(f32(style.pad))
	fs := ufont(style.font)
	line_h := fs + ui(1)

	// The portrait, if any, takes one end of the strip. A sprite's frame is
	// already in canvas pixels — scaling it again by the UI scale is how you
	// end up with a face that fills a third of the screen.
	portrait_w, portrait_h: f32
	if who != nil && who.portrait.texture.id != 0 {
		portrait_w = f32(who.portrait.frame_w)
		portrait_h = f32(who.portrait.frame_h)
		// Never more than a quarter of the width or 38% of the height,
		// however big the art happens to be. A big EGA-style bust
		// (about 60x72 on a 320x200 picture) fits whole.
		fit := min(f32(WIDTH) * 0.25 / portrait_w, f32(HEIGHT) * 0.38 / portrait_h, 1)
		portrait_w *= fit
		portrait_h *= fit
	}

	// Whatever is left over is for words.
	text_w := f32(WIDTH) - margin * 2 - pad * 2
	if portrait_w > 0 do text_w -= portrait_w + margin

	lines := wrap(text, i32(text_w), fs)
	widest: i32
	for l in lines do widest = max(widest, rl.MeasureText(l, fs))

	// Wide enough to look like a box even when the line is "...".
	box_w := clamp(f32(widest) + pad * 2, min(f32(WIDTH) * 0.35, text_w), text_w + pad * 2)
	box_h := f32(len(lines) * int(line_h)) + pad * 2

	// Lay the two out side by side, tops aligned.
	total := box_w + (portrait_w + margin if portrait_w > 0 else 0)
	left := (f32(WIDTH) - total) / 2
	strip_h := max(box_h, portrait_h)
	top := margin if at_top else f32(HEIGHT) - uf(14) - strip_h - margin

	box_x := left
	portrait_x := left
	if portrait_w > 0 {
		if who.side == .Left {
			box_x = left + portrait_w + margin
		} else {
			portrait_x = left + box_w + margin
		}
	}

	box := rl.Rectangle{box_x, top, box_w, box_h}
	frame(style, box)

	if style.tail && portrait_w > 0 {
		// A small wedge on the portrait's side, so the box points at them.
		tip := uf(3)
		y := box.y + box.height / 2
		if who.side == .Left {
			rl.DrawTriangle({box.x, y - tip}, {box.x - tip, y}, {box.x, y + tip}, style.fill)
			rl.DrawTriangleLines({box.x, y - tip}, {box.x - tip, y}, {box.x, y + tip}, style.edge)
		} else {
			rl.DrawTriangle({box.x + box.width, y - tip}, {box.x + box.width, y + tip}, {box.x + box.width + tip, y}, style.fill)
			rl.DrawTriangleLines({box.x + box.width, y - tip}, {box.x + box.width, y + tip}, {box.x + box.width + tip, y}, style.edge)
		}
	}

	if style.bubbles {
		// Two little clouds trailing away from the box: a thought, not a line.
		cx := box.x + (uf(8) if who == nil || who.side == .Left else box.width - uf(8))
		for i in 0 ..< 2 {
			r := uf(f32(3 - i))
			cy := box.y + box.height + uf(f32(3 + i * 5))
			rl.DrawCircleV({cx, cy}, r, style.fill)
			rl.DrawCircleLinesV({cx, cy}, r, style.edge)
		}
	}

	for l, i in lines {
		rl.DrawText(l, i32(box.x + pad), i32(box.y + pad) + i32(i) * line_h, fs, style.ink)
	}

	if portrait_w > 0 {
		p := rl.Rectangle{portrait_x, top, portrait_w, portrait_h}
		frame(style, p)
		fps := who.fps if who.fps > 0 else 0
		f := i32(time * fps) if fps > 0 else who.frame
		draw_sprite_in(who.portrait, f, p)
	}
}

// A panel in one of the box styles, for whatever a game draws over the room:
// a notebook, a map, a case of belongings laid out on a bed. The same frame the
// speech boxes use, so a game's own overlays and its speech look like one game
// rather than two.
draw_panel :: proc(style: Box_Style, r: rl.Rectangle) {
	// The comic's panels are all one kind: the style's own paper, a black
	// line and a shadow (look.odin).
	if the_look == .Comic {
		draw_comic_panel(style.fill, r)
		return
	}
	frame(style, r)
}

// The frame itself: fill, border, and whatever flourish the style asks for.
@(private)
frame :: proc(style: Box_Style, r: rl.Rectangle) {
	b := uf(f32(max(style.border, 1)))

	switch style.flourish {
	case .Notch:
		// Corners cut away, drawn as a rectangle with four little triangles
		// of background taken out of it.
		cut := uf(4)
		rl.DrawRectangleRec(r, style.fill)
		rl.DrawTriangle({r.x, r.y}, {r.x, r.y + cut}, {r.x + cut, r.y}, {0, 0, 0, 0})
		rl.DrawRectangleLinesEx(r, b, style.edge)
		rl.DrawLineEx({r.x, r.y + cut}, {r.x + cut, r.y}, b, style.accent)
		rl.DrawLineEx({r.x + r.width - cut, r.y}, {r.x + r.width, r.y + cut}, b, style.accent)

	case .Side_Bar:
		rl.DrawRectangleRec(r, style.fill)
		rl.DrawRectangleRec({r.x, r.y, uf(3), r.height}, style.accent)
		rl.DrawRectangleLinesEx(r, b, style.edge)

	case .Corners:
		rl.DrawRectangleRec(r, style.fill)
		rl.DrawRectangleLinesEx(r, b, style.edge)
		m := uf(3)
		for c in ([4][2]f32{{r.x, r.y}, {r.x + r.width - m, r.y}, {r.x, r.y + r.height - m}, {r.x + r.width - m, r.y + r.height - m}}) {
			rl.DrawRectangleRec({c.x, c.y, m, m}, style.accent)
		}

	case .Beads:
		rl.DrawRectangleRec(r, style.fill)
		rl.DrawRectangleLinesEx(r, b, style.edge)
		gap := uf(4)
		for x := r.x + gap; x < r.x + r.width - gap / 2; x += gap {
			rl.DrawRectangleRec({x, r.y + uf(2), uf(1), uf(1)}, style.accent)
			rl.DrawRectangleRec({x, r.y + r.height - uf(3), uf(1), uf(1)}, style.accent)
		}

	case .None:
		rl.DrawRectangleRec(r, style.fill)
		rl.DrawRectangleLinesEx(r, b, style.edge)
	}
}

// Draws one frame of a sprite stretched to fill a rectangle — portraits are
// authored at one size and shown at whatever the canvas allows. Public for a
// game's own overlays: a painted notebook page, a map, a photograph held up.
draw_sprite_in :: proc(s: Sprite, frame_index: i32, r: rl.Rectangle) {
	if s.texture.id == 0 do return
	draw_sprite_pro(s, frame_index %% max(s.frames, 1), r)
}

// Splits text into lines no wider than max_width pixels, at font size fs.
//
// A newline in the text is a line break the caller meant, and is kept: a
// page of a notebook is a list, and a list that has been reflowed into a
// paragraph is not a list any more. Everything between the breaks is
// wrapped as usual.
// Public for a game's own overlays, which wrap their text the same way the
// speech boxes do.
wrap :: proc(text: string, max_width, fs: i32) -> []cstring {
	lines := make([dynamic]cstring, context.temp_allocator)
	rest := beats_as_breaks(plain_text(text))
	for para in strings.split_iterator(&rest, "\n") {
		words := strings.fields(para, context.temp_allocator)
		if len(words) == 0 {
			append(&lines, temp_cstring(" ")) // a blank line the caller asked for
			continue
		}
		line := ""
		for word in words {
			longer := word if line == "" else strings.concatenate({line, " ", word}, context.temp_allocator)
			if line != "" && rl.MeasureText(temp_cstring(longer), fs) > max_width {
				append(&lines, temp_cstring(line))
				line = word
			} else {
				line = longer
			}
		}
		if line != "" do append(&lines, temp_cstring(line))
	}
	return lines[:]
}

// What `wrap` would produce, as plain strings. Exported so that the text box
// can be tested without a window: MeasureText needs a font, and a font needs
// a GPU, so the test passes a width in characters instead.
wrap_text :: proc(text: string, columns: int, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	rest := beats_as_breaks(text)
	for para in strings.split_iterator(&rest, "\n") {
		words := strings.fields(para, context.temp_allocator)
		if len(words) == 0 {
			append(&out, "")
			continue
		}
		line := ""
		for word in words {
			longer := word if line == "" else strings.concatenate({line, " ", word}, allocator)
			if line != "" && len(longer) > columns {
				append(&out, line)
				line = word
			} else {
				line = longer
			}
		}
		if line != "" do append(&out, line)
	}
	return out[:]
}

@(private)
temp_cstring :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

// A beat — "(beat)" or "(a beat)" — is the writers' pause inside a line.
// Shown in a box it is not printed: the words after it start a line of their
// own, as a breath does, and a box that times out stays up BEAT_SECS longer
// for each (post). The words keep it everywhere else (message, the play log,
// the script), so the files stay as written. Every box wraps through
// `wrap`, `wrap_measured` or `wrap_text`, and each of them does this.
BEAT_SECS :: f32(0.6)

@(private = "file")
BEAT_MARKS := [?]string{"(beat)", "(a beat)"}

// The text with each beat made a line break; none at the start or the end.
beats_as_breaks :: proc(text: string, allocator := context.temp_allocator) -> string {
	if beats_in(text) == 0 do return text
	b := strings.builder_make(allocator)
	rest := text
	for {
		at, n := -1, 0
		for m in BEAT_MARKS {
			if i := strings.index(rest, m); i >= 0 && (at < 0 || i < at) do at, n = i, len(m)
		}
		if at < 0 {
			strings.write_string(&b, rest)
			break
		}
		strings.write_string(&b, strings.trim_right_space(rest[:at]))
		rest = strings.trim_left_space(rest[at + n:])
		so_far := strings.to_string(b)
		if len(so_far) > 0 && so_far[len(so_far) - 1] != '\n' && rest != "" do strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// How many beats the text has.
beats_in :: proc(text: string) -> int {
	n := 0
	for m in BEAT_MARKS do n += strings.count(text, m)
	return n
}

// Text as the font can draw it. The font is ASCII, and writing is not: a
// script written properly is full of dashes, curly quotes and ellipses, and
// every one of them would come out as "?". So they become what a typewriter
// would have used — `--` for a dash, straight quotes, three full stops — and
// the script keeps its punctuation.
plain_text :: proc(text: string, allocator := context.temp_allocator) -> string {
	if strings.index_byte(text, 0xE2) < 0 do return text // all of these start with E2
	out := text
	for pair in ([][2]string{{"—", "--"}, {"–", "-"}, {"‘", "'"}, {"’", "'"}, {"“", "\""}, {"”", "\""}, {"…", "..."}}) {
		out, _ = strings.replace_all(out, pair[0], pair[1], allocator)
	}
	return out
}
