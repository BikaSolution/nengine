package ui

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

// Asking for one of a list of names from inside an editor — which dialogue
// node a cue says, say — when the answer is not a file. The same shape as
// asking for a file (pick.odin): it takes the whole window while it is up,
// with a search box over the list, a pane beside it that the editor draws for
// the one under the cursor, and **choose** and **cancel** along the bottom.
//
//     // Asking: the items are borrowed and must outlive the question.
//     ui.choose_open(&e.choose, "node", "Choose a dialogue node", items[:], current,
//                    detail = draw_node, ctx = e)
//
//     // Every frame, before the editor does anything else:
//     if ui.choose_active(&e.choose) {
//         if a := ui.choose_step(&e.choose, status); a.done {
//             if a.key != "" && a.asking == "node" do set_node(e, a.key)
//         }
//         return true
//     }
//
// Typing searches at once, in every item's `search` text as well as its
// label, without case: the words of a node's lines find it as well as its id.
// Up and down move, Enter or a double click chooses, Esc clears the search
// and then cancels. The detail pane may take clicks of its own (choosing
// lines of a node, say); it is drawn after the list, inside its rectangle.

Choice :: struct {
	key:    string, // what is answered
	label:  string, // the row
	note:   string, // dim, at the right of the row
	search: string, // more text the search looks in; "" for the label alone
}

Choose_Detail_Proc :: proc(ctx: rawptr, key: string, area: rl.Rectangle)

Chooser :: struct {
	asking:   string, // owned
	title:    string, // owned
	items:    []Choice, // borrowed
	shown:    [dynamic]int, // the items the search lets through, in order
	filter:   string, // owned: what the list was last searched for
	sel:      int, // into shown
	scroll:   f32,
	followed: int,
	text:     Text_Input,
	detail:   Choose_Detail_Proc,
	ctx:      rawptr,
	clicked:  int,
	click_at: f64,
	active:   bool,
}

Choose_Answer :: struct {
	done:   bool,
	key:    string, // "" when cancelled. Good for this frame
	asking: string, // good for this frame
}

choose_open :: proc(c: ^Chooser, asking, title: string, items: []Choice, current := "", detail: Choose_Detail_Proc = nil, ctx: rawptr = nil) {
	choose_close(c)
	c.asking = strings.clone(asking)
	c.title = strings.clone(title)
	c.items = items
	c.detail = detail
	c.ctx = ctx
	c.filter = strings.clone("")
	c.clicked = -1
	c.followed = -1
	c.active = true
	choose_refilter(c)
	for i, n in c.shown do if c.items[i].key == current do c.sel = n
	text_input_focus(&c.text, "choose.filter", "")
}

choose_active :: proc(c: ^Chooser) -> bool {
	return c.active
}

choose_close :: proc(c: ^Chooser) {
	delete(c.asking)
	delete(c.title)
	delete(c.filter)
	delete(c.shown)
	text_input_destroy(&c.text)
	c^ = {}
}

// Which items a search lets through: every word of it somewhere in the
// label, the key or the search text, without case.
choose_matches :: proc(item: Choice, filter: string) -> bool {
	words := strings.fields(strings.to_lower(filter, context.temp_allocator), context.temp_allocator)
	if len(words) == 0 do return true
	hay := strings.to_lower(strings.concatenate({item.key, " ", item.label, " ", item.search}, context.temp_allocator), context.temp_allocator)
	for w in words do if !strings.contains(hay, w) do return false
	return true
}

@(private = "file")
choose_refilter :: proc(c: ^Chooser) {
	keep := ""
	if c.sel >= 0 && c.sel < len(c.shown) do keep = c.items[c.shown[c.sel]].key
	clear(&c.shown)
	for item, i in c.items do if choose_matches(item, c.filter) do append(&c.shown, i)
	c.sel = 0
	for i, n in c.shown do if c.items[i].key == keep do c.sel = n
	c.followed = -1
}

CHOOSE_ROW :: 24

// One frame of the question, drawn over the whole window.
choose_step :: proc(c: ^Chooser, status: ^Status) -> (a: Choose_Answer) {
	if !c.active do return
	screen := [2]f32{f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
	body_y := f32(HEADER_H)
	body_h := screen.y - HEADER_H - NEW_H - FOOTER_H
	list_w := split("choose.list", clamp(screen.x * 0.38, 240, 460), body_y, body_h, 180, max(screen.x - 260, 200))
	bar := rl.Rectangle{0, body_y, list_w, TOOLBAR_H}
	list := rl.Rectangle{0, body_y + TOOLBAR_H, list_w, body_h - TOOLBAR_H}
	pane := rl.Rectangle{list_w + 1, body_y, screen.x - list_w - 1, body_h}
	bottom := rl.Rectangle{0, body_y + body_h, screen.x, NEW_H}

	answer :: proc(c: ^Chooser, key: string) -> (a: Choose_Answer) {
		a.done = true
		a.asking = strings.clone(c.asking, context.temp_allocator)
		a.key = strings.clone(key, context.temp_allocator)
		choose_close(c)
		input_swallow()
		input_hold_off_mouse()
		return
	}
	current :: proc(c: ^Chooser) -> string {
		if c.sel >= 0 && c.sel < len(c.shown) do return c.items[c.shown[c.sel]].key
		return ""
	}

	// The keys that move and answer work while typing in the search box: it
	// is where the caret always is.
	rows := max(int(list.height / CHOOSE_ROW), 1)
	switch {
	case repeated(.DOWN):         c.sel += 1
	case repeated(.UP):           c.sel -= 1
	case key_pressed(.PAGE_DOWN): c.sel += rows
	case key_pressed(.PAGE_UP):   c.sel -= rows
	}
	c.sel = clamp(c.sel, 0, max(len(c.shown) - 1, 0))
	if key_pressed(.ENTER) || key_pressed(.KP_ENTER) {
		if k := current(c); k != "" do return answer(c, k)
	}
	if key_pressed(.ESCAPE) {
		if c.filter != "" {
			reset_string(&c.filter, "")
			text_input_focus(&c.text, "choose.filter", "")
			choose_refilter(c)
			input_swallow()
		} else {
			return answer(c, "")
		}
	}

	rl.ClearBackground(BG)
	panel({0, 0, screen.x, HEADER_H})
	label(14, 13, c.title, INK, FONT)
	count := fmt.tprintf("%v of %v", len(c.shown), len(c.items))
	label(i32(screen.x) - measure(count, SMALL) - 14, 17, count, DIM, SMALL)

	// The search box: always focused, searched as it is typed.
	rl.DrawRectangleRec(bar, {28, 28, 35, 255})
	hline(i32(bar.x), i32(bar.y + bar.height) - 1, i32(bar.width))
	if c.text.focus == "" do text_input_focus(&c.text, "choose.filter", c.filter)
	text_field(&c.text, {bar.x + 8, bar.y + 5, bar.width - 16, 24}, "choose.filter", c.filter)
	typed := text_input_value(&c.text) if c.text.focus == "choose.filter" else c.filter
	if typed != c.filter {
		reset_string(&c.filter, typed)
		choose_refilter(c)
	}
	if c.filter == "" do label(i32(bar.x) + 16, i32(bar.y) + 11, "type to search", {88, 88, 102, 255}, SMALL)

	// The list.
	content := f32(len(c.shown)) * CHOOSE_ROW
	scroll_wheel(&c.scroll, list, CHOOSE_ROW * 3, content)
	if c.sel != c.followed {
		c.scroll = scroll_to_show(c.scroll, f32(c.sel) * CHOOSE_ROW, CHOOSE_ROW, content, list.height)
		c.followed = c.sel
	}
	c.scroll = scroll_clamp(c.scroll, content, list.height)
	rl.BeginScissorMode(i32(list.x), i32(list.y), i32(list.width), i32(list.height))
	chosen := ""
	for i, n in c.shown {
		y := list.y + f32(n) * CHOOSE_ROW - c.scroll
		if y + CHOOSE_ROW < list.y || y > list.y + list.height do continue
		row := rl.Rectangle{list.x, y, list.width, CHOOSE_ROW - 1}
		hot := rl.CheckCollisionPointRec(mouse(), row) && rl.CheckCollisionPointRec(mouse(), list)
		switch {
		case n == c.sel: rl.DrawRectangleRec(row, {56, 52, 36, 255})
		case hot:        rl.DrawRectangleRec(row, {38, 38, 47, 255})
		}
		item := c.items[i]
		nw := f32(0)
		if item.note != "" {
			nw = f32(measure(item.note, SMALL)) + 12
			label(i32(row.x + row.width - nw), i32(y) + 5, item.note, {110, 110, 126, 255}, SMALL)
		}
		label(i32(row.x) + 10, i32(y) + 5, ellipsize(item.label, row.width - nw - 20, SMALL), GOLD if n == c.sel else INK, SMALL)
		if hot && mouse_pressed(.LEFT) {
			if c.clicked == n && now() - c.click_at < 0.4 do chosen = item.key
			c.sel, c.clicked, c.click_at = n, n, now()
		}
	}
	rl.EndScissorMode()
	if len(c.shown) == 0 do label(i32(list.x) + 14, i32(list.y) + 14, "nothing matches", DIM, SMALL)
	scrollbar(list, c.scroll, content)
	if chosen != "" do return answer(c, chosen)

	// The pane: the editor's, for the item under the cursor.
	panel(pane, {30, 30, 37, 255})
	if c.detail != nil && current(c) != "" {
		inner := rl.Rectangle{pane.x + 14, pane.y + 12, pane.width - 28, pane.height - 24}
		rl.BeginScissorMode(i32(pane.x), i32(pane.y), i32(pane.width), i32(pane.height))
		c.detail(c.ctx, current(c), inner)
		rl.EndScissorMode()
	}

	// The answers.
	rl.DrawRectangleRec(bottom, {28, 28, 35, 255})
	hline(i32(bottom.x), i32(bottom.y), i32(bottom.width))
	if button({bottom.width - 86, bottom.y + 10, 78, 24}, "cancel") do return answer(c, "")
	cx := bottom.width - 86 - 8 - 96
	k := current(c)
	if button({cx, bottom.y + 10, 96, 24}, "choose", k != "") && k != "" do return answer(c, k)
	what := k if k != "" else "pick one, then choose (or double-click it)"
	label(12, i32(bottom.y) + 15, ellipsize(what, cx - 24, SMALL), INK if k != "" else DIM, SMALL)

	splits_draw()
	footer(status, "type to search  arrows move  enter choose  Esc clear, cancel")
	return
}
