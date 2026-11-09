package nengine

import "core:fmt"
import "core:math"
import "core:strings"
import rl "vendor:raylib"

// The menu bar: hidden until the pointer touches the top edge of the picture,
// then a strip across the top with a few words on it, each one a click. It is
// Sierra's SCI0 bar (Laura Bow, 1989), lettered as the rest of the game is.
//
//     ne.set_menu_bar(&w, []ne.Bar_Item{
//         {label = "Menu", key = .F10, pick = ne.open_menu_screen},
//         {label = "Save", key = .F5,  pick = ne.open_save_screen},
//         {label = "Notebook", key = .F4, pick = open_my_notebook},
//     })
//
// A game that sets no items has no bar.
//
// - **Appearing.** The pointer within BAR_REVEAL grid pixels of the top of the
//   canvas (or above it, in the black over a letterboxed picture) drops it
//   in; it stays while the pointer is over it, and goes back up when the
//   pointer leaves. Nothing else in the world stops for it.
// - **Using it.** The word under the pointer is picked out in yellow; a click
//   runs it. A click anywhere on the bar is the bar's, so it never walks her.
//   Each item may have a key that runs it without the bar — function keys and
//   Tab, never a letter, because letters are for the prompt — and the same key
//   closes the screen it opened.
// - **When it is not there.** Only in play with nothing holding the screen:
//   not during a death, a cutscene, an announcement, a conversation (a peep's
//   included), a ride or an open overlay — the same moments the prompt does
//   not take a command. The title is not play, so it is not there either.
//
// A hidden window (the harness) never reveals it by the pointer, which sits at
// 0,0 and would drop it over every screenshot; `!bar` holds it down instead.

Bar_Item :: struct {
	label: string,           // what the bar says: lettered, so in capitals in the comic
	key:   rl.KeyboardKey,   // runs it from anywhere in play; .KEY_NULL for none
	pick:  proc(w: ^World),
}

Menu_Bar :: struct {
	items:        []Bar_Item,
	drop:         f32,  // 0 up out of sight, 1 all the way down
	hover:        int,  // the item under the pointer, or -1
	held:         bool, // `!bar`: down for a shot, whatever the pointer does
	held_hover:   int,
	pointer_seen: bool, // the pointer has moved in this window: before that it is at 0,0 and means nothing
	took_click:   bool, // this frame's click was the bar's
}

// In grid pixels (the 320-wide reference grid, look.odin).
BAR_REVEAL :: 2   // this near the top calls the bar down
BAR_LINE :: 11    // the strip the words are on
BAR_DEPTH :: 15   // the whole of it: the strip, the double rule and the shadow
BAR_LEFT :: 6     // the first word in from the left
BAR_GAP :: 12     // between one item and the next
BAR_SECS :: 0.12  // to drop in, and to go

set_menu_bar :: proc(w: ^World, items: []Bar_Item) {
	w.bar.items = items
	w.bar.hover, w.bar.held_hover = -1, -1
}

// May the bar be there now? Play, with nothing holding the screen.
menu_bar_allowed :: proc(w: ^World) -> bool {
	if len(w.bar.items) == 0 || len(w.scenes) == 0 do return false
	return !w.dead && !overlay_open(w) && !cutting(w) && !announcing(w) && !talking(w) && !riding(w) && !peeping(w)
}

// The words of an item as the bar letters them, its key after them.
@(private)
bar_key_text :: proc(k: rl.KeyboardKey) -> string {
	#partial switch k {
	case .KEY_NULL: return ""
	case .TAB:      return "Tab"
	case .F1 ..= .F12:
		return fmt.tprintf("F%v", int(k) - int(rl.KeyboardKey.F1) + 1)
	}
	return ""
}

// Where each item sits along the bar, left and right, in grid pixels.
bar_spans :: proc(items: []Bar_Item, m: Comic_Metrics) -> [][2]f32 {
	out := make([][2]f32, len(items), context.temp_allocator)
	x := f32(BAR_LEFT)
	for it, i in items {
		wide := m.measure(it.label) / m.scale
		if k := bar_key_text(it.key); k != "" do wide += m.measure(strings.concatenate({" ", k}, context.temp_allocator)) / m.scale
		out[i] = {x, x + math.ceil(wide)}
		x += math.ceil(wide) + BAR_GAP
	}
	return out
}

// The item at a point on the bar (grid pixels), or -1.
bar_item_at :: proc(items: []Bar_Item, at: [2]f32, m: Comic_Metrics) -> int {
	if at.y >= BAR_LINE do return -1
	for s, i in bar_spans(items, m) {
		if at.x >= s[0] - BAR_GAP / 2 && at.x < s[1] + BAR_GAP / 2 do return i
	}
	return -1
}

// One frame of the bar, with the pointer at `at` (grid pixels) — `pointer`
// false when there is no pointer to believe — and `click` if the button went
// down. Returns the item clicked, or -1, and whether the click was the bar's.
// No window needed: the measuring is handed in.
bar_step :: proc(b: ^Menu_Bar, allowed: bool, at: [2]f32, pointer, click: bool, dt: f32, m: Comic_Metrics) -> (picked: int, took: bool) {
	picked = -1
	if !allowed {
		// Gone at once: a conversation that starts under it takes the screen.
		b.drop, b.hover = 0, -1
		return
	}
	want := b.held || (pointer && (at.y < BAR_REVEAL || (b.drop > 0 && at.y < BAR_DEPTH)))
	step := dt / BAR_SECS
	b.drop = clamp(b.drop + (step if want else -step), 0, 1)
	b.hover = -1
	if b.held {
		b.hover = b.held_hover
	} else if want && pointer && b.drop >= 0.5 {
		b.hover = bar_item_at(b.items, at, m)
	}
	if click && pointer && want {
		took = true
		picked = b.hover
	}
	return
}

// The pointer in play, for a frame: the bar first, and a click it did not take
// walks her there. Returns the bar item clicked, or -1. `at` is canvas pixels.
@(private)
pointer_in_play :: proc(w: ^World, at: [2]f32, pointer, click: bool, dt: f32, m: Comic_Metrics) -> int {
	picked, took := bar_step(&w.bar, menu_bar_allowed(w), at / m.scale, pointer, click, dt, m)
	w.bar.took_click = took
	if click && !took {
		// Clicking walks. Doing things is for the parser. Either one is the
		// player changing their mind about anything they were on their way
		// to do.
		// On an edge (water off a jetty), to the brink and over (edge.odin).
		click_walk(w, at)
	}
	return picked
}

// Runs a bar item, as a click or its key would; the screen it opens closes
// with the same key.
menu_bar_pick :: proc(w: ^World, i: int) {
	if i < 0 || i >= len(w.bar.items) do return
	it := w.bar.items[i]
	w.bar.drop, w.bar.hover, w.bar.held = 0, -1, false // a choice made, the bar goes back up
	if it.pick != nil do it.pick(w)
	if w.screen.kind != .None do w.screen.key = it.key
}

// The bar's keys, in play: the item whose key went down, or -1.
@(private)
bar_key_pressed :: proc(w: ^World) -> int {
	if !menu_bar_allowed(w) do return -1
	for it, i in w.bar.items do if it.key != .KEY_NULL && rl.IsKeyPressed(it.key) do return i
	return -1
}

// The bar's frame in play (update): the pointer, the click, the keys. `busy`
// is her hands full with a gesture, when a click waits. True if an item ran.
@(private)
menu_bar_frame :: proc(w: ^World, dt: f32, busy: bool) -> bool {
	click := !busy && rl.IsMouseButtonPressed(.LEFT)
	if rl.GetMouseDelta() != {0, 0} {
		w.bar.pointer_seen = true
		w.bar.held = false // a real pointer takes over from the harness
	}
	pointer := len(w.bar.items) > 0 && w.bar.pointer_seen && !hidden() && rl.IsCursorOnScreen()
	m := Comic_Metrics{scale = max(ui_scale(), 0.0001), grid_w = REFERENCE_WIDTH, measure = letters_width}
	i := pointer_in_play(w, mouse_pos(), pointer, click, dt, m)
	if i < 0 do i = bar_key_pressed(w)
	if i < 0 do return false
	menu_bar_pick(w, i)
	return true
}

// A band of the room behind darkened the EGA way, every other grid pixel
// black: rows y0..y1 of the grid, whole width.
@(private)
grid_dither_rows :: proc(y0, y1: f32, c: rl.Color) {
	for y := y0; y <= y1; y += 1 {
		for x := f32(int(y) %% 2); x < REFERENCE_WIDTH; x += 2 do grid_fill(x, y, x, y, c)
	}
}

// --- Drawing it ---

@(private)
draw_menu_bar :: proc(w: ^World) {
	b := &w.bar
	if b.drop <= 0 || !menu_bar_allowed(w) do return
	c := the_comic
	m := comic_metrics()
	gw := m.grid_w
	k := letter_scale()
	ease := 1 - (1 - b.drop) * (1 - b.drop) // quick out of the top, settling
	top := math.round(-f32(BAR_DEPTH) * (1 - ease))

	// The strip, its rule along the foot (if the theme has one), a double
	// black rule under it, and a shadow under that, dithered the EGA way as
	// the room behind a box is.
	bar := c.bar
	paper_fill(0, top, gw - 1, top + BAR_LINE - 1, bar.paper)
	if bar.rule.a != 0 do grid_fill(0, top + BAR_LINE - 1, gw - 1, top + BAR_LINE - 1, bar.rule)
	grid_fill(0, top + BAR_LINE, gw - 1, top + BAR_LINE + 1, c.line)
	grid_dither_rows(top + BAR_LINE + 2, top + BAR_DEPTH - 1, c.line)

	// The capitals stand from 2 to 7 font pixels under the top of the line.
	ty := (gx(top) + gx(top + BAR_LINE)) / 2 - 4.5 * k
	for s, i in bar_spans(b.items, m) {
		it := b.items[i]
		sf := bar
		if i == b.hover {
			sf = c.picked
			paper_fill(s[0] - 4, top + 1, s[1] + 3, top + BAR_LINE - 2, sf.paper)
			grid_outline(s[0] - 4, top + 1, s[1] + 3, top + BAR_LINE - 2, c.line)
		}
		end := letters_draw(it.label, gx(s[0]), ty, sf.ink)
		if key := bar_key_text(it.key); key != "" do letters_draw(key, end + letters_width(" "), ty, sf.aside)
	}
}

// --- The harness ---

// `!bar`: the bar held down for a shot; `!bar hover <item>` with that item
// picked out; `!bar <item> [row]` runs it as a click would, and with a row,
// the screen it opens has that row under the pointer; `!bar off`.
@(private)
bar_bang :: proc(w: ^World, arg: string) -> string {
	b := &w.bar
	if len(b.items) == 0 do return "no bar: the game set none"
	names := make([dynamic]string, context.temp_allocator)
	for it in b.items do append(&names, it.label)
	list := strings.join(names[:], ", ", context.temp_allocator)
	word, rest := arg, ""
	if sp := strings.index_byte(arg, ' '); sp >= 0 do word, rest = arg[:sp], strings.trim_space(arg[sp + 1:])
	find :: proc(items: []Bar_Item, name: string) -> int {
		for it, i in items do if strings.equal_fold(it.label, name) do return i
		return -1
	}
	why := ""
	if !menu_bar_allowed(w) do why = bar_why_not(w)
	switch {
	case word == "":
		if why != "" do return fmt.tprintf("the bar is not there now: %v", why)
		b.held, b.held_hover, b.drop = true, -1, 1
		return fmt.tprintf("the bar is down: %v", list)
	case word == "off":
		b.held, b.drop, b.hover = false, 0, -1
		return "the bar is up"
	case word == "hover":
		i := find(b.items, rest)
		if i < 0 do return fmt.tprintf("no item %q on the bar (%v)", rest, list)
		if why != "" do return fmt.tprintf("the bar is not there now: %v", why)
		b.held, b.held_hover, b.drop = true, i, 1
		return fmt.tprintf("the bar is down, %v picked out", b.items[i].label)
	}
	i := find(b.items, word)
	if i < 0 do return fmt.tprintf("no item %q on the bar (%v)", word, list)
	if why != "" do return fmt.tprintf("the bar is not there now: %v", why)
	menu_bar_pick(w, i)
	if w.screen.kind != .None && rest != "" {
		n, ok := parse_row(rest)
		if ok do screen_hover(w, n - 1)
	}
	if w.screen.kind != .None do return screen_report(w)
	if overlay_open(w) do return fmt.tprintf("%v: an overlay is open", b.items[i].label)
	return fmt.tprintf("%v: %v", b.items[i].label, message(w) if message(w) != "" else "nothing said")
}

// Why there is no bar now, for the harness.
@(private)
bar_why_not :: proc(w: ^World) -> string {
	switch {
	case w.dead:          return "dead"
	case overlay_open(w): return "an overlay is open"
	case cutting(w):      return "a cutscene"
	case announcing(w):   return "an announcement"
	case peeping(w):      return "a peep"
	case talking(w):      return "a conversation"
	case riding(w):       return "a ride"
	}
	return "nothing to show"
}
