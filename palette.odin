package nengine

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

// Which colours a picture is allowed, and which exact ones they are.
//
// A mode is a constraint on *authoring*, not a rendering mode. The file still
// stores plain RGBA and the game still draws it without knowing or caring, so
// nothing in here costs a frame. What a mode does is stop a picture quietly
// acquiring a colour the rest of the game cannot use — which is the failure
// you only notice three rooms later, when one lamp is the wrong yellow and
// you cannot say which afternoon it happened.
//
// The modes, in order of how much they allow:
//
//   bEGA  the sixteen colours an EGA card came up in, and nothing else.
//         Backwards EGA: what you got before anybody reprogrammed the DAC.
//   fEGA  any of the sixty-four an EGA card can be made to produce.
//   VGA   six bits a channel, which is what a VGA DAC takes.
//
// VGA is the zero value, so a file that says nothing about its mode keeps
// working exactly as it did. Every file the tools write from now on says which
// mode it is, on a `mode` line, because the file is the truth.
Palette_Mode :: enum u8 {
	VGA,
	FEGA,
	BEGA,
}

// --- EGA ---

// EGA's DAC takes six bits, two for each channel, and they are not laid out
// the way you would guess: the order is rgbRGB, with the *high* bit of each
// channel in the low half. A channel is 0xAA for its high bit alone, 0x55 for
// its low bit alone, and 0xFF for both — four levels a channel, sixty-four
// colours.
//
// That layout is why EGA brown is index 20 and not 6. Six would be red and
// green both at two thirds, which is a dull olive; brown is red at two thirds
// with green at one third, and somebody had to spend a bit to say so.
ega_colour :: proc(index: u8) -> rl.Color {
	return {ega_channel(index, 2, 5), ega_channel(index, 1, 4), ega_channel(index, 0, 3), 255}
}

@(private = "file")
ega_channel :: proc(index: u8, high, low: u8) -> u8 {
	v := u8(0)
	if index & (1 << high) != 0 do v += 0xAA
	if index & (1 << low) != 0 do v += 0x55
	return v
}

// The DAC index that makes this colour, if any does.
ega_index :: proc(c: rl.Color) -> (u8, bool) {
	for i in u8(0) ..= 63 {
		e := ega_colour(i)
		if e.r == c.r && e.g == c.g && e.b == c.b do return i, true
	}
	return 0, false
}

// The sixteen an EGA card came up in, in colour-number order — so BEGA[6] is
// brown and BEGA[8] is dark grey, whatever the DAC indices underneath them
// say. Written out rather than generated because these are the sixteen the
// whole game is drawn in, and a table you can read is worth more here than
// one you have to run; `ega_colour` agreeing with it is a test.
BEGA := [16]rl.Color {
	{0x00, 0x00, 0x00, 255}, // 0  black
	{0x00, 0x00, 0xAA, 255}, // 1  blue
	{0x00, 0xAA, 0x00, 255}, // 2  green
	{0x00, 0xAA, 0xAA, 255}, // 3  cyan
	{0xAA, 0x00, 0x00, 255}, // 4  red
	{0xAA, 0x00, 0xAA, 255}, // 5  magenta
	{0xAA, 0x55, 0x00, 255}, // 6  brown
	{0xAA, 0xAA, 0xAA, 255}, // 7  light grey
	{0x55, 0x55, 0x55, 255}, // 8  dark grey
	{0x55, 0x55, 0xFF, 255}, // 9  bright blue
	{0x55, 0xFF, 0x55, 255}, // 10 bright green
	{0x55, 0xFF, 0xFF, 255}, // 11 bright cyan
	{0xFF, 0x55, 0x55, 255}, // 12 bright red
	{0xFF, 0x55, 0xFF, 255}, // 13 bright magenta
	{0xFF, 0xFF, 0x55, 255}, // 14 yellow
	{0xFF, 0xFF, 0xFF, 255}, // 15 white
}

// The DAC index of each of the sixteen, in the same order.
BEGA_INDICES := [16]u8{0, 1, 2, 3, 4, 5, 20, 7, 56, 57, 58, 59, 60, 61, 62, 63}

// What to call them in a tool, so a status line can say "brown" rather than
// "#AA5500", which is what the person drawing is thinking.
BEGA_NAMES := [16]string {
	"black",
	"blue",
	"green",
	"cyan",
	"red",
	"magenta",
	"brown",
	"light grey",
	"dark grey",
	"bright blue",
	"bright green",
	"bright cyan",
	"bright red",
	"bright magenta",
	"yellow",
	"white",
}

// All sixty-four, by DAC index, which is the order an artist scanning a swatch
// grid wants: the four levels of each channel march in a predictable block.
fega_palette :: proc() -> (all: [64]rl.Color) {
	for i in u8(0) ..= 63 do all[i] = ega_colour(i)
	return
}

// --- VGA ---

// A VGA DAC takes six bits a channel, so what looks like 0..255 is really
// 0..63 scaled up. Rounding both ways means a colour already on the grid comes
// back unchanged, which matters: snapping has to be idempotent or a file drifts
// a little every time it is saved.
vga_quantise :: proc(c: rl.Color) -> rl.Color {
	return {vga_level(c.r), vga_level(c.g), vga_level(c.b), c.a}
}

@(private = "file")
vga_level :: proc(v: u8) -> u8 {
	six := (u32(v) * 63 + 127) / 255
	return u8((six * 255 + 31) / 63)
}

// --- Modes ---

palette_mode_name :: proc(m: Palette_Mode) -> string {
	switch m {
	case .BEGA:
		return "bega"
	case .FEGA:
		return "fega"
	case .VGA:
		return "vga"
	}
	return "vga"
}

// Reads a `mode` line's word. Case is ignored and the pretty spellings people
// actually type are accepted, because "bEGA" is how it is written everywhere
// else and a tool that rejects it is being difficult for no reason.
palette_mode_from_name :: proc(s: string) -> (Palette_Mode, bool) {
	switch strings.to_lower(s, context.temp_allocator) {
	case "bega", "b-ega", "ega16":
		return .BEGA, true
	case "fega", "f-ega", "ega", "ega64":
		return .FEGA, true
	case "vga":
		return .VGA, true
	}
	return .VGA, false
}

// The colours a mode offers to paint with. bEGA and fEGA offer their whole
// gamut; VGA's gamut is 262144 colours, so what it offers is a starter set and
// the rest is picked by hand.
//
// Fills the caller's buffer rather than allocating, because this is called
// every frame by a palette strip that redraws itself.
palette_swatches :: proc(m: Palette_Mode, buf: ^[64]rl.Color) -> []rl.Color {
	switch m {
	case .BEGA:
		copy(buf[:16], BEGA[:])
		return buf[:16]
	case .FEGA:
		buf^ = fega_palette()
		return buf[:]
	case .VGA:
		for c, i in VGA_STARTER do buf[i] = vga_quantise(c)
		return buf[:len(VGA_STARTER)]
	}
	return buf[:0]
}

// Where a VGA picture starts from. Not a gamut and not a rule — just somewhere
// to begin, since picking thirty-two useful colours out of a quarter of a
// million by hand is nobody's idea of an afternoon. These are the colours the
// editors used to force into every file whether it wanted them or not.
VGA_STARTER := [32]rl.Color {
	{0, 0, 0, 255},
	{36, 36, 44, 255},
	{84, 84, 96, 255},
	{140, 140, 156, 255},
	{200, 200, 210, 255},
	{255, 255, 255, 255},
	{120, 40, 40, 255},
	{190, 60, 50, 255},
	{232, 110, 70, 255},
	{250, 170, 90, 255},
	{250, 220, 130, 255},
	{160, 120, 60, 255},
	{90, 60, 35, 255},
	{140, 96, 58, 255},
	{40, 90, 50, 255},
	{80, 160, 80, 255},
	{150, 210, 110, 255},
	{40, 80, 110, 255},
	{60, 130, 190, 255},
	{110, 180, 240, 255},
	{180, 220, 250, 255},
	{40, 40, 90, 255},
	{80, 70, 150, 255},
	{140, 110, 210, 255},
	{200, 120, 190, 255},
	{240, 170, 200, 255},
	{232, 140, 44, 255},
	{248, 176, 90, 255},
	{28, 26, 32, 255},
	{150, 30, 40, 255},
	{14, 20, 48, 255},
	{236, 226, 196, 255},
}

// Whether a mode permits this colour.
//
// Transparent is permitted everywhere, because slot 0 of every palette is
// transparent and that is the format, not a colour choice. Part-way alpha is
// permitted nowhere: none of these cards had any, and a sprite that half
// dissolves is a thing you did by accident.
palette_mode_allows :: proc(m: Palette_Mode, c: rl.Color) -> bool {
	if c.a == 0 do return true
	if c.a != 255 do return false
	switch m {
	case .BEGA:
		for b in BEGA do if b == c do return true
		return false
	case .FEGA:
		_, ok := ega_index(c)
		return ok
	case .VGA:
		return vga_quantise(c) == c
	}
	return false
}

// The nearest colour the mode does permit. Distance is measured in linear
// light, because sRGB numbers are perceptual and averaging or comparing them
// arithmetically gets dark tones wrong — and dark tones are where all the
// shading lives.
palette_mode_snap :: proc(m: Palette_Mode, c: rl.Color) -> rl.Color {
	if c.a == 0 do return {0, 0, 0, 0}
	if m == .VGA do return vga_quantise({c.r, c.g, c.b, 255})

	buf: [64]rl.Color
	want := linear_of(c)
	best, best_d := rl.Color{}, max(f32)
	for cand in palette_swatches(m, &buf) {
		have := linear_of(cand)
		dr, dg, db := want[0] - have[0], want[1] - have[1], want[2] - have[2]
		if d := dr * dr + dg * dg + db * db; d < best_d do best, best_d = cand, d
	}
	return best
}

// --- Colour maths ---

// What a dither of two colours actually looks like from across the room.
//
// `ratio` is how much of `b` there is, 0 to 1. The average is taken in linear
// light, which is the whole reason this proc exists: eight parts black to two
// parts white is not twenty per cent grey in sRGB numbers, and a mixer panel
// that says it is will send somebody chasing a tone that is not there.
palette_blend :: proc(a, b: rl.Color, ratio: f32) -> rl.Color {
	t := clamp(ratio, 0, 1)
	la, lb := linear_of(a), linear_of(b)
	return srgb_of({
		la[0] + (lb[0] - la[0]) * t,
		la[1] + (lb[1] - la[1]) * t,
		la[2] + (lb[2] - la[2]) * t,
	})
}

linear_of :: proc(c: rl.Color) -> [3]f32 {
	return {linear_channel(c.r), linear_channel(c.g), linear_channel(c.b)}
}

srgb_of :: proc(l: [3]f32) -> rl.Color {
	return {srgb_channel(l[0]), srgb_channel(l[1]), srgb_channel(l[2]), 255}
}

@(private = "file")
linear_channel :: proc(v: u8) -> f32 {
	x := f32(v) / 255
	return x / 12.92 if x <= 0.04045 else math.pow((x + 0.055) / 1.055, 2.4)
}

@(private = "file")
srgb_channel :: proc(x: f32) -> u8 {
	y := clamp(x, 0, 1)
	s := y * 12.92 if y <= 0.0031308 else 1.055 * math.pow(y, 1.0 / 2.4) - 0.055
	return u8(clamp(s * 255 + 0.5, 0, 255))
}

// --- Ramps, and what a light level picks out of one ---

// A material: the tones one surface goes through, darkest first.
//
// This is the other half of drawing in sixteen colours. You do not shade by
// choosing a darker colour, because in bEGA there usually isn't one — you
// choose a *ramp*, and a light level picks a place along it. Where that place
// falls between two steps, the two are dithered, and the eye reads the tone in
// between. Sixteen colours and four ramps is a few hundred apparent tones.
//
// Ramps are authoring data. The game never reads them: what it loads is the
// pixels they helped somebody choose. They live in the file anyway, because
// coming back to a picture in six months and knowing which four colours were
// meant to be the same canvas in different light is the difference between
// carrying on and starting again.
Ramp :: struct {
	name:  string,
	steps: [dynamic]rl.Color,
}

ramp_destroy :: proc(r: ^Ramp) {
	delete(r.name)
	delete(r.steps)
	r^ = {}
}

ramps_destroy :: proc(rs: ^[dynamic]Ramp) {
	for &r in rs do ramp_destroy(&r)
	delete(rs^)
	rs^ = nil
}

ramps_clone :: proc(rs: []Ramp) -> (out: [dynamic]Ramp) {
	for r in rs {
		fresh := Ramp{name = strings.clone(r.name)}
		append(&fresh.steps, ..r.steps[:])
		append(&out, fresh)
	}
	return
}

// The two tones a light level falls between, and how much of the brighter one
// there should be. A `ratio` of 0 is the darker step exactly, with nothing to
// dither.
//
// Light is clamped to 1.0, which is the rule that cost an afternoon: above 1.0
// every tone within reach of a bright light lands on the top step, so the form
// does not go dim, it goes *missing*. The clamp lives here so that no tool can
// forget it.
ramp_at :: proc(steps: []rl.Color, light: f32) -> (lo, hi: rl.Color, ratio: f32) {
	if len(steps) == 0 do return {}, {}, 0
	if len(steps) == 1 do return steps[0], steps[0], 0

	p := clamp(light, 0, 1) * f32(len(steps) - 1)
	i := int(p)
	if i >= len(steps) - 1 do return steps[len(steps) - 1], steps[len(steps) - 1], 0
	return steps[i], steps[i + 1], p - f32(i)
}

// What a light level looks like from across the room: the blend of the two
// tones it falls between. For a swatch, a status line, or judging a ramp
// before painting a thousand pixels with it.
ramp_blend :: proc(steps: []rl.Color, light: f32) -> rl.Color {
	lo, hi, ratio := ramp_at(steps, light)
	return palette_blend(lo, hi, ratio)
}

// --- Hex ---

// Ramps name their colours in hex, because a ramp has to survive the palette
// being renumbered — which happens every time a character is saved, since two
// poses can disagree about which character means which colour. A slot number
// would quietly come to mean something else; `AA5500` cannot.
colour_to_hex :: proc(c: rl.Color, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%02X%02X%02X", c.r, c.g, c.b, allocator = allocator)
}

colour_from_hex :: proc(s: string) -> (rl.Color, bool) {
	if len(s) != 6 do return {}, false
	v, ok := strconv.parse_u64_of_base(s, 16)
	if !ok do return {}, false
	return {u8(v >> 16), u8(v >> 8), u8(v), 255}, true
}

// --- Naming palette slots ---

// The characters a palette slot can be named with, and the only list of them.
// A row of pixels is a row of these, so they have to be readable, distinct at
// a glance, and never a space. '#' is fine in a row — see load_sprite_data on
// why a `#` there is not a comment.
//
// Past the end this gives '?', deliberately, rather than wrapping round: two
// slots sharing a name is a corrupted picture, and it is not obvious from
// looking at the file which edit did it. Whoever is writing the file has to
// notice and fail loudly. That is also the cap on how many colours a picture
// may have, which is why VGA stops well short of 256.
PALETTE_CHARS :: "#o+*=xX%&$@ABCDEFGHJKLMNPQRSTUVWZabcdefghijkmnpqrstuvwz0123456789<>[]{}()/\\|!?,;:~^"

palette_char :: proc(index: int) -> u8 {
	chars := PALETTE_CHARS
	return chars[index] if index >= 0 && index < len(chars) else u8('?')
}

// How many colours a picture can hold at all: one per naming character, plus
// the transparent slot, which is named but never counted as a colour.
PALETTE_MAX :: len(PALETTE_CHARS)

// --- Ramp lines ---
//
// `ramp canvas 000000 555555 AAAAAA FFFFFF` — a name, then the tones darkest
// first. Written by the tools, ignored by the game.

parse_ramp :: proc(words: []string) -> (r: Ramp, ok: bool) {
	if len(words) < 2 do return {}, false
	r.name = strings.clone(words[0])
	for w in words[1:] {
		if c, good := colour_from_hex(w); good do append(&r.steps, c)
	}
	if len(r.steps) == 0 {
		ramp_destroy(&r)
		return {}, false
	}
	return r, true
}

write_ramps :: proc(b: ^strings.Builder, ramps: []Ramp) {
	for r in ramps {
		if len(r.steps) == 0 do continue
		fmt.sbprintf(b, "ramp %v", r.name)
		for c in r.steps do fmt.sbprintf(b, " %v", colour_to_hex(c))
		strings.write_byte(b, '\n')
	}
}

// The ramp of this name, or nil.
ramp_named :: proc(ramps: []Ramp, name: string) -> ^Ramp {
	for &r in ramps {
		if r.name == name do return &r
	}
	return nil
}
