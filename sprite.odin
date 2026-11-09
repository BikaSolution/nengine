package nengine

import "core:math"
import rl "vendor:raylib"

// A sprite sheet: every frame is the same size, laid out left to right in one
// texture. A static sprite is just a sheet with one frame.
//
// The texture is the art as painted, one texel per pixel of the .sprite, and
// it is blown up as it is drawn, never before: a 320x200 backdrop is 250 KB on
// the GPU rather than the 2.6 MB of its 1024x640 blow-up, and over a thousand
// sprites that is most of what the game used to load. `frame_w` and `frame_h`
// are still the size on the canvas, which is the size everything positions
// with; `w`, `h` and `scale` are how the drawing gets there.
//
// What lands on the canvas is exactly what the old blown-up picture put there:
// art pixel x covers canvas columns round(x*scale) up to round((x+1)*scale),
// three of them or four at 3.2, and the same rows (`sprite_source`).
Sprite :: struct {
	texture: rl.Texture2D, // the frames as painted, left to right, one texel per art pixel
	frame_w: i32,          // one frame on the canvas: round(w * scale)
	frame_h: i32,
	frames:  i32,
	holds:   []i32, // ticks per frame from the file's `frame N hold=K`; nil when every frame shows for one
	w, h:    i32,   // one frame as painted, in art pixels. 0: the same as frame_w and frame_h
	scale:   f32,   // canvas pixels per art pixel. 0 is 1
}

// The size a stretch of `v` art pixels covers on the canvas, at `scale`: what
// a sprite's frame_w is, and where the old blow-up put each art pixel's edge.
sprite_up :: proc(v: i32, scale: f32) -> i32 {
	return i32(f32(v) * scale + 0.5)
}

// One frame as painted, and how much it is blown up by. A Sprite made by hand
// with only frame_w and frame_h (a test's, or one at scale 1) is its own size.
sprite_native :: proc(s: Sprite) -> (w, h: i32, scale: f32) {
	if s.w <= 0 || s.h <= 0 || s.scale <= 0 do return s.frame_w, s.frame_h, 1
	return s.w, s.h, s.scale
}

// A sampled column or row whose centre falls exactly on the edge between two
// art pixels takes the one before it, as round() gave it to that one. Far below
// the closest a centre comes to an edge at the scales in use (a 32nd of a
// texel at 3.2), and far above the GPU's own rounding.
@(private)
SPRITE_NUDGE :: f32(1) / 128

// The part of the texture to draw into one frame's frame_w x frame_h box on the
// canvas, at a whole-pixel position, so that every art pixel lands on the
// columns and rows the old blown-up picture gave it. `frame` is the frame
// itself, already wrapped into the sheet.
//
// Not simply {frame*w, 0, w, h}: frame_w is round(w*scale), not w*scale, and
// fitting w texels into it would stretch the art by the difference and move
// its edges. Instead the source is frame_w/scale texels wide (a fraction more
// or less than w, never sampled past it), so the centre of canvas column i
// samples the texel at (i + 0.5)/scale — the art pixel round() put there.
// Flipped, the same columns are read from the other end: column i shows what
// column frame_w-1-i did, which is how a mirrored blow-up looked.
sprite_source :: proc(s: Sprite, frame: i32, flip := false) -> rl.Rectangle {
	w, _, scale := sprite_native(s)
	src := rl.Rectangle{f32(frame * w) - SPRITE_NUDGE, -SPRITE_NUDGE, f32(s.frame_w) / scale, f32(s.frame_h) / scale}
	if flip do src.width = -src.width
	return src
}

// Draws one frame with its bottom-centre (the "feet") at pos.
// flip mirrors it horizontally, so one set of frames can face both ways.
draw_sprite :: proc(s: Sprite, frame: i32, pos: [2]f32, flip := false) {
	w, h := f32(s.frame_w), f32(s.frame_h)
	// Snap to whole pixels, otherwise sprites shimmer while they move.
	x := f32(i32(pos.x - w / 2))
	y := f32(i32(pos.y - h))
	if sprite_camera {
		draw_sprite_blown(s, frame % max(s.frames, 1), {x, y, w, h}, {}, 0, flip, rl.WHITE)
		return
	}
	masked := depth_plain_begin() // behind the room's depth (priority.odin), if a mask is on
	rl.DrawTexturePro(s.texture, sprite_source(s, frame % max(s.frames, 1), flip), {x, y, w, h}, {0, 0}, 0, rl.WHITE)
	depth_plain_end(masked)
}

// Draws one frame at its own size with its top-left corner at (x, y): a
// backdrop, a layer of the title, a picture in a box.
draw_sprite_at :: proc(s: Sprite, frame: i32, x, y: i32, tint := rl.WHITE) {
	if s.texture.id == 0 do return
	dst := rl.Rectangle{f32(x), f32(y), f32(s.frame_w), f32(s.frame_h)}
	if sprite_camera {
		draw_sprite_blown(s, frame %% max(s.frames, 1), dst, {}, 0, false, tint)
		return
	}
	rl.DrawTexturePro(s.texture, sprite_source(s, frame %% max(s.frames, 1)), dst, {0, 0}, 0, tint)
}

// Draws a room's still thing with its feet at pos, on the backdrop's own grid.
//
// draw_sprite blows a sprite up from its own corner: its art pixel i covers
// the columns from x + round(i*scale). A backdrop's art pixel X covers the
// columns from round(X*scale). The two agree only for a corner on an art
// pixel whose edge is a whole number (every fifth at 3.2), so a picture cut
// from a backdrop and laid back over it anywhere else drew some of its columns
// and rows a canvas pixel off its own paint: on a fine pattern, a checker.
//
// Here the corner goes to the art pixel it is nearest — the place every art
// tool lays a sprite at from its pos (the kits' place() and sprite_pos) — and
// the sprite is blown up on the backdrop's grid from there: its art pixel i
// covers exactly the columns and rows the backdrop's art pixel corner+i does.
// The corner moves by at most half an art pixel, and the picture can be a
// canvas pixel wider or narrower than frame_w; the feet (pos and base), and so
// the order things are drawn in, do not change. Already on such an edge, or
// not blown up at all (scale 1), it is drawn just as draw_sprite draws it.
//
// Not for people: somebody walking moves a canvas pixel at a time, and must
// not hop from art pixel to art pixel.
draw_sprite_on_grid :: proc(s: Sprite, frame: i32, pos: [2]f32) {
	if s.texture.id == 0 do return
	f := frame % max(s.frames, 1)
	dst, art := sprite_grid_box(s, pos)
	if sprite_camera {
		draw_sprite_blown(s, f, dst, {}, 0, false, rl.WHITE, {dst.x, dst.y, f32(art.x), f32(art.y)})
		return
	}
	masked := depth_plain_begin()
	rl.DrawTexturePro(s.texture, sprite_grid_source(s, f, dst, art), dst, {0, 0}, 0, rl.WHITE)
	depth_plain_end(masked)
}

// The canvas box draw_sprite_on_grid fills for a sprite with its feet at pos,
// and the art pixel of the backdrop's grid its top-left corner is on.
sprite_grid_box :: proc(s: Sprite, pos: [2]f32) -> (dst: rl.Rectangle, art: [2]i32) {
	w, h, scale := sprite_native(s)
	// The corner draw_sprite would start from, to the nearest art pixel.
	art = {art_nearest(i32(pos.x - f32(s.frame_w) / 2), scale), art_nearest(i32(pos.y - f32(s.frame_h)), scale)}
	x0, y0 := art_edge(art.x, scale), art_edge(art.y, scale)
	x1, y1 := art_edge(art.x + w, scale), art_edge(art.y + h, scale)
	return {f32(x0), f32(y0), f32(x1 - x0), f32(y1 - y0)}, art
}

// The part of the texture draw_sprite_on_grid draws into `dst`: the centre of
// canvas column c samples (c + 0.5) / scale, which is the backdrop's own sum
// (sprite_source of a sprite at 0,0), less the art pixel the sprite starts on.
sprite_grid_source :: proc(s: Sprite, frame: i32, dst: rl.Rectangle, art: [2]i32) -> rl.Rectangle {
	w, _, scale := sprite_native(s)
	return {
		f32(frame * w) + (dst.x / scale - f32(art.x)) - SPRITE_NUDGE,
		(dst.y / scale - f32(art.y)) - SPRITE_NUDGE,
		dst.width / scale,
		dst.height / scale,
	}
}

// Where the backdrop's blow-up starts art pixel a, as sprite_up has it; to
// the left of the canvas (something hanging off its edge) the same way on.
art_edge :: proc(a: i32, scale: f32) -> i32 {
	return i32(math.floor(f32(a) * scale + 0.5))
}

// The art pixel whose edge is nearest canvas column (or row) c; halfway, the
// one to the right, as the art tools' round(c / scale) has it. In whole
// numbers, so no float decides a tie.
art_nearest :: proc(c: i32, scale: f32) -> i32 {
	a := i32(math.floor(f32(c) / scale))
	best := a - 1
	for b in a ..= a + 1 {
		if abs(art_edge(b, scale) - c) <= abs(art_edge(best, scale) - c) do best = b
	}
	return best
}

// A whole texture as a one-frame Sprite at its own size: a .png backdrop, which
// is painted at canvas size already.
texture_sprite :: proc(t: rl.Texture2D) -> Sprite {
	return {texture = t, frame_w = t.width, frame_h = t.height, frames = 1, w = t.width, h = t.height, scale = 1}
}

// The rectangle a sprite covers on screen when its feet are at pos.
sprite_bounds :: proc(s: Sprite, pos: [2]f32) -> rl.Rectangle {
	w, h := f32(s.frame_w), f32(s.frame_h)
	return {pos.x - w / 2, pos.y - h, w, h}
}

// Draws one frame centred on `center`, turned by `rotation` degrees. For
// things tumbling through the air.
draw_sprite_turned :: proc(s: Sprite, frame: i32, center: [2]f32, rotation: f32, flip := false) {
	w, h := f32(s.frame_w), f32(s.frame_h)
	draw_sprite_pro(s, frame % max(s.frames, 1), {center.x, center.y, w, h}, {w / 2, h / 2}, rotation, flip)
}

// One frame into any rectangle, turned by `rotation` degrees about `origin` as
// DrawTexturePro does it: a close-up at twice its size, a portrait shrunk to
// fit, the tools' zoomed views. `frame` is the frame itself, already wrapped.
//
// It looks as it did when the frame was blown up to frame_w x frame_h first
// and that picture stretched into `dst`: each canvas pixel finds the pixel of
// the blown-up frame under it, and then the art pixel that one was (the `up`
// shader). Straight to the art would be one rounding instead of two, and at
// most sizes that shifts some edges by a pixel.
//
// Drawn its own size at a whole-pixel position it needs no shader, and takes
// the path draw_sprite does; nor does a sprite that is not blown up.
draw_sprite_pro :: proc(s: Sprite, frame: i32, dst: rl.Rectangle, origin: [2]f32 = {}, rotation: f32 = 0, flip := false, tint := rl.WHITE) {
	if s.texture.id == 0 do return
	x, y := dst.x - origin.x, dst.y - origin.y
	if !sprite_camera && rotation == 0 && dst.width == f32(s.frame_w) && dst.height == f32(s.frame_h) && x == f32(i32(x)) && y == f32(i32(y)) {
		masked := depth_plain_begin()
		rl.DrawTexturePro(s.texture, sprite_source(s, frame, flip), dst, origin, 0, tint)
		depth_plain_end(masked)
		return
	}
	w, h, _ := sprite_native(s)
	if !sprite_camera && w == s.frame_w && h == s.frame_h {
		// Not blown up at all (a .png, or a tool's sprites at 1): the texture
		// is the picture, and the GPU's own lookup is the one it always had.
		src := rl.Rectangle{f32(frame * w), 0, f32(w), f32(h)}
		if flip do src.width = -src.width
		masked := depth_plain_begin()
		rl.DrawTexturePro(s.texture, src, dst, origin, rotation, tint)
		depth_plain_end(masked)
		return
	}
	draw_sprite_blown(s, frame, dst, origin, rotation, flip, tint)
}

// Set while a room is drawn through a camera that turns and zooms (a ride's
// view, ride.odin). Through one, even a sprite drawn its own size lands on the
// canvas at fractions of a pixel, so every sprite goes the `up` shader's way,
// and a tint (begin_tint) is done by the same shader.
@(private) sprite_camera: bool

// The palette map begin_tint asked for, while a camera is on: the shader does
// it, as the ride shader would have.
@(private)
sprite_map_begin :: proc(from, to: ^[16][3]f32) {
	// The `up` shader, and its masked twin (priority.odin), the same.
	for shader in ([2]rl.Shader{sprite_up_shader(), depth_shader(.Up)}) {
		a, cell, on := f32(1), f32(WIDTH) / 320, i32(1)
		rl.SetShaderValueV(shader, rl.GetShaderLocation(shader, "from"), from, .VEC3, 16)
		rl.SetShaderValueV(shader, rl.GetShaderLocation(shader, "to"), to, .VEC3, 16)
		rl.SetShaderValue(shader, rl.GetShaderLocation(shader, "amount"), &a, .FLOAT)
		rl.SetShaderValue(shader, rl.GetShaderLocation(shader, "cell"), &cell, .FLOAT)
		rl.SetShaderValue(shader, rl.GetShaderLocation(shader, "mapped"), &on, .INT)
	}
}

@(private)
sprite_map_end :: proc() {
	for shader in ([2]rl.Shader{sprite_up_shader(), depth_shader(.Up)}) {
		off := i32(0)
		rl.SetShaderValue(shader, rl.GetShaderLocation(shader, "mapped"), &off, .INT)
	}
}

// One frame through the `up` shader, with the coordinates the blown-up sheet
// was drawn with. Not between begin_tint and end_tint without a camera on: the
// shader would replace the tint's.
//
// `grid` is a still thing on the backdrop's grid (draw_sprite_on_grid): the
// canvas pixel its box starts on and the art pixel that is, x and y. Its
// blown-up frame is then that box (dst), blown up from the canvas's corner.
@(private)
draw_sprite_blown :: proc(s: Sprite, frame: i32, dst: rl.Rectangle, origin: [2]f32, rotation: f32, flip: bool, tint: rl.Color, grid: [4]f32 = {}) {
	if s.texture.id == 0 do return
	w, h, scale := sprite_native(s)
	// Behind the room's depth, if a mask is on (priority.odin): the masked twin.
	shader := depth_shader(.Up) if depth_mask.on else sprite_up_shader()
	// The blown-up sheet the coordinates are in, and one frame of it; the
	// frame as painted.
	fw, fh := s.frame_w, s.frame_h
	if grid != {} do fw, fh = i32(dst.width), i32(dst.height)
	sheet := [4]f32{f32(fw * max(s.frames, 1)), f32(fh), f32(fw), f32(fh)}
	painted := [2]f32{f32(w), f32(h)}
	grid := grid
	rl.SetShaderValue(shader, rl.GetShaderLocation(shader, "sheet"), &sheet, .VEC4)
	rl.SetShaderValue(shader, rl.GetShaderLocation(shader, "painted"), &painted, .VEC2)
	rl.SetShaderValue(shader, rl.GetShaderLocation(shader, "scale"), &scale, .FLOAT)
	rl.SetShaderValue(shader, rl.GetShaderLocation(shader, "grid"), &grid, .VEC4)
	rl.BeginShaderMode(shader)
	if depth_mask.on do depth_mask_uniforms(shader)
	// The very coordinates the blown-up sheet was drawn with, frame and all:
	// the texture as far as they go is that sheet's size. The shader takes
	// them to the blown-up pixel and that to the art pixel, which it fetches.
	blown := s.texture
	blown.width, blown.height = i32(sheet.x), i32(sheet.y)
	src := rl.Rectangle{f32(frame * fw), 0, f32(fw), f32(fh)}
	if flip do src.width = -src.width
	rl.DrawTexturePro(blown, src, dst, origin, rotation, tint)
	rl.EndShaderMode() // which draws it, with this sprite's sizes
}

// Which pixel of the blown-up sheet each canvas pixel lands on, as a nearest
// lookup into that sheet found it, and then which art pixel round(x*scale)
// had put there, as `sprite_up` laid them out. The whole sheet, as the
// texture was, wrapping round at its edges: a canvas pixel centred exactly on
// a frame's edge found the next frame's first column, and still does.
//
// The lookup is floor(u * size) of the exact product, which is what the
// texture unit computes. In floats the product can round up onto a whole
// number from just under it — a canvas pixel centred exactly on the line
// between two blown-up pixels, which a zoom that divides evenly makes all
// along a row — and then floor would take the pixel after the one the old
// lookup took. So a product that lands on a whole number is checked in
// integers: u is m * 2^-s, and u * size < k exactly when m * size < k * 2^s.
@(private)
SPRITE_UP_SHADER :: `#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform vec4 sheet;   // the blown-up sheet's width and height, then one frame's
uniform vec2 painted; // one frame as painted, in art pixels: a texel each
uniform float scale;  // canvas pixels per art pixel
uniform vec4 grid;    // on the backdrop's grid: the canvas pixel the frame starts on, and its art pixel; else 0
// A tint through a camera (sprite_map_begin), as RIDE_SHADER does it.
uniform int mapped;
uniform vec3 from[16];
uniform vec3 to[16];
uniform float amount;
uniform float cell;
out vec4 finalColor;
const float bayer[16] = float[16](0.,8.,2.,10.,12.,4.,14.,6.,3.,11.,1.,9.,15.,7.,13.,5.);

// a < b, for 64-bit numbers held as (high, low) halves
bool less64(uvec2 a, uvec2 b) {
	return a.x < b.x || (a.x == b.x && a.y < b.y);
}

// floor(u * n) of the exact product, for 0 <= u < 1 and a whole n < 65536
float lookup(float u, float n) {
	float k = floor(u * n);
	if (u * n != k || u <= 0.0) return k;
	uint bits = floatBitsToUint(u);
	int e = int((bits >> 23) & 255u);
	if (e == 0) return k; // too small to matter
	uint m = (bits & 0x7FFFFFu) | 0x800000u; // u = m * 2^-s
	int s = 150 - e;
	uint whole = uint(n);
	// m * n, as two halves: m is 24 bits, so in 16-bit pieces
	uint lo16 = (m & 0xFFFFu) * whole;
	uint hi8 = (m >> 16) * whole;
	uint lo = lo16 + (hi8 << 16);
	uvec2 mn = uvec2((hi8 >> 16) + (lo < lo16 ? 1u : 0u), lo);
	// k * 2^s, as two halves
	uint kk = uint(k);
	uvec2 ks;
	if (s >= 64) return k; // k * 2^s is out of reach of m * n: not under it
	if (s >= 32) ks = uvec2(kk << uint(s - 32), 0u);
	else if (s == 0) ks = uvec2(0u, kk);
	else ks = uvec2(kk >> uint(32 - s), kk << uint(s));
	return less64(mn, ks) ? k - 1.0 : k;
}

void main() {
	// Whole numbers divided by whole numbers, with a half added: a GPU
	// divides roughly, and 282/282 can come out a hair under 1.
	vec2 t = vec2(lookup(fragTexCoord.x, sheet.x), lookup(fragTexCoord.y, sheet.y));
	t -= sheet.xy * floor((t + 0.5) / sheet.xy); // round the sheet's edge, as the texture wrapped
	float f = floor((t.x + 0.5) / sheet.z);     // which frame of the sheet
	vec2 local = vec2(t.x - f * sheet.z, t.y);
	vec2 art = clamp(ceil((local + grid.xy + 0.5) / scale) - 1.0 - grid.zw, vec2(0.0), painted - 1.0);
	vec4 c = texelFetch(texture0, ivec2(f * painted.x + art.x, art.y), 0);
	if (mapped == 0) {
		finalColor = c * colDiffuse * fragColor;
		return;
	}
	ivec2 p = ivec2(floor(gl_FragCoord.xy / cell)) & 3;
	if ((bayer[p.y * 4 + p.x] + 0.5) / 16.0 > amount) discard;
	int best = 0;
	float bd = 1e9;
	for (int i = 0; i < 16; i++) {
		vec3 d = c.rgb - from[i];
		float dd = dot(d, d);
		if (dd < bd) { bd = dd; best = i; }
	}
	finalColor = vec4(to[best], c.a);
}`

@(private = "file") up_shader: rl.Shader

// Made the first time something is drawn at a size not its own, which needs a
// window open; shutdown unloads it.
@(private)
sprite_up_shader :: proc() -> rl.Shader {
	if up_shader.id == 0 do up_shader = rl.LoadShaderFromMemory(nil, SPRITE_UP_SHADER)
	return up_shader
}

@(private)
sprite_draw_shutdown :: proc() {
	if up_shader.id != 0 do rl.UnloadShader(up_shader)
	up_shader = {}
}
