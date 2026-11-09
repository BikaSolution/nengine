// pixel: the grid of coloured squares that every art editor in nart is.
//
// A sprite, a character's pose and a room's backdrop are the same thing at
// three sizes — indices into a palette, in rows — so painting them, showing
// them, selecting a rectangle of them and copying one into another is one
// piece of code, here, rather than three that drift apart.
//
// What is NOT here is anything about what the file means: how many poses a
// character has, that a backdrop is 320x200, which frame is which. That
// belongs to whichever editor owns the format.
package pixel

import ne "../../"
import "core:fmt"
import ui "../ui"
import rl "vendor:raylib"

// Painting a grid of pixels. Both the pixel art editor and the character
// editor are this plus a way of choosing what you're painting — one sprite,
// or one pose of a character.

// What the palette strip offers comes from the file's mode now — see
// nengine/palette.odin. The editors used to keep a list of thirty-two colours
// here and force every one of them into every file they made, whether the
// picture used them or not, which is why a new sprite arrived holding
// thirty-two colours it had never heard of and none of them EGA.

// How much the brush covers, and what shape it is.
//
// Size 1 is one pixel, which is what pixel art mostly wants. Size 2 is the
// four neighbours and no corners, size 3 a small disc, and so on — a round
// brush is every offset within the radius, `dx*dx + dy*dy <= r*r`, which is
// what makes 2 a plus rather than a three-by-three block.
//
//      size 1      size 2      size 3       size 3, square
//        o           o           o             ooooo
//                   ooo         ooo            ooooo
//                    o         ooooo           ooooo
//                               ooo            ooooo
//                                o             ooooo
Brush :: struct {
	size:   int, // 1 is a single pixel
	square: bool,
}

BRUSH_MAX :: 16

// Every offset the brush covers, relative to the pixel under the cursor.
// Fills the caller's buffer rather than allocating: this runs on every mouse
// position of every stroke.
brush_offsets :: proc(b: Brush, buf: ^[(BRUSH_MAX * 2 + 1) * (BRUSH_MAX * 2 + 1)][2]i32) -> [][2]i32 {
	size := clamp(b.size, 1, BRUSH_MAX)
	r := i32(size - 1)
	n := 0
	for dy in -r ..= r {
		for dx in -r ..= r {
			if !b.square && dx * dx + dy * dy > r * r do continue
			buf[n] = {dx, dy}
			n += 1
		}
	}
	return buf[:n]
}

// The mode a new picture starts in.
//
// bEGA, because the game this engine was written for is drawn in the sixteen,
// and because a constraint is the safer default: a picture's palette can be
// widened later, but a colour already used across three rooms is work to take
// back out. `--mode fega` on the command line, or M in any editor, says
// otherwise.
DEFAULT_MODE :: ne.Palette_Mode.BEGA

// A blank picture in a mode, seeded with whatever palette that mode seeds.
// Every editor and every `new` command goes through here, so a file cannot be
// created in one place with a palette a different place would not have given it.
new_data :: proc(name: string, w, h, frames: i32, mode := DEFAULT_MODE) -> ne.Sprite_Data {
	d := ne.sprite_data_new(name, w, h, frames)
	ne.sprite_data_set_mode(&d, mode)
	return d
}

Canvas :: struct {
	view:   ui.View,
	ink:    rl.Color, // the colour being painted with, not a slot: the strip
	                  // offers the mode's gamut, and a colour only takes a
	                  // palette slot once it is actually put on the picture
	grid:   bool,
	full:   bool, // the palette ran out of names. The editor says so; see canvas_slot_for
	dither: Dither, // two tones in a pattern, which in bEGA is how you shade. See dither.odin
	brush:  Brush,
	swatch: f32, // how big the palette squares are drawn. Remembered between runs

	// The art is uploaded to the GPU once and re-uploaded when it changes.
	// A backdrop is 320x200, which is sixty-four thousand cells: drawing
	// those one rectangle at a time is fine for a hat and hopeless for a
	// room.
	tex:    rl.Texture2D,
	pixels: []rl.Color,
	stale:  bool,
	shown:  i32, // which frame the texture currently holds

	// A marquee, for copy and paste. Shift-drag to draw one.
	sel:      [4]i32, // x, y, w, h in art pixels
	has_sel:  bool,
	dragging: bool,
	drag_from: [2]i32,
}

// The selection, or the whole frame when there isn't one — so Ctrl+C with
// nothing marked copies everything, which is what people expect.
canvas_selection :: proc(c: ^Canvas, d: ^ne.Sprite_Data) -> [4]i32 {
	return c.sel if c.has_sel else [4]i32{0, 0, d.w, d.h}
}

canvas_select_all :: proc(c: ^Canvas, d: ^ne.Sprite_Data) {
	c.sel = {0, 0, d.w, d.h}
	c.has_sel = true
}

canvas_destroy :: proc(c: ^Canvas) {
	if c.tex.id != 0 do rl.UnloadTexture(c.tex)
	delete(c.pixels)
	c^ = {}
}

// Rebuilds the GPU copy of one frame, if it has changed under us.
@(private = "file")
canvas_upload :: proc(c: ^Canvas, d: ^ne.Sprite_Data, frame: i32) {
	need := int(d.w * d.h)
	if len(c.pixels) != need {
		delete(c.pixels)
		c.pixels = make([]rl.Color, need)
		if c.tex.id != 0 do rl.UnloadTexture(c.tex)
		c.tex = {}
	}
	if c.tex.id == 0 {
		img := rl.GenImageColor(d.w, d.h, rl.BLANK)
		defer rl.UnloadImage(img)
		c.tex = rl.LoadTextureFromImage(img)
		rl.SetTextureFilter(c.tex, .POINT)
		c.stale = true
	}
	if !c.stale && c.shown == frame do return

	for y in 0 ..< d.h {
		for x in 0 ..< d.w {
			idx := int(ne.sprite_data_at(d, frame, x, y)^)
			c.pixels[int(y * d.w + x)] = d.palette[idx].color if idx < len(d.palette) else rl.BLANK
		}
	}
	rl.UpdateTexture(c.tex, raw_data(c.pixels))
	c.stale = false
	c.shown = frame
}

// Fills in whatever hasn't been set yet: a colour to paint with, and a view
// that fits the art in the space available.
canvas_ready :: proc(c: ^Canvas, d: ^ne.Sprite_Data, area: rl.Rectangle) {
	if c.brush.size == 0 do c.brush.size = 1 // one pixel, which is what pixel art mostly wants
	if c.ink.a == 0 {
		buf: [64]rl.Color
		swatches := ne.palette_swatches(d.mode, &buf)
		// Something visible on whatever the backdrop is, rather than slot one,
		// which in bEGA is black and looks like nothing happening.
		c.ink = swatches[len(swatches) - 1] if len(swatches) > 0 else rl.WHITE
	}
	if c.view.zoom == 0 do c.view = ui.fit_view({f32(d.w), f32(d.h)}, area)
}

// How big the palette squares are drawn.
//
// Remembered between runs, because it is not a preference about the picture,
// it is a preference about the person looking at it — and somebody who needs
// bigger swatches needs them every time, not once per window.
SWATCH_MIN :: f32(12)
SWATCH_MAX :: f32(72)
SWATCH_DEFAULT :: f32(24)

canvas_swatch :: proc(c: ^Canvas) -> f32 {
	if c.swatch <= 0 do c.swatch = clamp(ui.setting_num("swatch", SWATCH_DEFAULT), SWATCH_MIN, SWATCH_MAX)
	return c.swatch
}

canvas_swatch_by :: proc(c: ^Canvas, by: f32) {
	c.swatch = clamp(canvas_swatch(c) + by, SWATCH_MIN, SWATCH_MAX)
	ui.setting_set_num("swatch", c.swatch)
}

// The palette slot holding this colour, taking a new one if it has to.
//
// Fails when the picture has more colours than there are characters to name
// them with. That limit is the whole reason VGA stops well short of 256: two
// slots sharing a name is a corrupted picture and you cannot tell from looking
// at the file which edit did it, so running out has to be refused here, loudly,
// rather than discovered later.
canvas_slot_for :: proc(d: ^ne.Sprite_Data, col: rl.Color) -> (u8, bool) {
	if col.a == 0 do return 0, true
	if slot, have := ne.sprite_data_slot_of(d, col); have do return slot, true
	if len(d.palette) - 1 >= ne.PALETTE_MAX do return 0, false
	append(&d.palette, ne.Palette_Entry{palette_char(len(d.palette) - 1), col})
	return u8(len(d.palette) - 1), true
}

// Left paints, right rubs out, shift-drag marks a rectangle. True if the art
// actually changed — a selection is not a change.
canvas_paint :: proc(c: ^Canvas, d: ^ne.Sprite_Data, frame: i32, area: rl.Rectangle) -> (changed: bool) {
	// The canvas runs right up to the divider, so the pixels either side of it
	// belong to the divider and not to the picture. Without this, reaching for
	// the handle paints.
	if ui.split_hot() {
		c.dragging = false
		return false
	}
	inside := rl.CheckCollisionPointRec(ui.mouse(), area)
	if inside do ui.pan_and_zoom(&c.view)

	p := ui.to_content(c.view, ui.mouse())
	here := [2]i32{i32(p.x), i32(p.y)}

	// Marquee.
	if ui.shift_down() {
		if inside && ui.mouse_pressed(.LEFT) {
			c.dragging = true
			c.drag_from = here
		}
		if c.dragging {
			x0, x1 := min(c.drag_from.x, here.x), max(c.drag_from.x, here.x)
			y0, y1 := min(c.drag_from.y, here.y), max(c.drag_from.y, here.y)
			x0, y0 = max(x0, 0), max(y0, 0)
			x1, y1 = min(x1, d.w - 1), min(y1, d.h - 1)
			if x1 >= x0 && y1 >= y0 {
				c.sel = {x0, y0, x1 - x0 + 1, y1 - y0 + 1}
				c.has_sel = true
			}
		}
		if ui.mouse_released(.LEFT) do c.dragging = false
		return false
	}
	c.dragging = false

	if !inside do return false
	paint := ui.mouse_down(.LEFT)
	erase := ui.mouse_down(.RIGHT)
	if !paint && !erase do return false
	if p.x < 0 || p.y < 0 do return false

	// The tone is worked out once for the stroke, but which of its two colours
	// each pixel gets is worked out per pixel, from where that pixel is — so a
	// wall shaded in six passes comes out as one wall.
	lo, hi, ratio := dither_tones(&c.dither, c.ink, d.ramps[:])

	buf: [(BRUSH_MAX * 2 + 1) * (BRUSH_MAX * 2 + 1)][2]i32
	for off in brush_offsets(c.brush, &buf) {
		at := here + off
		cell := ne.sprite_data_at(d, frame, at.x, at.y)
		if cell == nil do continue

		want := u8(0)
		if paint {
			col := c.ink
			if c.dither.on do col = dither_pick(lo, hi, ratio, c.dither.pattern, at.x, at.y)
			slot, room := canvas_slot_for(d, col)
			if !room {
				c.full = true
				continue
			}
			want = slot
		}
		if cell^ == want do continue
		cell^ = want
		changed = true
	}
	if changed do c.stale = true
	return
}

// True on the frame a brush stroke or a marquee drag begins — the moment to
// take an undo snapshot, so a whole stroke is one step.
canvas_stroke_started :: proc(c: ^Canvas, area: rl.Rectangle) -> bool {
	if ui.shift_down() do return false
	if !rl.CheckCollisionPointRec(ui.mouse(), area) do return false
	return ui.mouse_pressed(.LEFT) || ui.mouse_pressed(.RIGHT)
}

// The art, on a checkerboard so transparent reads as transparent.
canvas_draw :: proc(c: ^Canvas, d: ^ne.Sprite_Data, frame: i32, area: rl.Rectangle) {
	rl.BeginScissorMode(i32(area.x), i32(area.y), i32(area.width), i32(area.height))
	defer rl.EndScissorMode()
	canvas_upload(c, d, frame)

	tl := ui.to_screen(c.view, {0, 0})
	whole := rl.Rectangle{tl.x, tl.y, f32(d.w) * c.view.zoom, f32(d.h) * c.view.zoom}

	// Checkerboard behind, so transparent reads as transparent — but only
	// while the squares are big enough to see. Zoomed out it is one flat
	// colour, which is both faster and less of a headache to look at.
	if c.view.zoom >= 4 {
		size := c.view.zoom
		x0 := max(i32((area.x - tl.x) / size), 0)
		y0 := max(i32((area.y - tl.y) / size), 0)
		x1 := min(i32((area.x + area.width - tl.x) / size) + 1, d.w)
		y1 := min(i32((area.y + area.height - tl.y) / size) + 1, d.h)
		for y in y0 ..< y1 {
			for x in x0 ..< x1 {
				at := ui.to_screen(c.view, {f32(x), f32(y)})
				shade := rl.Color{52, 52, 60, 255} if (x + y) % 2 == 0 else rl.Color{44, 44, 52, 255}
				rl.DrawRectangleV(at, {size, size}, shade)
			}
		}
	} else {
		rl.DrawRectangleRec(whole, {48, 48, 56, 255})
	}

	rl.DrawTexturePro(c.tex, {0, 0, f32(d.w), f32(d.h)}, whole, 0, 0, rl.WHITE)

	if c.grid && c.view.zoom >= 6 {
		for x in 0 ..= d.w {
			rl.DrawLineV(ui.to_screen(c.view, {f32(x), 0}), ui.to_screen(c.view, {f32(x), f32(d.h)}), {255, 255, 255, 30})
		}
		for y in 0 ..= d.h {
			rl.DrawLineV(ui.to_screen(c.view, {0, f32(y)}), ui.to_screen(c.view, {f32(d.w), f32(y)}), {255, 255, 255, 30})
		}
	}
	rl.DrawRectangleLinesEx(whole, 1, ui.EDGE)

	// The marquee, as a dashed box that crawls a little so it reads as a
	// selection and not as part of the art.
	if c.has_sel {
		r := rl.Rectangle {
			tl.x + f32(c.sel[0]) * c.view.zoom,
			tl.y + f32(c.sel[1]) * c.view.zoom,
			f32(c.sel[2]) * c.view.zoom,
			f32(c.sel[3]) * c.view.zoom,
		}
		phase := i32(ui.now() * 8)
		for step in 0 ..< i32(r.width / 4) + 1 {
			if (step + phase) % 2 != 0 do continue
			x := r.x + f32(step) * 4
			rl.DrawRectangleRec({x, r.y - 1, 3, 1}, ui.GOLD)
			rl.DrawRectangleRec({x, r.y + r.height, 3, 1}, ui.GOLD)
		}
		for step in 0 ..< i32(r.height / 4) + 1 {
			if (step + phase) % 2 != 0 do continue
			y := r.y + f32(step) * 4
			rl.DrawRectangleRec({r.x - 1, y, 1, 3}, ui.GOLD)
			rl.DrawRectangleRec({r.x + r.width, y, 1, 3}, ui.GOLD)
		}
	}
}

// The colours on offer, as a block of swatches. Returns the height it used.
//
// What is on offer is the *mode's* gamut — sixteen in bEGA, sixty-four in fEGA
// — and not the colours the file happens to contain, which would mean you could
// only ever paint with a colour already in the picture. After the gamut come any
// colours the file uses that the mode does not allow, so a picture drawn before
// there were modes can still be worked on rather than being half unreachable.
// Those are drawn with a cross through them, because they are going to have to
// go before the picture is finished.
canvas_palette :: proc(c: ^Canvas, d: ^ne.Sprite_Data, x, y, width: f32) -> f32 {
	// A bEGA strip is sixteen swatches and wants to be big enough to judge a
	// colour by; a fEGA strip is sixty-four and has to fit. Either way the
	// person looking decides in the end — shift with + and - resizes these,
	// and it is remembered between runs.
	sw := canvas_swatch(c) if d.mode != .FEGA else max(canvas_swatch(c) * 0.66, 8)
	buf: [64]rl.Color
	swatches := ne.palette_swatches(d.mode, &buf)

	shown := make([dynamic]rl.Color, 0, len(swatches) + 8, context.temp_allocator)
	append(&shown, ..swatches)
	legal := len(shown)
	for p, i in d.palette {
		if i == 0 do continue
		if ne.palette_mode_allows(d.mode, p.color) do continue
		already := false
		for have in shown do if have == p.color do already = true
		if !already do append(&shown, p.color)
	}

	per_row := max(int(width / (sw + 2)), 1)
	for col, i in shown {
		r := rl.Rectangle {
			x + f32(i % per_row) * (sw + 2),
			y + f32(i / per_row) * (sw + 2),
			sw,
			sw,
		}
		rl.DrawRectangleRec(r, col)
		picked := col == c.ink
		rl.DrawRectangleLinesEx(r, 2 if picked else 1, ui.GOLD if picked else ui.EDGE)
		if i >= legal {
			rl.DrawLineEx({r.x, r.y}, {r.x + r.width, r.y + r.height}, 1, ui.GOLD)
		}
		if rl.CheckCollisionPointRec(ui.mouse(), r) && ui.mouse_pressed(.LEFT) do c.ink = col
	}
	rows := f32((len(shown) - 1) / per_row + 1)
	return rows * (sw + 2)
}

// What to call the colour being painted with, for a status line. In bEGA a
// colour has a name a person drawing is actually thinking in — "brown", not
// "#AA5500".
canvas_ink_name :: proc(c: ^Canvas, d: ^ne.Sprite_Data) -> string {
	if d.mode == .BEGA {
		for col, i in ne.BEGA do if col == c.ink do return ne.BEGA_NAMES[i]
	}
	if idx, ok := ne.ega_index(c.ink); ok && d.mode == .FEGA {
		return fmt.tprintf("ega %v", idx)
	}
	return fmt.tprintf("%02X%02X%02X", c.ink.r, c.ink.g, c.ink.b)
}

// Adds a frame to a sprite, copying the one given. Returns the new count.
canvas_add_frame :: proc(d: ^ne.Sprite_Data, copy_of: i32) -> i32 {
	size := int(d.w * d.h)
	start := int(copy_of) * size
	scratch := make([]u8, size, context.temp_allocator)
	if start + size <= len(d.pixels) do copy(scratch, d.pixels[start:start + size])
	append(&d.pixels, ..scratch)
	d.frames += 1
	// The copy holds as long as the frame it was copied from.
	if hold := ne.sprite_data_hold(d, copy_of); hold != 1 do ne.sprite_data_set_hold(d, d.frames - 1, hold)
	return d.frames
}

// Drops a frame, unless it's the only one left.
canvas_remove_frame :: proc(d: ^ne.Sprite_Data, frame: i32) -> bool {
	if d.frames <= 1 do return false
	size := int(d.w * d.h)
	start := int(frame) * size
	if start + size > len(d.pixels) do return false
	copy(d.pixels[start:], d.pixels[start + size:])
	resize(&d.pixels, len(d.pixels) - size)
	d.frames -= 1
	// Its hold goes with it, so the frames after it keep theirs.
	if int(frame) < len(d.holds) do ordered_remove(&d.holds, int(frame))
	return true
}

// Characters for palette slots in a file. Forwards to the engine's one list,
// so the editors and the loader can never disagree about what a slot is
// called — they did once, in two copies of the same string.
palette_char :: proc(index: int) -> u8 {
	return ne.palette_char(index)
}
