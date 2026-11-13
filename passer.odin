package nengine

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"
import rl "vendor:raylib"

// Somebody going past outside: a figure that walks across a window, now and
// then, while the player is indoors.
//
//     ne.set_passer(&w, {character = "stranger", chance = 0.10, max_delay = 20, only = "light_night"})
//
// Each time the player comes into a room (go_to) that is `indoors`, has a
// `window` line whose `when=` holds, and while `only` holds, the passer rolls
// once: `chance` of somebody. On a hit it waits a random 0..max_delay seconds
// of real time (World.time, which stops under an overlay), then picks one of
// the room's open windows and a way to walk, and the figure crosses it at
// `speed`, from just past one edge of the glass to just past the other, in
// its walk. It is drawn clipped to the glass and just under the window's
// frame (Window.frame), so the frame, the room and everybody in it are in
// front of it. Leaving the room ends it.
//
// It is something seen and nothing else: no tick of the story clock, no flag,
// nothing in a save, nothing the parser knows. A game that wants somebody to
// mean something puts a person in the room file instead.
//
// The dice are the passer's own (`seed`, or the clock), so a test can say
// what they will throw. The harness throws the same ones every run: a script
// is seeded (run_script), and a passer a room rolled is walked out at once
// and printed, `[somebody passes the back window, left to right]`, the way a
// walk is. `!passer` forces one (script.odin).
Passer :: struct {
	character: string, // the figure: a .char with `walk_left` and `walk_right`
	chance:    f32,    // of somebody, per room come into: 0.10 is one in ten
	max_delay: f32,    // seconds of real time, at most, before they come
	only:      string, // a condition (flags.odin): "light_night", say
	speed:     f32,    // canvas pixels a second; 0 is PASSER_SPEED
	seed:      u64,    // the dice; 0 seeds them from the clock
}

// An unhurried walk at people scale on a 1024-wide canvas: a figure about 186
// tall (58 art pixels at 3.2) crosses a four-foot window in about two seconds.
PASSER_SPEED :: f32(110)

// What the harness seeds the dice with, so a script throws the same every run.
PASSER_SCRIPT_SEED :: u64(1962)

Passer_Phase :: enum {
	Idle,    // nobody: the roll missed, or they have gone by
	Waiting, // somebody is coming, at `starts_at`
	Walking, // across `window`, `walked` seconds of the way
	Held,    // stood at `held` of the way across, for a picture (the harness)
}

Passer_State :: struct {
	using cfg:  Passer,
	rng:        u64,
	scene:      int, // the room it was rolled for; leaving it ends it
	phase:      Passer_Phase,
	starts_at:  f32,
	walked:     f32, // seconds across, on its own clock: a stalled frame is not a walk skipped
	window:     int,
	rightward:  bool,
	held:       f32,
	forced:     bool, // the harness's: not walked out by it
}

// The item in draw_room's sort that is the passer.
@(private)
PASSER_ITEM :: min(int)

// Sets the passer up, once, at startup; it carries over a new game. With no
// character it is off. The strings are kept, not copied: pass literals.
set_passer :: proc(w: ^World, p: Passer) {
	w.passer.cfg = p
	if p.seed != 0 do w.passer.rng = p.seed
	passer_cancel(w)
}

// The dice, from here on: a test's, or the harness's.
passer_seed :: proc(w: ^World, seed: u64) {
	w.passer.rng = seed if seed != 0 else 1
}

// Nobody: whatever was coming or going past is gone.
passer_cancel :: proc(w: ^World) {
	w.passer.phase = .Idle
	w.passer.forced = false
	w.passer.scene = w.current
}

// A number in [0, 1) from the passer's dice (xorshift64*).
passer_rand :: proc(w: ^World) -> f32 {
	if w.passer.rng == 0 do w.passer.rng = u64(time.now()._nsec) | 1
	x := w.passer.rng
	x ~= x >> 12
	x ~= x << 25
	x ~= x >> 27
	w.passer.rng = x
	return f32((x * 0x2545F4914F6CDD1D) >> 40) / f32(1 << 24)
}

// How many of the room's windows are open now (their `when=` holds).
passer_windows_open :: proc(sc: ^Scene) -> int {
	n := 0
	for win in sc.windows do if !win.hidden do n += 1
	return n
}

// Could somebody go past here now? Indoors, a window open, and the game's
// condition holding.
passer_possible :: proc(w: ^World, sc: ^Scene) -> bool {
	return w.passer.character != "" && sc.indoors && passer_windows_open(sc) > 0 && condition_met(w, w.passer.only)
}

// The player has come into a room: end whatever was going past the last one
// and throw the dice for this one. go_to calls it.
passer_enter :: proc(w: ^World) {
	passer_cancel(w)
	if len(w.scenes) == 0 || !passer_possible(w, current_scene(w)) do return
	if passer_rand(w) >= w.passer.chance do return
	w.passer.phase = .Waiting
	w.passer.starts_at = w.time + passer_rand(w) * max(w.passer.max_delay, 0)
}

// Sets off across a window: `window` -1 for one of the open ones at random,
// `rightward` nil for either way at random. False if there is no window to
// cross, or nobody to cross it.
passer_start :: proc(w: ^World, window := -1, rightward: Maybe(bool) = nil) -> bool {
	if len(w.scenes) == 0 || passer_figure(w) == nil do return false
	sc := current_scene(w)
	at := window
	if at < 0 {
		open := passer_windows_open(sc)
		if open == 0 do return false
		pick := min(int(passer_rand(w) * f32(open)), open - 1)
		for win, i in sc.windows {
			if win.hidden do continue
			if pick == 0 {
				at = i
				break
			}
			pick -= 1
		}
	}
	if at < 0 || at >= len(sc.windows) do return false
	w.passer.window = at
	if r, given := rightward.?; given {
		w.passer.rightward = r
	} else {
		w.passer.rightward = passer_rand(w) < 0.5
	}
	w.passer.phase = .Walking
	w.passer.walked = 0
	w.passer.scene = w.current
	return true
}

// The longest a frame may move the figure: the first frame after loading, or
// after a stall, would otherwise carry seconds, and the walk be over unseen.
PASSER_MAX_STEP :: f32(1.0 / 15)

// Every frame, from update: off the room, it is gone; due, it sets off;
// across, it is done.
update_passer :: proc(w: ^World, dt: f32) {
	p := &w.passer
	if p.phase == .Idle do return
	if p.scene != w.current {
		passer_cancel(w)
		return
	}
	switch p.phase {
	case .Idle, .Held:
	case .Waiting:
		if w.time >= p.starts_at && !passer_start(w) do passer_cancel(w)
	case .Walking:
		p.walked += clamp(dt, 0, PASSER_MAX_STEP)
		if passer_progress(w) >= 1 do passer_cancel(w)
	}
}

// The figure's art, or nil if the game has none by that name.
passer_figure :: proc(w: ^World) -> ^Character_Art {
	if w.assets == nil || w.passer.character == "" do return nil
	art, found := &w.assets.chars[w.passer.character]
	return art if found else nil
}

// The figure's size on the canvas: its walk, or Ada's size, near enough, for a
// room with no figure to measure.
@(private)
passer_size :: proc(w: ^World) -> [2]f32 {
	if art := passer_figure(w); art != nil {
		for part in ([]string{"walk_right", "walk_left", "right", "front"}) {
			if s := art.parts[part].sprite; s.frame_h > 0 do return {f32(s.frame_w), f32(s.frame_h)}
		}
	}
	return {83, 166}
}

// Where a figure out there stands: the window's `feet`, or the foot of the
// glass and half a figure below it, so they show from the waist up.
window_feet :: proc(win: Window, figure_h: f32) -> f32 {
	if win.feet != 0 do return win.feet
	return win.glass.y + win.glass.height + figure_h / 2
}

// How far across, 0 at one edge to 1 past the other.
passer_progress :: proc(w: ^World) -> f32 {
	p := &w.passer
	switch p.phase {
	case .Idle, .Waiting: return 0
	case .Held:           return p.held
	case .Walking:
	}
	sc := current_scene(w)
	if p.window >= len(sc.windows) do return 1
	return p.walked * passer_speed(w) / passer_span(sc.windows[p.window].glass, passer_size(w).x)
}

@(private)
passer_speed :: proc(w: ^World) -> f32 {
	return w.passer.speed if w.passer.speed > 0 else PASSER_SPEED
}

// The way across: the glass, and the figure's width, so they come in from
// wholly out of sight and go wholly out of it.
passer_span :: proc(glass: rl.Rectangle, figure_w: f32) -> f32 {
	return max(glass.width + figure_w, 1)
}

// Their feet, `f` of the way across.
passer_feet :: proc(glass: rl.Rectangle, figure: [2]f32, feet_y: f32, f: f32, rightward: bool) -> [2]f32 {
	span := passer_span(glass, figure.x)
	if rightward do return {glass.x - figure.x / 2 + f * span, feet_y}
	return {glass.x + glass.width + figure.x / 2 - f * span, feet_y}
}

// The glass in whole canvas pixels and inside the canvas: the scissor the
// figure is drawn through, so it never shows on the wall.
passer_clip :: proc(glass: rl.Rectangle, canvas: [2]f32) -> (x, y, w, h: i32) {
	x0 := max(glass.x, 0)
	y0 := max(glass.y, 0)
	x1 := min(glass.x + glass.width, canvas.x)
	y1 := min(glass.y + glass.height, canvas.y)
	x, y = i32(x0 + 0.5), i32(y0 + 0.5)
	w, h = max(i32(x1 + 0.5) - x, 0), max(i32(y1 + 0.5) - y, 0)
	return
}

// Is somebody to be drawn in this room now, and at which window? The room on
// screen only, and not through a host's eyes.
passer_shown :: proc(w: ^World, sc: ^Scene) -> (shown: bool, window: int) {
	p := &w.passer
	if p.phase != .Walking && p.phase != .Held do return false, 0
	if len(w.scenes) == 0 || sc != current_scene(w) || riding(w) do return false, 0
	if p.window < 0 || p.window >= len(sc.windows) || passer_figure(w) == nil do return false, 0
	return true, p.window
}

// Where in draw_room's order: just under the window's frame (the item it is
// put before), or after everything at depth=back if it names none, or none
// that is here.
Passer_Key :: struct {
	depth: Depth,
	y:     f32,
	i:     int,
}

passer_key :: proc(sc: ^Scene, win: ^Window) -> Passer_Key {
	if win.frame != "" {
		for o, i in sc.objects do if o.name == win.frame && !o.hidden do return {o.depth, o.pos.y + o.base, i}
	}
	return {.Back, max(f32), len(sc.objects)}
}

// The figure, through the glass. Like a person, it wears the room's tint.
@(private)
draw_passer :: proc(w: ^World, win: ^Window, tint: Palette_Map, plain: bool) {
	art := passer_figure(w)
	if art == nil do return
	p := &w.passer
	size := passer_size(w)
	f := passer_progress(w)
	a := Actor {
		pos       = passer_feet(win.glass, size, window_feet(win^, size.y), f, p.rightward),
		character = art,
		facing    = .Right if p.rightward else .Left,
		walking   = true,
		speed     = passer_speed(w), // so a walk with `step=` keeps its feet (actor.odin)
		walk_fps  = 8,
		idle_fps  = 4,
		anim_time = f * passer_span(win.glass, size.x) / passer_speed(w),
	}
	x, y, cw, ch := passer_clip(win.glass, {f32(WIDTH), f32(HEIGHT)})
	if cw <= 0 || ch <= 0 do return
	rl.BeginScissorMode(x, y, cw, ch)
	if !plain do begin_tint(tint)
	draw_actor(a)
	if !plain do end_tint()
	rl.EndScissorMode()
}

// The harness: `[somebody passes the back window, left to right]` for a
// passer the room rolled, walked out at once, as a walk is.
@(private)
passer_walk_out :: proc(w: ^World) -> (said: string, ok: bool) {
	p := &w.passer
	if p.phase != .Waiting || p.forced || p.scene != w.current do return "", false
	if !passer_start(w) {
		passer_cancel(w)
		return "", false
	}
	said = fmt.tprintf("[somebody passes the %v window, %v]", current_scene(w).windows[p.window].name, passer_way(p.rightward))
	passer_cancel(w)
	return said, true
}

@(private)
passer_way :: proc(rightward: bool) -> string {
	return "left to right" if rightward else "right to left"
}

// `!passer [window] [left|right] [at=F] | chance=F | seed=N | ?`
@(private)
passer_bang :: proc(w: ^World, arg: string) -> string {
	p := &w.passer
	window := -1
	way: Maybe(bool)
	at: Maybe(f32)
	rest := arg
	for word in strings.fields_iterator(&rest) {
		switch {
		case word == "?":
			return passer_report(w)
		case strings.has_prefix(word, "chance="):
			v, ok := strconv.parse_f32(word[len("chance="):])
			if !ok do return "!passer chance=<0..1>"
			p.chance = v
			return fmt.tprintf("chance %v", v)
		case strings.has_prefix(word, "seed="):
			v, ok := strconv.parse_u64(word[len("seed="):])
			if !ok do return "!passer seed=<n>"
			passer_seed(w, v)
			return fmt.tprintf("seeded %v", v)
		case strings.has_prefix(word, "at="):
			v, ok := strconv.parse_f32(word[len("at="):])
			if !ok do return "!passer at=<0..1>"
			at = clamp(v, 0, 1)
		case window < 0 && passer_window_named(current_scene(w), word) >= 0:
			// A window first: a room may have one called `left`.
			i := passer_window_named(current_scene(w), word)
			win := current_scene(w).windows[i]
			if win.hidden do return fmt.tprintf("the %v window is not open now (when=%v)", word, win.only)
			window = i
		case word == "right" || word == "ltr":
			way = true
		case word == "left" || word == "rtl":
			way = false
		case:
			return fmt.tprintf("no window called %v here", word)
		}
	}
	if passer_figure(w) == nil do return fmt.tprintf("no passer: no figure called %q (ne.set_passer)", p.character)
	if !passer_start(w, window, way) do return "no window open here"
	p.forced = true
	name := current_scene(w).windows[p.window].name
	if f, held := at.?; held {
		p.phase = .Held
		p.held = f
		return fmt.tprintf("somebody at the %v window, %v, held at %v", name, passer_way(p.rightward), f)
	}
	return fmt.tprintf("somebody sets off across the %v window, %v", name, passer_way(p.rightward))
}

@(private)
passer_window_named :: proc(sc: ^Scene, name: string) -> int {
	for win, i in sc.windows do if win.name == name do return i
	return -1
}

@(private)
passer_report :: proc(w: ^World) -> string {
	p := &w.passer
	if p.character == "" do return "no passer set"
	sc := current_scene(w)
	could := "could come here" if passer_possible(w, sc) else "cannot come here"
	switch p.phase {
	case .Idle:    return fmt.tprintf("nobody (chance %v, %v)", p.chance, could)
	case .Waiting: return fmt.tprintf("somebody coming in %.1fs (chance %v)", max(p.starts_at - w.time, 0), p.chance)
	case .Walking: return fmt.tprintf("somebody crossing the %v window, %v, %.2f of the way", sc.windows[p.window].name, passer_way(p.rightward), passer_progress(w))
	case .Held:    return fmt.tprintf("somebody held at the %v window, %v, at %v", sc.windows[p.window].name, passer_way(p.rightward), p.held)
	}
	return ""
}
