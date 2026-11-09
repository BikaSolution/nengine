package assetcache

import ne "../../"
import ui "../ui"
import "core:fmt"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

// A room at a glance: its backdrop by day, with the floor, the ways out and a
// mark where each thing stands. The file browser draws it for a room before
// you open it (nscene), and so does a question asking which room (the
// cutscene editor's Room...): the same picture, from the same code.
//
// Only the backdrop is loaded — one picture, at its own size — and it is let
// go as soon as another room is shown. Everything else is a mark at its feet,
// a different shape for each kind of thing, read from the file's lines:
// scrolling through forty rooms must not mean loading forty rooms' art.

// Scenes are laid out in canvas pixels; art is drawn 320 wide and blown up
// 3.2 times to fill a 1024-wide room. The games load their art at this.
SCENE_SCALE :: f32(3.2)
DEFAULT_ROOM :: [2]f32{1024, 640}

// --- Marks: one shape per kind of thing ---
//
// The same in the browser's preview and in the editors, where they stand in
// for anything with no picture: a person is a figure, a sprite a square, a
// thing with no art at all a hollow square, an aperture an eye, a light a
// diamond.

Mark_Kind :: enum {
	Sprite,
	Person,
	Peep,
	Light,
	Unseen,
}

MARK_NAMES := [Mark_Kind]string {
	.Sprite = "things",
	.Person = "people",
	.Peep   = "peeps",
	.Light  = "lights",
	.Unseen = "unseen",
}

MARK_INK := [Mark_Kind]rl.Color {
	.Sprite = {120, 190, 240, 255},
	.Person = {140, 220, 130, 255},
	.Peep   = {200, 150, 240, 255},
	.Light  = {250, 210, 90, 255},
	.Unseen = {170, 170, 186, 255},
}

EXIT_INK :: rl.Color{240, 150, 90, 255}
TRIGGER_INK :: rl.Color{240, 90, 120, 255}
WINDOW_INK :: rl.Color{110, 210, 240, 255}
FLOOR_INK :: rl.Color{90, 200, 130, 255}

mark_kind_of :: proc(peep, person, glow: bool, sprite: string) -> Mark_Kind {
	switch {
	case peep:         return .Peep
	case person:       return .Person
	case glow:         return .Light
	case sprite != "": return .Sprite
	}
	return .Unseen
}

mark_icon :: proc(k: Mark_Kind, c: [2]f32, picked: bool, size: f32) {
	ink := ui.GOLD if picked else MARK_INK[k]
	s := 4 * size
	switch k {
	case .Sprite:
		rl.DrawRectangleRec({c.x - s, c.y - s, s * 2, s * 2}, ink)
		rl.DrawRectangleLinesEx({c.x - s, c.y - s, s * 2, s * 2}, 1, {0, 0, 0, 160})
	case .Person:
		rl.DrawCircleV({c.x, c.y - s * 1.4}, s * 0.7, ink)
		rl.DrawRectangleRec({c.x - s * 0.7, c.y - s * 0.6, s * 1.4, s * 1.6}, ink)
	case .Peep:
		rl.DrawCircleLinesV(c, s * 1.2, ink)
		rl.DrawCircleV(c, s * 0.5, ink)
	case .Light:
		rl.DrawTriangle({c.x, c.y - s * 1.3}, {c.x - s * 1.1, c.y}, {c.x + s * 1.1, c.y}, ink)
		rl.DrawTriangle({c.x - s * 1.1, c.y}, {c.x, c.y + s * 1.3}, {c.x + s * 1.1, c.y}, ink)
	case .Unseen:
		rl.DrawRectangleLinesEx({c.x - s, c.y - s, s * 2, s * 2}, 1.5, ink)
	}
}

draw_floor :: proc(walk: [][2]f32, view: ui.View, thick: f32) {
	if len(walk) < 2 do return
	for p, i in walk {
		q := walk[(i + 1) % len(walk)]
		rl.DrawLineEx(ui.to_screen(view, p), ui.to_screen(view, q), thick, FLOOR_INK)
	}
}

draw_area :: proc(r: [4]f32, view: ui.View, ink: rl.Color, name: string, picked := false) {
	tl := ui.to_screen(view, {r[0], r[1]})
	on := rl.Rectangle{tl.x, tl.y, r[2] * view.zoom, r[3] * view.zoom}
	rl.DrawRectangleRec(on, {ink.r, ink.g, ink.b, 40})
	rl.DrawRectangleLinesEx(on, 2 if picked else 1, ui.GOLD if picked else ink)
	if name != "" do ui.label(i32(on.x) + 3, i32(on.y) + 2, name, ui.GOLD if picked else ink, ui.SMALL)
}

// --- The backdrop ---

// A room's backdrop by day, at its own size, and how big the room is in the
// file's numbers: the baked .png if there is one, else the .sprite blown up
// as the game blows it up. A zero texture when there is no picture by that
// name. The caller unloads it.
load_backdrop :: proc(ix: ^Asset_Index, bg: string) -> (tex: rl.Texture2D, room: [2]f32) {
	room = DEFAULT_ROOM
	key, _ := lit_name(ix, bg, .Day, images = true)
	if key == "" do return
	if png, is_png := ix.images[key]; is_png {
		tex = rl.LoadTexture(strings.clone_to_cstring(png, context.temp_allocator))
		room = {f32(tex.width), f32(tex.height)}
	} else if file, found := ix.sprites[key]; found {
		if d, read := ne.load_sprite_data(file); read {
			s := ne.sprite_data_to_sprite(&d, 1)
			delete(s.holds)
			tex = s.texture
			room = {f32(d.w) * SCENE_SCALE, f32(d.h) * SCENE_SCALE}
			ne.sprite_data_destroy(&d)
		}
	}
	if tex.id != 0 do trace("load preview backdrop %v", key)
	return
}

// --- The picture ---

// What a preview draws, filled in by whoever read the file: nscene from its
// own lines, the cutscene editor's question from the engine's reading. All of
// it is borrowed for the one call.
Sketch_Mark :: struct {
	kind: Mark_Kind,
	pos:  [2]f32,
}

Room_Sketch :: struct {
	backdrop:  rl.Texture2D,
	room:      [2]f32,
	bg:        string, // the `bg` line's name; "" for none
	marks:     []Sketch_Mark,
	floor:     [][2]f32,
	exits:     [][4]f32, // the ones with an area
	triggers:  [][4]f32,
	windows:   [][4]f32, // the glass of each `window` line
	n_exits:   int,
	n_triggers: int,
	n_scenery: int,
	desc:      string, // the everyday description: the first with no when=
}

room_sketch_draw :: proc(sk: ^Room_Sketch, area: rl.Rectangle) {
	scale := min(area.width / sk.room.x, (area.height * 0.5) / sk.room.y)
	room := rl.Rectangle{area.x, area.y, sk.room.x * scale, sk.room.y * scale}
	rl.DrawRectangleRec(room, {18, 18, 24, 255})
	if sk.backdrop.id != 0 {
		rl.DrawTexturePro(sk.backdrop, {0, 0, f32(sk.backdrop.width), f32(sk.backdrop.height)}, room, {}, 0, rl.WHITE)
		rl.DrawRectangleRec(room, {0, 0, 0, 70}) // a little darker, so the marks read
	} else {
		msg := "no backdrop" if sk.bg == "" else fmt.tprintf("no picture called %v", sk.bg)
		ui.label(i32(room.x) + 8, i32(room.y) + 8, msg, ui.DIM, ui.SMALL)
	}
	view := ui.View{{room.x, room.y}, scale}
	rl.BeginScissorMode(i32(room.x), i32(room.y), i32(room.width), i32(room.height))
	draw_floor(sk.floor, view, 1)
	for r in sk.exits do draw_area(r, view, EXIT_INK, "")
	for r in sk.triggers do draw_area(r, view, TRIGGER_INK, "")
	for r in sk.windows do draw_area(r, view, WINDOW_INK, "")
	for m in sk.marks do mark_icon(m.kind, ui.to_screen(view, m.pos), false, 1.3)
	rl.EndScissorMode()
	rl.DrawRectangleLinesEx(room, 1, ui.EDGE)

	y := room.y + room.height + 10
	x := area.x
	// The key to the marks, with how many of each.
	counts: [Mark_Kind]int
	for m in sk.marks do counts[m.kind] += 1
	for k in Mark_Kind {
		if counts[k] == 0 do continue
		text := fmt.tprintf("%v %v", counts[k], MARK_NAMES[k])
		w := f32(ui.measure(text, ui.SMALL)) + 20
		if x + w > area.x + area.width {
			x = area.x
			y += 18
		}
		mark_icon(k, {x + 5, y + 8}, false, 1)
		ui.label(i32(x) + 13, i32(y) + 1, text, ui.DIM, ui.SMALL)
		x += w + 6
	}
	y += 20
	x = area.x
	extra := fmt.tprintf("%v exits  %v triggers  %v scenery  %v floor corners", sk.n_exits, sk.n_triggers, sk.n_scenery, len(sk.floor))
	ui.label(i32(x), i32(y), ui.ellipsize(extra, area.width, ui.SMALL), {110, 110, 126, 255}, ui.SMALL)
	y += 24

	// The everyday description: what the room is, in the author's words.
	if sk.desc != "" {
		for row in ui.text_rows(sk.desc, area.width) {
			if y > area.y + area.height - 18 do break
			ui.label(i32(area.x), i32(y), sk.desc[row.start:row.end], ui.INK, ui.SMALL)
			y += 17
		}
	}
}

// --- A room asked for: the preview a picker shows ---
//
// For a question that wants a room (ui.pick_open with ROOM_KINDS): give it
// `room_preview` and the address of one of these, with `root` set to the
// game's assets folder, where the backdrops are found by name.
//
//     e.pick_room.root = strings.clone(asset_dir)
//     ui.pick_open(&e.pick, "room", "Choose a room", ac.ROOM_KINDS[:], start,
//                  preview = ac.room_preview, ctx = &e.pick_room)
//     ...
//     ac.room_preview_close(&e.pick_room)   // when it has answered

ROOM_KINDS := [?]ui.File_Kind {
	{suffix = ".scene", label = "scene", color = {150, 220, 140, 255}},
}

Room_Preview :: struct {
	root:     string, // owned: the assets folder; "" to work it out from the file
	path:     string,
	ok:       bool,
	scene:    ne.Scene, // the engine's reading, with no art
	backdrop: rl.Texture2D,
	room:     [2]f32,
	index:    Asset_Index,
}

room_preview_close :: proc(p: ^Room_Preview) {
	room_preview_forget(p)
	index_destroy(&p.index)
	delete(p.root)
	p^ = {}
}

@(private = "file")
room_preview_forget :: proc(p: ^Room_Preview) {
	if p.backdrop.id != 0 {
		rl.UnloadTexture(p.backdrop)
		trace("unload preview backdrop %v", p.path)
	}
	if p.ok do scene_free(&p.scene)
	delete(p.path)
	p.path = ""
	p.ok = false
	p.backdrop = {}
}

// Reads a scene the way the game does, with no art: names, places, lines.
scene_read :: proc(path: string) -> (s: ne.Scene, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	return ne.parse_scene(string(data), nil)
}

// Lets go of a scene read with no art.
scene_free :: proc(s: ^ne.Scene) {
	for o in s.objects {
		for st in o.routine.steps {
			delete(st.pose)
			delete(st.text)
		}
		delete(o.routine.steps)
	}
	ne.free_scene_strings(s)
	delete(s.objects)
	delete(s.exits)
	delete(s.triggers)
	delete(s.walk_area)
	delete(s.scenery)
	delete(s.said)
	s^ = {}
}

room_preview :: proc(ctx: rawptr, path: string, kind: int, area: rl.Rectangle) -> bool {
	p := cast(^Room_Preview)ctx
	if p == nil do return false
	if p.path != path {
		room_preview_forget(p)
		p.path = strings.clone(path)
		p.room = DEFAULT_ROOM
		p.scene, p.ok = scene_read(path)
		if p.ok && p.scene.background_name != "" {
			root := p.root if p.root != "" else ui.assets_root(path)
			if root != "" {
				index_build(&p.index, ui.abs_path(root, context.temp_allocator))
				p.backdrop, p.room = load_backdrop(&p.index, p.scene.background_name)
			}
		}
	}
	if !p.ok {
		ui.label(i32(area.x), i32(area.y), "could not read it", ui.DIM, ui.SMALL)
		return true
	}
	s := &p.scene
	marks := make([dynamic]Sketch_Mark, context.temp_allocator)
	for &o in s.objects do append(&marks, Sketch_Mark{mark_kind_of(o.peep.is, o.char_name != "", o.glow, o.sprite_name), o.pos})
	exits := make([dynamic][4]f32, context.temp_allocator)
	for x in s.exits do if x.area.width > 0 || x.area.height > 0 do append(&exits, [4]f32{x.area.x, x.area.y, x.area.width, x.area.height})
	triggers := make([dynamic][4]f32, context.temp_allocator)
	for t in s.triggers do append(&triggers, [4]f32{t.area.x, t.area.y, t.area.width, t.area.height})
	desc := ""
	for said in s.said do if said.only == "" {
		desc = said.text
		break
	}
	sk := Room_Sketch {
		backdrop   = p.backdrop,
		room       = p.room,
		bg         = s.background_name,
		marks      = marks[:],
		floor      = s.walk_area[:],
		exits      = exits[:],
		triggers   = triggers[:],
		n_exits    = len(s.exits),
		n_triggers = len(s.triggers),
		n_scenery  = len(s.scenery),
		desc       = desc,
	}
	room_sketch_draw(&sk, area)
	return true
}

// The scene file for a room called `name`: scenes/<room>/<room>.scene, or
// scenes/<room>.scene, or one of that name anywhere in the assets. "" if
// there is none.
find_scene :: proc(asset_dir, name: string) -> string {
	if name == "" do return ""
	file := fmt.tprintf("%v.scene", name)
	for dir in ([]string{fmt.tprintf("scenes/%v", name), "scenes", ""}) {
		p := ui.path_join(ui.path_join(asset_dir, dir), file) if dir != "" else ui.path_join(asset_dir, file)
		if os.is_file(p) do return p
	}
	search :: proc(dir, file: string, depth: int) -> string {
		if depth > 5 do return ""
		infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
		if err != nil do return ""
		for f in infos do if f.type != .Directory && f.name == file do return ui.path_join(dir, f.name)
		for f in infos do if f.type == .Directory && !ui.skipped(f.name) {
			if p := search(ui.path_join(dir, f.name), file, depth + 1); p != "" do return p
		}
		return ""
	}
	return search(asset_dir, file, 0)
}
