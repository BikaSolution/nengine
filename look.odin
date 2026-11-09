package nengine

import "core:fmt"
import "core:math"
import "core:strings"
import rl "vendor:raylib"

// The look of the engine's own words on screen: the speech, the narration,
// the line the player types, the death box, an announcement, the menu's
// choices. A game picks one once, before its first frame, and everything the
// engine draws matches it.
//
//     ne.set_look(.Comic)                       // balloons and captions on white paper
//     ne.set_look(.Comic, ne.COMIC_PARCHMENT)   // the same on cream, ruled in sepia
//     ne.set_look(.Comic, my_comic)             // or the game's own papers and inks
//     ne.set_look_lit(.Comic, ne.COMIC_PARCHMENT_LIT) // a theme for each light
//
// **Boxes** is the look every game had first: the Box_Style frames
// (textbox.odin) in raylib's own font, at the top of the screen with the
// portrait beside them. It is the default, and nothing about it changes.
//
// **Comic** letters the game like a comic of 1962:
//   - speech is a balloon with a black line round it, the speaker's name
//     over the words and their portrait in a small inset panel beside it.
//     There is no tail: the balloon sits at the top of the screen on the
//     speaker's side, out of the way of their face where it can be;
//   - a voice through a wall, with no face and nobody on screen, is a square
//     balloon with a broken outline;
//   - narration (LOOK, a message, an announcement) is a caption box;
//   - the typing line is a panel with a `>` and a block cursor;
//   - the death box is a last panel: the picture framed, a caption saying so,
//     the reason in a second caption and the choices as three small panels.
//
// Its lettering is Tiny5 (OFL; fonts/OFL.txt), in capitals, at a whole
// number of canvas pixels per font pixel so every stroke is the same width.
// Its frames are drawn on the 320-wide reference grid (ui_scale), the
// grid the paintings are painted on, so their edges land where a painted
// pixel's would.
//
// **Its colours are a theme** (`Comic`): a paper and inks for each kind of
// box (`Surface`), the black line and the shadows, and a few loose inks for
// the title screen. A paper is one colour or two dithered the EGA way on the
// reference grid (`Paper`), and a surface can have a thin rule inside its
// edge. That is all code draws: flat colours, a dither and lines. A frame
// that needs drawing (brass corners, a printed hem) would be a sprite.
//
// A game can give the comic **a theme for each light** (set_look_lit): the
// boxes are then drawn in the one for the light the player sees (`w.light`,
// light.odin), so they change when the painting does and never while she
// stands still outdoors. Steps, like the paintings, not a dimmer.

Look :: enum {
	Boxes, // Box_Style frames in raylib's font: the default
	Comic, // balloons, captions and panels, lettered in Tiny5
}

// How a paper's second colour lies on its first, on the reference grid, so
// it lines up with the paintings' own pixels.
Weave :: enum u8 {
	Solid,   // `a` alone
	Checker, // `b` on every other grid pixel: a 50% EGA dither
	Quarter, // `b` on one grid pixel in four
}

// What a box is filled with.
Paper :: struct {
	a, b:  rl.Color,
	weave: Weave,
}

// One kind of box: its paper, the inks read on it, and the rule inside its
// edge.
Surface :: struct {
	paper: Paper,
	ink:   rl.Color, // the words
	name:  rl.Color, // who is speaking, the `>`, a title, a room's name, a question
	aside: rl.Color, // a stage direction, a key, a play time, a hint
	faded: rl.Color, // what cannot be picked
	rule:  rl.Color, // a thin line just inside the black one; alpha 0 for none
}

// The comic's theme: a surface for each kind of box, and whether it letters
// in capitals.
Comic :: struct {
	balloon:  Surface,  // speech, and a voice through a wall
	caption:  Surface,  // narration, an announcement, the death box's words, a thing's description
	prompt:   Surface,  // the typing panel
	bar:      Surface,  // the menu bar's strip; its rule runs along the foot
	panel:    Surface,  // a screen (save, load, inventory, menu), the frame round a picture, a balloon's inset
	row:      Surface,  // a slot on the save screen, a button
	picked:   Surface,  // the row, button, cell or bar item that is picked
	title:    Surface,  // a screen's title, the tab over its corner
	tag:      Surface,  // a thing's name by its cell in the inventory
	line:     rl.Color, // every outline, and the shadows
	ground:   rl.Color, // behind a portrait in its inset
	heading:  rl.Color, // the title screen's title
	subtitle: rl.Color, // and the line under it
	note:     rl.Color, // and its note under the choices
	capitals: bool,     // comic lettering: every word in capitals
}

// bEGA, by name, for the themes below (palette.odin's BEGA is a variable).
@(private = "file") BLACK :: rl.Color{0x00, 0x00, 0x00, 255}
@(private = "file") RED :: rl.Color{0xAA, 0x00, 0x00, 255}
@(private = "file") BROWN :: rl.Color{0xAA, 0x55, 0x00, 255}
@(private = "file") LIGHT_GREY :: rl.Color{0xAA, 0xAA, 0xAA, 255}
@(private = "file") DARK_GREY :: rl.Color{0x55, 0x55, 0x55, 255}
@(private = "file") YELLOW :: rl.Color{0xFF, 0xFF, 0x55, 255}
@(private = "file") WHITE :: rl.Color{0xFF, 0xFF, 0xFF, 255}
@(private = "file") BLUE :: rl.Color{0x00, 0x00, 0xAA, 255}
@(private = "file") MAGENTA :: rl.Color{0xAA, 0x00, 0xAA, 255}
@(private = "file") LIGHT_RED :: rl.Color{0xFF, 0x55, 0x55, 255}
@(private = "file") LIGHT_MAGENTA :: rl.Color{0xFF, 0x55, 0xFF, 255}
@(private = "file") LIGHT_CYAN :: rl.Color{0x55, 0xFF, 0xFF, 255}

// White paper: black words, red names, dark grey asides.
@(private = "file") ON_WHITE :: Surface{paper = {a = WHITE, b = WHITE}, ink = BLACK, name = RED, aside = DARK_GREY, faded = LIGHT_GREY}
// Yellow: narration, and whatever is picked.
@(private = "file") ON_YELLOW :: Surface{paper = {a = YELLOW, b = YELLOW}, ink = BLACK, name = RED, aside = DARK_GREY, faded = LIGHT_GREY}

// The sixteen-colour default: white paper, yellow captions, black lines.
COMIC_BEGA :: Comic {
	balloon  = ON_WHITE,
	caption  = ON_YELLOW,
	prompt   = ON_WHITE,
	bar      = ON_WHITE,
	panel    = ON_WHITE,
	row      = ON_WHITE,
	picked   = ON_YELLOW,
	title    = ON_YELLOW,
	tag      = ON_YELLOW,
	line     = BLACK,
	ground   = YELLOW,
	heading  = YELLOW,
	subtitle = WHITE,
	note     = YELLOW,
	capitals = true,
}

// Cream: white and yellow, checkered; black words, sepia names, a thin
// brown rule inside the edge.
@(private = "file") ON_CREAM :: Surface{paper = {a = WHITE, b = YELLOW, weave = .Checker}, ink = BLACK, name = BROWN, aside = DARK_GREY, faded = LIGHT_GREY, rule = BROWN}
// The same unruled, for the small boxes: a slot, a button.
@(private = "file") ON_CREAM_PLAIN :: Surface{paper = {a = WHITE, b = YELLOW, weave = .Checker}, ink = BLACK, name = BROWN, aside = DARK_GREY, faded = LIGHT_GREY}
// The yellow caption, kept, ruled in brown.
@(private = "file") ON_YELLOW_RULED :: Surface{paper = {a = YELLOW, b = YELLOW}, ink = BLACK, name = RED, aside = DARK_GREY, faded = LIGHT_GREY, rule = BROWN}

// Parchment and sepia: the comic warmed, its white gone to cream. The rows
// and buttons are cream unruled; a slot's room is sepia, the picked one's
// red, on yellow as the default picks.
COMIC_PARCHMENT :: Comic {
	balloon  = ON_CREAM,
	caption  = ON_YELLOW_RULED,
	prompt   = ON_CREAM,
	bar      = ON_CREAM,
	panel    = ON_CREAM,
	row      = ON_CREAM_PLAIN,
	picked   = ON_YELLOW,
	title    = ON_YELLOW_RULED,
	tag      = ON_YELLOW,
	line     = BLACK,
	ground   = YELLOW,
	heading  = YELLOW,
	subtitle = WHITE,
	note     = YELLOW,
	capitals = true,
}

// Parchment by the light: the paper stays cream; the rule inside the boxes
// and the caption go with the light the player sees. By day as
// COMIC_PARCHMENT; at sunset a red rule and an apricot caption; at night a
// blue rule and a moonlit light-cyan caption, its label blue; at sunrise a
// magenta rule and a pink caption. The rows, the picks and the name tag
// never change.
@(private = "file") CREAM :: Paper{a = WHITE, b = YELLOW, weave = .Checker}
@(private = "file") ON_CREAM_RED :: Surface{paper = CREAM, ink = BLACK, name = BROWN, aside = DARK_GREY, faded = LIGHT_GREY, rule = RED}
@(private = "file") ON_CREAM_BLUE :: Surface{paper = CREAM, ink = BLACK, name = BROWN, aside = DARK_GREY, faded = LIGHT_GREY, rule = BLUE}
@(private = "file") ON_CREAM_MAGENTA :: Surface{paper = CREAM, ink = BLACK, name = BROWN, aside = DARK_GREY, faded = LIGHT_GREY, rule = MAGENTA}
@(private = "file") CAPTION_SUNSET :: Surface{paper = {a = YELLOW, b = LIGHT_RED, weave = .Quarter}, ink = BLACK, name = RED, aside = DARK_GREY, faded = LIGHT_GREY, rule = RED}
@(private = "file") CAPTION_NIGHT :: Surface{paper = {a = LIGHT_CYAN, b = LIGHT_CYAN}, ink = BLACK, name = BLUE, aside = DARK_GREY, faded = LIGHT_GREY, rule = BLUE}
@(private = "file") CAPTION_SUNRISE :: Surface{paper = {a = YELLOW, b = LIGHT_MAGENTA, weave = .Quarter}, ink = BLACK, name = MAGENTA, aside = DARK_GREY, faded = LIGHT_GREY, rule = MAGENTA}

COMIC_PARCHMENT_LIT :: [Light]Comic {
	.Day     = COMIC_PARCHMENT,
	.Sunset  = {
		balloon = ON_CREAM_RED, caption = CAPTION_SUNSET, prompt = ON_CREAM_RED, bar = ON_CREAM_RED,
		panel = ON_CREAM_RED, row = ON_CREAM_PLAIN, picked = ON_YELLOW, title = CAPTION_SUNSET, tag = ON_YELLOW,
		line = BLACK, ground = YELLOW, heading = YELLOW, subtitle = WHITE, note = YELLOW, capitals = true,
	},
	.Night   = {
		balloon = ON_CREAM_BLUE, caption = CAPTION_NIGHT, prompt = ON_CREAM_BLUE, bar = ON_CREAM_BLUE,
		panel = ON_CREAM_BLUE, row = ON_CREAM_PLAIN, picked = ON_YELLOW, title = CAPTION_NIGHT, tag = ON_YELLOW,
		line = BLACK, ground = YELLOW, heading = YELLOW, subtitle = WHITE, note = YELLOW, capitals = true,
	},
	.Sunrise = {
		balloon = ON_CREAM_MAGENTA, caption = CAPTION_SUNRISE, prompt = ON_CREAM_MAGENTA, bar = ON_CREAM_MAGENTA,
		panel = ON_CREAM_MAGENTA, row = ON_CREAM_PLAIN, picked = ON_YELLOW, title = CAPTION_SUNRISE, tag = ON_YELLOW,
		line = BLACK, ground = YELLOW, heading = YELLOW, subtitle = WHITE, note = YELLOW, capitals = true,
	},
}

@(private) the_look: Look
@(private) the_comic: Comic = COMIC_BEGA
@(private) the_comics: [Light]Comic // set_look_lit's, one for each light
@(private) comic_lit: bool

// Which look the engine draws in, and in the comic, which theme. Once, at
// startup; a tool never calls it and keeps the boxes.
set_look :: proc(look: Look, comic := COMIC_BEGA) {
	the_look = look
	the_comic = comic
	comic_lit = false
}

// The same, with a theme for each light: the comic is drawn in the one for
// the light the player sees (comic_follow_light). On the title screen, the
// one for the light its picture is in (Menu.lights), or day's.
set_look_lit :: proc(look: Look, by_light: [Light]Comic) {
	the_look = look
	the_comics = by_light
	the_comic = by_light[.Day]
	comic_lit = true
}

// The theme for the light she sees now, once a frame before anything is
// drawn. Nothing, for a game with one theme.
@(private)
comic_follow_light :: proc(w: ^World) {
	if comic_lit do the_comic = the_comics[w.light]
}

current_look :: proc() -> Look {
	return the_look
}

// --- The lettering ---

// Tiny5 is drawn on an 8-pixel em: one font pixel is 128 of its 1024 units,
// so at 8 every edge falls on a whole pixel and nothing is half covered.
// raylib sizes a font by its whole height, ascender to descender (896 + 256
// units), not by its em: 9 pixels of that is the 8-pixel em.
LETTER_SIZE :: 9
// A line of lettering, in font pixels: the cap height, the descender and a
// gap, as the mockups set it.
LETTER_LINE :: 10

@(private) TINY5 :: #load("fonts/Tiny5-Regular.ttf")
@(private) letters: rl.Font
@(private) letters_loaded: bool

// The font, loaded the first time it is wanted (it needs a window). The
// glyphs are made hard-edged before they are packed: a pixel is ink or it is
// not, so nothing grey survives being blown up.
@(private)
letter_font :: proc() -> rl.Font {
	if letters_loaded do return letters
	letters_loaded = true
	// ASCII and Latin-1, which Tiny5 has all of but the soft hyphen (U+00AD,
	// never drawn anyway): a pound sign, an e acute.
	points: [95 + 95]rune
	for i in 0 ..< 95 do points[i] = rune(32 + i)
	n := 95
	for c in 160 ..< 256 do if c != 0xAD { points[n] = rune(c); n += 1 }
	count: i32
	glyphs := rl.LoadFontData(raw_data(TINY5), i32(len(TINY5)), LETTER_SIZE, &points[0], len(points), .DEFAULT, &count)
	if glyphs == nil || count == 0 {
		fmt.eprintln("nengine: could not read the lettering font; using raylib's")
		letters = rl.GetFontDefault()
		return letters
	}
	for i in 0 ..< count {
		img := glyphs[i].image
		if img.data == nil do continue
		px := ([^]u8)(img.data)
		for j in 0 ..< img.width * img.height do px[j] = 255 if px[j] >= 128 else 0
	}
	recs: [^]rl.Rectangle
	atlas := rl.GenImageFontAtlas(glyphs, &recs, count, LETTER_SIZE, 2, 0)
	letters = rl.Font {
		baseSize     = LETTER_SIZE,
		glyphCount   = count,
		glyphPadding = 2,
		texture      = rl.LoadTextureFromImage(atlas),
		recs         = recs,
		glyphs       = glyphs,
	}
	rl.UnloadImage(atlas)
	rl.SetTextureFilter(letters.texture, .POINT)
	return letters
}

@(private)
letter_font_shutdown :: proc() {
	if !letters_loaded do return
	letters_loaded = false
	if letters.texture.id != rl.GetFontDefault().texture.id do rl.UnloadFont(letters)
	letters = {}
}

// Canvas pixels per font pixel: the reference scale rounded down to a whole
// number, so a stroke is three pixels wide everywhere and never three here
// and four there. 3 on a 1024-wide canvas.
letter_scale :: proc() -> f32 {
	return max(1, math.floor(ui_scale()))
}

// A line of lettering, in canvas pixels.
letter_line :: proc() -> f32 {
	return LETTER_LINE * letter_scale()
}

// The words as the comic letters them.
@(private)
lettered :: proc(text: string) -> string {
	t := plain_text(text)
	if the_comic.capitals do t = strings.to_upper(t, context.temp_allocator)
	return t
}

// How wide `text` is when lettered, in canvas pixels.
letters_width :: proc(text: string) -> f32 {
	if text == "" do return 0
	return rl.MeasureTextEx(letter_font(), temp_cstring(lettered(text)), LETTER_SIZE * letter_scale(), 0).x
}

// Letters `text` with its top-left at (x, y), on whole pixels. Returns where
// it ended.
letters_draw :: proc(text: string, x, y: f32, color: rl.Color, scale: f32 = 0) -> f32 {
	if text == "" do return x
	k := scale if scale > 0 else letter_scale()
	t := temp_cstring(lettered(text))
	rl.DrawTextEx(letter_font(), t, {math.round(x), math.round(y)}, LETTER_SIZE * k, 0, color)
	return x + rl.MeasureTextEx(letter_font(), t, LETTER_SIZE * k, 0).x
}

// Wrapped lines, each in `ink` but for its stage directions — whatever is
// inside brackets, which can run on from one line to the next — in `aside`.
@(private)
letters_rich :: proc(lines: []string, x, y: f32, ink, aside: rl.Color) {
	inside := false
	for line, i in lines {
		at := x
		ly := y + f32(i) * letter_line()
		start := 0
		for c, j in line {
			switch {
			case c == '(' && !inside:
				at = letters_draw(line[start:j], at, ly, ink)
				start, inside = j, true
			case c == ')' && inside:
				at = letters_draw(line[start:j + 1], at, ly, aside)
				start, inside = j + 1, false
			}
		}
		letters_draw(line[start:], at, ly, aside if inside else ink)
	}
}

// --- The grid ---
//
// The frames are drawn on the reference grid, 320 wide, so that a line one
// grid pixel thick lands on the same canvas pixels as a painted pixel would:
// grid x covers canvas columns round(x*s) up to round((x+1)*s).

@(private)
gx :: proc(v: f32) -> f32 {
	return math.round(v * ui_scale())
}

// A filled rectangle of grid pixels, x0..x1 and y0..y1 both inclusive.
@(private)
grid_fill :: proc(x0, y0, x1, y1: f32, c: rl.Color) {
	a := [2]f32{gx(x0), gx(y0)}
	b := [2]f32{gx(x1 + 1), gx(y1 + 1)}
	if b.x <= a.x || b.y <= a.y do return
	rl.DrawRectangleRec({a.x, a.y, b.x - a.x, b.y - a.y}, c)
}

// A one-grid-pixel line round the rectangle x0..x1, y0..y1.
@(private)
grid_outline :: proc(x0, y0, x1, y1: f32, c: rl.Color) {
	grid_fill(x0, y0, x1, y0, c)
	grid_fill(x0, y1, x1, y1, c)
	grid_fill(x0, y0, x0, y1, c)
	grid_fill(x1, y0, x1, y1, c)
}

// Whether a grid pixel takes a paper's second colour.
weave_on :: proc(weave: Weave, x, y: i32) -> bool {
	switch weave {
	case .Solid:   return false
	case .Checker: return (x + y) % 2 == 0
	case .Quarter: return x % 2 == 0 && y % 2 == 0
	}
	return false
}

// A weave over the whole canvas, white where it is on and clear elsewhere,
// made the first time it is wanted: drawn tinted, a cut of it is the second
// colour of any box, always in step with the grid.
@(private) weave_tex: [Weave]rl.Texture2D

@(private)
weave_texture :: proc(weave: Weave) -> rl.Texture2D {
	if weave_tex[weave].id != 0 do return weave_tex[weave]
	img := rl.GenImageColor(WIDTH, HEIGHT, {0, 0, 0, 0})
	s := ui_scale()
	for y in 0 ..< HEIGHT {
		gy := i32(math.floor((f32(y) + 0.5) / s))
		for x in 0 ..< WIDTH {
			g := i32(math.floor((f32(x) + 0.5) / s))
			if weave_on(weave, g, gy) do rl.ImageDrawPixel(&img, x, y, rl.WHITE)
		}
	}
	weave_tex[weave] = rl.LoadTextureFromImage(img)
	rl.UnloadImage(img)
	return weave_tex[weave]
}

// The room behind darkened the EGA way: every other grid pixel black, a
// checkerboard, rather than a translucent wash in a colour EGA never had.
@(private)
grid_dither :: proc(c: rl.Color) {
	rl.DrawTexture(weave_texture(.Checker), 0, 0, c)
}

// A rectangle of grid pixels, x0..x1 and y0..y1 both inclusive, in a paper.
@(private)
paper_fill :: proc(x0, y0, x1, y1: f32, p: Paper) {
	grid_fill(x0, y0, x1, y1, p.a)
	if p.weave == .Solid || p.a == p.b do return
	a := [2]f32{gx(x0), gx(y0)}
	b := [2]f32{gx(x1 + 1), gx(y1 + 1)}
	if b.x <= a.x || b.y <= a.y do return
	rl.DrawTextureRec(weave_texture(p.weave), {a.x, a.y, b.x - a.x, b.y - a.y}, a, p.b)
}

// The comic's balloon corners, stepped: two pixels in at the very corner, one
// on the next row. A one-pixel line round x0..x1, y0..y1 with them.
@(private)
round_outline :: proc(x0, y0, x1, y1: f32, c: rl.Color) {
	grid_fill(x0 + 2, y0, x1 - 2, y0, c)
	grid_fill(x0 + 2, y1, x1 - 2, y1, c)
	grid_fill(x0, y0 + 2, x0, y1 - 2, c)
	grid_fill(x1, y0 + 2, x1, y1 - 2, c)
	grid_fill(x0 + 1, y0 + 1, x0 + 1, y0 + 1, c)
	grid_fill(x1 - 1, y0 + 1, x1 - 1, y0 + 1, c)
	grid_fill(x0 + 1, y1 - 1, x0 + 1, y1 - 1, c)
	grid_fill(x1 - 1, y1 - 1, x1 - 1, y1 - 1, c)
}

// A box in a surface: its paper, a black line round it (two, `double`, for a
// heavy panel), and the surface's rule one paper pixel inside that. `round`
// steps the corners as a balloon's are. The shadow is the caller's.
@(private)
surface_box :: proc(x0, y0, x1, y1: f32, s: Surface, round := false, double := false) {
	line := the_comic.line
	if round {
		paper_fill(x0 + 1, y0 + 2, x1 - 1, y1 - 2, s.paper)
		paper_fill(x0 + 2, y0 + 1, x1 - 2, y0 + 1, s.paper)
		paper_fill(x0 + 2, y1 - 1, x1 - 2, y1 - 1, s.paper)
		round_outline(x0, y0, x1, y1, line)
	} else {
		paper_fill(x0, y0, x1, y1, s.paper)
		grid_outline(x0, y0, x1, y1, line)
	}
	if double do grid_outline(x0 + 1, y0 + 1, x1 - 1, y1 - 1, line)
	if s.rule.a == 0 do return
	in_ := f32(3 if double else 2)
	if round do round_outline(x0 + in_, y0 + in_, x1 - in_, y1 - in_, s.rule)
	else do grid_outline(x0 + in_, y0 + in_, x1 - in_, y1 - in_, s.rule)
}

@(private)
look_shutdown :: proc() {
	letter_font_shutdown()
	for &t in weave_tex {
		if t.id != 0 do rl.UnloadTexture(t)
		t = {}
	}
}

// --- Laying the words out ---
//
// Everything below is arithmetic, with the measuring handed in, so that it
// can be tested without a window (a font needs one).

Measure :: proc(text: string) -> f32

Comic_Metrics :: struct {
	scale:   f32,     // canvas pixels per grid pixel: 3.2 on a 1024-wide canvas
	line:    f32,     // a line of lettering, in canvas pixels
	grid_w:  f32,     // the canvas, in grid pixels: 320
	measure: Measure, // how wide some words are, in canvas pixels
}

@(private)
comic_metrics :: proc() -> Comic_Metrics {
	return {scale = ui_scale(), line = letter_line(), grid_w = f32(WIDTH) / ui_scale(), measure = letters_width}
}

// Splits text into lines no wider than max_width, measured as given. A
// newline is a break the writer meant and is kept; a blank line stays blank.
wrap_measured :: proc(text: string, max_width: f32, measure: Measure, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	rest := beats_as_breaks(plain_text(text))
	for para in strings.split_iterator(&rest, "\n") {
		words := strings.fields(para, context.temp_allocator)
		if len(words) == 0 {
			append(&out, "")
			continue
		}
		line := ""
		for word in words {
			longer := word if line == "" else strings.concatenate({line, " ", word}, allocator)
			if line != "" && measure(longer) > max_width {
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

// The measurements, in grid pixels. The mockups' own.
@(private) BALLOON_TOP :: 6     // a balloon's top edge
@(private) BALLOON_START :: 210 // the width a balloon tries first
@(private) BALLOON_MIN :: 40
@(private) BALLOON_PAD :: 7     // words in from the balloon's sides
@(private) BALLOON_LINES :: 4   // more than this and it widens rather than grows
@(private) INSET_STEP :: 47     // from the inset portrait's left edge to the balloon's
@(private) INSET_ROOM :: 50     // all the inset takes up, frame and gap
@(private) EDGE :: 4            // from the screen's edge
@(private) EDGE_INSET :: 8      // from the right edge, a balloon with an inset
@(private) CAPTION_START :: 190
@(private) CAPTION_PAD :: 6

// A speech balloon to lay out.
Balloon_Ask :: struct {
	text:     string, // the words, without the name
	name:     string, // over them, in the name colour; "" for none
	portrait: bool,   // an inset panel with their face
	voice:    bool,   // heard, not seen: square, a broken line, no inset
	side:     Box_Side,
	at:       Maybe(f32),         // where the speaker stands, grid x
	head:     Maybe(rl.Rectangle), // their head on screen, in grid pixels
}

// A balloon, laid out, in grid pixels.
Balloon :: struct {
	x, y, w, h: f32,
	lines:      []string,
	inset:      bool,
	inset_at:   [2]f32, // the portrait's top-left
	right:      bool,   // on the right-hand side of the screen
}

// Which side of the screen the balloon goes: the speaker's, by where they
// stand. Somebody standing in the middle, or not on screen at all, goes by
// their Speaker.side — so the protagonist in the middle of the floor and the
// person she is talking to still take a side each, and alternate.
balloon_on_right :: proc(ask: Balloon_Ask, grid_w: f32) -> bool {
	if x, ok := ask.at.?; ok {
		mid := grid_w / 2
		if abs(x - mid) >= grid_w / 8 do return x > mid
	}
	return ask.side == .Right
}

plan_balloon :: proc(ask: Balloon_Ask, m: Comic_Metrics) -> Balloon {
	b: Balloon
	b.inset = ask.portrait && !ask.voice
	b.right = balloon_on_right(ask, m.grid_w)
	b.y = BALLOON_TOP
	room := m.grid_w - EDGE - (EDGE_INSET if b.inset else EDGE) - (INSET_ROOM if b.inset else 0)
	balloon_fit(&b, ask, m, min(BALLOON_START, room), room)
	balloon_place(&b, m.grid_w)

	// Over the speaker's face: widest first, which is fewer lines and a
	// shorter balloon; then along the top, clear of their head.
	head, has_head := ask.head.?
	if !has_head || !balloon_covers(b, head) do return b
	balloon_fit(&b, ask, m, room, room)
	balloon_place(&b, m.grid_w)
	if !balloon_covers(b, head) do return b
	left, right := balloon_span(b)
	span := right - left
	// To the side of the head the balloon is on, then the other.
	tries := [2]f32{head.x + head.width + 4, head.x - 4 - span}
	if !b.right do tries = {tries[1], tries[0]}
	for start in tries {
		if start < EDGE || start + span > m.grid_w - EDGE do continue
		moved := b
		shift := start - left
		moved.x += shift
		moved.inset_at.x += shift
		if !balloon_covers(moved, head) do return moved
	}
	return b
}

// The words wrapped at `width`, widened (up to `room`) while they run to too
// many lines; then no wider than the words need.
@(private)
balloon_fit :: proc(b: ^Balloon, ask: Balloon_Ask, m: Comic_Metrics, width, room: f32) {
	w := width
	lines := wrap_measured(ask.text, (w - BALLOON_PAD * 2) * m.scale, m.measure)
	for len(lines) > BALLOON_LINES && w < room {
		w = min(w + 10, room)
		lines = wrap_measured(ask.text, (w - BALLOON_PAD * 2) * m.scale, m.measure)
	}
	widest := m.measure(fmt.tprintf("%v:", ask.name)) if ask.name != "" else 0
	for l in lines do widest = max(widest, m.measure(l))
	b.w = clamp(math.ceil(widest / m.scale) + BALLOON_PAD * 2, BALLOON_MIN, w)
	b.lines = lines
	rows := len(lines) + (1 if ask.name != "" else 0)
	b.h = math.floor(f32(rows) * m.line / m.scale) + 8
}

// Flush to the edge on its side, the inset (if any) on its left.
@(private)
balloon_place :: proc(b: ^Balloon, grid_w: f32) {
	if b.right {
		b.x = grid_w - (EDGE_INSET if b.inset else EDGE) - b.w
	} else {
		b.x = EDGE + (INSET_ROOM if b.inset else 0)
	}
	b.inset_at = {b.x - INSET_STEP, max(EDGE, b.y)}
}

// The balloon and its inset together, left to right.
@(private)
balloon_span :: proc(b: Balloon) -> (left, right: f32) {
	left = b.x - INSET_ROOM if b.inset else b.x
	return left, b.x + b.w
}

@(private)
balloon_covers :: proc(b: Balloon, head: rl.Rectangle) -> bool {
	left, right := balloon_span(b)
	bottom := b.y + b.h
	if b.inset do bottom = max(bottom, b.inset_at.y + 55)
	return left < head.x + head.width && head.x < right && head.y < bottom + 2
}

// A caption, laid out, in grid pixels.
Caption :: struct {
	x, y, w, h: f32,
	lines:      []string,
	label:      string, // a first line in the name colour: a title
}

// A caption at (x, y) that starts `start` wide and widens, up to `room`,
// while the words run past four lines; then no wider than they need.
plan_caption :: proc(text: string, m: Comic_Metrics, x: f32 = EDGE, y: f32 = EDGE, start: f32 = CAPTION_START, room: f32 = 0, label := "") -> Caption {
	c := Caption{x = x, y = y, label = label}
	most := room if room > 0 else m.grid_w - x - EDGE
	w := min(start, most)
	lines := wrap_measured(text, (w - CAPTION_PAD * 2) * m.scale, m.measure)
	for len(lines) > BALLOON_LINES && w < most {
		w = min(w + 10, most)
		lines = wrap_measured(text, (w - CAPTION_PAD * 2) * m.scale, m.measure)
	}
	widest := m.measure(label)
	for l in lines do widest = max(widest, m.measure(l))
	c.w = clamp(math.ceil(widest / m.scale) + CAPTION_PAD * 2, 20, w)
	c.lines = lines
	rows := len(lines) + (1 if label != "" else 0)
	c.h = math.floor(f32(rows) * m.line / m.scale) + 9
	return c
}

// --- Drawing them ---

// The message that is up, as the comic shows it.
@(private)
draw_comic_message :: proc(w: ^World, text: string) {
	m := comic_metrics()
	ask, balloon := comic_ask(w, text, m.scale)
	if !balloon {
		draw_caption(plan_caption(text, m))
		return
	}
	b := plan_balloon(ask, m)
	draw_balloon(b, ask.name, ask.voice)
	if b.inset {
		who := w.message_who
		f := i32(w.time * who.fps) if who.fps > 0 else who.frame
		draw_sprite_at(who.portrait, f %% max(who.portrait.frames, 1), i32(gx(b.inset_at.x)), i32(gx(b.inset_at.y)))
	}
}

// What the message up now is, as the comic lays it out: a balloon, and who
// for, and where they stand; or (`balloon` false) a caption — the game's own
// words, or a stage direction in a conversation, which nobody says.
// `scale` is canvas pixels per grid pixel.
comic_ask :: proc(w: ^World, text: string, scale: f32) -> (ask: Balloon_Ask, balloon: bool) {
	sp := w.message_who if w.message_who != nil else w.message_speaker
	if w.message_mode == .Narration || sp == nil do return {text = text}, false
	ask.name = sp.name
	ask.text = text
	// Named on the box already ("a man: ..."): the name goes over the words.
	if sp.name != "" && strings.has_prefix(text, sp.name) && strings.has_prefix(text[len(sp.name):], ": ") {
		ask.text = text[len(sp.name) + 2:]
	}
	ask.portrait = w.message_who != nil && w.message_who.portrait.texture.id != 0
	ask.side = sp.side
	if r, seen := speaker_bounds(w, sp); seen {
		ask.at = (r.x + r.width / 2) / scale
		ask.head = rl.Rectangle{r.x / scale, r.y / scale, r.width / scale, r.height * 0.3 / scale}
	} else if sp.portrait.texture.id == 0 {
		// Nobody to see and no face to show: a voice.
		ask.voice = true
	}
	return ask, true
}

// Who on screen answers to a speaker's name: the player, or somebody in the
// room, by the whole name or its last word ("Mrs Hargreave" is `hargreave`),
// as an object's name or the .char it wears. Their sprite's rectangle.
speaker_bounds :: proc(w: ^World, sp: ^Speaker) -> (r: rl.Rectangle, ok: bool) {
	if sp == nil || sp.name == "" || len(w.scenes) == 0 do return {}, false
	// A split close-up, a ride or a close-up is not the room.
	if peeping(w) || riding(w) do return {}, false
	if _, _, shot := conversation_shot(w); shot do return {}, false
	answers :: proc(name, noun: string) -> bool {
		if noun == "" do return false
		if strings.equal_fold(name, noun) do return true
		space := strings.last_index_byte(name, ' ')
		return space >= 0 && strings.equal_fold(name[space + 1:], noun)
	}
	if (w.player_name != "" && answers(sp.name, w.player_name)) || (w.player.character != nil && answers(sp.name, w.player.character.name)) {
		return sprite_bounds(actor_sprite(w.player), w.player.pos), true
	}
	for &o in current_scene(w).objects {
		if o.hidden || !(answers(sp.name, o.name) || answers(sp.name, o.char_name)) do continue
		if o.walks do return sprite_bounds(actor_sprite(o.actor), o.actor.pos), true
		return sprite_bounds(o.sprite, o.pos), true
	}
	return {}, false
}

// The sprite draw_actor would draw, for its size.
@(private)
actor_sprite :: proc(a: Actor) -> Sprite {
	if a.character != nil {
		if a.anim != "" {
			if part := a.character.parts[a.anim]; part.sprite.texture.id != 0 do return part.sprite
		}
		want := a.pose if a.pose != "" else facing_part(a.facing, a.walking)
		if part := a.character.parts[want]; part.sprite.texture.id != 0 do return part.sprite
		if part := a.character.parts[facing_part(a.facing, false)]; part.sprite.texture.id != 0 do return part.sprite
	}
	return a.walk if a.walking else a.idle
}

// A balloon: rounded, or square with a broken line for a voice; the name
// over the words; the inset's frame (the portrait goes in after).
@(private)
draw_balloon :: proc(b: Balloon, name: string, voice: bool) {
	c := the_comic
	s := c.balloon
	x0, y0, x1, y1 := b.x, b.y, b.x + b.w - 1, b.y + b.h - 1
	if voice {
		// Heard, not seen: no rule, only the line broken two on, two off.
		paper_fill(x0, y0, x1, y1, s.paper)
		for i := x0; i <= x1; i += 4 {
			grid_fill(i, y0, min(i + 1, x1), y0, c.line)
			grid_fill(i, y1, min(i + 1, x1), y1, c.line)
		}
		for j := y0; j <= y1; j += 4 {
			grid_fill(x0, j, x0, min(j + 1, y1), c.line)
			grid_fill(x1, j, x1, min(j + 1, y1), c.line)
		}
	} else {
		surface_box(x0, y0, x1, y1, s, round = true)
	}
	if b.inset {
		ix, iy := b.inset_at.x, b.inset_at.y
		paper_fill(ix - 2, iy - 2, ix + 45, iy + 53, c.panel.paper)
		grid_outline(ix - 3, iy - 3, ix + 46, iy + 54, c.line)
		grid_outline(ix - 1, iy - 1, ix + 44, iy + 52, c.line)
		grid_fill(ix, iy, ix + 43, iy + 51, c.ground)
	}
	tx, ty := gx(b.x + BALLOON_PAD), gx(b.y + 3)
	if name != "" {
		letters_draw(fmt.tprintf("%v:", name), tx, ty, s.name)
		ty += letter_line()
	}
	letters_rich(b.lines, tx, ty, s.ink, s.aside)
}

// A caption: narration's box, a black line, a black shadow down and to the
// right. Its first line, if it has a label, in the surface's name ink; a
// stage direction in it is in the ink, because nobody is saying it.
@(private)
draw_caption :: proc(cap: Caption, s := the_comic.caption) {
	c := the_comic
	x0, y0 := cap.x, cap.y
	grid_fill(x0 + 2, y0 + 2, x0 + cap.w + 1, y0 + cap.h + 1, c.line)
	surface_box(x0, y0, x0 + cap.w - 1, y0 + cap.h - 1, s)
	tx, ty := gx(x0 + CAPTION_PAD), gx(y0 + 4)
	if cap.label != "" {
		letters_draw(cap.label, tx, ty, s.name)
		ty += letter_line()
	}
	letters_rich(cap.lines, tx, ty, s.ink, s.ink)
}

@(private = "file") cursor_clock: f32

// The typing line: a white panel that pops up over the foot of the picture
// while something is typed, as Sierra's SCI0 parser window did (Laura Bow,
// 1989): a red `>`, the words, a block cursor, and a caption's shadow.
@(private)
draw_comic_prompt :: proc(w: ^World) {
	// Only while something is being typed: an empty bar is a white slab
	// over the bottom of the picture. The cursor starts lit with the first key.
	if w.input_len == 0 {
		cursor_clock = 0
		return
	}
	c := the_comic
	s := c.prompt
	gh := f32(HEIGHT) / ui_scale()
	gw := f32(WIDTH) / ui_scale()
	left, right := f32(12), gw - 15
	top, bottom := gh - 39, gh - 10
	grid_fill(left + 2, top + 2, right + 2, bottom + 2, c.line)
	surface_box(left, top, right, bottom, s, double = true)
	x, y := gx(left + 6), gx(top + 10)
	letters_draw(">", x, y, s.name)
	end := letters_draw(string(w.input[:w.input_len]), x + letters_width("> "), y, s.ink)
	// Blinking by the frames it has been drawn for, not the world's clock: a
	// cursor is not part of the story, and a harness that moved the world on
	// would otherwise catch it out every other time.
	cursor_clock += min(rl.GetFrameTime(), 1.0 / 30) // not the seconds a first frame waited
	if i32(cursor_clock * 2) % 2 == 0 {
		k := letter_scale()
		rl.DrawRectangleRec({math.round(end) + 2 * k, y + 2 * k, 3 * k + 1, 7 * k + 1}, s.ink)
	}
}

// The heavy frame round a picture in a panel: the panel's paper, then two
// black lines.
@(private)
draw_picture_frame :: proc(x, y, w, h: f32) {
	c := the_comic
	paper_fill(x - 4, y - 4, x + w + 3, y + h + 3, c.panel.paper)
	grid_outline(x - 3, y - 3, x + w + 2, y + h + 2, c.line)
	grid_outline(x - 2, y - 2, x + w + 1, y + h + 1, c.line)
}

// A button: a small panel with a shadow, a row, or the picked surface when it
// is the one picked, the word centred in it.
@(private)
draw_comic_button :: proc(r: rl.Rectangle, label: string, picked, ready: bool) {
	c := the_comic
	s := ui_scale()
	x0, y0 := math.round(r.x / s), math.round(r.y / s)
	x1, y1 := math.round((r.x + r.width) / s) - 1, math.round((r.y + r.height) / s) - 1
	grid_fill(x0 + 2, y0 + 2, x1 + 2, y1 + 2, c.line)
	sf := c.picked if picked else c.row
	surface_box(x0, y0, x1, y1, sf)
	tw := letters_width(label)
	cx := (gx(x0) + gx(x1 + 1)) / 2
	// The capitals stand from 2 to 7 font pixels under the top of the line.
	ty := (gx(y0) + gx(y1 + 1)) / 2 - 4.5 * letter_scale()
	letters_draw(label, cx - tw / 2, ty, sf.ink if ready else sf.faded)
}

// A panel for a game's own overlay (draw_panel): its fill, a black line and
// a shadow, on the grid.
@(private)
draw_comic_panel :: proc(fill: rl.Color, r: rl.Rectangle) {
	c := the_comic
	s := ui_scale()
	x0, y0 := math.round(r.x / s), math.round(r.y / s)
	x1, y1 := math.round((r.x + r.width) / s) - 1, math.round((r.y + r.height) / s) - 1
	grid_fill(x0 + 2, y0 + 2, x1 + 2, y1 + 2, c.line)
	grid_fill(x0, y0, x1, y1, fill)
	grid_outline(x0, y0, x1, y1, c.line)
}
