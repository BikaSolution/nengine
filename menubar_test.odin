package nengine

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// The menu bar (menubar.odin) and the screens it opens (screens.odin): where
// the pointer calls it, when it is not there, that a click on it never walks
// her, that saving and loading from the screens are the typed SAVE and
// RESTORE, and that a screen stops the world.

// What the bar's items and the screens' words did, kept on the world
// (w.user) so that tests running side by side do not share it.
@(private = "file")
Bar_Record :: struct {
	picked:  [8]int,
	outcome: Slot_Outcome,
	slot:    int,
	said:    int,
	flipped: bool,
}

@(private = "file")
record :: proc(w: ^World) -> ^Bar_Record {
	return cast(^Bar_Record)w.user
}

@(private = "file")
BAR_ITEMS := [?]Bar_Item {
	{label = "Menu", key = .F10, pick = proc(w: ^World) {record(w).picked[0] += 1}},
	{label = "Save", key = .F5, pick = proc(w: ^World) {record(w).picked[1] += 1}},
	{label = "Load", key = .F7, pick = proc(w: ^World) {record(w).picked[2] += 1}},
}

// Every letter 16 canvas pixels wide, at 3.2 canvas pixels to the grid's.
@(private = "file")
METRICS :: Comic_Metrics {
	scale = 3.2,
	line = 30,
	grid_w = 320,
	measure = proc(text: string) -> f32 {return f32(len(text)) * 16},
}

@(private = "file")
bar_world :: proc(t: ^testing.T, rec: ^Bar_Record, name := "") -> World {
	w := World{user = rec}
	sc := Scene{name = "the_yard"}
	sc.walk_area = make([][2]f32, 4)
	sc.walk_area[0], sc.walk_area[1], sc.walk_area[2], sc.walk_area[3] = {0, 300}, {1024, 300}, {1024, 640}, {0, 640}
	append(&w.scenes, sc)
	w.player.pos = {500, 500}
	set_menu_bar(&w, BAR_ITEMS[:])
	if name != "" {
		base := os.get_env("TMPDIR", context.temp_allocator)
		if base == "" do base = "/tmp"
		dir := strings.concatenate({base, "/nengine-bar-", name}, context.temp_allocator)
		os.remove_all(dir)
		w.save_name = strings.clone(dir, context.temp_allocator)
	}
	w.screen_words = {
		save_title = proc(w: ^World) -> string {return "16:40"},
		slot_said = proc(w: ^World, outcome: Slot_Outcome, slot: int) {
			r := record(w)
			r.outcome, r.slot = outcome, slot
			r.said += 1
		},
	}
	return w
}

@(private = "file")
bar_tidy :: proc(w: ^World) {
	if w.save_name != "" && strings.contains(w.save_name, "nengine-bar-") do os.remove_all(save_dir(w))
	close_overlay(w)
	clear_flags(w)
	clear_notebook(w)
	delete(w.notebook)
	for &sc in w.scenes do delete(sc.walk_area)
	delete(w.scenes)
}

// --- Where it appears ---

@(test)
the_bar_drops_in_at_the_top_edge_and_goes_when_the_pointer_leaves :: proc(t: ^testing.T) {
	b := Menu_Bar{items = BAR_ITEMS[:], hover = -1}

	// Below the top edge, with the bar up: nothing, even over where it would be.
	bar_step(&b, true, {40, 8}, true, false, 0.2, METRICS)
	testing.expect_value(t, b.drop, f32(0))

	// At the very top: down, sliding in.
	bar_step(&b, true, {40, 1}, true, false, 0.05, METRICS)
	testing.expect(t, b.drop > 0 && b.drop < 1, "it slides in, not appears")
	bar_step(&b, true, {40, 1}, true, false, 0.2, METRICS)
	testing.expect_value(t, b.drop, f32(1))
	// Above the canvas, in the black over a letterboxed picture, is the top too.
	bar_step(&b, true, {40, -20}, true, false, 0.2, METRICS)
	testing.expect_value(t, b.drop, f32(1))

	// Down, it stays while the pointer is on it, and the word under it is picked out.
	bar_step(&b, true, {BAR_LEFT + 2, 8}, true, false, 0.2, METRICS)
	testing.expect_value(t, b.drop, f32(1))
	testing.expect_value(t, b.hover, 0)
	spans := bar_spans(BAR_ITEMS[:], METRICS)
	bar_step(&b, true, {spans[2][0] + 1, 5}, true, false, 0.016, METRICS)
	testing.expect_value(t, b.hover, 2)

	// Off it: it goes back up, and nothing is picked out on the way.
	bar_step(&b, true, {40, 60}, true, false, 0.05, METRICS)
	testing.expect(t, b.drop < 1)
	testing.expect_value(t, b.hover, -1)
	bar_step(&b, true, {40, 60}, true, false, 0.2, METRICS)
	testing.expect_value(t, b.drop, f32(0))

	// No pointer to believe (hidden, or not yet moved into the window): it
	// sits at 0,0 and calls nothing down.
	bar_step(&b, true, {0, 0}, false, false, 0.2, METRICS)
	testing.expect_value(t, b.drop, f32(0))

	// Held down by the harness, whatever the pointer does.
	b.held, b.held_hover = true, 1
	bar_step(&b, true, {0, 0}, false, false, 0.2, METRICS)
	testing.expect_value(t, b.drop, f32(1))
	testing.expect_value(t, b.hover, 1)
}

@(test)
the_bar_is_not_there_while_something_holds_the_screen :: proc(t: ^testing.T) {
	rec: Bar_Record
	w := bar_world(t, &rec)
	defer bar_tidy(&w)
	testing.expect(t, menu_bar_allowed(&w), "in play, with nothing up")

	w.dead = true
	testing.expect(t, !menu_bar_allowed(&w), "not while dying, nor under the death box")
	w.dead = false

	open_overlay(&w, {update = proc(w: ^World, dt: f32) -> bool {return true}})
	testing.expect(t, !menu_bar_allowed(&w), "not over an overlay: the notebook, a screen of its own")
	close_overlay(&w)

	chat: Conversation
	begin_conversation(&w, &chat, []Talk_Line{{text = "One."}, {text = "Two."}})
	testing.expect(t, !menu_bar_allowed(&w), "not in a conversation, where nothing is typed either")
	end_conversation(&w)
	testing.expect(t, menu_bar_allowed(&w))

	w.ride.phase = .Riding
	testing.expect(t, !menu_bar_allowed(&w), "not in a ride")
	w.ride.phase = .None
	w.peeping.active = true
	testing.expect(t, !menu_bar_allowed(&w), "not at a peep")
	w.peeping.active = false
	a := Announcement{title = "A body"}
	w.announcing = &a
	testing.expect(t, !menu_bar_allowed(&w), "not under an announcement")
	w.announcing = nil
	w.cut.world, w.cut.running = true, true
	testing.expect(t, !menu_bar_allowed(&w), "not in a cutscene")
	w.cut.world, w.cut.running = false, false

	// And when it goes, it goes at once: a conversation that starts under the
	// bar takes the screen.
	w.bar.drop = 1
	w.dead = true
	bar_step(&w.bar, menu_bar_allowed(&w), {40, 1}, true, false, 0.016, METRICS)
	testing.expect_value(t, w.bar.drop, f32(0))
	testing.expect(t, strings.contains(bar_bang(&w, ""), "not there"), "and the harness says so")
	w.dead = false

	// A game that sets no items has no bar: v1's.
	set_menu_bar(&w, nil)
	testing.expect(t, !menu_bar_allowed(&w))
}

// --- A click on it ---

@(test)
a_click_on_the_bar_is_the_bars_and_never_walks_her :: proc(t: ^testing.T) {
	rec: Bar_Record
	w := bar_world(t, &rec)
	defer bar_tidy(&w)
	spans := bar_spans(BAR_ITEMS[:], METRICS)
	on_save := [2]f32{(spans[1][0] + 2) * METRICS.scale, 1 * METRICS.scale} // canvas pixels, at the top edge

	// The pointer goes up; the bar comes down.
	testing.expect_value(t, pointer_in_play(&w, on_save, true, false, 0.2, METRICS), -1)
	testing.expect_value(t, w.bar.drop, f32(1))
	// A click on SAVE is SAVE, and she stays where she is.
	i := pointer_in_play(&w, on_save, true, true, 0.016, METRICS)
	testing.expect_value(t, i, 1)
	testing.expect(t, w.bar.took_click)
	testing.expect(t, !w.player.moving, "a click on the bar walked her")
	menu_bar_pick(&w, i)
	testing.expect_value(t, rec.picked[1], 1)
	testing.expect_value(t, w.bar.drop, f32(0)) // a choice made, the bar goes up

	// A click on the bar between words is still the bar's.
	w.bar.drop = 1
	gap := [2]f32{300 * METRICS.scale, 4 * METRICS.scale}
	testing.expect_value(t, pointer_in_play(&w, gap, true, true, 0.016, METRICS), -1)
	testing.expect(t, !w.player.moving)

	// A click on the floor walks, as it always did.
	testing.expect_value(t, pointer_in_play(&w, {600, 450}, true, true, 0.016, METRICS), -1)
	testing.expect(t, !w.bar.took_click)
	testing.expect(t, w.player.moving)
	testing.expect_value(t, w.player.target, [2]f32{600, 450})

	// And with no bar there to take it, a click at the top walks too (to the
	// nearest floor): the bar takes only the clicks it is there for.
	w.player.moving = false
	w.dead = true
	pointer_in_play(&w, on_save, true, true, 0.016, METRICS)
	testing.expect(t, w.player.moving)
}

// --- Saving and loading from the screens ---

@(private = "file")
file_without_when :: proc(w: ^World, slot: int) -> string {
	text, _ := read_data_file(save_path(w, slot))
	b := strings.builder_make(context.temp_allocator)
	for line in strings.split_lines(text, context.temp_allocator) {
		if strings.has_prefix(line, "when ") do continue
		strings.write_string(&b, line)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

@(test)
saving_from_the_screen_is_the_typed_save :: proc(t: ^testing.T) {
	rec: Bar_Record
	w := bar_world(t, &rec, "save")
	defer bar_tidy(&w)
	set_flag(&w, "act2", true)

	open_save_screen(&w)
	testing.expect_value(t, screen_open(&w), Screen_Kind.Save)
	testing.expect_value(t, screen_rows(&w), SAVE_SLOTS) // the player's eight: never the autosaves
	screen_pick(&w, 2) // slot 3, empty: at once
	testing.expect_value(t, rec.outcome, Slot_Outcome.Saved)
	testing.expect_value(t, rec.slot, 3)
	testing.expect(t, !overlay_open(&w), "the screen goes once it has saved")

	// The same file the typed SAVE writes, titled the same way.
	outcome, slot := slot_command(&w, Command{verb = "save", noun = "4"}, "16:40")
	testing.expect_value(t, outcome, Slot_Outcome.Saved)
	testing.expect_value(t, slot, 4)
	testing.expect_value(t, file_without_when(&w, 3), file_without_when(&w, 4))

	// Over a slot with something in it: a second click.
	set_flag(&w, "night", true)
	open_save_screen(&w)
	said := rec.said
	screen_pick(&w, 2)
	testing.expect_value(t, w.screen.armed, 2)
	testing.expect(t, overlay_open(&w), "it asks rather than saving over")
	testing.expect_value(t, rec.said, said)
	testing.expect(t, !strings.contains(file_without_when(&w, 3), "night"))
	screen_pick(&w, 2)
	testing.expect_value(t, rec.outcome, Slot_Outcome.Saved)
	testing.expect(t, strings.contains(file_without_when(&w, 3), "night"))

	// Where the typed SAVE cannot write, neither can the screen.
	dir := w.save_name
	defer w.save_name = dir
	w.save_name = "/proc/nengine-bar-cannot"
	typed, _ := slot_command(&w, Command{verb = "save", noun = "1"}, "16:40")
	open_save_screen(&w)
	screen_pick(&w, 0)
	testing.expect_value(t, rec.outcome, typed)
	testing.expect_value(t, rec.outcome, Slot_Outcome.Not_Saved)

	// And the autosaves are not the player's to write, typed or not.
	testing.expect_value(t, slot_act(&w, true, AUTOSAVE), Slot_Outcome.No_Slot)
}

@(test)
loading_from_the_screen_is_the_typed_restore :: proc(t: ^testing.T) {
	rec: Bar_Record
	w := bar_world(t, &rec, "load")
	defer bar_tidy(&w)

	set_flag(&w, "in_slot_two", true)
	testing.expect(t, save_game(&w, 2, "16:40"))
	clear_flags(&w)
	set_flag(&w, "in_the_autosave", true)
	testing.expect(t, autosave(&w, "17:00"))
	clear_flags(&w)
	set_flag(&w, "now", true)

	open_load_screen(&w)
	testing.expect_value(t, screen_rows(&w), SAVE_SLOTS + 2) // the two autosaves, then the eight
	// An empty slot is greyed: a click does nothing, and the screen stays.
	screen_pick(&w, 2) // slot 1
	testing.expect(t, overlay_open(&w))
	testing.expect_value(t, rec.said, 0)
	testing.expect(t, flag(&w, "now"))

	screen_pick(&w, 3) // slot 2
	testing.expect_value(t, rec.outcome, Slot_Outcome.Restored)
	testing.expect_value(t, rec.slot, 2)
	testing.expect(t, flag(&w, "in_slot_two") && !flag(&w, "now"))
	testing.expect(t, !overlay_open(&w))

	// The autosave, which a typed RESTORE cannot reach by number.
	open_load_screen(&w)
	screen_pick(&w, 0)
	testing.expect_value(t, rec.outcome, Slot_Outcome.Restored)
	testing.expect_value(t, rec.slot, AUTOSAVE)
	testing.expect(t, flag(&w, "in_the_autosave") && !flag(&w, "in_slot_two"))

	// The typed RESTORE is the same act.
	outcome, _ := slot_command(&w, Command{verb = "restore", noun = "2"})
	testing.expect_value(t, outcome, Slot_Outcome.Restored)
	testing.expect(t, flag(&w, "in_slot_two"))
	outcome, _ = slot_command(&w, Command{verb = "restore", noun = "5"})
	testing.expect_value(t, outcome, Slot_Outcome.Nothing_There)
}

// --- The world stops ---

@(test)
a_screen_stops_the_world :: proc(t: ^testing.T) {
	rec: Bar_Record
	w := bar_world(t, &rec)
	defer bar_tidy(&w)
	w.time = 12
	walk_to(&w.player, {700, 500})
	w.player.speed = 100

	for open in ([]proc(w: ^World){open_save_screen, open_load_screen, open_inventory_screen, open_menu_screen}) {
		open(&w)
		update(&w, 1)
		testing.expect_value(t, w.time, f32(12)) // the play clock waits
		testing.expect_value(t, w.player.pos, [2]f32{500, 500}) // nobody walks
		testing.expect(t, overlay_open(&w))
		close_overlay(&w)
		testing.expect_value(t, w.screen.kind, Screen_Kind.None)
	}
}

// --- The menu and the things she carries ---

@(test)
restart_and_quit_ask_first :: proc(t: ^testing.T) {
	rec: Bar_Record
	w := bar_world(t, &rec)
	defer bar_tidy(&w)
	flips := [?]Menu_Choice{{label = "Mercy", pick = proc(w: ^World) {record(w).flipped = !record(w).flipped}, stays = true}}
	w.screen_words.menu = flips[:]

	open_menu_screen(&w)
	testing.expect_value(t, screen_rows(&w), 4) // Resume, the game's own, Restart, Quit
	testing.expect_value(t, choice_label(&w, menu_choices(&w)[0]), "Resume")

	// A setting: done, and the menu stays to show it.
	screen_pick(&w, 1)
	testing.expect(t, rec.flipped)
	testing.expect(t, overlay_open(&w))

	// Restart: once is a question, twice is an answer; Esc says no.
	screen_pick(&w, 2)
	testing.expect(t, !w.restart)
	testing.expect_value(t, w.screen.armed, 2)
	screen_bang(&w, "esc")
	testing.expect_value(t, w.screen.armed, -1)
	testing.expect(t, overlay_open(&w), "the first Esc takes back the question, not the menu")
	screen_pick(&w, 3)
	screen_pick(&w, 3)
	testing.expect(t, w.quit)
	testing.expect(t, !overlay_open(&w))

	// Resume goes back to the game.
	open_menu_screen(&w)
	screen_pick(&w, 0)
	testing.expect(t, !overlay_open(&w))
}

@(test)
the_inventory_lists_what_she_always_has_then_what_she_carries :: proc(t: ^testing.T) {
	rec: Bar_Record
	w := bar_world(t, &rec)
	defer bar_tidy(&w)
	always := [?]Item{{"hat", "Straw hat", "A hat.", ""}, {"book", "Notebook", "A book.", ""}}
	items := [?]Item{{"lamp", "A lamp", "Lit.", ""}, {"key", "A key", "Brass.", ""}}
	w.items = items[:]
	w.screen_words.always = always[:]
	w.screen_words.item_pick = proc(w: ^World, it: Item) -> bool {
		if it.name != "book" do return false
		open_overlay(w, {update = proc(w: ^World, dt: f32) -> bool {return true}}) // the game's notebook
		return true
	}
	carry(&w, "key")

	open_inventory_screen(&w)
	testing.expect_value(t, screen_rows(&w), 3)
	things := screen_things(&w)
	testing.expect_value(t, things[0].label, "Straw hat")
	testing.expect_value(t, things[2].label, "A key")

	// A thing clicked: what it looks like, and the screen stays.
	screen_pick(&w, 2)
	testing.expect_value(t, w.screen.shown, 2)
	testing.expect(t, strings.contains(screen_report(&w), "Brass."))
	// The notebook: the game opens its own, and that is what stays up.
	screen_pick(&w, 1)
	testing.expect(t, overlay_open(&w))
	testing.expect_value(t, w.screen.kind, Screen_Kind.None)
}

@(test)
a_thing_is_drawn_with_its_own_sprite_or_the_one_it_names :: proc(t: ^testing.T) {
	testing.expect_value(t, item_icon({name = "lamp"}), "item_lamp")
	testing.expect_value(t, item_icon({name = "film", icon = "item_can"}), "item_can")
}

@(test)
the_inventory_is_a_grid_of_pictures :: proc(t: ^testing.T) {
	rec: Bar_Record
	w := bar_world(t, &rec)
	defer bar_tidy(&w)
	// Twenty-four things: a page of seven by three, and a row more.
	items: [24]Item
	for &it, i in items {
		it = {name = fmt.tprintf("k%v", i), label = fmt.tprintf("Thing %v", i), description = "Plain."}
	}
	w.items = items[:]
	for it in items do carry(&w, it.name)
	// One of them has a picture; the rest are tags.
	assets: Assets
	defer delete(assets.sprites)
	assets.sprites["item_k0"] = Sprite{}
	w.assets = &assets

	open_inventory_screen(&w)
	testing.expect_value(t, screen_rows(&w), 24)

	// Seven along a row, the eighth under the first; the twenty-second is
	// over the page.
	a, _ := screen_row_rect(&w, 0)
	b, _ := screen_row_rect(&w, 1)
	c, _ := screen_row_rect(&w, 7)
	testing.expect_value(t, b.y, a.y)
	testing.expect_value(t, b.x - a.x, f32(INVENTORY_PITCH))
	testing.expect_value(t, c.x, a.x)
	testing.expect_value(t, c.y - a.y, f32(INVENTORY_PITCH))
	_, on := screen_row_rect(&w, 21)
	testing.expect(t, !on, "the fourth row is over the page")
	p := screen_panel(&w)
	last, _ := screen_row_rect(&w, 20)
	testing.expect(t, a.x >= p.x + 8 && last.x + last.width <= p.x + p.width - 8, "the grid inside the panel")

	// The pointer on a cell finds it.
	testing.expect_value(t, screen_row_at(&w, {c.x + 5, c.y + 5}), 7)
	testing.expect_value(t, screen_row_at(&w, {p.x + 2, p.y + 2}), -1)

	// What the harness says: each thing's sprite, and whether there is one.
	r := screen_report(&w)
	testing.expect(t, strings.contains(r, "1 to 21 of 24"), r)
	testing.expect(t, strings.contains(r, "Thing 0  [item_k0]"), r)
	testing.expect(t, strings.contains(r, "Thing 3  [item_k3: none, a tag]"), r)

	// The pointer put on the twenty-third: the page goes down a row, and its
	// name is up.
	r = screen_bang(&w, "hover 23")
	testing.expect_value(t, w.screen.first, 7)
	testing.expect(t, strings.contains(r, "8 to 24 of 24"), r)
	testing.expect(t, strings.contains(r, "the pointer on 23: its name shows, \"Thing 22\""), r)
	_, on = screen_row_rect(&w, 0)
	testing.expect(t, !on, "the first row is over the top now")
	_, _, more_up, more_down := inventory_arrows(&w)
	testing.expect(t, more_up && !more_down, "an arrow up, none down")
	inventory_scroll(&w, -1)
	testing.expect_value(t, w.screen.first, 0)
	inventory_scroll(&w, -1)
	testing.expect_value(t, w.screen.first, 0)

	// A click is LOOK, as it was.
	screen_pick(&w, 3)
	testing.expect_value(t, w.screen.shown, 3)
	testing.expect(t, strings.contains(screen_report(&w), "[shown: Plain.]"))
}

@(test)
the_keys_go_round_the_grid :: proc(t: ^testing.T) {
	// Twenty-four: rows of seven, and three in the last.
	testing.expect_value(t, inventory_step(-1, 1, 24), 0)  // nothing picked: the first
	testing.expect_value(t, inventory_step(0, -1, 24), 0)  // the first, and Left
	testing.expect_value(t, inventory_step(3, 1, 24), 4)
	testing.expect_value(t, inventory_step(3, -INVENTORY_ACROSS, 24), 3) // the top row, and Up
	testing.expect_value(t, inventory_step(3, INVENTORY_ACROSS, 24), 10)
	testing.expect_value(t, inventory_step(19, INVENTORY_ACROSS, 24), 23) // down into the short row: its last
	testing.expect_value(t, inventory_step(22, INVENTORY_ACROSS, 24), 22) // the bottom row, and Down
	testing.expect_value(t, inventory_step(23, 1, 24), 23)
	testing.expect_value(t, inventory_step(0, 1, 0), -1)
	// The page follows, a row at a time, and never runs past the last row.
	testing.expect_value(t, inventory_keep_in_view(0, 23, 24), 7)
	testing.expect_value(t, inventory_keep_in_view(7, 2, 24), 0)
	testing.expect_value(t, inventory_first(70, 24), 7)
	testing.expect_value(t, inventory_first(0, 5), 0)
}
