package nengine

import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

// A title screen: the game's name over a scrolling parallax picture, and a
// short list of choices. The game says what the choices are and decides what
// they do.
//
// Parallax: the picture is a stack of layers, back to front, each drifting
// sideways at its own speed. Far layers (sky, distant hills) crawl; near ones
// (the street) move faster. The difference in speed is what makes it look
// deep. Each layer repeats sideways, so it can drift forever.
//
// **Dusk**: a layer can be painted twice, in the light the title opens in and
// in a later one (`Layer.night`, the same size). Over `Menu.dusk_seconds`
// from the moment the title first shows, every layer dissolves into its
// night painting the Sierra way, a pixel at a time in a fixed order, so that
// half way it is an even dither of the two (dissolve.odin), while it goes on
// drifting; then it stays night. Light is
// paintings, not a dimmer: nothing is tinted or faded. NENGINE_TITLE_DUSK=30
// in the environment overrides the game's seconds, for trying a timing
// without a rebuild.
//
// **Lettering**: an `overline` over the title (who the story is about), the
// `title`, the `subtitle` under it, the choices, and a `byline` at the very
// bottom (who made it). Any of them may be left out.
//
// **About**: `about`, the game's own page of words, opened by the game from
// one of its choices (`open_about`, from Front.on_menu). It comes up over the
// title, which goes on drifting behind it; Esc, Enter or a click puts it away.

Layer :: struct {
	sprite: Sprite, // at least as wide as the screen. Its left and right edges should join up.
	speed:  f32,    // pixels a second it drifts left. 0 stays put.
	y:      f32,    // where its top edge sits
	night:  Sprite, // the same layer painted in the later light, the same size; the dusk turns `sprite` into it. Zero: it never changes
	fps:    f32,    // a layer of several frames plays them at this rate, with their holds: moving water. 0 shows the first
}

// The game's page about itself: a tab and some paragraphs, wrapped to fit.
About :: struct {
	title: string,   // the tab over its corner: "About"
	lines: []string, // paragraphs; "" is a blank line between them
}

Menu :: struct {
	overline: cstring, // a small line over the title: "Ada Westcott in"
	title:    cstring,
	subtitle: cstring,
	byline:   cstring, // a small line at the very bottom: who made it
	layers:   []Layer, // back to front
	items:    []cstring, // e.g. "Start", "Quit"
	music:    ^Loop,
	about:    About,

	// How long, in seconds from when the title first shows, the layers take
	// to dissolve into their `night` paintings. 0: they never do.
	// NENGINE_TITLE_DUSK overrides it (menu_dusk_seconds).
	dusk_seconds: f32,
	// The light the layers are painted in and the light their `night` is,
	// for a comic with a theme for each light (set_look_lit): its boxes take
	// the first light's theme and the second's once the dusk is half way. Left
	// zero, day's throughout.
	lights:   [2]Light,

	// Draws anything else over the layers, before the title and the
	// choices. A car going by, say. t is seconds since the menu opened.
	extra:    proc(t: f32),

	// A line under the choices, for when picking one couldn't be done:
	// "nart isn't built". Empty most of the time.
	note:     string,

	pick:     int,
	time:     f32,
	playing:  bool,

	// The dusk under way: when it began (menu time), how long it is, and,
	// for the harness's `!title at=F`, a progress held still.
	dusk_on:    bool,
	dusk_from:  f32,
	dusk_secs:  f32,
	dusk_held:  bool,
	dusk_hold:  f32,
	dissolves:  [dynamic]Dissolve, // one a layer, made the first frame the menu is drawn
	about_open: bool,
	covered:    bool, // a screen is up over the title (the Load screen): it takes the keys and the mouse
}

// The environment variable that overrides Menu.dusk_seconds: a number of
// seconds, read when the dusk begins. `NENGINE_TITLE_DUSK=30 just game`.
TITLE_DUSK_ENV :: "NENGINE_TITLE_DUSK"

// The dusk's length: the environment's, if it holds a number, or the game's.
menu_dusk_seconds :: proc(m: ^Menu) -> f32 {
	if v := os.get_env(TITLE_DUSK_ENV, context.temp_allocator); v != "" {
		if s, ok := strconv.parse_f32(strings.trim_space(v)); ok && s >= 0 do return s
	}
	return m.dusk_seconds
}

// How far the dusk has come, 0 (the first painting) to 1 (night).
menu_dusk :: proc(m: ^Menu) -> f32 {
	if m.dusk_held do return clamp(m.dusk_hold, 0, 1)
	if !m.dusk_on do return 0
	return dusk_progress(m.time - m.dusk_from, m.dusk_secs)
}

// Puts the game's About page up over the title.
open_about :: proc(m: ^Menu) {
	m.about_open = true
}

about_open :: proc(m: ^Menu) -> bool {
	return m.about_open
}

// Run the menu for a frame. Returns the index of the item chosen, or -1.
//   Up/Down (or numpad 8/2): move.   Enter/Space: choose.   Mouse: point and click.
update_menu :: proc(m: ^Menu, dt: f32) -> (chosen: int) {
	m.time += dt
	if !m.dusk_on {
		// The title has just come up: the dusk begins now, every time it does.
		m.dusk_on, m.dusk_from, m.dusk_secs = true, m.time, menu_dusk_seconds(m)
	}
	if m.music != nil {
		if !m.playing do rl.PlayMusicStream(m.music.music)
		m.playing = true
		rl.UpdateMusicStream(m.music.music)
	}

	if m.covered do return -1
	if m.about_open {
		if rl.IsKeyPressed(.ESCAPE) || rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) ||
		   rl.IsKeyPressed(.SPACE) || rl.IsMouseButtonPressed(.LEFT) {
			m.about_open = false
		}
		return -1
	}

	n := len(m.items)
	if n == 0 do return -1
	if rl.IsKeyPressed(.UP) || rl.IsKeyPressed(.KP_8) do m.pick = (m.pick + n - 1) % n
	if rl.IsKeyPressed(.DOWN) || rl.IsKeyPressed(.KP_2) || rl.IsKeyPressed(.TAB) do m.pick = (m.pick + 1) % n

	mouse := mouse_pos()
	for i in 0 ..< n {
		if !in_rect(mouse, menu_item_rect(m, i)) do continue
		if rl.GetMouseDelta() != {0, 0} do m.pick = i
		if rl.IsMouseButtonPressed(.LEFT) do return i
	}

	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) || rl.IsKeyPressed(.SPACE) do return m.pick
	return -1
}

// Stop the menu's music, e.g. when the game starts. The dusk goes with it:
// if the title comes up again it begins again, from the first painting.
leave_menu :: proc(m: ^Menu) {
	if m.music != nil do rl.StopMusicStream(m.music.music)
	m.playing = false
	m.dusk_on = false
	m.about_open = false
	for &d in m.dissolves do dissolve_free(&d)
	delete(m.dissolves)
	m.dissolves = nil
}

// Draws the title, and over it the world's screen if one is up (the Load
// screen from the title, title_load).
draw_menu :: proc(m: ^Menu, w: ^World = nil) {
	begin_canvas()
	rl.ClearBackground(rl.BLACK)

	dusk := menu_dusk(m)
	menu_dusk_layers(m, dusk)
	for i in 0 ..< len(m.layers) do draw_layer(menu_layer_now(m, i, dusk), m.time)
	if m.extra != nil do m.extra(m.time)
	if the_look == .Comic {
		// The boxes in the light the picture is in, as a room's are.
		if comic_lit do the_comic = the_comics[m.lights[1] if dusk >= 0.5 else m.lights[0]]
		draw_comic_menu(m)
		if m.about_open do draw_comic_about(m)
		if w != nil && screen_open(w) != .None do screen_draw(w)
		end_canvas()
		return
	}

	if m.overline != nil {
		fs := ufont(8)
		ow := rl.MeasureText(m.overline, fs)
		rl.DrawText(m.overline, (WIDTH - ow) / 2 + ui(1), ui(9), fs, rl.BLACK)
		rl.DrawText(m.overline, (WIDTH - ow) / 2, ui(8), fs, rl.RAYWHITE)
	}
	// The title, big, with a drop shadow.
	if m.title != nil {
		fs := ufont(20)
		tw := rl.MeasureText(m.title, fs)
		x := (WIDTH - tw) / 2
		rl.DrawText(m.title, x + ui(2), ui(22), fs, rl.BLACK)
		rl.DrawText(m.title, x, ui(20), fs, {232, 200, 120, 255})
	}
	if m.subtitle != nil {
		fs := ufont(10)
		sw := rl.MeasureText(m.subtitle, fs)
		rl.DrawText(m.subtitle, (WIDTH - sw) / 2 + ui(1), ui(45), fs, rl.BLACK)
		rl.DrawText(m.subtitle, (WIDTH - sw) / 2, ui(44), fs, rl.RAYWHITE)
	}
	if m.byline != nil {
		fs := ufont(8)
		bw := rl.MeasureText(m.byline, fs)
		y := HEIGHT - ui(12)
		rl.DrawText(m.byline, (WIDTH - bw) / 2 + ui(1), y + ui(1), fs, rl.BLACK)
		rl.DrawText(m.byline, (WIDTH - bw) / 2, y, fs, rl.RAYWHITE)
	}

	// The choices.
	gold := rl.Color{200, 168, 90, 255}
	fs := ufont(10)
	for item, i in m.items {
		r := menu_item_rect(m, i)
		picked := i == m.pick
		rl.DrawRectangleRec(r, gold if picked else rl.Color{18, 12, 20, 220})
		rl.DrawRectangleLinesEx(r, uf(1), gold)
		tw := rl.MeasureText(item, fs)
		ink := rl.Color{18, 12, 20, 255} if picked else rl.RAYWHITE
		rl.DrawText(item, i32(r.x) + (i32(r.width) - tw) / 2, i32(r.y) + ui(3), fs, ink)
	}

	if m.note != "" {
		text := temp_cstring(m.note)
		tw := rl.MeasureText(text, fs)
		y := i32(menu_item_rect(m, len(m.items)).y) + ui(4)
		rl.DrawText(text, (WIDTH - tw) / 2 + ui(1), y + ui(1), fs, rl.BLACK)
		rl.DrawText(text, (WIDTH - tw) / 2, y, fs, {230, 150, 120, 255})
	}

	if m.about_open do draw_boxes_about(m)
	if w != nil && screen_open(w) != .None do screen_draw(w)

	end_canvas()
}

@(private)
menu_item_rect :: proc(m: ^Menu, i: int) -> rl.Rectangle {
	w := uf(80)
	return {(f32(WIDTH) - w) / 2, uf(70) + f32(i) * uf(20), w, uf(14)}
}

// The dissolves, made the first time they are wanted (they read the
// paintings back from the GPU) and turned on to `dusk`. Each layer has its
// own seed, so the three do not turn the same pixels at the same moment.
@(private)
menu_dusk_layers :: proc(m: ^Menu, dusk: f32) {
	any_night := false
	for l in m.layers do if l.night.texture.id != 0 do any_night = true
	if !any_night do return
	if len(m.dissolves) != len(m.layers) {
		for &d in m.dissolves do dissolve_free(&d)
		clear(&m.dissolves)
		for l, i in m.layers do append(&m.dissolves, dissolve_make(l.sprite, l.night, DISSOLVE_SEED + u64(i) * 7919))
	}
	for &d in m.dissolves do dissolve_set(&d, dusk)
}

// The layer as it is now: the dissolve's picture, or, when the two paintings
// could not be dissolved, the first until half way and the night after.
@(private)
menu_layer_now :: proc(m: ^Menu, i: int, dusk: f32) -> Layer {
	l := m.layers[i]
	if l.night.texture.id == 0 do return l
	if i < len(m.dissolves) && m.dissolves[i].ok {
		l.sprite = m.dissolves[i].sprite
	} else if dusk >= 0.5 {
		l.sprite = l.night
	}
	return l
}

// Draws a layer repeated sideways, shifted by how far it has drifted. The
// title screen's layers and a room's drifting ones (Drift, scene.odin) are
// both drawn by this.
@(private)
draw_layer :: proc(l: Layer, time: f32) {
	w := f32(l.sprite.frame_w)
	if w <= 0 do return
	frame := layer_frame(l, time)
	for x := layer_offset(time, l.speed, w); x < f32(WIDTH); x += w {
		draw_sprite_at(l.sprite, frame, i32(x), i32(l.y))
	}
}

// Which of its frames a layer shows at `time`: its first, unless it has
// several and an `fps`, when it plays them in a loop as a sprite does.
@(private)
layer_frame :: proc(l: Layer, time: f32) -> i32 {
	if l.fps <= 0 || l.sprite.frames <= 1 do return 0
	frame, _ := anim_frame(time, l.fps, l.sprite.frames, l.sprite.holds)
	return frame
}

// Where a layer's first copy starts: slides from 0 down towards -width, then
// jumps back to 0, which looks seamless because the layer's ends join up.
@(private)
layer_offset :: proc(time, speed, width: f32) -> f32 {
	gone := time * speed
	return -(gone - width * f32(int(gone / width)))
}

// Where the title screen's lettering stands, in grid pixels from the top: the
// overline, the title, the subtitle, and the byline's distance from the foot.
@(private) MENU_OVERLINE_Y :: 8
@(private) MENU_TITLE_Y :: 19
@(private) MENU_SUBTITLE_Y :: 45
@(private) MENU_BYLINE_UP :: 12

// The comic's title screen: the title and the lines round it lettered, with a
// black shadow, and the choices as small panels, the picked one yellow. The
// byline at the foot stands over the busiest part of the picture, so it is
// outlined in black all round as well.
@(private = "file")
draw_comic_menu :: proc(m: ^Menu) {
	c := the_comic
	k := letter_scale()
	if m.overline != nil {
		t := string(m.overline)
		x := math.round((f32(WIDTH) - letters_width(t)) / 2)
		letters_draw(t, x + k, uf(MENU_OVERLINE_Y) + k, c.line)
		letters_draw(t, x, uf(MENU_OVERLINE_Y), c.subtitle)
	}
	if m.title != nil {
		big := k * 2
		t := string(m.title)
		x := math.round((f32(WIDTH) - letters_width(t) * 2) / 2)
		letters_draw(t, x + big, uf(MENU_TITLE_Y) + big, c.line, big)
		letters_draw(t, x, uf(MENU_TITLE_Y), c.heading, big)
	}
	if m.subtitle != nil {
		t := string(m.subtitle)
		x := math.round((f32(WIDTH) - letters_width(t)) / 2)
		letters_draw(t, x + k, uf(MENU_SUBTITLE_Y) + k, c.line)
		letters_draw(t, x, uf(MENU_SUBTITLE_Y), c.subtitle)
	}
	if m.byline != nil {
		t := string(m.byline)
		x := math.round((f32(WIDTH) - letters_width(t)) / 2)
		y := f32(HEIGHT) - uf(MENU_BYLINE_UP)
		for d in ([][2]f32{{-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1}, {2, 2}}) {
			letters_draw(t, x + d.x * k, y + d.y * k, c.line)
		}
		letters_draw(t, x, y, c.subtitle)
	}
	for item, i in m.items do draw_comic_button(menu_item_rect(m, i), string(item), i == m.pick, true)
	if m.note != "" {
		x := math.round((f32(WIDTH) - letters_width(m.note)) / 2)
		y := menu_item_rect(m, len(m.items)).y + uf(4)
		letters_draw(m.note, x + k, y + k, c.line)
		letters_draw(m.note, x, y, c.note)
	}
}

// --- About ---

@(private) ABOUT_LEFT :: 24   // the panel's edges, in grid pixels
@(private) ABOUT_RIGHT :: 295
@(private) ABOUT_PAD :: 10    // the words' margin inside it
@(private) ABOUT_HEAD :: 14   // room under the tab
@(private) ABOUT_FOOT :: 20   // room for the hint

// The About page in the comic: the screens' panel (screens.odin) over the
// title darkened the EGA way, its tab over the corner, the words wrapped
// inside, and how to put it away at the foot.
@(private = "file")
draw_comic_about :: proc(m: ^Menu) {
	c := the_comic
	s := ui_scale()
	grid_dither(c.line)
	room := (ABOUT_RIGHT - ABOUT_LEFT + 1 - 2 * ABOUT_PAD) * s
	lines := about_lines(m.about, room, letters_width)
	text_h := math.ceil(f32(len(lines)) * letter_line() / s)
	gh := f32(HEIGHT) / s
	h := ABOUT_HEAD + text_h + ABOUT_FOOT
	x0, x1 := f32(ABOUT_LEFT), f32(ABOUT_RIGHT)
	y0 := math.floor((gh - h) / 2) + 3
	y1 := y0 + h - 1
	grid_fill(x0 + 2, y0 + 2, x1 + 2, y1 + 2, c.line)
	surface_box(x0, y0, x1, y1, c.panel, double = true)
	title := m.about.title if m.about.title != "" else "About"
	cap := plan_caption(title, comic_metrics(), x0 + 8, y0 - 9, 80)
	draw_caption(cap, c.title)
	letters_rich(lines, gx(x0 + ABOUT_PAD), gx(y0 + ABOUT_HEAD), c.panel.ink, c.panel.aside)
	letters_draw("Esc goes back.", gx(x0 + ABOUT_PAD), gx(y1 - ABOUT_FOOT + 7), c.panel.aside)
}

// The same in the boxes' look: a dark panel and raylib's own letters.
@(private = "file")
draw_boxes_about :: proc(m: ^Menu) {
	fs := ufont(8)
	r := rl.Rectangle{uf(ABOUT_LEFT), uf(20), uf(ABOUT_RIGHT - ABOUT_LEFT + 1), f32(HEIGHT) - uf(40)}
	rl.DrawRectangleRec(r, {18, 12, 20, 235})
	rl.DrawRectangleLinesEx(r, uf(1), {200, 168, 90, 255})
	y := i32(r.y) + ui(6)
	for para in m.about.lines {
		for line in wrap(para if para != "" else " ", i32(r.width) - ui(2 * ABOUT_PAD), fs) {
			rl.DrawText(line, i32(r.x) + ui(ABOUT_PAD), y, fs, rl.RAYWHITE)
			y += fs + ui(2)
		}
	}
}

// The About page's paragraphs wrapped to `room` canvas pixels, a blank line
// kept blank: what is lettered, a line at a time. Measured as given, so it
// can be tested without a window.
about_lines :: proc(a: About, room: f32, measure: Measure) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for para in a.lines {
		if para == "" {
			append(&out, "")
			continue
		}
		for line in wrap_measured(para, room, measure) do append(&out, line)
	}
	return out[:]
}
