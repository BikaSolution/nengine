package pixel

import ne "../../"
import ui "../ui"
import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

// What the file browser shows about a piece of art before you open it.
//
// It knows nothing about files. Whichever editor owns the format loads its
// own and hands over a grid of pixels and a line about it; the drawing — the
// art animating on a checkerboard, its palette, and how big it is against the
// screen and against a person — is the same for a sprite, a pose and a
// backdrop, so it is here.
//
// The size comparison is the part worth having. Art is authored in 320x200
// numbers and blown up on the way into the game, so "14x46" means nothing on
// its own; what you want to know is how much of the screen it covers and how
// it measures against a person.

// The screen art is drawn for. Everything in an asset file is in these
// numbers; the engine scales them up on load.
DESIGN_W :: 320
DESIGN_H :: 200

// Ada is 26x52, and every other sprite is judged against her whether or not
// anyone says so. Making that comparison visible is most of the point.
REF_W :: 26
REF_H :: 52

Browse :: struct {
	path: string,
	ok:   bool,
	data: ne.Sprite_Data, // owned: what to show
	tex:  rl.Texture2D,
	note: string, // owned: "10 of 10 poses drawn", "3 frames"
}

browse_close :: proc(b: ^Browse) {
	if b.tex.id != 0 do rl.UnloadTexture(b.tex)
	if b.ok do ne.sprite_data_destroy(&b.data)
	delete(b.note)
	delete(b.path)
	b^ = {}
}

// True when `path` is already loaded, so a caller can skip the work. The
// preview pane is drawn every frame and the file is not going to have changed
// sixty times a second.
browse_showing :: proc(b: ^Browse, path: string) -> bool {
	return b.ok && b.path == path
}

// Hands the browse pane a grid to show. It takes ownership of `data` and
// copies `note`.
browse_set :: proc(b: ^Browse, path: string, data: ne.Sprite_Data, note: string) {
	browse_close(b)
	b.path = strings.clone(path)
	b.data = data
	b.note = strings.clone(note)
	b.ok = true
	b.tex = texture_of(&b.data, 0)
}

// Says the file couldn't be read, without pretending there is art to show.
browse_failed :: proc(b: ^Browse, path: string) {
	browse_close(b)
	b.path = strings.clone(path)
	b.note = strings.clone("")
}

@(private = "file")
texture_of :: proc(d: ^ne.Sprite_Data, frame: i32) -> rl.Texture2D {
	img := rl.GenImageColor(d.w, d.h, rl.BLANK)
	defer rl.UnloadImage(img)
	for y in 0 ..< d.h {
		for x in 0 ..< d.w {
			idx := int(ne.sprite_data_at(d, frame, x, y)^)
			col := d.palette[idx].color if idx < len(d.palette) else rl.BLANK
			rl.ImageDrawPixel(&img, x, y, col)
		}
	}
	tex := rl.LoadTextureFromImage(img)
	rl.SetTextureFilter(tex, .POINT)
	return tex
}

// Draws whatever was last handed over, into the browser's preview pane.
browse_draw :: proc(b: ^Browse, area: rl.Rectangle) -> bool {
	if !b.ok {
		ui.label(i32(area.x), i32(area.y), "could not read it", ui.DIM, ui.SMALL)
		return true
	}

	// The art, as large as it will go in the top of the pane, on a
	// checkerboard so you can see where it stops.
	stage := rl.Rectangle{area.x, area.y, area.width, area.height * 0.42}
	ui.checkerboard(stage)
	frame := i32(0)
	if b.data.frames > 1 do frame = i32(ui.now() * 6) % b.data.frames
	if frame != 0 {
		// Re-uploading one small texture as the frame changes is cheaper than
		// keeping a texture per frame for a file being glanced at.
		if b.tex.id != 0 do rl.UnloadTexture(b.tex)
		b.tex = texture_of(&b.data, frame)
	}
	scale := min((stage.width - 16) / f32(b.data.w), (stage.height - 16) / f32(b.data.h))
	scale = max(f32(int(scale)), 1) // whole pixels only, so it stays crisp
	w, h := f32(b.data.w) * scale, f32(b.data.h) * scale
	rl.DrawTexturePro(
		b.tex,
		{0, 0, f32(b.data.w), f32(b.data.h)},
		{stage.x + (stage.width - w) / 2, stage.y + (stage.height - h) / 2, w, h},
		{0, 0},
		0,
		rl.WHITE,
	)
	rl.DrawRectangleLinesEx(stage, 1, ui.EDGE)

	y := i32(stage.y + stage.height) + 12
	ui.label(i32(area.x), y, fmt.tprintf("%v x %v", b.data.w, b.data.h), ui.INK, ui.SMALL)
	right := fmt.tprintf("x%v", int(scale))
	ui.label(i32(area.x + area.width) - ui.measure(right, ui.SMALL), y, right, {96, 96, 112, 255}, ui.SMALL)
	y += 20

	if b.note != "" {
		ui.label(i32(area.x), y, ui.ellipsize(b.note, area.width, ui.SMALL), ui.DIM, ui.SMALL)
		y += 22
	}

	// The palette as it is actually stored: a file keeps only the colours it
	// uses, so this is a fair look at how many it really needs.
	used := len(b.data.palette)
	ui.label(i32(area.x), y, fmt.tprintf("%v colours", used), ui.DIM, ui.SMALL)
	y += 18
	sw := f32(12)
	for e, i in b.data.palette {
		cx := area.x + f32(i % 20) * (sw + 2)
		cy := f32(y) + f32(i / 20) * (sw + 2)
		if cy > area.y + area.height - 90 do break
		rl.DrawRectangleRec({cx, cy, sw, sw}, e.color)
		rl.DrawRectangleLinesEx({cx, cy, sw, sw}, 1, {0, 0, 0, 90})
	}
	y += i32((f32(used + 19) / 20) * (sw + 2)) + 10

	draw_size_comparison(b, {area.x, f32(y), area.width, area.y + area.height - f32(y)})
	return true
}

// How big it is, drawn rather than stated: the art inside a 320x200 frame,
// with a person-sized block beside it. A number of pixels means nothing until
// you can see what share of the screen it is.
@(private = "file")
draw_size_comparison :: proc(b: ^Browse, r: rl.Rectangle) {
	if r.height < 70 do return
	ui.label(i32(r.x), i32(r.y), "on a 320x200 screen", {110, 110, 126, 255}, ui.SMALL)

	box := rl.Rectangle{r.x, r.y + 20, r.width, r.height - 26}
	scale := min(box.width / DESIGN_W, box.height / DESIGN_H)
	screen := rl.Rectangle{
		box.x + (box.width - DESIGN_W * scale) / 2,
		box.y,
		DESIGN_W * scale,
		DESIGN_H * scale,
	}
	rl.DrawRectangleRec(screen, {20, 20, 26, 255})
	rl.DrawRectangleLinesEx(screen, 1, ui.EDGE)

	// Art the size of the whole screen is a backdrop, and a backdrop has
	// nothing to be compared with: it simply is the screen.
	if b.data.w >= DESIGN_W - 8 && b.data.h >= DESIGN_H - 8 {
		rl.DrawRectangleRec({screen.x + 1, screen.y + 1, screen.width - 2, screen.height - 2}, {56, 52, 36, 255})
		msg := "the whole screen"
		ui.label(i32(screen.x + screen.width / 2) - ui.measure(msg, ui.SMALL) / 2,
			i32(screen.y + screen.height / 2) - 6, msg, ui.GOLD, ui.SMALL)
		return
	}

	// A ground line, so both blocks stand on something and read as heights.
	ground := screen.y + screen.height * 0.86
	rl.DrawLine(i32(screen.x), i32(ground), i32(screen.x + screen.width), i32(ground), {60, 60, 72, 255})

	// The reference figure, then this art beside it, each named — two grey
	// blocks with nothing to say which is which would be a worse diagram than
	// no diagram.
	ref_w, ref_h := f32(REF_W) * scale, f32(REF_H) * scale
	ref_x := screen.x + screen.width * 0.28 - ref_w / 2
	rl.DrawRectangleRec({ref_x, ground - ref_h, ref_w, ref_h}, {70, 70, 84, 255})
	caption("a person", ref_x + ref_w / 2, ground + 3)

	sw, sh := f32(b.data.w) * scale, f32(b.data.h) * scale
	if sh > screen.height do sh = screen.height
	this_x := screen.x + screen.width * 0.62 - sw / 2
	rl.DrawRectangleRec({this_x, ground - sh, sw, sh}, ui.GOLD)
	caption("this", this_x + sw / 2, ground + 3)

	// And the share of the screen it takes, which is the number nobody works
	// out in their head.
	pct := 100 * (f32(b.data.w) * f32(b.data.h)) / (DESIGN_W * DESIGN_H)
	tall := 100 * f32(b.data.h) / REF_H
	text := fmt.tprintf("%.1f%% of the screen, %v%% of a person", pct, int(tall))
	ui.label(i32(r.x), i32(screen.y + screen.height) + 4, ui.ellipsize(text, r.width, ui.SMALL), {110, 110, 126, 255}, ui.SMALL)
}

// A word under a block in the size diagram, centred on it.
@(private = "file")
caption :: proc(text: string, cx, y: f32) {
	ui.label(i32(cx) - ui.measure(text, ui.SMALL) / 2, i32(y), text, {130, 130, 148, 255}, ui.SMALL)
}

// A copy of `src` that the browse pane can own and free.
clone_data :: proc(src: ^ne.Sprite_Data) -> (out: ne.Sprite_Data) {
	out = ne.sprite_data_new(src.name, src.w, src.h, src.frames)
	clear(&out.palette)
	for e in src.palette do append(&out.palette, e)
	for v, i in src.pixels do out.pixels[i] = v
	return
}
