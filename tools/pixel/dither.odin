// Dithering: making sixteen colours look like several hundred.
//
// This is not an effect. In bEGA it is the only way to shade anything, because
// there is usually no darker version of the colour you want — there is brown,
// and then there is black, and nothing in between. Two colours in a pattern,
// small enough that the eye stops resolving it, reads as one colour that the
// hardware cannot make. Sixteen colours taken in pairs at a handful of ratios
// is a few hundred apparent tones, and that is the whole trick of the era.
//
// Two ways to reach one:
//
//   a pair    two colours you chose, and how much of the second
//   a ramp    a material and a light level, which chooses both tones and the
//             ratio for you. See Ramp in nengine/palette.odin
//
// Either way what lands in the file is ordinary pixels. Nothing here is stored
// as "a dither"; the game has no idea, and a picture drawn this way can be
// edited pixel by pixel afterwards like any other.
package pixel

import ne "../../"
import ui "../ui"
import "core:fmt"
import rl "vendor:raylib"

Pattern :: enum {
	Mixed, // the default, and the zero value, for the reason below
	Bayer2,
	Bayer4,
	Bayer8,
	Noise,
}

// Mixed is the default because pure Bayer over a wide soft gradient lays down
// visible rings: the ordered matrix is regular enough to become a pattern of its
// own at the exact scale a sky or a lamp's halo works at.
//
// The fix is to jitter each threshold *within its own band* rather than to
// average the ordered value with noise. A band is 1/64 wide, the noise moves the
// threshold somewhere inside it, and the ordering is untouched — so the rings go
// and the even spread stays.
//
// Averaging the two instead, which is the obvious thing and what a note in
// lessons.md used to recommend, is wrong, and quietly: the mean of two uniform
// distributions is not uniform, it bunches in the middle. At sixty-forty,
// asking for a quarter light gives you an eighth. Every light level would lie,
// most visibly in exactly the dim shading this is for. Measured, not guessed:
// the jittered version is exact to four decimal places at every ratio and still
// puts precisely thirty-two pixels in every eight-by-eight tile at half light,
// where pure noise swings between twenty-two and forty-six.

// Bayer matrices, as thresholds. The point of an ordered matrix is that the
// pixels it turns on are spread as evenly as possible at every ratio, so a
// half-and-half mix looks like a tone rather than like stripes.
BAYER2 := [4]f32{0, 2, 3, 1}

BAYER4 := [16]f32 {
	0,  8,  2,  10,
	12, 4,  14, 6,
	3,  11, 1,  9,
	15, 7,  13, 5,
}

BAYER8 := [64]f32 {
	0,  32, 8,  40, 2,  34, 10, 42,
	48, 16, 56, 24, 50, 18, 58, 26,
	12, 44, 4,  36, 14, 46, 6,  38,
	60, 28, 52, 20, 62, 30, 54, 22,
	3,  35, 11, 43, 1,  33, 9,  41,
	51, 19, 59, 27, 49, 17, 57, 25,
	15, 47, 7,  39, 13, 45, 5,  37,
	63, 31, 55, 23, 61, 29, 53, 21,
}

// The threshold at one place in the picture, 0 to just under 1.
//
// Keyed on where the pixel *is*, never on where the stroke started. That is
// what makes two strokes over the same ground line up instead of showing a
// seam, and it is why you can shade a wall in six passes over ten minutes and
// have it come out as one wall.
dither_threshold :: proc(p: Pattern, x, y: i32) -> f32 {
	ordered :: proc(m: []f32, n, x, y: i32) -> f32 {
		return (m[int(wrap(y, n) * n + wrap(x, n))] + 0.5) / f32(n * n)
	}
	switch p {
	case .Bayer2:
		return ordered(BAYER2[:], 2, x, y)
	case .Bayer4:
		return ordered(BAYER4[:], 4, x, y)
	case .Bayer8:
		return ordered(BAYER8[:], 8, x, y)
	case .Noise:
		return hash01(x, y)
	case .Mixed:
		return (BAYER8[int(wrap(y, 8) * 8 + wrap(x, 8))] + hash01(x, y)) / 64
	}
	return 0.5
}

@(private = "file")
wrap :: proc(v, n: i32) -> i32 {
	return ((v % n) + n) % n // negative coordinates exist; -1 % 8 is not 7
}

// A cheap deterministic hash. Deterministic matters: the same picture has to
// dither the same way every time it is opened, or undo and redo would not
// agree with each other.
@(private = "file")
hash01 :: proc(x, y: i32) -> f32 {
	h := u32(x) * 0x9E37_79B1 + u32(y) * 0x85EB_CA77
	h ~= h >> 15
	h *= 0x2545_F491
	h ~= h >> 13
	return f32(h & 0xFF_FFFF) / f32(0x100_0000)
}

// --- The brush ---

Source :: enum {
	Pair, // two colours, chosen by hand
	Ramp, // a material and a light level
}

Dither :: struct {
	on:      bool,
	pattern: Pattern,
	source:  Source,

	// Source .Pair: the second colour, and how much of it there is. The first
	// is whatever the canvas is painting with.
	other:   rl.Color,
	ratio:   f32,

	// Source .Ramp: which material, and how much light is falling on it. Light
	// is clamped to 1.0 by ramp_at, and the clamp is not negotiable — above
	// 1.0 every tone lands on the top step and the form does not dim, it
	// disappears.
	ramp:    string,
	light:   f32,
}

// The two tones the brush is currently between, and how much of the brighter.
// A ratio of 0 means there is nothing to dither and one colour will do.
dither_tones :: proc(
	dth: ^Dither,
	ink: rl.Color,
	ramps: []ne.Ramp,
) -> (lo, hi: rl.Color, ratio: f32) {
	if dth.source == .Ramp {
		if r := ne.ramp_named(ramps, dth.ramp); r != nil do return ne.ramp_at(r.steps[:], dth.light)
		return ink, ink, 0 // the named material is gone; paint flat rather than nothing
	}
	return ink, dth.other, clamp(dth.ratio, 0, 1)
}

// Which of the two tones this pixel gets.
dither_pick :: proc(lo, hi: rl.Color, ratio: f32, p: Pattern, x, y: i32) -> rl.Color {
	if ratio <= 0 do return lo
	if ratio >= 1 do return hi
	return hi if dither_threshold(p, x, y) < ratio else lo
}

// What the brush would look like from across the room. For a swatch and a
// status line: a person needs to know that eight parts black to two parts
// white is about a fifth-lit grey, and needs to know it before painting a
// thousand pixels with it.
dither_perceived :: proc(dth: ^Dither, ink: rl.Color, ramps: []ne.Ramp) -> rl.Color {
	lo, hi, ratio := dither_tones(dth, ink, ramps)
	return ne.palette_blend(lo, hi, ratio)
}

pattern_name :: proc(p: Pattern) -> string {
	switch p {
	case .Mixed:
		return "mixed"
	case .Bayer2:
		return "bayer2"
	case .Bayer4:
		return "bayer4"
	case .Bayer8:
		return "bayer8"
	case .Noise:
		return "noise"
	}
	return "mixed"
}

// --- The brush, as keys and a panel ---
//
// Shared by every editor in nart, because shading a hat and shading a wall are
// the same act and should not have two sets of keys. The keys avoided are the
// ones the character editor already owns — A, D, G, N, P, R and the brackets —
// so these work the same in all three.
//
//   B        the dither on and off
//   T        which pattern
//   M        the next material; shift+M back to a plain pair
//   , .      less light, more light  (shift: bigger steps)
//   + -      a bigger or smaller brush
//   O        a round brush or a square one
//   shift +- bigger or smaller palette swatches, remembered between runs
//
// Changing the mode is deliberately not a key. It re-gamuts a whole picture,
// and that is not a thing anybody should be able to do by leaning on the
// keyboard: it belongs on the command line, where it can be read back before
// it happens.
canvas_brush_keys :: proc(c: ^Canvas, d: ^ne.Sprite_Data, status: ^ui.Status) {
	dth := &c.dither

	if ui.key_pressed(.B) && !ui.ctrl_down() { // ^B is back to the files
		dither_toggle(dth)
		ui.say(status, "dither %v", "on" if dth.on else "off")
	}

	if ui.key_pressed(.T) {
		dither_next_pattern(dth)
		ui.say(status, "pattern %v", pattern_name(dth.pattern))
	}

	if ui.key_pressed(.M) {
		if ui.shift_down() {
			dth.source = .Pair
			ui.say(status, "a pair of colours")
		} else if len(d.ramps) == 0 {
			ui.say(status, "no materials in this file — nart ramp adds one")
		} else {
			at := -1
			for r, i in d.ramps do if r.name == dth.ramp do at = i
			next := d.ramps[(at + 1) % len(d.ramps)]
			dth.ramp, dth.source = next.name, .Ramp
			if dth.light == 0 do dth.light = 1
			ui.say(status, "material %v", dth.ramp)
		}
	}

	// + and - are the brush; with shift they are the palette swatches, which
	// is a setting about the person rather than about the picture. `=` is the
	// unshifted key that has + printed on it, and the numpad pair are the
	// same thing for anyone who reaches for those instead.
	up := ui.key_pressed(.EQUAL) || ui.key_pressed(.KP_ADD)
	down := ui.key_pressed(.MINUS) || ui.key_pressed(.KP_SUBTRACT)
	if up || down {
		if ui.shift_down() {
			canvas_swatch_by(c, 4 if up else -4)
			ui.say(status, "swatches %v px", int(canvas_swatch(c)))
		} else {
			c.brush.size = clamp(c.brush.size + (1 if up else -1), 1, BRUSH_MAX)
			ui.say(status, "brush %v", c.brush.size)
		}
	}

	if ui.key_pressed(.O) {
		c.brush.square = !c.brush.square
		ui.say(status, "%v brush", "square" if c.brush.square else "round")
	}

	step := f32(0.25) if ui.shift_down() else f32(0.05)
	amount := &dth.ratio if dth.source == .Pair else &dth.light
	if ui.key_pressed(.COMMA) || ui.key_pressed(.PERIOD) {
		if ui.key_pressed(.COMMA) do amount^ -= step
		if ui.key_pressed(.PERIOD) do amount^ += step
		// Clamped to 1.0 at the top, always. Above 1.0 every tone lands on the
		// brightest step and the form does not dim, it disappears.
		amount^ = clamp(amount^, 0, 1)
		if dth.source == .Pair {
			ui.say(status, "%v per cent", int(amount^ * 100 + 0.5))
		} else {
			ui.say(status, "%v at %v per cent light", dth.ramp, int(amount^ * 100 + 0.5))
		}
	}
}

// The brush and dither keys, for an editor's footer: every editor that paints
// takes them, so every footer says them, from this one string.
BRUSH_KEYS :: "B dither  T pattern  M material  , . mix/light  + - brush  O round/square  shift+- swatches"

// The dither on or off. The B key and the panel's button both come here.
dither_toggle :: proc(dth: ^Dither) {
	dth.on = !dth.on
	// A brush switched on for the first time has no second tone and would
	// paint flat, which looks like it not working. Start it somewhere useful:
	// the darkest thing in the gamut, since shading is what this is mostly for.
	if dth.on && dth.other.a == 0 && dth.source == .Pair {
		dth.other = ne.BEGA[0]
		if dth.ratio == 0 do dth.ratio = 0.5
	}
}

dither_next_pattern :: proc(dth: ^Dither) {
	dth.pattern = Pattern((int(dth.pattern) + 1) % len(Pattern))
}

// The brush: how big it is, what shape, and the footprint drawn actual size so
// you can see what one click will cover. Returns the height it used.
//
// The shape is a button as well as a key, because a person who has just turned
// the swatches up to seventy pixels is not looking for a keyboard shortcut.
canvas_brush_panel :: proc(c: ^Canvas, x, y, width: f32) -> f32 {
	cy := y
	ui.label(i32(x), i32(cy), fmt.tprintf("brush %v  (+ -)", c.brush.size), ui.DIM, ui.SMALL)
	cy += 18

	if ui.button({x, cy, 86, 22}, "round" if !c.brush.square else "square") {
		c.brush.square = !c.brush.square
	}

	// The footprint, beside the button, blown up to fill a fixed square rather
	// than drawn one screen pixel per art pixel. A brush of one would be a
	// single dot you could not see, and a brush of sixteen is thirty-one
	// across and would not fit — so the shape is scaled to the box and stays
	// the same size on screen whatever the brush is doing.
	PREVIEW :: f32(40)
	buf: [(BRUSH_MAX * 2 + 1) * (BRUSH_MAX * 2 + 1)][2]i32
	offs := brush_offsets(c.brush, &buf)
	span := f32(clamp(c.brush.size, 1, BRUSH_MAX) * 2 - 1)
	room := min(PREVIEW, width - 106)
	dot := max(room / max(span, 1), 1)
	ox := x + 100 + (PREVIEW - span * dot) / 2
	oy := cy + (PREVIEW - span * dot) / 2
	for off in offs {
		rl.DrawRectangleRec(
			{ox + (f32(off.x) + (span - 1) / 2) * dot, oy + (f32(off.y) + (span - 1) / 2) * dot, dot, dot},
			ui.INK,
		)
	}
	cy += PREVIEW + 6

	return cy - y
}

// The brush, drawn: what it is mixing, and what that will look like from across
// the room. Returns the height it used.
//
// The big swatch is the point of the panel. Two colours and a ratio are three
// numbers; what a person needs to know before covering a wall in them is the
// one colour those three add up to, and no amount of staring at a ratio tells
// you that.
canvas_dither_panel :: proc(c: ^Canvas, d: ^ne.Sprite_Data, x, y, width: f32) -> f32 {
	dth := &c.dither
	top := y
	cy := y // a parameter cannot be assigned to, so walk a local down the panel

	ui.label(i32(x), i32(cy), "dither  (B)", ui.DIM if !dth.on else ui.GOLD, ui.SMALL)
	cy += 18

	// A button as well as a key, like the brush's shape: somebody looking at
	// the palette is not looking for a keyboard shortcut.
	if ui.button({x, cy, 86, 22}, "dither on" if dth.on else "dither off", dth.on) do dither_toggle(dth)
	if !dth.on {
		ui.label(i32(x + 96), i32(cy + 4), "flat colour", ui.DIM, ui.SMALL)
		return cy + 22 + 8 - top
	}
	if ui.button({x + 92, cy, 86, 22}, pattern_name(dth.pattern)) do dither_next_pattern(dth)
	cy += 22 + 8

	lo, hi, ratio := dither_tones(dth, c.ink, d.ramps[:])
	seen := ne.palette_blend(lo, hi, ratio)

	// The two tones, then what they come to.
	SW :: f32(22)
	rl.DrawRectangleRec({x, cy, SW, SW}, lo)
	rl.DrawRectangleLinesEx({x, cy, SW, SW}, 1, ui.EDGE)
	rl.DrawRectangleRec({x + SW + 3, cy, SW, SW}, hi)
	rl.DrawRectangleLinesEx({x + SW + 3, cy, SW, SW}, 1, ui.EDGE)
	ui.label(i32(x + SW * 2 + 12), i32(cy + 4), "=", ui.DIM, ui.SMALL)

	// Drawn as the actual pattern rather than as the flat average, because at
	// this size the eye does the mixing itself and that is the honest preview.
	big := rl.Rectangle{x + SW * 2 + 26, cy, width - (SW * 2 + 26), SW}
	for py in 0 ..< i32(big.height) {
		for pxl in 0 ..< i32(big.width) {
			col := dither_pick(lo, hi, ratio, dth.pattern, pxl, py)
			rl.DrawPixel(i32(big.x) + pxl, i32(big.y) + py, col)
		}
	}
	rl.DrawRectangleLinesEx(big, 1, ui.EDGE)
	cy += SW + 6

	if dth.source == .Pair {
		ui.label(i32(x), i32(cy), fmt.tprintf("mix %v%%   , .", int(ratio * 100 + 0.5)), ui.DIM, ui.SMALL)
	} else {
		ui.label(
			i32(x),
			i32(cy),
			fmt.tprintf("%v  light %v%%   , .", dth.ramp, int(dth.light * 100 + 0.5)),
			ui.DIM,
			ui.SMALL,
		)
	}
	cy += 16
	ui.label(i32(x), i32(cy), fmt.tprintf("reads as %02X%02X%02X", seen.r, seen.g, seen.b), ui.DIM, ui.SMALL)
	cy += 18

	return cy - top
}

// The mixer: what the colour being painted with makes when it is dithered
// against each of the others.
//
// This is the panel that turns "sixteen colours" into something you can use.
// Every swatch is a tone the hardware cannot produce, drawn as the pattern that
// produces it, and clicking one sets it as the brush's second colour. Without
// it a person has to hold several hundred combinations in their head and pick
// by guessing; with it they pick the green-brown they can see.
//
// Only for a pair. A material already knows its own tones.
canvas_mixer :: proc(c: ^Canvas, d: ^ne.Sprite_Data, x, y, width: f32) -> f32 {
	dth := &c.dither
	if !dth.on || dth.source != .Pair do return 0
	cy := y

	ui.label(i32(x), i32(cy), fmt.tprintf("mixed with  (%v%%)", int(dth.ratio * 100 + 0.5)), ui.DIM, ui.SMALL)
	cy += 18

	buf: [64]rl.Color
	swatches := ne.palette_swatches(d.mode, &buf)
	sw := canvas_swatch(c) if len(swatches) <= 16 else max(canvas_swatch(c) * 0.6, 8)
	per_row := max(int(width / (sw + 2)), 1)

	for col, i in swatches {
		r := rl.Rectangle{x + f32(i % per_row) * (sw + 2), cy + f32(i / per_row) * (sw + 2), sw, sw}
		// Drawn as the real pattern, not as the flat average, because at this
		// size the eye does the mixing and that is the honest preview.
		for py in 0 ..< i32(r.height) {
			for pxl in 0 ..< i32(r.width) {
				rl.DrawPixel(
					i32(r.x) + pxl,
					i32(r.y) + py,
					dither_pick(c.ink, col, dth.ratio, dth.pattern, i32(r.x) + pxl, i32(r.y) + py),
				)
			}
		}
		picked := col == dth.other
		rl.DrawRectangleLinesEx(r, 2 if picked else 1, ui.GOLD if picked else ui.EDGE)
		if rl.CheckCollisionPointRec(ui.mouse(), r) && ui.mouse_pressed(.LEFT) do dth.other = col
	}
	cy += f32((len(swatches) - 1) / per_row + 1) * (sw + 2)
	return cy - y
}

// A line for the top bar: which mode the picture is in, and whether anything in
// it is out of gamut. An offending colour is not an error — the file is the
// truth — but it is something the person drawing should be able to see without
// going looking.
canvas_mode_line :: proc(d: ^ne.Sprite_Data) -> string {
	bad: [dynamic]u8
	defer delete(bad)
	ne.sprite_data_offenders(d, &bad)
	colours := len(d.palette) - 1
	if len(bad) > 0 {
		return fmt.tprintf("%v  %v colours, %v off-gamut", ne.palette_mode_name(d.mode), colours, len(bad))
	}
	return fmt.tprintf("%v  %v colours", ne.palette_mode_name(d.mode), colours)
}
