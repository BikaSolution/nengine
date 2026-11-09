package nengine

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

// The engine's own screens, the ones a menu bar opens: Save, Load, the things
// she carries, and a small menu. Each is an overlay (world.odin), so the world
// stops under it — nobody walks, the play clock waits — and each is lettered
// in the comic's look over the room darkened the EGA way.
//
//     ne.open_save_screen(w)       // the eight slots the player owns
//     ne.open_load_screen(w)       // all ten: the two autosaves too
//     ne.open_inventory_screen(w)  // what she carries, as pictures
//     ne.open_menu_screen(w)       // Resume, the game's own, Restart, Quit
//
// Esc closes one, and so does a click outside it, and so does the key that
// opened it from the bar. Up and Down and Enter work as the mouse does; in
// the inventory, a grid, Left and Right go along a row and Up and Down a row
// at a time.
//
// **The inventory is pictures.** Each thing is a cell with its sprite in it
// (`item_icon`: `item_<name>`, inventory.odin); the pointer on a cell picks it
// out and its label comes up in a small caption by it, a click shows its
// description at the foot, as LOOK would. A thing with no picture yet is a
// plain tag with its label lettered under it, so nothing is ever invisible.
// Seven across and three down make a page; the wheel, the keys and the
// arrows at the right-hand edge go up and down a row at a time.
//
// **Saving and loading are the typed commands.** A slot picked here goes
// through `slot_act`, which is what SAVE 3 and RESTORE 3 do once they know the
// number, and the game says how it went in the same words (`slot_said`).
// Saving over a slot that has something in it wants a second click; a slot
// with nothing in it cannot be loaded and is greyed.
//
// **The words are the game's where they are its voice**: what a save is
// called, what she says when it is done, what a room is called, the things
// she always has, and the game's own lines in the menu. The rest — SAVE,
// EMPTY, AUTOSAVE — is the engine's, as the death box's are.

Screen_Kind :: enum {
	None,
	Save,
	Load,
	Inventory,
	Menu,
	Hint, // the hint, and how she is getting on (hint.odin)
}

// The screen that is up, if one of these is, and where its pointer is.
Screen :: struct {
	kind:  Screen_Kind,
	hover: int,            // the row under the pointer or the keys, or -1; in the inventory, a cell
	armed: int,            // a row clicked once that wants a second click: a save over another, Restart, Quit; -1
	shown: int,            // the inventory: the thing whose description is up, or -1
	first: int,            // the inventory: the first cell on the page, a whole row of them at a time
	key:   rl.KeyboardKey, // the bar's key that opened it, which also closes it
	infos: []Save_Info,    // the slots, read once as it opened
}

// A line in the menu: its words (or a procedure for words that change, "Mercy:
// on"), what it does, a question it asks first, and whether the menu stays up
// after (a setting) or goes (everything else).
Menu_Choice :: struct {
	label:    string,
	label_of: proc(w: ^World) -> string,
	pick:     proc(w: ^World),
	ask:      string,
	stays:    bool,
}

// What the screens need from the game. Everything may be left out.
Screen_Words :: struct {
	// What a save made from the Save screen is called: the hour, in a game
	// with a story clock. nil, and it is the room's name, as save_game does.
	save_title: proc(w: ^World) -> string,
	// How SAVE or RESTORE went, in the game's words: the same procedure its
	// typed SAVE and RESTORE say it with. nil, and the engine's plain ones.
	slot_said:  proc(w: ^World, outcome: Slot_Outcome, slot: int),
	// A room's name for the slot list. nil, and the scene's own, spaced.
	room_name:  proc(w: ^World, scene: string) -> string,
	// What she always has, listed before what she has picked up.
	always:     []Item,
	// A thing in the list clicked: true if the game did something with it
	// (the notebook opens), and the screen goes. False, and its description
	// is shown.
	item_pick:  proc(w: ^World, it: Item) -> bool,
	// The game's own lines in the menu, between Resume and Restart.
	menu:       []Menu_Choice,
	// The questions Restart and Quit ask before they do it.
	restart_ask, quit_ask: string,
	// The lines over the hint: how she is getting on, in the game's words.
	// nil, and the score, what is left, the hour and the room (hint.odin).
	status:     proc(w: ^World) -> []Status_Line,
}

// --- Opening ---

open_save_screen :: proc(w: ^World) {open_screen(w, .Save)}
open_load_screen :: proc(w: ^World) {open_screen(w, .Load)}
open_inventory_screen :: proc(w: ^World) {open_screen(w, .Inventory)}
open_menu_screen :: proc(w: ^World) {open_screen(w, .Menu)}

open_screen :: proc(w: ^World, kind: Screen_Kind) {
	if overlay_open(w) do close_overlay(w)
	w.message_until = 0 // the caption up goes, as a Sierra window took the screen
	w.screen = {kind = kind, hover = -1, armed = -1, shown = -1}
	if kind == .Save || kind == .Load do w.screen.infos = save_infos(w)
	if kind == .Menu do w.screen.hover = 0 // Resume, for Enter
	open_overlay(w, {update = screen_update, draw = screen_draw})
}

// The screen's state, gone with it: close_overlay calls this, and so does an
// overlay opened over it.
@(private)
screen_forget :: proc(w: ^World) {
	if w.screen.infos != nil do save_info_destroy(w.screen.infos)
	w.screen = {hover = -1, armed = -1, shown = -1}
}

screen_open :: proc(w: ^World) -> Screen_Kind {
	if !overlay_open(w) do return .None
	return w.screen.kind
}

// --- The rows ---

// How many rows the screen has: slots, things or lines of the menu.
screen_rows :: proc(w: ^World) -> int {
	switch w.screen.kind {
	case .Save:      return SAVE_SLOTS
	case .Load:      return SAVE_SLOTS + 2
	case .Inventory: return len(screen_things(w))
	case .Menu:      return len(menu_choices(w))
	case .Hint:      return hint_rows(w)
	case .None:
	}
	return 0
}

// The slot a row of Save or Load is: Save lists 1 to 8; Load the autosave,
// the one before it, then 1 to 8 (save_infos's order).
@(private)
row_info :: proc(w: ^World, row: int) -> (Save_Info, bool) {
	i := row + 2 if w.screen.kind == .Save else row
	if i < 0 || i >= len(w.screen.infos) do return {}, false
	return w.screen.infos[i], true
}

// What she always has, then what she has picked up.
screen_things :: proc(w: ^World) -> []Item {
	out := make([dynamic]Item, context.temp_allocator)
	append(&out, ..w.screen_words.always)
	append(&out, ..carried(w))
	return out[:]
}

// Resume, the game's own lines, Restart, Quit.
menu_choices :: proc(w: ^World) -> []Menu_Choice {
	out := make([dynamic]Menu_Choice, context.temp_allocator)
	append(&out, Menu_Choice{label = "Resume"})
	if len(w.hints) > 0 do append(&out, Menu_Choice{label = "Hint", pick = open_hint_screen})
	append(&out, ..w.screen_words.menu)
	ask_restart := w.screen_words.restart_ask if w.screen_words.restart_ask != "" else "Restart: are you sure?"
	ask_quit := w.screen_words.quit_ask if w.screen_words.quit_ask != "" else "Quit: are you sure?"
	append(&out, Menu_Choice{label = "Restart", ask = ask_restart, pick = proc(w: ^World) {w.restart = true}})
	append(&out, Menu_Choice{label = "Quit", ask = ask_quit, pick = proc(w: ^World) {w.quit = true}})
	return out[:]
}

@(private)
choice_label :: proc(w: ^World, c: Menu_Choice) -> string {
	return c.label_of(w) if c.label_of != nil else c.label
}

// --- Doing it ---

// A row picked, by a click or Enter: save, load, look at a thing, a line of
// the menu. What the harness's `!screen n` does, and the tests.
screen_pick :: proc(w: ^World, row: int) {
	s := &w.screen
	if row < 0 || row >= screen_rows(w) do return
	s.hover = row
	switch s.kind {
	case .None:
	case .Save:
		info, _ := row_info(w, row)
		// Over something: a second click says so.
		if info.used && s.armed != row {
			s.armed = row
			return
		}
		title := w.screen_words.save_title(w) if w.screen_words.save_title != nil else ""
		slot := info.slot
		close_overlay(w)
		log_begin(w, fmt.tprintf("save %v", slot))
		log_route(w, "screen")
		slot_said(w, slot_act(w, true, slot, title), slot)
	case .Load:
		info, _ := row_info(w, row)
		if !info.used || info.stale do return // greyed: nothing to load, or an older game's
		slot := info.slot
		close_overlay(w)
		log_begin(w, fmt.tprintf("restore %v", slot_name(slot)))
		log_route(w, "screen")
		outcome := slot_act(w, false, slot)
		w.restored = outcome == .Restored
		slot_said(w, outcome, slot)
	case .Inventory:
		it := screen_things(w)[row]
		if w.screen_words.item_pick != nil && w.screen_words.item_pick(w, it) {
			// The game did something with it. If that was not to open
			// something of its own, the screen goes.
			if w.screen.kind != .None do close_overlay(w)
			return
		}
		s.shown = row
	case .Menu:
		c := menu_choices(w)[row]
		if c.ask != "" && s.armed != row {
			s.armed = row
			return
		}
		s.armed = -1
		if !c.stays do close_overlay(w)
		if c.pick != nil do c.pick(w)
	case .Hint:
		hint_pick(w, row)
	}
}

// How SAVE or RESTORE went: the game's words, or these.
@(private)
slot_said :: proc(w: ^World, outcome: Slot_Outcome, slot: int) {
	if w.screen_words.slot_said != nil {
		w.screen_words.slot_said(w, outcome, slot)
		return
	}
	switch outcome {
	case .No_Slot:       say(w, "Which slot?")
	case .Saved:         say(w, fmt.tprintf("Saved to %v.", slot_name(slot)))
	case .Not_Saved:     say(w, "It would not save.")
	case .Nothing_There: say(w, fmt.tprintf("There is nothing in %v.", slot_name(slot)))
	case .Restored:      say(w, "Restored.")
	case .Not_Restored:  say(w, "That save is from an older version of the game, and can't be restored." if w.old_save else "It would not load.")
	}
}

// --- The frame ---

@(private)
screen_update :: proc(w: ^World, dt: f32) -> bool {
	s := &w.screen
	n := screen_rows(w)
	if rl.IsKeyPressed(.ESCAPE) {
		// A question first, then the screen.
		if s.armed >= 0 do s.armed = -1
		else do close_overlay(w)
		return true
	}
	if s.key != .KEY_NULL && rl.IsKeyPressed(s.key) {
		close_overlay(w)
		return true
	}

	move := 0
	if rl.IsKeyPressed(.UP) || rl.IsKeyPressed(.KP_8) do move = -1
	if rl.IsKeyPressed(.DOWN) || rl.IsKeyPressed(.KP_2) do move = 1
	if s.kind == .Inventory {
		// A grid: Left and Right along a row, Up and Down a row at a time.
		if move != 0 do move *= INVENTORY_ACROSS
		if rl.IsKeyPressed(.LEFT) || rl.IsKeyPressed(.KP_4) do move = -1
		if rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressed(.KP_6) do move = 1
		if wheel := rl.GetMouseWheelMove(); wheel != 0 do inventory_scroll(w, -int(math.sign(wheel)))
	}
	if move != 0 && n > 0 {
		s.armed = -1
		if s.kind == .Inventory do screen_hover(w, inventory_step(s.hover, move, n))
		else do s.hover = clamp(s.hover + move if s.hover >= 0 else 0, 0, n - 1)
	}
	if (rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER)) && s.hover >= 0 {
		screen_pick(w, s.hover)
		return true
	}

	if WIDTH <= 0 do return true // no canvas, no pointer (a test)
	at := mouse_pos() / ui_scale()
	if rl.GetMouseDelta() != {0, 0} {
		r := screen_row_at(w, at)
		// A cell's name is up only while the pointer is on it; a row of a
		// list stays lit until the pointer finds another.
		if r >= 0 || s.kind == .Inventory do s.hover = r
	}
	if rl.IsMouseButtonPressed(.LEFT) {
		if !in_rect(at, screen_panel(w)) {
			close_overlay(w)
			return true
		}
		if s.kind == .Inventory {
			if step := inventory_arrow_at(w, at); step != 0 {
				inventory_scroll(w, step)
				return true
			}
		}
		if r := screen_row_at(w, at); r >= 0 do screen_pick(w, r)
	}
	return true
}

// The pointer, or the keys, on a row (from 0; -1 for none). In the
// inventory the page follows it.
@(private)
screen_hover :: proc(w: ^World, row: int) {
	n := screen_rows(w)
	w.screen.hover = clamp(row, -1, n - 1)
	if w.screen.kind == .Inventory && w.screen.hover >= 0 do w.screen.first = inventory_keep_in_view(w.screen.first, w.screen.hover, n)
}

// --- Where everything is, in grid pixels ---

@(private) SCREEN_LEFT :: 20
@(private) SCREEN_RIGHT :: 299
@(private) SLOT_PITCH :: 14   // a slot row and the gap under it
@(private) SLOT_H :: 12
@(private) SCREEN_HEAD :: 16  // the title's room at the top of a panel
@(private) SCREEN_FOOT :: 16  // the hint's at the bottom
@(private) MENU_W :: 170
@(private) MENU_PITCH :: 20
@(private) MENU_H :: 16
@(private) INVENTORY_ACROSS :: 7 // cells in a row of the inventory
@(private) INVENTORY_DOWN :: 3   // rows of them on a page
@(private) INVENTORY_PITCH :: 36 // a cell and the gap after it
@(private) INVENTORY_CELL :: 34  // a cell: a picture of up to 28 by 28, and room round it
@(private) INVENTORY_DESC :: 46  // the description's room at the foot
@(private) INVENTORY_TIP_H :: 11 // the caption with a thing's name in it

// The panel, as a rectangle in grid pixels.
screen_panel :: proc(w: ^World) -> rl.Rectangle {
	gh := f32(200)
	switch w.screen.kind {
	case .Save, .Load:
		h := f32(SCREEN_HEAD + screen_rows(w) * SLOT_PITCH + SCREEN_FOOT)
		top := math.floor((gh - h) / 2)
		return {SCREEN_LEFT, top, SCREEN_RIGHT - SCREEN_LEFT + 1, h}
	case .Menu:
		h := f32(SCREEN_HEAD + screen_rows(w) * MENU_PITCH + SCREEN_FOOT + 6)
		top := math.floor((gh - h) / 2)
		return {f32((320 - MENU_W) / 2), top, MENU_W, h}
	case .Inventory:
		h := f32(SCREEN_HEAD + INVENTORY_DOWN * INVENTORY_PITCH + INVENTORY_DESC)
		return {SCREEN_LEFT, math.floor((gh - h) / 2), SCREEN_RIGHT - SCREEN_LEFT + 1, h}
	case .Hint:
		return hint_panel(w)
	case .None:
	}
	return {}
}

// A row's rectangle in grid pixels, or false when it is not on the page.
screen_row_rect :: proc(w: ^World, row: int) -> (rl.Rectangle, bool) {
	p := screen_panel(w)
	switch w.screen.kind {
	case .Save, .Load:
		return {p.x + 8, p.y + SCREEN_HEAD + f32(row * SLOT_PITCH), p.width - 16, SLOT_H}, true
	case .Menu:
		return {p.x + 12, p.y + SCREEN_HEAD + 2 + f32(row * MENU_PITCH), p.width - 24, MENU_H}, true
	case .Inventory:
		at := row - w.screen.first
		if at < 0 || at >= INVENTORY_ACROSS * INVENTORY_DOWN do return {}, false
		return {inventory_left(p) + f32(at % INVENTORY_ACROSS * INVENTORY_PITCH), p.y + SCREEN_HEAD + f32(at / INVENTORY_ACROSS * INVENTORY_PITCH), INVENTORY_CELL, INVENTORY_CELL}, true
	case .Hint:
		return hint_row_rect(w, row), true
	case .None:
	}
	return {}, false
}

// The row at a point (grid pixels), or -1.
screen_row_at :: proc(w: ^World, at: [2]f32) -> int {
	for row in 0 ..< screen_rows(w) {
		if r, on := screen_row_rect(w, row); on && in_rect(at, r) do return row
	}
	return -1
}

// The inventory's grid, centred in its panel: its left edge.
@(private)
inventory_left :: proc(p: rl.Rectangle) -> f32 {
	wide := INVENTORY_ACROSS * INVENTORY_PITCH - (INVENTORY_PITCH - INVENTORY_CELL)
	return p.x + math.floor((p.width - f32(wide)) / 2)
}

// The inventory's first cell, a whole row at a time, never so far down that
// the last page is not full of rows.
@(private)
inventory_first :: proc(first, n: int) -> int {
	rows := (n + INVENTORY_ACROSS - 1) / INVENTORY_ACROSS
	last := max(0, rows - INVENTORY_DOWN) * INVENTORY_ACROSS
	return clamp(first - first %% INVENTORY_ACROSS, 0, last)
}

@(private)
inventory_keep_in_view :: proc(first, cell, n: int) -> int {
	if cell < 0 do return inventory_first(first, n)
	f := first - first %% INVENTORY_ACROSS
	for cell < f do f -= INVENTORY_ACROSS
	for cell >= f + INVENTORY_ACROSS * INVENTORY_DOWN do f += INVENTORY_ACROSS
	return inventory_first(f, n)
}

// Where the keys go from `cell` in a grid of `n`: along a row by one, or a
// row up or down. Off the top or the bottom it stays; down into a short last
// row it lands on the last thing. Nothing picked yet, and the first is.
inventory_step :: proc(cell, move, n: int) -> int {
	if n <= 0 do return -1
	if cell < 0 do return 0
	to := cell + move
	switch {
	case to < 0:  return cell if move < -1 else 0
	case to >= n:
		if move > 1 && cell / INVENTORY_ACROSS < (n - 1) / INVENTORY_ACROSS do return n - 1
		return cell if move > 1 else n - 1
	}
	return to
}

// The page a row up (-1) or down (1).
@(private)
inventory_scroll :: proc(w: ^World, step: int) {
	w.screen.first = inventory_first(w.screen.first + step * INVENTORY_ACROSS, screen_rows(w))
}

// The arrows at the grid's right-hand edge, when there is more above or
// below: where each is, in grid pixels.
@(private)
inventory_arrows :: proc(w: ^World) -> (up, down: rl.Rectangle, more_up, more_down: bool) {
	p := screen_panel(w)
	n := screen_rows(w)
	x := inventory_left(p) + INVENTORY_ACROSS * INVENTORY_PITCH - (INVENTORY_PITCH - INVENTORY_CELL) + 1
	top := p.y + SCREEN_HEAD
	bottom := top + INVENTORY_DOWN * INVENTORY_PITCH - (INVENTORY_PITCH - INVENTORY_CELL)
	up = {x + 1, top, 9, 12}
	down = {x + 1, bottom - 12, 9, 12}
	return up, down, w.screen.first > 0, w.screen.first + INVENTORY_ACROSS * INVENTORY_DOWN < n
}

// -1 for the up arrow under the pointer, 1 for the down, 0 for neither.
@(private)
inventory_arrow_at :: proc(w: ^World, at: [2]f32) -> int {
	up, down, more_up, more_down := inventory_arrows(w)
	if more_up && in_rect(at, up) do return -1
	if more_down && in_rect(at, down) do return 1
	return 0
}

// --- Drawing ---

@(private)
screen_draw :: proc(w: ^World) {
	s := &w.screen
	if s.kind == .None do return
	c := the_comic
	grid_dither(c.line) // the room behind, darkened the EGA way
	p := screen_panel(w)
	x0, y0, x1, y1 := p.x, p.y, p.x + p.width - 1, p.y + p.height - 1
	grid_fill(x0 + 2, y0 + 2, x1 + 2, y1 + 2, c.line)
	surface_box(x0, y0, x1, y1, c.panel, double = true)

	titles := [Screen_Kind]string{.None = "", .Save = "Save", .Load = "Load", .Inventory = "Inventory", .Menu = "Menu", .Hint = "Hint"}
	m := comic_metrics()
	cap := plan_caption(titles[s.kind], m, x0 + 8, y0 - 9, 80)
	draw_caption(cap, c.title)

	hint := ""
	switch s.kind {
	case .Save, .Load: hint = draw_slot_rows(w)
	case .Inventory:   hint = draw_inventory(w)
	case .Menu:        hint = draw_menu_rows(w)
	case .Hint:        hint = draw_hint_screen(w)
	case .None:
	}
	if hint != "" {
		ink := c.panel.name if s.armed >= 0 else c.panel.aside
		letters_draw(hint, gx(x0 + 8), gx(y1 - SCREEN_FOOT + 4), ink)
	}
}

// The capitals' top, for a line of lettering centred in rows y0..y1 of the grid.
@(private)
row_text_y :: proc(y0, y1: f32) -> f32 {
	return (gx(y0) + gx(y1 + 1)) / 2 - 4.5 * letter_scale()
}

// Lettering cut down to `room` canvas pixels, with a full stop or two for
// what is missing.
@(private)
letters_fit :: proc(text: string, room: f32) -> string {
	if letters_width(text) <= room do return text
	t := text
	for len(t) > 1 && letters_width(strings.concatenate({t, ".."}, context.temp_allocator)) > room do t = strings.trim_right_space(t[:len(t) - 1])
	return strings.concatenate({t, ".."}, context.temp_allocator)
}

// A room's name for the list: the game's, or the scene's, spaced.
@(private)
room_label :: proc(w: ^World, scene: string) -> string {
	if scene == "" do return ""
	if w.screen_words.room_name != nil do return w.screen_words.room_name(w, scene)
	t, _ := strings.replace_all(scene, "_", " ", context.temp_allocator)
	return t
}

// A slot's name in its own column.
@(private)
slot_column :: proc(slot: int) -> string {
	switch slot {
	case AUTOSAVE:          return "Autosave"
	case AUTOSAVE_PREVIOUS: return "Previous"
	}
	return fmt.tprintf("%v", slot)
}

// A slot's title, without the room at its end when it names one: the room
// has a column of its own.
@(private)
slot_title_text :: proc(info: Save_Info) -> string {
	if info.stale do return "(an older game)"
	t := info.title
	if info.scene != "" && strings.has_suffix(t, info.scene) && len(t) > len(info.scene) do t = strings.trim_right(t[:len(t) - len(info.scene)], ", ")
	return t
}

@(private)
draw_slot_rows :: proc(w: ^World) -> string {
	s := &w.screen
	c := the_comic
	n := screen_rows(w)
	// The columns, the same down the list: which slot, what it is called,
	// which room, and how long it had been played, on the right.
	label_w, title_w := f32(0), letters_width("00:00")
	for row in 0 ..< n {
		info, _ := row_info(w, row)
		label_w = max(label_w, letters_width(slot_column(info.slot)))
		if info.used do title_w = max(title_w, min(letters_width(slot_title_text(info)), gx(80)))
	}
	for row in 0 ..< n {
		info, _ := row_info(w, row)
		r, _ := screen_row_rect(w, row)
		rx0, ry0, rx1, ry1 := r.x, r.y, r.x + r.width - 1, r.y + r.height - 1
		// Load has nothing to do with an empty slot: it is greyed and never lit.
		live := (info.used && !info.stale) || s.kind == .Save
		lit := (row == s.hover && live) || row == s.armed
		sf := c.picked if lit else c.row
		surface_box(rx0, ry0, rx1, ry1, sf)
		ty := row_text_y(ry0, ry1)
		left := gx(rx0 + 5)
		letters_draw(slot_column(info.slot), left, ty, sf.ink if live else sf.faded)
		x := left + label_w + gx(8)
		right := gx(rx1 - 4)
		switch {
		case row == s.armed:
			letters_draw("Save over this one?", x, ty, sf.name)
		case !info.used:
			letters_draw("Empty", x, ty, sf.aside if live else sf.faded)
		case:
			played := playtime_text(info.played)
			pw := letters_width(played)
			letters_draw(played, right - pw, ty, sf.aside)
			letters_draw(letters_fit(slot_title_text(info), title_w), x, ty, sf.ink)
			room_x := x + title_w + gx(8)
			letters_draw(letters_fit(room_label(w, info.scene), right - pw - gx(6) - room_x), room_x, ty, sf.name)
		}
	}
	if s.armed >= 0 do return "Click it again to save over it.  Esc: no."
	if s.kind == .Save do return "Click a slot to save in it.  Esc closes."
	return "Click a save to go back to it.  Esc closes."
}

// A thing's picture, if the game has one: the sprite item_icon names.
@(private)
item_sprite :: proc(w: ^World, it: Item) -> (Sprite, bool) {
	if w.assets == nil do return {}, false
	spr, ok := w.assets.sprites[item_icon(it)]
	return spr, ok
}

@(private)
draw_inventory :: proc(w: ^World) -> string {
	s := &w.screen
	c := the_comic
	things := screen_things(w)
	p := screen_panel(w)
	for it, row in things {
		r, on := screen_row_rect(w, row)
		if !on do continue
		rx0, ry0, rx1, ry1 := r.x, r.y, r.x + r.width - 1, r.y + r.height - 1
		if row == s.hover || row == s.shown do surface_box(rx0, ry0, rx1, ry1, c.picked)
		if spr, ok := item_sprite(w, it); ok && spr.texture.id != 0 {
			draw_item_picture(spr, r)
		} else {
			draw_item_tag(it.label, r)
		}
	}
	up, down, more_up, more_down := inventory_arrows(w)
	if more_up do draw_grid_arrow(up, -1)
	if more_down do draw_grid_arrow(down, 1)
	if s.hover >= 0 && s.hover < len(things) {
		if r, on := screen_row_rect(w, s.hover); on {
			last_row := (s.hover - s.first) / INVENTORY_ACROSS == INVENTORY_DOWN - 1
			draw_item_tip(things[s.hover].label, r, p, last_row)
		}
	}
	more := more_up || more_down
	if s.shown >= 0 && s.shown < len(things) {
		it := things[s.shown]
		m := comic_metrics()
		inner := p.width - 16
		cap := plan_caption(it.description, m, p.x + 8, 0, inner, inner, it.label)
		cap.y = p.y + p.height - 6 - cap.h
		draw_caption(cap)
		return ""
	}
	if more do return "Click a thing to look at it.  Up, down: more."
	return "Click a thing to look at it.  Esc closes."
}

// A picture, centred in its cell at the size it was painted; shrunk to fit,
// keeping its shape, only if it was painted bigger than the cell.
@(private)
draw_item_picture :: proc(spr: Sprite, r: rl.Rectangle) {
	x0, y0 := gx(r.x), gx(r.y)
	cw, ch := gx(r.x + r.width) - x0, gx(r.y + r.height) - y0
	fw, fh := f32(spr.frame_w), f32(spr.frame_h)
	if fw <= cw && fh <= ch {
		draw_sprite_at(spr, 0, i32(x0 + math.floor((cw - fw) / 2)), i32(y0 + math.floor((ch - fh) / 2)))
		return
	}
	k := min(cw / fw, ch / fh)
	dw, dh := math.floor(fw * k), math.floor(fh * k)
	draw_sprite_pro(spr, 0, {x0 + math.floor((cw - dw) / 2), y0 + math.floor((ch - dh) / 2), dw, dh})
}

// What a thing with no picture yet is shown as: a plain luggage tag, its
// point to the left and a hole in it, and the thing's label lettered small
// under it, as many lines as fit.
@(private)
draw_item_tag :: proc(label: string, r: rl.Rectangle) {
	c := the_comic
	x0, x1 := r.x + 8, r.x + r.width - 9
	y0, y1 := r.y + 2, r.y + 10 // room under it for three lines of label
	for i in 0 ..= int(y1 - y0) {
		// The corners cut off at the left, a step a row: the tag's point.
		y := y0 + f32(i)
		cut := f32(max(0, 3 - min(i, int(y1 - y0) - i)))
		paper_fill(x0 + cut, y, x1, y, c.panel.paper)
		grid_fill(x0 + cut, y, x0 + cut, y, c.line)
	}
	grid_fill(x0 + 3, y0, x1, y0, c.line)
	grid_fill(x0 + 3, y1, x1, y1, c.line)
	grid_fill(x1, y0, x1, y1, c.line)
	mid := math.floor((y0 + y1) / 2)
	grid_fill(x0 + 4, mid, x0 + 5, mid + 1, c.line) // the hole

	k := tag_letter_scale()
	room := gx(r.x + r.width - 2) - gx(r.x + 2)
	lines := wrap_measured(label, room, tag_letters_width)
	line_h := LETTER_LINE * k
	most := int((gx(r.y + r.height - 1) - gx(y1 + 3)) / line_h)
	for i in 0 ..< min(len(lines), most) {
		t := lines[i]
		if i == most - 1 && len(lines) > most do t = strings.concatenate({t, ".."}, context.temp_allocator)
		for len(t) > 3 && tag_letters_width(t) > room do t = strings.concatenate({strings.trim_right_space(t[:len(t) - 3]), ".."}, context.temp_allocator)
		tw := tag_letters_width(t)
		cx := (gx(r.x) + gx(r.x + r.width)) / 2
		letters_draw(t, math.floor(cx - tw / 2), gx(y1 + 3) + f32(i) * line_h, c.panel.ink, k)
	}
}

// The tag's lettering: a font pixel smaller than the rest.
@(private)
tag_letter_scale :: proc() -> f32 {
	return max(1, letter_scale() - 1)
}

@(private)
tag_letters_width :: proc(text: string) -> f32 {
	return letters_width(text) * tag_letter_scale() / letter_scale()
}

// A thing's name in a small caption by its cell: under it, or over it for the
// bottom row of the page, so that it keeps off the description at the foot.
// Centred on the cell and kept inside the panel.
@(private)
draw_item_tip :: proc(label: string, r, p: rl.Rectangle, above: bool) {
	c := the_comic
	tw := letters_width(label)
	w := math.ceil(tw / ui_scale()) + 8
	x0 := math.floor(r.x + r.width / 2 - w / 2)
	x0 = clamp(x0, p.x + 4, p.x + p.width - 5 - w)
	y0 := r.y + r.height + 1 if !above else r.y - INVENTORY_TIP_H - 1
	x1, y1 := x0 + w - 1, y0 + INVENTORY_TIP_H - 1
	grid_fill(x0 + 1, y0 + 1, x1 + 1, y1 + 1, c.line)
	surface_box(x0, y0, x1, y1, c.tag)
	letters_draw(label, math.floor((gx(x0) + gx(x1 + 1) - tw) / 2), row_text_y(y0, y1), c.tag.ink)
}

// A small solid triangle pointing up (-1) or down (1), centred in r: there is
// more of the inventory that way.
@(private)
draw_grid_arrow :: proc(r: rl.Rectangle, dir: int) {
	c := the_comic
	cx := r.x + math.floor(r.width / 2)
	cy := r.y + math.floor(r.height / 2) - 2
	for i in 0 ..< 4 {
		y := cy + f32(i) if dir < 0 else cy + f32(3 - i)
		grid_fill(cx - f32(i), y, cx + f32(i), y, c.line)
	}
}

@(private)
draw_menu_rows :: proc(w: ^World) -> string {
	s := &w.screen
	for ch, row in menu_choices(w) {
		r, _ := screen_row_rect(w, row)
		label := ch.ask if row == s.armed else choice_label(w, ch)
		rc := rl.Rectangle{gx(r.x), gx(r.y), gx(r.x + r.width) - gx(r.x), gx(r.y + r.height) - gx(r.y)}
		draw_comic_button(rc, label, row == s.hover || row == s.armed, true)
	}
	if s.armed >= 0 do return "Again for yes. Esc for no."
	return "Esc goes back to the game."
}

// --- The harness ---

// The screen as text: what is on each row, which is under the pointer.
screen_report :: proc(w: ^World) -> string {
	s := &w.screen
	b := strings.builder_make(context.temp_allocator)
	names := [Screen_Kind]string{.None = "no screen", .Save = "save", .Load = "load", .Inventory = "inventory", .Menu = "menu", .Hint = "hint"}
	fmt.sbprintf(&b, "%v screen", names[s.kind])
	if s.kind == .Inventory {
		n := screen_rows(w)
		last := min(n, s.first + INVENTORY_ACROSS * INVENTORY_DOWN)
		fmt.sbprintf(&b, ", %v across: %v to %v of %v on the page", INVENTORY_ACROSS, min(s.first + 1, n), last, n)
	}
	if s.kind == .Hint {
		strings.write_string(&b, hint_screen_report(w))
		return strings.to_string(b)
	}
	for row in 0 ..< screen_rows(w) {
		mark := ">" if row == s.hover else " "
		text := ""
		switch s.kind {
		case .Save, .Load:
			info, _ := row_info(w, row)
			text = fmt.tprintf("%v: %v", slot_column(info.slot), fmt.tprintf("%v, %v, %v", slot_title_text(info), room_label(w, info.scene), playtime_text(info.played)) if info.used else "empty")
		case .Inventory:
			it := screen_things(w)[row]
			_, drawn := item_sprite(w, it)
			text = fmt.tprintf("%v  [%v%v]", it.label, item_icon(it), "" if drawn else ": none, a tag")
		case .Menu:
			text = choice_label(w, menu_choices(w)[row])
		case .Hint, .None:
		}
		if row == s.armed do text = strings.concatenate({text, "  [asks: again for yes]"}, context.temp_allocator)
		if row == s.shown do text = strings.concatenate({text, "  [shown: ", screen_things(w)[row].description, "]"}, context.temp_allocator)
		fmt.sbprintf(&b, "\n    %v %v. %v", mark, row + 1, text)
	}
	if s.kind == .Inventory && s.hover >= 0 && s.hover < screen_rows(w) {
		fmt.sbprintf(&b, "\n    the pointer on %v: its name shows, %q", s.hover + 1, screen_things(w)[s.hover].label)
	}
	return strings.to_string(b)
}

// A row number as the harness gives it, from 1.
@(private)
parse_row :: proc(text: string) -> (int, bool) {
	return strconv.parse_int(strings.trim_space(text))
}

// `!screen`: the screen up, as text. `!screen <n>` clicks row n (from 1), as
// the mouse would; `!screen hover <n>` puts the pointer on it; `!screen esc`.
@(private)
screen_bang :: proc(w: ^World, arg: string) -> string {
	if screen_open(w) == .None do return "no screen is open"
	switch {
	case arg == "":
		return screen_report(w)
	case arg == "esc":
		if w.screen.armed >= 0 {
			w.screen.armed = -1
			return screen_report(w)
		}
		close_overlay(w)
		return "closed"
	case strings.has_prefix(arg, "hover "):
		n, ok := parse_row(arg[len("hover "):])
		if !ok do return "!screen hover <row>"
		screen_hover(w, n - 1)
		return screen_report(w)
	}
	n, ok := parse_row(arg)
	if !ok || n < 1 || n > screen_rows(w) do return fmt.tprintf("no row %q", arg)
	w.message_len = 0
	screen_pick(w, n - 1)
	if screen_open(w) != .None do return screen_report(w)
	if m := message(w); m != "" do return m
	if overlay_open(w) do return "[an overlay is open]"
	return "[nothing said]"
}
