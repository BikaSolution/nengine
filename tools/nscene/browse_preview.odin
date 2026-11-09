package main

import ac "../assetcache"
import ui "../ui"
import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

// What the browser shows about a room before you open it: its backdrop, by
// day, with the floor, the ways out and a mark for everything standing in it.
//
// Only the backdrop is loaded — one picture, at its own size — and it is let
// go as soon as the selection moves on. Everything else is a mark at its
// feet, a different shape for each kind of thing, read from the file's lines:
// scrolling through forty rooms must not mean loading forty rooms' art.
// It used to: every room previewed loaded the game's whole assets folder, and
// so did every row of the list, to count its objects.
//
// The picture itself is assetcache's (room.odin), so a question asking for a
// room — the cutscene editor's Room... — shows the same one.

Browse_Preview :: struct {
	path:     string,
	ok:       bool,
	doc:      Doc,
	backdrop: rl.Texture2D,    // the day painting, at its own size; 0 for none
	room:     [2]f32,          // the room's size in the file's numbers
	index:    ac.Asset_Index,  // the assets folder's names, kept while browsing one game
}

browse_preview_close :: proc(p: ^Browse_Preview) {
	browse_preview_forget(p)
	ac.index_destroy(&p.index)
}

// Lets go of the room on show, keeping the index.
@(private = "file")
browse_preview_forget :: proc(p: ^Browse_Preview) {
	if p.backdrop.id != 0 {
		rl.UnloadTexture(p.backdrop)
		trace("unload preview backdrop %v", p.path)
	}
	doc_destroy(&p.doc)
	delete(p.path)
	p.path = ""
	p.ok = false
	p.backdrop = {}
}

@(private = "file")
browse_preview_load :: proc(p: ^Browse_Preview, path: string) {
	if p.path == path do return
	browse_preview_forget(p)
	p.path = strings.clone(path)
	p.room = ac.DEFAULT_ROOM
	if !doc_load(&p.doc, path) do return
	p.ok = true
	if p.doc.bg < 0 do return
	ac.index_build(&p.index, asset_dir_for(path))
	p.backdrop, p.room = ac.load_backdrop(&p.index, doc_head(&p.doc, p.doc.bg, 0))
}

// --- What the browser calls ---

// "12 objects  3 exits", from the file's lines alone.
scene_detail :: proc(ctx: rawptr, path: string, kind: int) -> string {
	d: Doc
	defer doc_destroy(&d)
	if !doc_load(&d, path) do return "unreadable"
	return fmt.aprintf("%v objects  %v exits", len(d.objects), len(d.exits))
}

scene_preview :: proc(ctx: rawptr, path: string, kind: int, area: rl.Rectangle) -> bool {
	app := cast(^App)ctx
	browse_preview_load(&app.preview, path)
	p := &app.preview
	if !p.ok {
		ui.label(i32(area.x), i32(area.y), "could not read it", ui.DIM, ui.SMALL)
		return true
	}
	d := &p.doc

	// The picture is drawn from what the lines say (assetcache/room.odin).
	marks := make([dynamic]ac.Sketch_Mark, context.temp_allocator)
	for &o in d.objects do append(&marks, ac.Sketch_Mark{mark_kind(&o), o.pos})
	exits := make([dynamic][4]f32, context.temp_allocator)
	for e in d.exits do if e.has_area do append(&exits, e.area)
	triggers := make([dynamic][4]f32, context.temp_allocator)
	for t in d.triggers do append(&triggers, t.area)
	windows := make([dynamic][4]f32, context.temp_allocator)
	for win in d.windows do if win.has_glass do append(&windows, win.glass)
	desc := ""
	for line in d.descs {
		if doc_field(d, line, "when") != "" do continue
		desc = doc_line_text(d, line)
		break
	}
	sk := ac.Room_Sketch {
		backdrop   = p.backdrop,
		room       = p.room,
		bg         = doc_head(d, d.bg, 0) if d.bg >= 0 else "",
		marks      = marks[:],
		floor      = d.walk[:],
		exits      = exits[:],
		triggers   = triggers[:],
		windows    = windows[:],
		n_exits    = len(d.exits),
		n_triggers = len(d.triggers),
		n_scenery  = len(d.scenery),
		desc       = desc,
	}
	ac.room_sketch_draw(&sk, area)
	return true
}

// --- Marks: one shape per kind of thing (assetcache/room.odin) ---

mark_kind :: proc(o: ^Doc_Object) -> ac.Mark_Kind {
	return ac.mark_kind_of(o.peep, o.person, o.glow, o.sprite)
}

draw_mark :: proc(o: ^Doc_Object, at: [2]f32, picked: bool, size: f32) {
	ac.mark_icon(mark_kind(o), at, picked, size)
}

// NSCENE_TRACE=1: what is loaded and let go, on stderr (assetcache/art.odin).
trace :: ac.trace
