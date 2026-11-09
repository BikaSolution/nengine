package cutscene

import ne "../../../"
import ui "../../ui"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"

// The game's dialogue, for `line` cues: every `### ID · title` node in the
// writers' Markdown (nengine/nodes.odin), read by the engine's own reader.
//
// A `line` cue names a node and which of its lines to say, and the words stay
// in the writers' file. So choosing one is reading the script: Line... opens a
// list of every node, searchable by id, title or any word of its lines, with
// the node's lines numbered beside it, as the engine counts them, in the
// telling chosen. Click a line to start there, shift-click to end there.
//
// The dialogue is read the first time it is wanted — a cut with a `line` cue
// draws each as long as its lines take to read — and let go with the editor.
// It is text: about a megabyte of Markdown for a game.

Node_Index :: struct {
	tried:   bool,
	dir:     string, // owned: where the dialogue was found; "" for nowhere
	world:   ^ne.World, // only its nodes are used
	ids:     [dynamic]string, // borrowed from world.nodes' keys, in id order
	file:    map[string]string, // id -> the file it is in (both borrowed / owned value)
	choices: [dynamic]ui.Choice, // built when a node is asked for; search text owned
}

// Where a game's dialogue is: story/dialogue beside its assets folder, as
// the games are laid out, or a dialogue folder there.
dialogue_dir_for :: proc(asset_dir: string) -> string {
	game := ui.parent_dir(ui.abs_path(asset_dir, context.temp_allocator))
	for sub in ([]string{"story/dialogue", "dialogue", "story"}) {
		dir := ui.path_join(game, sub)
		if os.is_dir(dir) do return dir
	}
	return ""
}

nodes_load :: proc(ix: ^Node_Index, asset_dir: string) {
	if ix.tried do return
	ix.tried = true
	ix.dir = strings.clone(dialogue_dir_for(asset_dir))
	if ix.dir == "" do return
	ix.world = new(ne.World)
	files, err := os.read_directory_by_path(ix.dir, -1, context.temp_allocator)
	if err != nil do return
	names := make([dynamic]string, context.temp_allocator)
	for f in files do if strings.has_suffix(f.name, ".md") do append(&names, f.name)
	slice.sort(names[:])
	for name in names {
		ne.load_nodes(ix.world, ui.path_join(ix.dir, name))
		for id in ix.world.nodes do if id not_in ix.file do ix.file[id] = strings.clone(name)
	}
	for id in ix.world.nodes do append(&ix.ids, id)
	slice.sort_by(ix.ids[:], proc(a, b: string) -> bool {return ui.natural_less(a, b)})
}

nodes_destroy :: proc(ix: ^Node_Index) {
	nodes_choices_free(ix)
	delete(ix.choices)
	for _, f in ix.file do delete(f)
	delete(ix.file)
	delete(ix.ids)
	if ix.world != nil {
		ne.nodes_destroy(ix.world)
		free(ix.world)
	}
	delete(ix.dir)
	ix^ = {}
}

nodes_choices_free :: proc(ix: ^Node_Index) {
	for c in ix.choices {
		delete(c.label)
		delete(c.search)
	}
	clear(&ix.choices)
}

node_of :: proc(ix: ^Node_Index, id: string) -> ^ne.Node {
	if ix.world == nil do return nil
	n, _ := ne.node(ix.world, id)
	return n
}

// The lines of one telling, as a `line` cue counts them: every untagged
// line, and those tagged `tag`.
node_telling :: proc(n: ^ne.Node, tag: string, allocator := context.temp_allocator) -> []ne.Talk_Line {
	out := make([dynamic]ne.Talk_Line, allocator)
	for l, i in n.lines {
		t := n.tags[i] if i < len(n.tags) else ""
		if t == "" || (tag != "" && t == tag) do append(&out, l)
	}
	return out[:]
}

// The tellings a node has, once each.
node_tags :: proc(n: ^ne.Node, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	outer: for t in n.tags {
		if t == "" do continue
		for have in out do if have == t do continue outer
		append(&out, t)
	}
	return out[:]
}

// How long a line cue's lines take, as the engine times a range: each line
// its reading time (ne.line_secs). 0 when the node or the lines are not there.
line_cue_secs :: proc(ix: ^Node_Index, q: ne.Cue) -> f32 {
	n := node_of(ix, q.text)
	if n == nil do return 0
	lines := node_telling(n, q.tag)
	secs := f32(0)
	for l, i in lines {
		if i + 1 < q.lines[0] || i + 1 > q.lines[1] do continue
		secs += ne.line_secs(said_text(l))
	}
	return secs
}

// What the box says: the words, without the "Moore: " the reader puts on a
// line whose speaker it does not know (the editor knows none).
said_text :: proc(l: ne.Talk_Line) -> string {
	t := l.text
	if colon := strings.index(t, ": "); colon > 0 && colon <= 32 {
		name := t[:colon]
		if name[0] >= 'A' && name[0] <= 'Z' && strings.index_any(name, ".,!?()") < 0 do return t[colon + 2:]
	}
	return t
}

// The list a Line... question shows: every node, its title, and every word of
// its lines to search.
nodes_choices :: proc(ix: ^Node_Index) -> []ui.Choice {
	nodes_choices_free(ix)
	for id in ix.ids {
		n := node_of(ix, id)
		if n == nil do continue
		b := strings.builder_make()
		for l in n.lines {
			strings.write_string(&b, l.text)
			strings.write_byte(&b, ' ')
		}
		for t in n.tags do if t != "" do fmt.sbprintf(&b, "%v ", t)
		label := fmt.aprintf("%v  %v", id, ne.plain_text(n.title)) if n.title != "" else strings.clone(id)
		append(&ix.choices, ui.Choice{key = id, label = label, note = fmt.tprintf("%v", len(n.lines)), search = strings.to_string(b)})
	}
	return ix.choices[:]
}

// --- Choosing the lines ---

// What the Line... question has picked so far, in the node under its cursor.
Line_Pick :: struct {
	node:   string, // owned: the node these are for
	tag:    string, // owned
	first:  int,
	last:   int,
	scroll: f32,
}

line_pick_destroy :: proc(p: ^Line_Pick) {
	delete(p.node)
	delete(p.tag)
	p^ = {}
}

// The pane beside the list: the node's lines in the telling chosen, numbered
// as the cue counts them, the range lit.
draw_node_detail :: proc(ctx: rawptr, key: string, area: rl.Rectangle) {
	e := cast(^Editor)ctx
	p := &e.line_pick
	n := node_of(&e.nodes, key)
	if n == nil do return
	if p.node != key {
		// Another node: all of its untagged lines, to start with.
		ui.reset_string(&p.node, key)
		ui.reset_string(&p.tag, "")
		p.first, p.last, p.scroll = 1, len(node_telling(n, "")), 0
	}
	x, y, w := area.x, area.y, area.width
	ui.label(i32(x), i32(y), key, ui.GOLD, ui.FONT)
	y += 24
	if n.title != "" {
		ui.label(i32(x), i32(y), ui.ellipsize(ne.plain_text(n.title), w, ui.SMALL), ui.INK, ui.SMALL)
		y += 18
	}
	about := fmt.tprintf("%v", e.nodes.file[key])
	if n.when_ != "" do about = fmt.tprintf("%v   when: %v", about, n.when_)
	if n.gives != "" do about = fmt.tprintf("%v   gives: %v", about, n.gives)
	ui.label(i32(x), i32(y), ui.ellipsize(ne.plain_text(about), w, ui.SMALL), ui.DIM, ui.SMALL)
	y += 24

	// Which telling: the untagged lines alone, or with one tag's.
	tags := node_tags(n)
	if len(tags) > 0 {
		ui.label(i32(x), i32(y) + 4, "telling", ui.DIM, ui.SMALL)
		cx := x + 60
		options := make([dynamic]string, context.temp_allocator)
		append(&options, "")
		append(&options, ..tags)
		for t in options {
			text := "untagged only" if t == "" else t
			cw := min(f32(ui.measure(text, ui.SMALL) + 14), w - 60)
			if cx + cw > x + w {
				cx = x + 60
				y += 24
			}
			// A tag with a space in it cannot be written as `tag=`.
			usable := strings.index_byte(t, ' ') < 0
			if ui.chip({cx, y, cw, 20}, ui.ellipsize(text, cw - 8, ui.SMALL), p.tag == t) && usable && p.tag != t {
				ui.reset_string(&p.tag, t)
				p.first, p.last = 1, len(node_telling(n, t))
			}
			cx += cw + 4
		}
		y += 28
	}

	lines := node_telling(n, p.tag)
	p.first = clamp(p.first, 1, max(len(lines), 1))
	p.last = clamp(p.last, p.first, max(len(lines), 1))
	pick := fmt.tprintf("lines %v of %v", ne.line_range_text({p.first, p.last}), len(lines))
	if p.tag != "" do pick = fmt.tprintf("%v   tag=%v", pick, p.tag)
	secs := f32(0)
	for l, i in lines do if i + 1 >= p.first && i + 1 <= p.last do secs += ne.line_secs(said_text(l))
	ui.label(i32(x), i32(y), fmt.tprintf("%v   %.1fs to read", pick, secs), ui.INK, ui.SMALL)
	y += 18
	ui.label(i32(x), i32(y), "click a line to start there, shift-click to end there", {110, 110, 126, 255}, ui.SMALL)
	y += 22

	box := rl.Rectangle{x, y, w, area.y + area.height - y}
	if box.height < 40 do return
	// Each line as tall as it wraps.
	text_w := w - 44
	total := f32(0)
	for l in lines do total += f32(len(ui.text_rows(ne.plain_text(l.text), text_w))) * 17 + 6
	ui.scroll_wheel(&p.scroll, box, 51, total)
	p.scroll = ui.scroll_clamp(p.scroll, total, box.height)
	rl.BeginScissorMode(i32(box.x), i32(box.y), i32(box.width), i32(box.height))
	ly := box.y - p.scroll
	for l, i in lines {
		said := ne.plain_text(l.text)
		rows := ui.text_rows(said, text_w)
		h := f32(len(rows)) * 17 + 6
		row := rl.Rectangle{box.x, ly, box.width, h - 2}
		in_range := i + 1 >= p.first && i + 1 <= p.last
		hot := rl.CheckCollisionPointRec(ui.mouse(), row) && rl.CheckCollisionPointRec(ui.mouse(), box)
		if in_range do rl.DrawRectangleRec(row, {56, 52, 36, 255})
		else if hot do rl.DrawRectangleRec(row, {40, 40, 50, 255})
		ink := ui.GOLD if in_range else ui.DIM
		ui.label(i32(box.x) + 4, i32(ly) + 3, fmt.tprintf("%v", i + 1), ink, ui.SMALL)
		text_ink := ui.INK if in_range else rl.Color{170, 170, 186, 255}
		if l.thinking do text_ink = {200, 180, 240, 255}
		for r, k in rows do ui.label(i32(box.x) + 36, i32(ly) + 3 + i32(k) * 17, said[r.start:r.end], text_ink, ui.SMALL)
		if hot && ui.mouse_pressed(.LEFT) {
			if ui.shift_down() {
				if i + 1 < p.first do p.first = i + 1
				else do p.last = i + 1
			} else {
				p.first, p.last = i + 1, i + 1
			}
		}
		ly += h
	}
	rl.EndScissorMode()
	ui.scrollbar(box, p.scroll, total)
	if len(lines) == 0 do ui.label(i32(box.x), i32(box.y), "no lines in this telling", ui.DIM, ui.SMALL)
}
