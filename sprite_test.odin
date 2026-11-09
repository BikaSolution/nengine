package nengine

import "core:math"
import "core:testing"
import rl "vendor:raylib"

// Sprites are kept as painted and blown up as they are drawn (sprite.odin).
// These check, without a window, that the drawing puts every art pixel on
// exactly the canvas columns and rows the old blow-up on the CPU gave it: art
// pixel x on columns sprite_up(x) up to sprite_up(x+1).

// The art pixel the old blow-up put at canvas column (or row) i of a frame
// `w` art pixels across.
@(private = "file")
blown_up_pixel :: proc(i, w: i32, scale: f32) -> i32 {
	for x in 0 ..< w {
		if sprite_up(x, scale) <= i && i < sprite_up(x + 1, scale) do return x
	}
	return -1
}

// What the GPU does with a source rectangle drawn into `n` canvas pixels at a
// whole-pixel position, along one axis: pixel i's centre samples the texel at
// the matching point of the source, and a nearest lookup takes the texel that
// point is in. A negative size runs from the far end, as a flipped source does.
@(private = "file")
sampled_texel :: proc(start, size: f32, n, i: i32) -> i32 {
	along := (f32(i) + 0.5) / f32(n)
	u := start + along * size if size >= 0 else start - size - along * -size
	return i32(math.floor(u))
}

@(test)
a_drawn_sprite_covers_the_columns_and_rows_the_blow_up_did :: proc(t: ^testing.T) {
	scales := [?]f32{1, 2, 3, 4, 3.2, 1.5, 2.5, 6.4, 0.5}
	widths := [?]i32{1, 2, 3, 5, 7, 13, 16, 26, 31, 40, 160, 320}
	for scale in scales {
		for w in widths {
			h := w / 2 + 3
			s := Sprite{frame_w = sprite_up(w, scale), frame_h = sprite_up(h, scale), frames = 3, w = w, h = h, scale = scale}
			for frame in i32(0) ..< 3 {
				for flip in ([]bool{false, true}) {
					src := sprite_source(s, frame, flip)
					for i in 0 ..< s.frame_w {
						from := s.frame_w - 1 - i if flip else i // a flipped frame shows its columns from the other end
						want := blown_up_pixel(from, w, scale)
						if want < 0 do continue // a column no art pixel had (only below 1x)
						got := sampled_texel(src.x, src.width, s.frame_w, i) - frame * w
						if got != want {
							testing.expectf(t, false, "scale %v, %v wide, frame %v, flip %v: column %v shows art pixel %v, the blow-up had %v", scale, w, frame, flip, i, got, want)
							return
						}
					}
					for r in 0 ..< s.frame_h {
						want := blown_up_pixel(r, h, scale)
						if want < 0 do continue
						got := sampled_texel(src.y, src.height, s.frame_h, r)
						if got != want {
							testing.expectf(t, false, "scale %v, %v high: row %v shows art pixel %v, the blow-up had %v", scale, h, r, got, want)
							return
						}
					}
				}
			}
		}
	}
}

// The `up` shader's sum, for a picture drawn at any size: from the pixel of
// the blown-up frame to the art pixel. It must be the inverse of sprite_up.
@(test)
the_up_shader_finds_the_art_pixel_the_blow_up_had :: proc(t: ^testing.T) {
	for scale in ([]f32{1, 2, 3, 3.2, 1.5, 2.5, 6.4}) {
		w := i32(320)
		for i in 0 ..< sprite_up(w, scale) {
			art := i32(math.ceil((f32(i) + 0.5) / scale) - 1) // SPRITE_UP_SHADER, line for line
			testing.expectf(t, art == blown_up_pixel(i, w, scale), "scale %v: blown-up pixel %v is art pixel %v, the shader says %v", scale, i, blown_up_pixel(i, w, scale), art)
		}
	}
}

// A sprite made by hand with only its canvas size (a test's, or one at scale
// 1) is its own size: nothing divides by a zero scale.
@(test)
a_sprite_without_its_painted_size_is_drawn_as_it_is :: proc(t: ^testing.T) {
	s := Sprite{frame_w = 40, frame_h = 30, frames = 2}
	w, h, scale := sprite_native(s)
	testing.expect_value(t, w, i32(40))
	testing.expect_value(t, h, i32(30))
	testing.expect_value(t, scale, f32(1))
	src := sprite_source(s, 1)
	testing.expect_value(t, sampled_texel(src.x, src.width, 40, 0), i32(40))
	testing.expect_value(t, sampled_texel(src.x, src.width, 40, 39), i32(79))
}

// What a game positions by is still the size on the canvas: 320 painted at
// 3.2 is 1024, 13 is 42 (41.6, rounded), and a .png is its own size.
@(test)
a_sprite_keeps_its_size_on_the_canvas :: proc(t: ^testing.T) {
	testing.expect_value(t, sprite_up(320, 3.2), i32(1024))
	testing.expect_value(t, sprite_up(200, 3.2), i32(640))
	testing.expect_value(t, sprite_up(13, 3.2), i32(42))
	p := texture_sprite(rl.Texture2D{id = 3, width = 1024, height = 640})
	testing.expect_value(t, p.frame_w, i32(1024))
	testing.expect_value(t, p.frame_h, i32(640))
	testing.expect_value(t, p.frames, i32(1))
}
