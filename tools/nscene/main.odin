// nscene: the nengine room editor.
//
// A scene is one room: its backdrop, the objects standing in it, the polygon
// the player may walk on, the ways out, and the places that set something off
// when walked into. The editor shows the room as the game draws it, in any of
// its lights, and every line of the file in a panel beside it.
//
//     nscene                                pick a room to open
//     nscene mygame/assets/scenes/parlour.scene
//
// Or from the command line, which is the point of the text formats — no
// window, no mouse, and it composes with everything else:
//
//     nscene scene add-object parlour.scene lamp 232 158
//     nscene scene set parlour.scene lamp pos=240,160 reach=circle:48
//     nscene scene walk parlour.scene 0,157 320,157 320,200 0,200
//
// Both change the file a line at a time (doc.odin): comments, blank lines and
// the order of things stay as they were written.
//
// `nscene help` lists the lot.
package main

import ne "../../"
import ui "../ui"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

main :: proc() {
	args := os.args[1:]
	if len(args) > 0 {
		switch args[0] {
		case "help", "-h", "--help":
			usage()
			return
		case "scene":
			if !scene_cmd(args[1:]) do os.exit(1)
			return
		case "audit":
			if !audit_cmd(args[1:]) do os.exit(1)
			return
		case "world":
			if !world_cmd(args[1:]) do os.exit(1)
			return
		}
	}

	flags := ui.parse_flags(args)
	app := App{}

	// A file to open, a folder to go looking in, or neither.
	arg := flags.rest[0] if len(flags.rest) > 0 else ""
	switch ui.target_of(arg) {
	case .Nothing:
		app.browsing = true
	case .Folder:
		app.browsing = true
		app.dir = strings.clone(arg)
	case .Missing:
		fmt.eprintfln("nscene: there is no %v", arg)
		fmt.eprintfln("        make one with `nscene scene new %v`, or run `nscene` and browse", arg)
		os.exit(1)
	case .File:
		if !strings.has_suffix(arg, ".scene") {
			fmt.eprintfln("nscene: %v is not a .scene", arg)
			os.exit(1)
		}
		app.path = strings.clone(arg)
	}

	app.find = flags.find
	ui.run({title = "nscene", size = flags.window, shot = flags.shot, frames = flags.frames, events = flags.events}, &app, frame, app_close)
}

usage :: proc() {
	fmt.println(`nscene - nengine's room editor

  nscene                             pick a room to open
  nscene <file.scene>                open that one
  nscene <file> --window 900x600 --shot out.png [--frames N] [--events script]

scene
  scene new <file> [name]            an empty scene with a floor
  scene info <file>                  what's in it
  scene add-object <file> <name> <x> <y>
  scene set <file> <object> <key=value>...   any field: pos, sprite, when, reach...
                                     (key= with nothing after it takes the field off;
                                      name#2 is the second object of that name)
  scene describe <file> <object> <text>...   its LOOK AT text
  scene add-exit <file> <name> <x> <y> <w> <h> <to-scene> [arrive-x] [arrive-y]
  scene add-trigger <file> <name> <x> <y> <w> <h> <action>
  scene add-window <file> <name> <x> <y> <w> <h> [feet]   an opening's glass
  scene window <file> <name> <key=value>...  glass, feet, frame, when
  scene walk <file> <x,y> <x,y>...   replace the floor polygon
  scene remove <file> <name>         drop an object, exit, trigger, scenery or window
                                     (side:<dir>[#n] for a side)
  scene add-side <file> <dir> <to> <lo> <hi> [key=value...]
                                     a border walked across into <to>: span lo..hi
                                     along it (x for north and south, y for east and west)
  scene side <file> <dir>[#n] <key=value>...   to, span, gate, name, when, arrive, dir
  scene sides-from-exits <file> [--write]
                                     a side for each exit rectangle on a border, as a
                                     first draft (gated exits become one side and its
                                     shut line); --write swaps them in

audit <scenes-dir> [--assets dir] [--person char] [--dress group,...] [--tsv f] [--md f] [--points dir] [--only a,b]
                                     every room read with its paintings: what is drawn in
                                     front of what (feet lines, painted furniture with floor
                                     behind it, depth=back/front), people's spots, missing
                                     art and lights, walk_to, exits and arrivals (audit.odin)

world <scenes-dir> [--start room] [--strict] [--quiet] [--md f]
                                     the rooms as one world joined by their sides:
                                     partners facing back, spans agreeing, gates and
                                     conditions on both, every room reachable, a grid
                                     that closes; then the grid as a map (world.odin).
                                     --strict fails on anything but its info lines

NSCENE_TRACE=1 prints what the editor loads and lets go.`)
}

// --- The window ---

App :: struct {
	path:     string,
	dir:      string, // where the browser starts, if a folder was named
	browsing: bool,
	find:     string, // --find: what to put in the search box (borrowed from the command line)
	opened:   bool,
	browser:  ui.Browser,
	preview:  Browse_Preview,
	scene:    Scene_Editor,
}

KINDS := [?]ui.File_Kind {
	{suffix = ".scene", label = "scene", color = {150, 220, 140, 255}, blank = scene_blank},
}

frame :: proc(data: rawptr, status: ^ui.Status) -> bool {
	app := cast(^App)data

	if !app.browsing {
		if !app.opened do open_editor(app)
		if scene_editor_step(&app.scene, status) do return true
		back_to_browser(app)
		// The key or the click that left the editor has done its job. The
		// browser opens on this same frame rather than leaving one blank, and
		// must not see it too: an Esc that closed the editor would quit.
		ui.input_swallow()
	}

	if !app.browser.loaded {
		ui.browser_open(&app.browser, "Rooms", "nscene", KINDS[:], app.dir, scene_detail, scene_preview, app, app.find)
		ui.browser_select(&app.browser, app.path)
	}
	path, chosen, running := ui.browser_step(&app.browser, status)
	if chosen {
		file := strings.clone(path, context.temp_allocator)
		ui.browser_close(&app.browser)
		browse_preview_close(&app.preview)
		app.browsing = false
		delete(app.path)
		app.path = strings.clone(file)
		open_editor(app)
	}
	if !running {
		ui.browser_close(&app.browser)
		browse_preview_close(&app.preview)
	}
	return running || chosen
}

// Esc in the editor goes back to the list rather than out of the program, so
// the next room is one keypress away.
back_to_browser :: proc(app: ^App) {
	if app.opened {
		scene_editor_close(&app.scene)
		app.opened = false
	}
	ui.reset_dir(&app.dir, app.path)
	app.find = "" // a slice of the command line: dropped, never freed
	app.browsing = true
}

open_editor :: proc(app: ^App) {
	app.opened = true
	// The assets ROOT, not the scenes folder it was opened from: a room's art
	// can be anywhere in the game's assets, and is found by name.
	scene_editor_open(&app.scene, app.path, asset_dir_for(app.path))
}

// Called by ui.run on the way out, while the window is still open. It takes a
// rawptr for the same reason `frame` does: the host knows nothing about App.
app_close :: proc(data: rawptr) {
	app := cast(^App)data
	ui.browser_close(&app.browser)
	browse_preview_close(&app.preview)
	if app.opened do scene_editor_close(&app.scene)
	ui.clipboard_text_destroy()
	delete(app.path)
	delete(app.dir)
}

scene_blank :: proc(path, name: string, opts: []int) -> bool {
	return scene_file_new(path, name)
}

// A scene sits in assets/scenes/, or in a folder of its own inside it
// (assets/scenes/banda/banda.scene); its sprites sit in assets/sprites/ or
// beside it. Given one, find the assets folder they have in common.
asset_dir_for :: proc(path: string) -> string {
	dir := "assets"
	if slash := strings.last_index_byte(path, '/'); slash > 0 do dir = path[:slash]
	for kind in ([?]string{"scenes", "sprites", "characters", "music", "sounds"}) {
		if strings.has_suffix(dir, fmt.tprintf("/%v", kind)) do return dir[:len(dir) - len(kind) - 1]
		// One folder deeper: scenes/<room>/.
		if at := strings.last_index(dir, fmt.tprintf("/%v/", kind)); at >= 0 do return dir[:at]
	}
	return dir
}

// --- scene ---

scene_cmd :: proc(args: []string) -> bool {
	if len(args) < 2 do return ui.fail("scene: need a command and a file")
	path := args[1]

	if args[0] == "new" {
		name := args[2] if len(args) > 2 else ui.base_name(path)
		if !scene_file_new(path, name) do return ui.fail("scene new: could not write %v", path)
		fmt.printfln("%v: scene %v", path, name)
		return true
	}

	d: Doc
	defer doc_destroy(&d)
	if !doc_load(&d, path) do return ui.fail("scene: could not read %v", path)

	// `lamp`, or `elena#3` for the third object of that name.
	find_object :: proc(d: ^Doc, spec: string) -> int {
		name, nth := spec, 1
		if hash := strings.index_byte(spec, '#'); hash > 0 {
			name = spec[:hash]
			nth, _ = strconv.parse_int(spec[hash + 1:])
		}
		seen := 0
		for o, i in d.objects do if o.name == name {
			seen += 1
			if seen == nth do return i
		}
		return -1
	}

	switch args[0] {
	case "info":
		fmt.printfln("scene %v", doc_head(&d, d.scene, 0) if d.scene >= 0 else "?")
		if d.bg >= 0 do fmt.printfln("  backdrop: %v", doc_head(&d, d.bg, 0))
		for line in d.descs {
			only := doc_field(&d, line, "when")
			fmt.printfln("  %v%v", fmt.tprintf("[when=%v] ", only) if only != "" else "", doc_line_text(&d, line))
		}
		fmt.printfln("  floor: %v corners", len(d.walk))
		for o, i in d.objects {
			fmt.printfln("  %v %v at %v,%v%v%v%v  (%v lines)", "peep" if o.peep else ("person" if o.person else "object"), o.name, o.pos.x, o.pos.y,
				fmt.tprintf("  sprite=%v", o.sprite) if o.sprite != "" else "",
				fmt.tprintf("  char=%v", o.char) if o.char != "" else "",
				fmt.tprintf("  when=%v", o.only) if o.only != "" else "",
				len(doc_object_lines(&d, i)))
		}
		for e in d.exits do fmt.printfln("  exit %v -> %v%v", e.name, e.to, "  (closed)" if e.closed else "")
		for t in d.triggers do fmt.printfln("  trigger %v -> %v", t.name, t.action)
		for s in d.scenery do fmt.printfln("  scenery %v", s.name)
		for s in d.sides do fmt.printfln("  side %v -> %v span %v..%v%v%v%v", ne.COMPASS_WORDS[s.dir], s.to, s.span[0], s.span[1],
			fmt.tprintf("  gate=%v", s.gate) if s.gate != "" else "",
			fmt.tprintf("  when=%v", s.only) if s.only != "" else "",
			fmt.tprintf("  arrive=%v", vec(s.arrive)) if s.has_arrive else "")
		for w in d.windows do fmt.printfln("  window %v glass=%v feet=%v%v%v", w.name, rect_text(w.glass), doc_window_feet(w),
			"" if w.feet != 0 else " (default)",
			fmt.tprintf("  under %v", w.frame) if w.frame != "" else "")
		return true

	case "add-object":
		if len(args) < 5 do return ui.fail("scene add-object: need a name, x and y")
		name := clean_name(args[2])
		if name == "" do return ui.fail("scene add-object: a name is one word")
		doc_add_object(&d, "obj", name, {f32(ui.num(args, 3, 0)), f32(ui.num(args, 4, 0))}, {"reach", "circle:128"})

	case "set":
		if len(args) < 4 do return ui.fail("scene set: need an object and some key=value")
		i := find_object(&d, args[2])
		if i < 0 do return ui.fail("scene set: no object called %v", args[2])
		for kv in args[3:] {
			eq := strings.index_byte(kv, '=')
			if eq <= 0 do return ui.fail("scene set: %v is not key=value", kv)
			doc_set_field(&d, d.objects[i].line, kv[:eq], kv[eq + 1:])
		}

	case "describe":
		if len(args) < 4 do return ui.fail("scene describe: need an object and some text")
		i := find_object(&d, args[2])
		if i < 0 do return ui.fail("scene describe: no object called %v", args[2])
		doc_set_object_text(&d, i, strings.join(args[3:], " ", context.temp_allocator))

	case "add-exit":
		if len(args) < 8 do return ui.fail("scene add-exit: need a name, x y w h and a destination scene")
		area := [4]f32{f32(ui.num(args, 3, 0)), f32(ui.num(args, 4, 0)), f32(ui.num(args, 5, 0)), f32(ui.num(args, 6, 0))}
		doc_add_exit(&d, clean_name(args[2]), area, args[7], {f32(ui.num(args, 8, 512)), f32(ui.num(args, 9, 560))})

	case "add-window", "window":
		// `add-window f.scene back 445 176 138 122 [feet]`: a new one.
		// `window f.scene back feet=380 frame=win_back`: change one.
		if len(args) < 3 do return ui.fail("scene %v: need a window's name", args[0])
		name := clean_name(args[2])
		at := -1
		for w, n in d.windows do if w.name == name do at = n
		if args[0] == "add-window" {
			if len(args) < 7 do return ui.fail("scene add-window: need a name and x y w h of the glass")
			if at >= 0 do return ui.fail("scene add-window: there is a window called %v already", name)
			glass := [4]f32{f32(ui.num(args, 3, 0)), f32(ui.num(args, 4, 0)), f32(ui.num(args, 5, 0)), f32(ui.num(args, 6, 0))}
			at = doc_add_window(&d, name, glass)
			if len(args) > 7 do doc_set_field(&d, d.windows[at].line, "feet", args[7])
		} else {
			if at < 0 do return ui.fail("scene window: no window called %v", name)
			for kv in args[3:] {
				eq := strings.index_byte(kv, '=')
				if eq <= 0 do return ui.fail("scene window: %v is not key=value", kv)
				doc_set_field(&d, d.windows[at].line, kv[:eq], kv[eq + 1:])
			}
		}

	case "add-trigger":
		if len(args) < 8 do return ui.fail("scene add-trigger: need a name, x y w h and an action")
		area := [4]f32{f32(ui.num(args, 3, 0)), f32(ui.num(args, 4, 0)), f32(ui.num(args, 5, 0)), f32(ui.num(args, 6, 0))}
		doc_add_trigger(&d, clean_name(args[2]), area, args[7])

	case "walk":
		if len(args) < 5 do return ui.fail("scene walk: a floor needs at least three corners")
		points := make([dynamic][2]f32, context.temp_allocator)
		for a in args[2:] {
			p, good := parse_point(a)
			if !good do return ui.fail("scene walk: %v is not x,y", a)
			append(&points, p)
		}
		doc_set_walk(&d, points[:])

	case "add-side":
		if len(args) < 7 do return ui.fail("scene add-side: need a direction, a room, and lo and hi along the side")
		dir, ok := ne.compass_of(args[2])
		if !ok do return ui.fail("scene add-side: %v is not north, east, south or west", args[2])
		i := doc_add_side(&d, dir, args[3], {f32(ui.num(args, 4, 0)), f32(ui.num(args, 5, 0))})
		for kv in args[6:] {
			eq := strings.index_byte(kv, '=')
			if eq <= 0 do return ui.fail("scene add-side: %v is not key=value", kv)
			doc_set_field(&d, d.sides[i].line, kv[:eq], kv[eq + 1:])
		}

	case "side":
		if len(args) < 4 do return ui.fail("scene side: need a direction and some key=value")
		i := find_side(&d, args[2])
		if i < 0 do return ui.fail("scene side: no %v side", args[2])
		for kv in args[3:] {
			eq := strings.index_byte(kv, '=')
			if eq <= 0 do return ui.fail("scene side: %v is not key=value", kv)
			if kv[:eq] == "dir" {
				dir, ok := ne.compass_of(kv[eq + 1:])
				if !ok do return ui.fail("scene side: %v is not north, east, south or west", kv[eq + 1:])
				doc_set_side_dir(&d, i, dir)
				continue
			}
			doc_set_field(&d, d.sides[i].line, kv[:eq], kv[eq + 1:])
		}

	case "sides-from-exits":
		write := len(args) > 2 && args[2] == "--write"
		plans := sides_from_exits(&d)
		if len(plans) == 0 {
			fmt.println("no exit rectangle touches a border")
			return true
		}
		for p in plans {
			fmt.printfln("side %v to=%v span=%v,%v%v    # from exit %v (%v line%v)%v", ne.COMPASS_WORDS[p.dir], p.to, num(p.span[0]), num(p.span[1]),
				" gate=?" if p.gated else "", p.exit, p.lines, "" if p.lines == 1 else "s",
				fmt.tprintf("; shut %v %v", ne.COMPASS_WORDS[p.dir], p.shut) if p.shut != "" else "")
		}
		if !write do return true
		for p in plans {
			i := doc_add_side(&d, p.dir, p.to, p.span)
			if p.name != "" do doc_set_field(&d, d.sides[i].line, "name", p.name)
			if p.shut != "" do doc_set_side_shut(&d, i, p.shut)
			for {
				at := -1
				for e, n in d.exits do if e.name == p.exit do at = n
				if at < 0 do break
				doc_remove_exit(&d, at)
			}
		}

	case "remove":
		if len(args) < 3 do return ui.fail("scene remove: need a name")
		if strings.has_prefix(args[2], "side:") {
			i := find_side(&d, args[2][5:])
			if i < 0 do return ui.fail("scene remove: no %v side", args[2][5:])
			doc_remove_side(&d, i)
		} else if i := find_object(&d, args[2]); i >= 0 {
			doc_remove_object(&d, i)
		} else {
			found := false
			for e, n in d.exits do if e.name == args[2] {
				doc_remove_exit(&d, n)
				found = true
				break
			}
			if !found do for t in d.triggers do if t.name == args[2] {
				doc_remove(&d, t.line)
				found = true
				break
			}
			if !found do for s in d.scenery do if s.name == args[2] {
				doc_remove(&d, s.line)
				found = true
				break
			}
			if !found do for w in d.windows do if w.name == args[2] {
				doc_remove(&d, w.line)
				found = true
				break
			}
			if !found do return ui.fail("scene remove: nothing called %v", args[2])
		}

	case:
		return ui.fail("scene: don't know %v", args[0])
	}

	if !doc_save(&d, path) do return ui.fail("scene: could not write %v", path)
	fmt.printfln("%v updated", path)
	return true
}

// `east`, or `east#2` for the second side facing east.
@(private = "file")
find_side :: proc(d: ^Doc, spec: string) -> int {
	word, nth := spec, 1
	if hash := strings.index_byte(spec, '#'); hash > 0 {
		word = spec[:hash]
		nth, _ = strconv.parse_int(spec[hash + 1:])
	}
	dir, ok := ne.compass_of(word)
	if !ok do return -1
	seen := 0
	for s, i in d.sides do if s.dir == dir {
		seen += 1
		if seen == nth do return i
	}
	return -1
}

// A side proposed for an exit rectangle on a border (nengine side.odin):
// which way, where along it, and what the exit was.
Side_Plan :: struct {
	dir:   ne.Compass,
	to:    string,
	span:  [2]f32,
	exit:  string,
	name:  string, // kept as the side's noun, so GO <name> still goes
	lines: int,
	gated: bool,   // it had a closed=true line: a gate, to be named
	shut:  string,
}

// Every exit name whose rectangle touches a border of the canvas (or the top
// of the floor, for north): one side each, its lines taken together.
sides_from_exits :: proc(d: ^Doc) -> []Side_Plan {
	out := make([dynamic]Side_Plan, context.temp_allocator)
	top := f32(1e9)
	for p in d.walk do top = min(top, p.y)
	BORDER :: f32(8)
	for e, i in d.exits {
		if !e.has_area do continue
		done := false
		for p in out do if p.exit == e.name do done = true
		if done do continue
		a := e.area
		plan := Side_Plan{to = e.to, exit = e.name, name = e.name}
		switch {
		case a[0] <= BORDER:                     plan.dir, plan.span = .West, {a[1], a[1] + a[3]}
		case a[0] + a[2] >= 1024 - BORDER:       plan.dir, plan.span = .East, {a[1], a[1] + a[3]}
		case a[1] + a[3] >= 640 - 30:            plan.dir, plan.span = .South, {a[0], a[0] + a[2]}
		case a[1] <= top + BORDER:               plan.dir, plan.span = .North, {a[0], a[0] + a[2]}
		case:                                    continue
		}
		plan.span = {snap_span(plan.span[0]), snap_span(plan.span[1])}
		for x in d.exits do if x.name == e.name {
			plan.lines += 1
			if x.closed do plan.gated = true
		}
		if shuts := doc_shuts(d, i); len(shuts) > 0 do plan.shut = strings.clone(doc_line_text(d, shuts[len(shuts) - 1]), context.temp_allocator)
		append(&out, plan)
	}
	return out[:]
}

@(private = "file")
parse_point :: proc(s: string) -> (p: [2]f32, ok: bool) {
	comma := strings.index_byte(s, ',')
	if comma <= 0 do return
	x, xo := strconv.parse_f32(s[:comma])
	y, yo := strconv.parse_f32(s[comma + 1:])
	return {x, y}, xo && yo
}
