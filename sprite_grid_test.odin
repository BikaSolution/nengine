package nengine

import "core:math"
import "core:testing"
import rl "vendor:raylib"

// A room's still things on the backdrop's own grid (draw_sprite_on_grid,
// sprite.odin). The backdrop puts art pixel X on canvas columns
// round(X*scale) up to round((X+1)*scale); a thing laid over it at art pixel
// (ax, ay) must put its own art pixel i on exactly the columns of X = ax+i,
// and the same for rows, wherever ax is. Without a window: the sums the GPU
// and the `up` shader do, done here.

// The backdrop's art pixel at canvas column (or row) c, from its edges; on
// past the canvas's left edge the same way.
@(private = "file")
grid_pixel :: proc(c: i32, scale: f32) -> i32 {
	x := i32(math.floor(f32(c) / scale)) - 2
	for art_edge(x + 1, scale) <= c do x += 1
	return x
}

// As in sprite_test.odin: the texel a nearest lookup takes for canvas pixel i
// of a source `size` texels long drawn into n canvas pixels.
@(private = "file")
sampled :: proc(start, size: f32, n, i: i32) -> i32 {
	return i32(math.floor(start + (f32(i) + 0.5) / f32(n) * size))
}

@(test)
a_still_thing_lands_on_the_backdrops_own_pixels :: proc(t: ^testing.T) {
	scales := [?]f32{3.2, 1, 2, 3, 4, 1.5, 2.5, 6.4}
	widths := [?]i32{1, 2, 3, 5, 7, 13, 26, 37, 100}
	for scale in scales {
		for w in widths {
			h := w / 2 + 3
			s := Sprite{frame_w = sprite_up(w, scale), frame_h = sprite_up(h, scale), frames = 2, w = w, h = h, scale = scale}
			for frame in i32(0) ..< 2 {
				for px in -40 ..< 260 {
					pos := [2]f32{f32(px), f32(px / 2 + 200)}
					dst, art := sprite_grid_box(s, pos)
					src := sprite_grid_source(s, frame, dst, art)
					x0, y0, n, m := i32(dst.x), i32(dst.y), i32(dst.width), i32(dst.height)
					if x0 != art_edge(art.x, scale) || x0 + n != art_edge(art.x + w, scale) || y0 != art_edge(art.y, scale) || y0 + m != art_edge(art.y + h, scale) {
						testing.expectf(t, false, "scale %v, %v wide at %v: box %v is not art %v's", scale, w, pos, dst, art)
						return
					}
					for j in 0 ..< n {
						got := sampled(src.x, src.width, n, j) - frame * w
						want := grid_pixel(x0 + j, scale) - art.x
						if got != want || got < 0 || got >= w {
							testing.expectf(t, false, "scale %v, %v wide at %v (art %v): column %v shows art pixel %v, the backdrop's grid has %v", scale, w, pos, art.x, x0 + j, got, want)
							return
						}
					}
					for r in 0 ..< m {
						got := sampled(src.y, src.height, m, r)
						want := grid_pixel(y0 + r, scale) - art.y
						if got != want || got < 0 || got >= h {
							testing.expectf(t, false, "scale %v, %v high at %v (art %v): row %v shows art pixel %v, the backdrop's grid has %v", scale, h, pos, art.y, y0 + r, got, want)
							return
						}
					}
				}
			}
		}
	}
}

// Through a ride's camera every sprite goes through the `up` shader. With a
// grid it must find the same art pixels (SPRITE_UP_SHADER, line for line).
@(test)
through_a_camera_a_still_thing_finds_the_same_pixels :: proc(t: ^testing.T) {
	for scale in ([]f32{3.2, 2, 3, 4, 6.4}) {
		for w in ([]i32{1, 5, 13, 37, 100}) {
			s := Sprite{frame_w = sprite_up(w, scale), frame_h = sprite_up(w, scale), frames = 1, w = w, h = w, scale = scale}
			for px in -20 ..< 200 {
				dst, art := sprite_grid_box(s, {f32(px), 300})
				grid := [4]f32{dst.x, dst.y, f32(art.x), f32(art.y)}
				for local in 0 ..< i32(dst.width) {
					a := clamp(math.ceil((f32(local) + grid.x + 0.5) / scale) - 1 - grid.z, 0, f32(w - 1))
					want := grid_pixel(i32(dst.x) + local, scale) - art.x
					if i32(a) != want {
						testing.expectf(t, false, "scale %v, %v wide at %v: the shader takes art pixel %v for column %v, the backdrop's grid has %v", scale, w, px, a, local, want)
						return
					}
				}
			}
		}
	}
}

// Nothing already right moves: a corner on an art pixel's edge stays where
// it is, and on every fifth (at 3.2: a whole number of canvas pixels) the
// picture is draw_sprite's to the pixel. Nor does one not blown up.
@(test)
on_the_grid_already_a_still_thing_does_not_move :: proc(t: ^testing.T) {
	scale := f32(3.2)
	for w in ([]i32{1, 5, 13, 40, 100, 320}) {
		s := Sprite{frame_w = sprite_up(w, scale), frame_h = sprite_up(w, scale), frames = 1, w = w, h = w, scale = scale}
		for a in i32(0) ..< 120 {
			x0 := art_edge(a, scale)
			pos := [2]f32{f32(x0) + f32(s.frame_w) / 2, f32(x0 + s.frame_h)}
			testing.expect_value(t, i32(pos.x - f32(s.frame_w) / 2), x0) // draw_sprite's corner
			dst, art := sprite_grid_box(s, pos)
			testing.expect_value(t, art, [2]i32{a, a})
			testing.expect_value(t, i32(dst.x), x0)
			testing.expect_value(t, i32(dst.y), x0)
			if a % 5 != 0 do continue
			testing.expect_value(t, dst, rl.Rectangle{f32(x0), f32(x0), f32(s.frame_w), f32(s.frame_h)})
			src, old := sprite_grid_source(s, 0, dst, art), sprite_source(s, 0)
			for j in 0 ..< s.frame_w {
				testing.expect_value(t, sampled(src.x, src.width, s.frame_w, j), sampled(old.x, old.width, s.frame_w, j))
			}
		}
	}
	plain := Sprite{frame_w = 40, frame_h = 30, frames = 1}
	for px in -10 ..< 60 {
		pos := [2]f32{f32(px) + 0.5, f32(px) * 3}
		dst, _ := sprite_grid_box(plain, pos)
		testing.expect_value(t, dst, rl.Rectangle{f32(i32(pos.x - 20)), f32(i32(pos.y - 30)), 40, 30})
	}
}

// The art tools lay a sprite at art (round(x/3.2), round(y/3.2)) of the
// corner its pos gives (the tree kit's place(); outkit's sprite_pos takes the
// first pos that does): the engine puts it on the same art pixel, halfway
// cases and all, and every pos sprite_pos can give lands on its art.
@(test)
a_still_thing_is_where_the_art_tools_put_it :: proc(t: ^testing.T) {
	scale := f32(3.2)
	for c in i32(-40) ..< 1100 {
		kit := i32(math.floor(f64(c) / 3.2 + 0.5))
		testing.expectf(t, art_nearest(c, scale) == kit, "corner %v: art pixel %v, the art tools say %v", c, art_nearest(c, scale), kit)
	}
	for w in ([]i32{1, 4, 7, 33, 92}) {
		fw := sprite_up(w, scale)
		s := Sprite{frame_w = fw, frame_h = fw, frames = 1, w = w, h = w, scale = scale}
		for left in i32(0) ..< 60 {
			// outkit.sprite_pos, x only (y is the same sum)
			found := false
			for dx in -3 ..= 3 {
				X := i32(math.round(f64(left) * 3.2 + f64(fw) / 2)) + i32(dx)
				if i32(math.floor(f64(i32(f64(X) - f64(fw) / 2)) / 3.2 + 0.5)) != left do continue
				_, art := sprite_grid_box(s, {f32(X), 400})
				testing.expectf(t, art.x == left, "%v wide at art %v: sprite_pos's x %v lands on art %v", w, left, X, art.x)
				found = true
			}
			testing.expectf(t, found, "%v wide at art %v: no pos", w, left)
		}
	}
}
