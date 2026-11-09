package ui

import "core:fmt"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

// Choosing a file to work on, for when there's no command line to type one
// on. It replaces the old picker, which showed one folder's worth of one
// extension and gave you no way to go anywhere else — so when it guessed
// wrong about where your files were, and it usually did, you were left
// staring at an empty list with nothing to click.
//
// This one browses. Folders you can walk into and back out of, shortcuts to
// every assets folder in the checkout with a count beside each, a filter that
// searches everything underneath you rather than only what is on screen, and
// a preview pane the program fills in — because only nart knows how to draw a
// sprite.
//
// It knows nothing about any file format. Each program hands it a list of
// kinds — a suffix, a label, a colour, and how to write a blank one — and two
// optional procedures, for the detail column and for the preview.
//
// Everything drawn here is ASCII: raylib's built-in font has nothing above
// codepoint 126, and a clever arrow renders as a hole.

// Writes an empty file. `opts` are the values of that kind's `fields`, in
// order, so a new sprite arrives at the size that was asked for.
New_File_Proc :: proc(path, name: string, opts: []int) -> bool

// A short line about one file for the list: "14x46 1f", "4 bars 3 voices".
// Called for the rows on screen and then cached, so it may open the file.
// Return "" when there is nothing worth saying.
Detail_Proc :: proc(ctx: rawptr, path: string, kind: int) -> string

// Draws the selected file into `area`. Return false for the browser's own
// plain description instead.
Preview_Proc :: proc(ctx: rawptr, path: string, kind: int, area: rl.Rectangle) -> bool

// Whether a file of the right kind is one to list at all: a picker asking for
// a backdrop wants the sprites that are the size of a room, not every lamp.
// It may open the file, so keep it to the head of it.
Accept_Proc :: proc(ctx: rawptr, path: string) -> bool

MAX_NEW_FIELDS :: 4

// An extra number asked for when making a new file: a sprite's width, a
// song's bars. `lo` and `hi` clamp what can be typed.
New_Field :: struct {
	label:  string,
	value:  int,
	lo, hi: int,
}

File_Kind :: struct {
	suffix: string, // ".sprite", lower case, with the dot
	label:  string, // "sprite"
	color:  rl.Color,
	blank:  New_File_Proc, // nil means openable but not creatable here
	fields: []New_Field,
}

Browser :: struct {
	title:    string,
	tool:     string, // which tool this is, for remembering the last folder
	kinds:    []File_Kind,
	suffixes: []string, // the kinds' suffixes, in the same order

	dir:      string, // absolute: where we are
	root:     string, // absolute: the checkout, for short paths and breadcrumbs
	home:     string, // the checkout the tool was started in, for when `dir` is in none
	entries:  [dynamic]Entry,
	places:   [dynamic]Place,
	scope:    string, // what `places` was built for (places_scope); built again when it changes
	details:  map[string]string, // path -> detail line, emptied on refresh

	sel:      int,
	scroll:   f32,
	followed: int, // the row the list last scrolled to show; -1 to show `sel` again
	side_scroll: f32, // the places column's own scroll
	side_follow: bool, // bring the lit place into view on the next draw
	sort:     Sort_Mode,
	reverse:  bool,
	only:     int, // show just this kind, -1 for all

	filter:   string, // what's in the search box
	typed:    string, // the name being typed for a new file
	opts:     [dynamic][MAX_NEW_FIELDS]int,
	new_kind: int,

	renaming: string, // path being renamed in place, "" for none
	deleting: string, // path Delete was pressed on, waiting to be pressed again

	clicked:  int, // last row clicked, for spotting a double click
	click_at: f64,

	text:     Text_Input,
	preview:  Preview_Proc,
	detail:   Detail_Proc,
	ctx:      rawptr,
	loaded:   bool,

	// Picking (ui/pick.odin): the browser asked a question by an editor —
	// which backdrop, which sprite — rather than the way into one. Nothing is
	// made, renamed or erased from here, the bottom row is the answer, and
	// the folder is not remembered as where this tool was last browsing.
	picking:  bool,
	accept:   Accept_Proc, // nil lists every file of the right kind
	// Every file below the folder, not just those in it, as a search lists
	// them: a picker asking for a room, where each room is in a folder of
	// its own.
	deep:     bool,
}

ROW_H :: 26
SIDEBAR_W :: 200
PREVIEW_W :: 330
HEADER_H :: 46
TOOLBAR_H :: 34
NEW_H :: 44

// `dir` is where to start; "" means pick up where this tool left off, or else
// find the folder with the most of what this tool edits. `kinds` is borrowed
// and must outlive the browser.
//
// `detail` and `preview` are passed here rather than set on the struct
// afterwards, because this clears the struct: a hook assigned before the call
// would be quietly thrown away, which is exactly the bug it cost an afternoon
// to find once.
browser_open :: proc(
	b: ^Browser,
	title, tool: string,
	kinds: []File_Kind,
	dir := "",
	detail: Detail_Proc = nil,
	preview: Preview_Proc = nil,
	ctx: rawptr = nil,
	find := "",
) {
	suffixes := make([]string, len(kinds))
	for k, i in kinds do suffixes[i] = k.suffix

	start := dir
	if start == "" do start = recall_dir(context.temp_allocator)
	if start == "" || !os.is_dir(start) do start = best_start(suffixes)

	b^ = {
		title    = title,
		tool     = strings.clone(tool),
		kinds    = kinds,
		suffixes = suffixes,
		dir      = abs_path(start),
		home     = workspace_root(),
		typed    = strings.clone(""),
		filter   = strings.clone(find),
		renaming = strings.clone(""),
		deleting = strings.clone(""),
		only     = -1,
		clicked  = -1,
		followed = -1,
		side_follow = true,
		detail   = detail,
		preview  = preview,
		ctx      = ctx,
		loaded   = true,
	}
	for k in kinds {
		vals: [MAX_NEW_FIELDS]int
		for f, i in k.fields do if i < MAX_NEW_FIELDS do vals[i] = f.value
		append(&b.opts, vals)
	}
	for k, i in kinds do if k.blank != nil {
		b.new_kind = i
		break
	}
	places_follow(b, true)
	browser_refresh(b)
}

// Puts the selection on `path` if it is in the list, so coming back from an
// editor lands on the file you were just in rather than the top of its folder.
browser_select :: proc(b: ^Browser, path: string) {
	want := abs_path(path, context.temp_allocator)
	for e, i in b.entries do if e.path == want {
		b.sel, b.followed = i, -1
		return
	}
}

// Points the places tree at where we are now: which checkout, and the tree
// built again if we have gone into another game (or `force`). Moving about
// inside one game only changes which rows are open, which is worked out as
// they are drawn.
@(private = "file")
places_follow :: proc(b: ^Browser, force: bool) {
	root := workspace_root_of(b.dir, context.temp_allocator)
	if root == "" do root = b.home
	scope := places_scope(root, b.dir)
	if force || root != b.root || scope != b.scope {
		reset_string(&b.root, root)
		reset_string(&b.scope, scope)
		discover_places(&b.places, b.suffixes, b.root, b.dir)
	}
	b.side_follow = true
}

browser_close :: proc(b: ^Browser) {
	if !b.loaded do return
	if !b.picking do remember_dir(b.dir)
	entries_destroy(&b.entries)
	delete(b.entries)
	places_destroy(&b.places)
	delete(b.places)
	clear_details(b)
	delete(b.details)
	delete(b.opts)
	text_input_destroy(&b.text)
	delete(b.suffixes)
	delete(b.tool)
	delete(b.dir)
	delete(b.root)
	delete(b.home)
	delete(b.scope)
	delete(b.typed)
	delete(b.filter)
	delete(b.renaming)
	delete(b.deleting)
	b^ = {}
}

@(private = "file")
clear_details :: proc(b: ^Browser) {
	for k, v in b.details {
		delete(k)
		delete(v)
	}
	clear(&b.details)
}

// The folder holding the most of what this tool edits, so a tool started
// anywhere at all opens on something rather than on nothing. Where two
// folders hold the same number, the deeper one wins: it is the one whose own
// files those are, rather than a parent that merely contains it.
@(private = "file")
best_start :: proc(suffixes: []string) -> string {
	places: [dynamic]Place
	defer {
		places_destroy(&places)
		delete(places)
	}
	root := workspace_root(context.temp_allocator)
	discover_places(&places, suffixes, root, root, all = true)
	best, best_n, best_depth := "", 0, -1
	for p in places {
		if p.count > best_n || (p.count == best_n && p.count > 0 && p.depth > best_depth) {
			best, best_n, best_depth = p.path, p.count, p.depth
		}
	}
	if best != "" do return strings.clone(best, context.temp_allocator)
	return abs_path("", context.temp_allocator)
}

browser_refresh :: proc(b: ^Browser) {
	entries_destroy(&b.entries)
	clear_details(b)

	suffixes := b.suffixes
	if b.only >= 0 && b.only < len(b.suffixes) do suffixes = b.suffixes[b.only:b.only + 1]

	if strings.trim_space(b.filter) != "" || b.deep {
		// A filter searches everything below here, not just this folder. That
		// is the whole point of it: you type "lamp" and stop caring which of
		// the four asset folders it was filed in.
		list_tree(&b.entries, b.dir, suffixes)
		needle := strings.to_lower(strings.trim_space(b.filter), context.temp_allocator)
		keep := 0
		for e in b.entries {
			if (!b.deep || !e.dir) && strings.contains(strings.to_lower(e.name, context.temp_allocator), needle) {
				b.entries[keep] = e
				keep += 1
			} else {
				delete(e.name)
				delete(e.path)
			}
		}
		resize(&b.entries, keep)
	} else {
		list_dir(&b.entries, b.dir, suffixes)
		for &e in b.entries do if e.dir do e.count = count_below(e.path, suffixes)
	}
	if b.accept != nil {
		keep := 0
		for e in b.entries {
			if e.dir || b.accept(b.ctx, e.path) {
				b.entries[keep] = e
				keep += 1
			} else {
				delete(e.name)
				delete(e.path)
			}
		}
		resize(&b.entries, keep)
	}
	sort_entries(b.entries[:], b.sort, b.reverse)
	b.sel = clamp(b.sel, 0, max(len(b.entries) - 1, 0))
}

browser_goto :: proc(b: ^Browser, dir: string) {
	if !os.is_dir(dir) do return
	reset_string(&b.dir, abs_path(dir, context.temp_allocator))
	reset_string(&b.filter, "")
	reset_string(&b.deleting, "")
	reset_string(&b.renaming, "")
	b.sel, b.scroll, b.clicked, b.followed = 0, 0, -1, -1
	places_follow(b, false)
	browser_refresh(b)
}

// The detail line for one file, worked out once and kept. Without the cache
// this would re-open every visible file sixty times a second.
@(private = "file")
detail_for :: proc(b: ^Browser, e: Entry) -> string {
	if b.detail == nil || e.dir do return ""
	if have, ok := b.details[e.path]; ok do return have
	text := strings.clone(b.detail(b.ctx, e.path, e.kind))
	b.details[strings.clone(e.path)] = text
	return text
}

// One frame. `chosen` is a path to open; `running` goes false on Esc.
browser_step :: proc(b: ^Browser, status: ^Status) -> (path: string, chosen: bool, running: bool) {
	running = true
	if !b.loaded do return "", false, false

	screen := [2]f32{f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
	editing := typing(&b.text)

	// The rectangles first, so the keyboard and the mouse agree about what is
	// where. Both columns are dragged by their edge and remember where they
	// were left; on a narrow window they drop out rather than squeezing the
	// list to nothing.
	body_y := f32(HEADER_H)
	body_h := screen.y - HEADER_H - FOOTER_H
	side_w, prev_w := f32(0), f32(0)
	if screen.x > 720 {
		side_w = split("browser.places", SIDEBAR_W, body_y, body_h, 120, min(screen.x * 0.4, 420))
	}
	if screen.x > 1020 {
		prev_x := split_right("browser.preview", PREVIEW_W, screen.x, body_y, body_h, 200, max(screen.x - side_w - 260, 200))
		prev_w = screen.x - prev_x
	}
	side := rl.Rectangle{0, body_y, side_w, body_h}
	prev := rl.Rectangle{screen.x - prev_w, body_y, prev_w, body_h}
	mid_x := side_w + (1 if side_w > 0 else 0)
	mid_w := screen.x - mid_x - prev_w
	bar := rl.Rectangle{mid_x, HEADER_H, mid_w, TOOLBAR_H}
	list := rl.Rectangle{mid_x, bar.y + bar.height, mid_w, screen.y - bar.y - bar.height - NEW_H - FOOTER_H}
	newbar := rl.Rectangle{mid_x, list.y + list.height, mid_w, NEW_H}

	rows := max(int(list.height / ROW_H), 1)

	// --- Keys ---
	if !editing {
		switch {
		case repeated(.DOWN):         b.sel += 1
		case repeated(.UP):           b.sel -= 1
		case key_pressed(.PAGE_DOWN): b.sel += rows
		case key_pressed(.PAGE_UP):   b.sel -= rows
		case key_pressed(.HOME):      b.sel = 0
		case key_pressed(.END):       b.sel = len(b.entries) - 1
		}
		b.sel = clamp(b.sel, 0, max(len(b.entries) - 1, 0))

		if key_pressed(.F5) {
			places_follow(b, true)
			browser_refresh(b)
			say(status, "reloaded")
		}
		if ctrl_down() && key_pressed(.F) do text_input_focus(&b.text, "browser.filter", b.filter)
		if ctrl_down() && key_pressed(.N) && !b.picking do text_input_focus(&b.text, "browser.new", b.typed)

		if key_pressed(.BACKSPACE) || key_pressed(.LEFT) {
			if up := parent_dir(b.dir); up != b.dir do browser_goto(b, up)
		}
		if key_pressed(.ENTER) || key_pressed(.KP_ENTER) || key_pressed(.RIGHT) {
			if b.sel < len(b.entries) {
				e := b.entries[b.sel]
				if e.dir {
					browser_goto(b, e.path)
				} else {
					return e.path, true, true
				}
			}
		}
		if b.sel < len(b.entries) && !b.entries[b.sel].dir && !b.picking {
			e := b.entries[b.sel]
			if key_pressed(.F2) {
				reset_string(&b.renaming, e.path)
				text_input_focus(&b.text, "browser.rename", file_of(e.path))
				// The name, not the extension: that is the part being renamed.
				b.text.anchor, b.text.caret = 0, len(base_name(file_of(e.path)))
			}
			if ctrl_down() && key_pressed(.D) do duplicate(b, e, status)
			if key_pressed(.DELETE) {
				if b.deleting == e.path {
					remove_entry(b, e, status)
				} else {
					reset_string(&b.deleting, e.path)
					say(status, "Delete again to erase %v", file_of(e.path))
				}
			}
		}
		if key_pressed(.ESCAPE) {
			switch {
			case b.deleting != "": reset_string(&b.deleting, "")
			case b.renaming != "": reset_string(&b.renaming, "")
			case strings.trim_space(b.filter) != "":
				reset_string(&b.filter, "")
				browser_refresh(b)
			case:
				running = false
			}
		}
	}

	// The wheel scrolls the list. When the selection moves — arrows, Page
	// Down, a new folder — the list is brought round to show it, once; it is
	// not held there, or the wheel could never move the selection off screen.
	// It used to be held, every frame, which is why the wheel did nothing.
	content := f32(len(b.entries)) * ROW_H
	scroll_wheel(&b.scroll, list, ROW_H * 3, content)
	if b.sel != b.followed {
		b.scroll = scroll_to_show(b.scroll, f32(b.sel) * ROW_H, ROW_H, content, list.height)
		b.followed = b.sel
	}
	b.scroll = scroll_clamp(b.scroll, content, list.height)

	// --- Draw ---
	rl.ClearBackground(BG)

	draw_header(b, screen.x)
	if side_w > 0 do draw_places(b, side, status)
	draw_toolbar(b, bar)
	if p, c := draw_list(b, list, status); c {
		path, chosen = p, c
	}
	if prev_w > 0 do draw_preview(b, prev)
	if b.picking {
		if p, c, gone := draw_pick(b, newbar); c {
			path, chosen = p, c
		} else if gone {
			running = false
		}
	} else if p, c := draw_new(b, newbar, status); c {
		path, chosen = p, c
	}

	// A hint that runs off the end of the bar is no hint, so a narrow window
	// gets the short list rather than a sentence with its end cut off.
	splits_draw()

	keys := "arrows move  enter open  bksp up  ^F find  ^N new  F2 rename  ^D copy  Del erase  F5 reload  Esc back"
	if screen.x < 760 do keys = "arrows  enter open  bksp up  ^F find  Esc back"
	switch {
	case b.picking:        keys = "arrows move  enter choose  bksp up  ^F find  Esc cancel"
	case b.deleting != "": keys = "press Delete again to erase it, or Esc to keep it"
	case b.renaming != "": keys = "type a new name, enter to rename, Esc to leave it alone"
	}
	footer(status, keys)
	return
}

// The bottom row while picking: what would be chosen, and the two answers.
@(private = "file")
draw_pick :: proc(b: ^Browser, r: rl.Rectangle) -> (path: string, chosen: bool, cancelled: bool) {
	rl.DrawRectangleRec(r, {28, 28, 35, 255})
	hline(i32(r.x), i32(r.y), i32(r.width))
	if button({r.x + r.width - 86, r.y + 10, 78, 24}, "cancel") do return "", false, true
	file := b.sel < len(b.entries) && !b.entries[b.sel].dir
	cx := r.x + r.width - 86 - 8 - 96
	if button({cx, r.y + 10, 96, 24}, "choose", file) && file do return b.entries[b.sel].path, true, false
	what := file_of(b.entries[b.sel].path) if file else "pick a file, then choose (or double-click it)"
	label(i32(r.x) + 12, i32(r.y) + 15, ellipsize(what, cx - r.x - 24, SMALL), INK if file else DIM, SMALL)
	return
}

// --- The pieces ---

// Every folder from the top down to where we are, each one a button: the
// shortest way back out of a wrong turn. A folder outside the checkout is
// shown from the filesystem root instead, rather than pretending it hangs off
// the project.
@(private = "file")
Crumb :: struct {
	label: string,
	path:  string,
}

@(private = "file")
crumb_trail :: proc(b: ^Browser, out: ^[dynamic]Crumb) {
	inside := b.root != "" && (b.dir == b.root || strings.has_prefix(b.dir, path_join(b.root, "")))
	walk, rest := "", b.dir
	if inside {
		walk = b.root
		rest = under(b.root, b.dir)
		append(out, Crumb{file_of(b.root), b.root})
	} else {
		walk = ""
		append(out, Crumb{"/", "/"})
	}
	for c in strings.split(rest, "/", context.temp_allocator) {
		if c == "" do continue
		walk = path_join(walk, c) if walk != "" else strings.concatenate({"/", c}, context.temp_allocator)
		append(out, Crumb{c, strings.clone(walk, context.temp_allocator)})
	}
}

@(private = "file")
draw_header :: proc(b: ^Browser, width: f32) {
	panel({0, 0, width, HEADER_H})
	label(14, 13, b.title, INK, FONT)
	x := f32(14 + measure(b.title, FONT) + 20)

	trail := make([dynamic]Crumb, context.temp_allocator)
	crumb_trail(b, &trail)

	// A path too long for the bar loses its head, not its tail: the folder
	// you are in is the part you need to read.
	avail := width - x - 12
	from := 0
	for {
		total := f32(0)
		for c, i in trail do if i >= from do total += f32(measure(c.label, SMALL)) + 23
		if total <= avail || from >= len(trail) - 1 do break
		from += 1
	}
	if from > 0 {
		label(i32(x), 15, "...", DIM, SMALL)
		x += 26
	}

	for c, i in trail {
		if i < from do continue
		// No separator after the filesystem root, which is one already.
		if (i > from && trail[i - 1].label != "/") || from > 0 {
			label(i32(x), 15, "/", {80, 80, 94, 255}, SMALL)
			x += 9
		}
		if crumb(c.label, &x, c.path == b.dir) do browser_goto(b, c.path)
	}
}

@(private = "file")
crumb :: proc(text: string, x: ^f32, here: bool) -> bool {
	w := f32(measure(text, SMALL)) + 14
	r := rl.Rectangle{x^, 11, w, 24}
	hot := rl.CheckCollisionPointRec(mouse(), r)
	if hot do rl.DrawRectangleRec(r, {46, 46, 56, 255})
	label(i32(x^) + 7, 15, text, GOLD if here else (INK if hot else DIM), SMALL)
	x^ += w
	return hot && mouse_pressed(.LEFT)
}

PLACE_H :: 22

@(private = "file")
draw_places :: proc(b: ^Browser, r: rl.Rectangle, status: ^Status) {
	panel(r, {30, 30, 38, 255})
	label(i32(r.x) + 12, i32(r.y) + 10, "PLACES", {110, 110, 126, 255}, SMALL)
	rows := rl.Rectangle{r.x, r.y + 32, r.width, r.height - 36}

	// The rows that are open for where we are, in order.
	shown := make([dynamic]int, context.temp_allocator)
	lit := -1
	for _, i in b.places do if place_shown(b.places[:], i, b.dir) {
		if b.places[i].path == b.dir do lit = len(shown)
		append(&shown, i)
	}
	content := f32(len(shown)) * PLACE_H

	scroll_wheel(&b.side_scroll, rows, PLACE_H * 3, content)
	if b.side_follow {
		if lit >= 0 do b.side_scroll = scroll_to_show(b.side_scroll, f32(lit) * PLACE_H, PLACE_H, content, rows.height)
		b.side_follow = false
	}
	b.side_scroll = scroll_clamp(b.side_scroll, content, rows.height)

	rl.BeginScissorMode(i32(rows.x), i32(rows.y), i32(rows.width), i32(rows.height))
	goto_path := ""
	for i, n in shown {
		y := rows.y + f32(n) * PLACE_H - b.side_scroll
		if y + PLACE_H < rows.y || y > rows.y + rows.height do continue
		p := b.places[i]
		row := rl.Rectangle{r.x + 4, y, r.width - 12, PLACE_H}
		hot := rl.CheckCollisionPointRec(mouse(), row) && rl.CheckCollisionPointRec(mouse(), rows)
		here := p.path == b.dir
		on_way := !here && inside(p.path, b.dir)
		if here {
			rl.DrawRectangleRec(row, {56, 52, 36, 255})
		} else if hot {
			rl.DrawRectangleRec(row, {42, 42, 52, 255})
		}

		// `-` open, `+` closed, nothing for a folder with no folders in it.
		indent := f32(8 + p.depth * 11)
		if p.kids {
			mark := "-" if place_open(b.places[:], i, b.dir) else "+"
			label(i32(row.x + indent), i32(y) + 4, mark, GOLD if here || on_way else {96, 96, 112, 255}, SMALL)
		}
		indent += 11

		ink: rl.Color
		switch {
		case here:        ink = GOLD
		case on_way:      ink = {226, 214, 180, 255}
		case p.count > 0: ink = INK if p.kind != .Folder else rl.Color{196, 196, 206, 255}
		case:             ink = {110, 110, 126, 255}
		}
		n := fmt.tprintf("%v", p.count)
		nw := f32(measure(n, SMALL))
		// Cut from the middle: two games are often one name and a suffix, and
		// `my_first_gam..` twice tells you nothing about which is which.
		label(i32(row.x + indent), i32(y) + 4, ellipsize_middle(p.label, row.width - indent - nw - 14, SMALL), ink, SMALL)
		if p.count > 0 {
			label(i32(row.x + row.width - nw) - 6, i32(y) + 4, n, DIM if !here else GOLD, SMALL)
		}
		if hot && mouse_pressed(.LEFT) && !here do goto_path = p.path
	}
	rl.EndScissorMode()
	scrollbar({rows.x, rows.y, rows.width - 1, rows.height}, b.side_scroll, content)

	if goto_path != "" {
		to := strings.clone(goto_path, context.temp_allocator)
		browser_goto(b, to)
		say(status, "%v", under(b.root, to))
	}
}

@(private = "file")
draw_toolbar :: proc(b: ^Browser, r: rl.Rectangle) {
	rl.DrawRectangleRec(r, {28, 28, 35, 255})
	hline(i32(r.x), i32(r.y + r.height) - 1, i32(r.width))

	x := r.x + 8
	fw := clamp(r.width * 0.32, 130, 250)
	if v, done := text_field(&b.text, {x, r.y + 5, fw, 24}, "browser.filter", b.filter); done {
		reset_string(&b.filter, v)
		b.sel, b.scroll = 0, 0
		browser_refresh(b)
	}
	if b.filter == "" && b.text.focus != "browser.filter" {
		label(i32(x) + 8, i32(r.y) + 11, "find, incl. subfolders", {88, 88, 102, 255}, SMALL)
	}
	x += fw + 10

	if len(b.kinds) > 1 {
		if chip({x, r.y + 5, 38, 24}, "all", b.only < 0) {
			b.only = -1
			browser_refresh(b)
		}
		x += 42
		for k, i in b.kinds {
			w := f32(measure(k.label, SMALL) + 18)
			if x + w > r.x + r.width - 160 do break
			if chip({x, r.y + 5, w, 24}, k.label, b.only == i) {
				b.only = -1 if b.only == i else i
				browser_refresh(b)
			}
			x += w + 4
		}
	}

	// Sorting, right-aligned so it never shoves the filter box about.
	sorts := [?]Sort_Chip{{.Name, "name"}, {.Size, "size"}, {.Modified, "newest"}}
	sx := r.x + r.width - 8
	#reverse for s in sorts {
		w := f32(measure(s.label, SMALL) + 16)
		sx -= w + 4
		if sx < x do break
		if chip({sx, r.y + 5, w, 24}, s.label, b.sort == s.mode) {
			if b.sort == s.mode {
				b.reverse = !b.reverse
			} else {
				b.sort, b.reverse = s.mode, false
			}
			sort_entries(b.entries[:], b.sort, b.reverse)
		}
	}
}

// How wide each right-hand column is, given the room there is. Zero means
// that column isn't shown at this width.
@(private = "file")
Columns :: struct {
	age, size, detail, badge: f32,
}

@(private = "file")
columns :: proc(width: f32, kinds: bool) -> (c: Columns) {
	// A name needs room before any of this is worth having; the order these
	// are given up in is the order they stop earning their place.
	if width > 330 do c.age = 74
	if width > 420 do c.size = 62
	if width > 620 do c.detail = 136
	if kinds && width > 700 do c.badge = 62
	return
}

// Drawn against the right edge of its column, so figures line up on their
// last digit rather than their first.
@(private = "file")
right_align :: proc(text: string, x, w: f32, y: f32, color: rl.Color) {
	if text == "" do return
	cut := ellipsize(text, w - 8, SMALL)
	label(i32(x + w - f32(measure(cut, SMALL))) - 8, i32(y) + 5, cut, color, SMALL)
}

@(private = "file")
Sort_Chip :: struct {
	mode:  Sort_Mode,
	label: string,
}

@(private = "file")
draw_list :: proc(b: ^Browser, r: rl.Rectangle, status: ^Status) -> (path: string, chosen: bool) {
	if len(b.entries) == 0 {
		label(i32(r.x) + 16, i32(r.y) + 18, "nothing here" if strings.trim_space(b.filter) == "" else "nothing below here matches", DIM, SMALL)
		label(i32(r.x) + 16, i32(r.y) + 40, "pick a place on the left, backspace to go up,", {96, 96, 112, 255}, SMALL)
		label(i32(r.x) + 16, i32(r.y) + 58, "or name a new file along the bottom", {96, 96, 112, 255}, SMALL)
		return
	}

	rl.BeginScissorMode(i32(r.x), i32(r.y), i32(r.width), i32(r.height))
	for e, i in b.entries {
		y := r.y + f32(i) * ROW_H - b.scroll
		if y + ROW_H < r.y || y > r.y + r.height do continue
		row := rl.Rectangle{r.x, y, r.width, ROW_H - 1}
		hot := rl.CheckCollisionPointRec(mouse(), row)
		switch {
		case e.path == b.deleting: rl.DrawRectangleRec(row, {86, 32, 36, 255})
		case i == b.sel:           rl.DrawRectangleRec(row, {56, 52, 36, 255})
		case hot:                  rl.DrawRectangleRec(row, {38, 38, 47, 255})
		}

		x := row.x + 12
		if e.dir {
			label(i32(x), i32(y) + 5, ">", GOLD, SMALL)
		}
		x += 14

		// The columns sit at fixed positions rather than being packed in from
		// the right, so they line up down the list instead of jittering with
		// the length of whatever is in them. Narrow windows drop the columns
		// they can't afford, from the least useful inwards.
		cols := columns(row.width, len(b.kinds) > 1)
		right := row.x + row.width - 10
		if cols.age > 0 {
			right -= cols.age
			right_align(age_text(e.mtime), right, cols.age, y, {100, 100, 116, 255})
		}
		if e.dir {
			n := fmt.tprintf("%v inside", e.count) if e.count > 0 else "empty"
			w := max(cols.size + cols.detail, f32(measure(n, SMALL)) + 10)
			right -= w
			right_align(n, right, w, y, DIM if e.count > 0 else rl.Color{92, 92, 106, 255})
		} else {
			if cols.size > 0 {
				right -= cols.size
				right_align(size_text(e.size), right, cols.size, y, {120, 120, 136, 255})
			}
			if cols.detail > 0 {
				right -= cols.detail
				right_align(detail_for(b, e), right, cols.detail, y, {150, 172, 196, 255})
			}
			if cols.badge > 0 && e.kind >= 0 && e.kind < len(b.kinds) {
				right -= cols.badge
				k := b.kinds[e.kind]
				badge(i32(right), i32(y) + 4, k.label, k.color)
			}
		}
		rx := right - 8

		if e.path == b.renaming {
			w := min(f32(280), rx - x - 10)
			if v, done := text_field(&b.text, {x, y + 2, w, ROW_H - 5}, "browser.rename", file_of(e.path)); done {
				rename_entry(b, e, v, status)
				reset_string(&b.renaming, "")
				rl.EndScissorMode()
				return
			}
		} else {
			ink := rl.Color{214, 204, 176, 255} if e.dir else INK
			label(i32(x), i32(y) + 5, ellipsize(e.name, rx - x - 10, SMALL), ink, SMALL)
		}

		// One click selects and fills the preview; a second opens. Opening on
		// the first click would make the preview pane pointless.
		if hot && mouse_pressed(.LEFT) && b.renaming == "" {
			double := b.clicked == i && now() - b.click_at < 0.4
			b.sel, b.clicked, b.click_at = i, i, now()
			if e.dir {
				rl.EndScissorMode()
				browser_goto(b, e.path)
				return
			}
			if double {
				rl.EndScissorMode()
				return e.path, true
			}
		}
	}
	rl.EndScissorMode()

	scrollbar(r, b.scroll, f32(len(b.entries)) * ROW_H)
	return
}

@(private = "file")
draw_preview :: proc(b: ^Browser, r: rl.Rectangle) {
	panel(r, {30, 30, 38, 255})
	if b.sel >= len(b.entries) {
		label(i32(r.x) + 16, i32(r.y) + 16, "nothing selected", {96, 96, 112, 255}, SMALL)
		return
	}
	e := b.entries[b.sel]

	label(i32(r.x) + 14, i32(r.y) + 12, ellipsize(file_of(e.path), r.width - 28, SMALL), INK, SMALL)
	hline(i32(r.x) + 14, i32(r.y) + 34, i32(r.width) - 28)

	body := rl.Rectangle{r.x + 14, r.y + 46, r.width - 28, r.height - 60}
	if e.dir {
		n := fmt.tprintf("%v matching file%v inside", e.count, "" if e.count == 1 else "s")
		label(i32(body.x), i32(body.y), "folder", DIM, SMALL)
		label(i32(body.x), i32(body.y) + 22, n, DIM, SMALL)
		label(i32(body.x), i32(body.y) + 50, "enter, or click again, to go in", {96, 96, 112, 255}, SMALL)
		return
	}

	if b.preview != nil && b.preview(b.ctx, e.path, e.kind, body) do return

	// No preview from the program: say what can be said without opening it.
	y := i32(body.y)
	if e.kind >= 0 && e.kind < len(b.kinds) {
		label(i32(body.x), y, b.kinds[e.kind].label, b.kinds[e.kind].color, SMALL)
		y += 24
	}
	label(i32(body.x), y, size_text(e.size), DIM, SMALL)
	y += 20
	label(i32(body.x), y, age_text(e.mtime), DIM, SMALL)
	y += 30
	label(i32(body.x), y, ellipsize_middle(under(b.root, e.path), body.width, SMALL), {96, 96, 112, 255}, SMALL)
}

@(private = "file")
draw_new :: proc(b: ^Browser, r: rl.Rectangle, status: ^Status) -> (path: string, chosen: bool) {
	rl.DrawRectangleRec(r, {28, 28, 35, 255})
	hline(i32(r.x), i32(r.y), i32(r.width))
	if len(b.kinds) == 0 do return

	b.new_kind = clamp(b.new_kind, 0, len(b.kinds) - 1)
	kind := b.kinds[b.new_kind]

	x := r.x + 8
	label(i32(x), i32(r.y) + 15, "new", {110, 110, 126, 255}, SMALL)
	x += 30

	creatable := 0
	for k in b.kinds do if k.blank != nil do creatable += 1
	if creatable > 1 {
		for k, i in b.kinds {
			if k.blank == nil do continue
			w := f32(measure(k.label, SMALL) + 16)
			if chip({x, r.y + 10, w, 24}, k.label, b.new_kind == i) do b.new_kind = i
			x += w + 4
		}
		x += 8
	}

	name_w := clamp(r.width * 0.22, 110, 200)
	made := false
	if v, done := text_field(&b.text, {x, r.y + 10, name_w, 24}, "browser.new", b.typed); done {
		reset_string(&b.typed, v)
		made = strings.trim_space(v) != "" // Enter in the name box makes it
	}
	if b.typed == "" && b.text.focus != "browser.new" {
		label(i32(x) + 8, i32(r.y) + 16, fmt.tprintf("name%v", kind.suffix), {88, 88, 102, 255}, SMALL)
	}
	x += name_w + 12

	// That kind's extra numbers: a sprite's size, a song's bars.
	vals := &b.opts[b.new_kind]
	for f, i in kind.fields {
		if i >= MAX_NEW_FIELDS do break
		w := f32(measure(f.label, SMALL))
		if x + w + 82 > r.x + r.width - 92 do break
		label(i32(x), i32(r.y) + 15, f.label, {110, 110, 126, 255}, SMALL)
		x += w + 5
		id := fmt.tprintf("browser.opt.%v.%v", b.new_kind, i)
		if v, done := number_field(&b.text, {x, r.y + 10, 76, 24}, id, vals[i]); done {
			vals[i] = clamp(v, f.lo, f.hi)
		}
		x += 80
	}

	if button({r.x + r.width - 86, r.y + 10, 78, 24}, "create") || made {
		return create(b, kind, vals[:], status)
	}
	return
}

@(private = "file")
create :: proc(b: ^Browser, kind: File_Kind, vals: []int, status: ^Status) -> (path: string, chosen: bool) {
	if kind.blank == nil {
		say(status, "a %v is made somewhere else", kind.label)
		return
	}
	name := strings.trim_space(b.typed)
	if name == "" {
		say(status, "give it a name first")
		text_input_focus(&b.text, "browser.new", b.typed)
		return
	}
	if strings.contains(name, "/") {
		say(status, "a name, not a path - browse to the folder first")
		return
	}
	if !strings.has_suffix(strings.to_lower(name, context.temp_allocator), kind.suffix) {
		name = fmt.tprintf("%v%v", name, kind.suffix)
	}
	full := path_join(b.dir, name)
	if os.exists(full) {
		say(status, "%v is already here", name)
		return
	}
	if !kind.blank(full, base_name(name), vals[:len(kind.fields)]) {
		say(status, "could not write %v", name)
		return
	}
	reset_string(&b.typed, "")
	browser_refresh(b)
	say(status, "made %v", name)
	return full, true
}

// --- Changing files ---

@(private = "file")
duplicate :: proc(b: ^Browser, e: Entry, status: ^Status) {
	dir := parent_dir(e.path)
	name := free_name(dir, file_of(e.path))
	if copy_file(e.path, path_join(dir, name)) {
		browser_refresh(b)
		say(status, "copied to %v", name)
	} else {
		say(status, "could not copy %v", file_of(e.path))
	}
}

@(private = "file")
rename_entry :: proc(b: ^Browser, e: Entry, to: string, status: ^Status) {
	name := strings.trim_space(to)
	if name == "" || name == file_of(e.path) do return
	if strings.contains(name, "/") {
		say(status, "a name, not a path")
		return
	}
	dest := path_join(parent_dir(e.path), name)
	if os.exists(dest) {
		say(status, "%v is already there", name)
		return
	}
	if os.rename(e.path, dest) != nil {
		say(status, "could not rename %v", file_of(e.path))
		return
	}
	browser_refresh(b)
	say(status, "renamed to %v", name)
}

@(private = "file")
remove_entry :: proc(b: ^Browser, e: Entry, status: ^Status) {
	if os.remove(e.path) != nil {
		say(status, "could not erase %v", file_of(e.path))
	} else {
		say(status, "erased %v", file_of(e.path))
	}
	reset_string(&b.deleting, "")
	browser_refresh(b)
}
