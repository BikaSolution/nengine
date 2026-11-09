package background

import ne "../../../"
import ui "../../ui"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

// The room a backdrop belongs to, read straight out of the .scene files
// beside it and drawn over the art while you paint.
//
// This is the whole reason a backdrop wants its own editor. Painting a room is
// not painting a picture: there is a floor the player can stand on, doors they
// walk through and objects they bump into, and all of it is in another file
// written by another tool. Without it you paint a handsome wall across a
// doorway and find out in the game.
//
// Nothing here writes anything. The scene belongs to nscene; this only looks.

Room :: struct {
	ok:      bool,
	name:    string,
	scene:   string, // the .scene file it came from
	floor:   [][2]f32,
	objects: [dynamic]Marker,
	exits:   [dynamic]rl.Rectangle,
}

Marker :: struct {
	name: string,
	at:   [2]f32,
	walk: [2]f32, // where the player stands to use it, 0,0 for nowhere
}

room_close :: proc(r: ^Room) {
	delete(r.name)
	delete(r.scene)
	delete(r.floor)
	for m in r.objects do delete(m.name)
	delete(r.objects)
	delete(r.exits)
	r^ = {}
}

// Looks for a .scene whose `bg` names this backdrop: first beside it, then in
// a `scenes` folder next door, which is where the asset layout puts them.
room_find :: proc(r: ^Room, backdrop: string) {
	room_close(r)
	want := ui.base_name(backdrop)
	// A backdrop in another light (light.odin) belongs to the same room:
	// banda.night is the banda's.
	for suffix in ne.LIGHT_SUFFIX do if suffix != "" && strings.has_suffix(want, suffix) do want = want[:len(want) - len(suffix)]
	dir := ui.parent_dir(ui.abs_path(backdrop, context.temp_allocator))

	if room_scan(r, dir, want) do return
	if room_scan(r, ui.path_join(ui.parent_dir(dir), "scenes"), want) do return
	room_scan(r, ui.parent_dir(dir), want)
}

@(private = "file")
room_scan :: proc(r: ^Room, dir, want: string) -> bool {
	infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil do return false
	for fi in infos {
		if fi.type == .Directory || !strings.has_suffix(fi.name, ".scene") do continue
		path := ui.path_join(dir, fi.name)
		if names_backdrop(path, want) {
			room_read(r, path)
			return r.ok
		}
	}
	return false
}

// Which backdrop a scene asks for, without loading the whole thing — the
// sprites it mentions are not wanted here and loading them needs a window.
@(private = "file")
names_backdrop :: proc(path, want: string) -> bool {
	text, ok := ne.read_data_file(path)
	if !ok do return false
	for raw in ne.data_lines(text) {
		l := ne.parse_line(raw)
		if l.key == "bg" && len(l.words) > 0 do return l.words[0] == want
	}
	return false
}

// The floor, the objects and the exits, read out of the text. The scene file
// is plain enough to read directly, which saves loading an assets folder and
// a GPU's worth of sprites to draw four outlines.
@(private = "file")
room_read :: proc(r: ^Room, path: string) {
	text, ok := ne.read_data_file(path)
	if !ok do return
	r.scene = strings.clone(path)
	r.name = strings.clone(ui.base_name(path))

	floor := make([dynamic][2]f32)
	for raw in ne.data_lines(text) {
		l := ne.parse_line(raw)
		switch l.key {
		case "scene":
			if len(l.words) > 0 {
				delete(r.name)
				r.name = strings.clone(l.words[0])
			}
		case "walk":
			for w in l.words {
				if comma := strings.index_byte(w, ','); comma > 0 {
					append(&floor, [2]f32{ui.to_f32(w[:comma]), ui.to_f32(w[comma + 1:])})
				}
			}
		case "obj":
			m := Marker{name = strings.clone(l.words[0] if len(l.words) > 0 else "?")}
			m.at = field_point(l, "pos")
			m.walk = field_point(l, "walk_to")
			append(&r.objects, m)
		case "exit":
			// exit <name> <x>,<y> <w>x<h> ... — the area is what matters here.
			if rect, has := field_rect(l); has do append(&r.exits, rect)
		}
	}
	r.floor = floor[:]
	r.ok = len(floor) > 0 || len(r.objects) > 0 || len(r.exits) > 0
}

@(private = "file")
field_point :: proc(l: ne.Line, name: string) -> [2]f32 {
	text, has := ne.field(l, name)
	if !has do return {}
	comma := strings.index_byte(text, ',')
	if comma <= 0 do return {}
	return {ui.to_f32(text[:comma]), ui.to_f32(text[comma + 1:])}
}

@(private = "file")
field_rect :: proc(l: ne.Line) -> (rl.Rectangle, bool) {
	at, has_at := ne.field(l, "at")
	size, has_size := ne.field(l, "size")
	if !has_at || !has_size do return {}, false
	ac := strings.index_byte(at, ',')
	sc := strings.index_byte(size, ',')
	if ac <= 0 || sc <= 0 do return {}, false
	return rl.Rectangle{
		ui.to_f32(at[:ac]),
		ui.to_f32(at[ac + 1:]),
		ui.to_f32(size[:sc]),
		ui.to_f32(size[sc + 1:]),
	}, true
}

// --- Drawing it over the art ---
//
// Scene coordinates are canvas pixels (1024 wide); a backdrop is 320 wide. So
// everything read out of the scene is divided by the same 3.2 the engine
// multiplies art by on the way in.

SCENE_TO_ART :: 1 / PNG_SCALE

room_draw :: proc(r: ^Room, view: ui.View, area: rl.Rectangle) {
	if !r.ok do return
	rl.BeginScissorMode(i32(area.x), i32(area.y), i32(area.width), i32(area.height))
	defer rl.EndScissorMode()

	at :: proc(view: ui.View, p: [2]f32) -> rl.Vector2 {
		return ui.to_screen(view, p * SCENE_TO_ART)
	}

	// The floor, as an outline: a filled polygon wants to be convex and a
	// room's floor usually isn't.
	green := rl.Color{110, 220, 140, 190}
	for i in 0 ..< len(r.floor) {
		a := at(view, r.floor[i])
		b := at(view, r.floor[(i + 1) % len(r.floor)])
		rl.DrawLineEx(a, b, 2, green)
	}

	for e in r.exits {
		tl := at(view, {e.x, e.y})
		br := at(view, {e.x + e.width, e.y + e.height})
		rl.DrawRectangleLinesEx({tl.x, tl.y, br.x - tl.x, br.y - tl.y}, 2, {240, 150, 130, 200})
	}

	for m in r.objects {
		c := at(view, m.at)
		rl.DrawCircleLinesV(c, 5, {200, 170, 110, 220})
		rl.DrawLineEx({c.x - 8, c.y}, {c.x + 8, c.y}, 1, {200, 170, 110, 150})
		if m.walk.x != 0 || m.walk.y != 0 {
			w := at(view, m.walk)
			rl.DrawLineEx(c, w, 1, {200, 170, 110, 90})
			rl.DrawCircleV(w, 2, {200, 170, 110, 160})
		}
		ui.label(i32(c.x) + 8, i32(c.y) - 6, m.name, {210, 190, 150, 220}, ui.SMALL)
	}
}
