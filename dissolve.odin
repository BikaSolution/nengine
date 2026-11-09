package nengine

import rl "vendor:raylib"

// The Sierra dissolve: one painting turning into another a pixel at a time,
// in a fixed order, until every pixel has turned. No fade and no
// blend: at any moment each art pixel is wholly one painting or wholly the
// other, so what is on screen is always sixteen colours, dithered the way the
// EGA did it. The title screen uses it to bring the night down over its
// layers (menu.odin, `Menu.dusk_seconds`).
//
// The order is over the painting's own pixels — one texel per art pixel, the
// 320-wide grid — so a layer that drifts sideways carries its half-turned
// pixels with it and nothing shimmers. Every pixel turns exactly once:
// `dissolve_order` is a permutation of all of them — an ordered 4x4 dither's
// sixteen classes in turn, each class shuffled — and progress 1 is all of them.
//
// The arithmetic (the order, how many have turned, how far through a dusk)
// needs no window and is tested in dissolve_test.odin. `Dissolve` itself
// reads the two paintings back from the GPU and keeps a third, the one shown,
// which it updates as pixels turn.

// The dice for the order: the same every run, so the same pixel always turns
// at the same moment and a shot of the dusk half way is the same shot.
DISSOLVE_SEED :: u64(0x5EED_D05C)

// The ordered dither's 4x4 matrix (Bayer): the class a pixel is in by where
// it stands, 0 to 15. Class 0 turns first, then 8, then 2 and 10...
@(private)
BAYER4 := [4][4]u8 {
	{0, 8, 2, 10},
	{12, 4, 14, 6},
	{3, 11, 1, 9},
	{15, 7, 13, 5},
}

// The order the pixels of a w x h painting turn in: a permutation of
// 0 ..< w*h (pixel y*w + x), each pixel once. Ordered first and random
// second: the sixteen classes of a 4x4 ordered dither in turn, and within a
// class its pixels in a fixed shuffle (Fisher-Yates on splitmix64, the same
// for the same seed on every machine). So the turning is one pixel at a
// time, never a pattern at once, and yet at a quarter, a half, three
// quarters, the picture is a regular EGA dither of the two paintings, as a
// painter would have dithered a dusk, rather than static.
dissolve_order :: proc(w, h: int, seed: u64 = DISSOLVE_SEED, allocator := context.allocator) -> []i32 {
	n := max(w, 0) * max(h, 0)
	order := make([]i32, n, allocator)
	if n == 0 do return order
	// Count each class, then lay the pixels out class by class.
	starts: [17]int
	for y in 0 ..< h do for x in 0 ..< w do starts[int(BAYER4[y % 4][x % 4]) + 1] += 1
	for c in 1 ..= 16 do starts[c] += starts[c - 1]
	at := starts
	for y in 0 ..< h {
		for x in 0 ..< w {
			c := int(BAYER4[y % 4][x % 4])
			order[at[c]] = i32(y * w + x)
			at[c] += 1
		}
	}
	state := seed
	for c in 0 ..< 16 {
		class := order[starts[c]:starts[c + 1]]
		for i := len(class) - 1; i > 0; i -= 1 {
			state += 0x9E3779B97F4A7C15
			z := state
			z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
			z = (z ~ (z >> 27)) * 0x94D049BB133111EB
			z ~= z >> 31
			j := int(z % u64(i + 1))
			class[i], class[j] = class[j], class[i]
		}
	}
	return order
}

// How many of n pixels have turned at `progress`, 0 to 1: none at 0, every
// one at 1, and never fewer as progress grows.
dissolve_count :: proc(progress: f32, n: int) -> int {
	if progress <= 0 do return 0
	if progress >= 1 do return n
	return clamp(int(progress * f32(n)), 0, n)
}

// How far through a dusk `seconds` long, `elapsed` seconds after it began:
// 0 to 1, and 1 for ever after. A dusk of no length (0 or less) never begins.
dusk_progress :: proc(elapsed, seconds: f32) -> f32 {
	if seconds <= 0 do return 0
	return clamp(elapsed / seconds, 0, 1)
}

// Turns the shown pixels on to `want`: the next ones in the order take their
// colour from `to`; going back (a dusk begun again), the ones past `want`
// take theirs from `from` again. Returns how many have turned now.
dissolve_step :: proc(shown, from, to: []rl.Color, order: []i32, done, want: int) -> int {
	upto := clamp(want, 0, len(order))
	for i in done ..< upto do shown[order[i]] = to[order[i]]
	for i in upto ..< done do shown[order[i]] = from[order[i]]
	return upto
}

// One layer's dissolve: its two paintings, CPU side, and the picture shown,
// which is `from` with the first `done` pixels of the order taken from `to`.
Dissolve :: struct {
	from, to: []rl.Color,
	shown:    []rl.Color,
	order:    []i32,
	done:     int,
	sprite:   Sprite, // `from`'s sprite, drawing `shown` instead
	ok:       bool,   // false: the two paintings are not the same size, and it cuts at half way instead
}

// Reads both paintings back and makes the picture to show. Each layer can
// have its own seed, so two layers' pixels do not turn in step.
dissolve_make :: proc(from, to: Sprite, seed: u64 = DISSOLVE_SEED) -> (d: Dissolve) {
	if from.texture.id == 0 || to.texture.id == 0 do return
	if from.texture.width != to.texture.width || from.texture.height != to.texture.height do return
	d.from = texture_colors(from.texture)
	d.to = texture_colors(to.texture)
	d.shown = make([]rl.Color, len(d.from))
	copy(d.shown, d.from)
	d.order = dissolve_order(int(from.texture.width), int(from.texture.height), seed)
	img := rl.Image {
		data    = raw_data(d.shown),
		width   = from.texture.width,
		height  = from.texture.height,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	d.sprite = from
	d.sprite.texture = rl.LoadTextureFromImage(img)
	rl.SetTextureFilter(d.sprite.texture, .POINT)
	d.ok = true
	return
}

// The picture at `progress`, 0 to 1: the texture is sent again only when a
// pixel has turned.
dissolve_set :: proc(d: ^Dissolve, progress: f32) {
	if !d.ok do return
	want := dissolve_count(progress, len(d.order))
	if want == d.done do return
	d.done = dissolve_step(d.shown, d.from, d.to, d.order, d.done, want)
	rl.UpdateTexture(d.sprite.texture, raw_data(d.shown))
}

dissolve_free :: proc(d: ^Dissolve) {
	if d.sprite.texture.id != 0 && d.ok do rl.UnloadTexture(d.sprite.texture)
	delete(d.from)
	delete(d.to)
	delete(d.shown)
	delete(d.order)
	d^ = {}
}

// A texture's pixels, read back from the GPU, as RGBA.
@(private = "file")
texture_colors :: proc(t: rl.Texture2D) -> []rl.Color {
	img := rl.LoadImageFromTexture(t)
	defer rl.UnloadImage(img)
	rl.ImageFormat(&img, .UNCOMPRESSED_R8G8B8A8)
	n := int(img.width * img.height)
	out := make([]rl.Color, n)
	copy(out, ([^]rl.Color)(img.data)[:n])
	return out
}
