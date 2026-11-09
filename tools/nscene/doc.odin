package main

import ne "../../"
import "core:fmt"
import "core:os"
import "core:strings"

// A scene file as the room editor holds it: its lines.
//
// The engine's writer (ne.scene_text) writes a scene out from what it parsed,
// and a parse keeps what the game needs, not what the file says: comments go,
// the order goes (every `text` moves under its object, every trigger to the
// bottom), and a field the writer does not know goes too. The rooms in this
// game are as much notes as numbers — admin.scene has sixty-five lines of
// comment saying why each thing is where it is — and an editor that threw
// them away on the first save would be an editor nobody could use.
//
// So the editor keeps the lines. A line nobody touched is written back exactly
// as it was read, byte for byte, and a line that was changed is written again
// from its parts — keyword, its words, its fields in the order they came, the
// free text last — with only the part that changed being different. Opening
// a room and saving it changes nothing, and changing a lamp's `when=` shows
// up in git as that one line.
//
// What the lines *mean* — which object a `text` or an `on` line belongs to,
// where everything stands — is worked out again after every change by
// `doc_index`, the same way the engine works it out (scene_file.odin): an
// attached line belongs to the latest object of that name above it.

Doc :: struct {
	lines:          [dynamic]string, // owned, each without its line break
	newline_at_end: bool,

	// Everything below is doc_index's, rebuilt after every change. Strings in
	// it are slices of `lines`, good until the next change.
	meta:      [dynamic]Line_Meta, // one per line
	scene:     int, // the `scene` line, -1 for none
	bg:        int,
	indoors:   int,
	footstep:  int,
	walk_at:   int, // the first `walk` line
	walk:      [dynamic][2]f32, // every corner of every `walk` line, as the engine joins them
	descs:     [dynamic]int,
	ambiences: [dynamic]int,
	objects:   [dynamic]Doc_Object,
	exits:     [dynamic]Doc_Exit,
	triggers:  [dynamic]Doc_Trigger,
	scenery:   [dynamic]Doc_Scenery,
	windows:   [dynamic]Doc_Window,
	sides:     [dynamic]Doc_Side,
	strays:    int, // attached lines with nothing above them to attach to
}

Line_Meta :: struct {
	key:   string, // "" for a blank line or a comment
	owner: int,    // the object (for text/on/routine/step) or exit (shut) it belongs to; -1 for none
}

// An `obj` or `peep` line, and what it says.
Doc_Object :: struct {
	line:    int,
	name:    string,
	peep:    bool,
	person:  bool, // has char=
	pos:     [2]f32,
	walk_to: [2]f32,
	block:   ne.Shape,
	reach:   ne.Shape,
	sprite:  string,
	char:    string,
	pose:    string,
	facing:  ne.Facing,
	depth:   ne.Depth,
	base:    f32,
	fps:     f32,
	frame:   i32,
	glow:    bool,
	only:    string, // when=
	text:    int,    // its `text` line (the last, which is the one that counts), -1 for none
	last:    int,    // the last line that belongs to it
}

Doc_Exit :: struct {
	line:    int,
	name:    string,
	area:    [4]f32,
	has_area: bool,
	to:      string,
	arrive:  [2]f32,
	at:      [2]f32,
	closed:  bool,
	only:    string,
	last:    int,
}

Doc_Trigger :: struct {
	line:   int,
	name:   string,
	area:   [4]f32,
	action: string,
	only:   string,
}

Doc_Scenery :: struct {
	line: int,
	name: string,
	only: string,
}

// A `window` line: an opening onto the outside, its glass, and the line a
// figure out there stands on (ne.Window, passer.odin).
Doc_Window :: struct {
	line:      int,
	name:      string,
	glass:     [4]f32,
	has_glass: bool,
	feet:      f32, // 0: the default, the foot of the glass and half a person
	frame:     string,
	only:      string,
}

// A `side` line: a border walked straight across into the room next door
// (ne.Side, side.odin). Its `shut <dir>` lines are found by doc_side_shuts.
Doc_Side :: struct {
	line:       int,
	dir:        ne.Compass,
	to:         string,
	span:       [2]f32, // lo, hi along the side
	gate:       string,
	name:       string,
	only:       string,
	arrive:     [2]f32,
	has_arrive: bool,
}

// The fields a side's panel shows by name; any others are listed after them.
SIDE_FIELDS :: []string{"to", "span", "gate", "name", "when", "arrive"}

// --- Reading and writing ---

doc_load :: proc(d: ^Doc, path: string) -> bool {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return false
	doc_set_text_all(d, string(data))
	return true
}

// Replaces the whole document with `text`: a file's contents, or an undo step.
doc_set_text_all :: proc(d: ^Doc, text: string) {
	for l in d.lines do delete(l)
	clear(&d.lines)
	d.newline_at_end = strings.has_suffix(text, "\n")
	body := text[:len(text) - 1] if d.newline_at_end else text
	if len(text) > 0 {
		rest := body
		for {
			nl := strings.index_byte(rest, '\n')
			if nl < 0 {
				append(&d.lines, strings.clone(rest))
				break
			}
			append(&d.lines, strings.clone(rest[:nl]))
			rest = rest[nl + 1:]
		}
	}
	doc_index(d)
}

// The file, as it would be saved.
doc_text :: proc(d: ^Doc, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for l, i in d.lines {
		strings.write_string(&b, l)
		if i + 1 < len(d.lines) || d.newline_at_end do strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

doc_save :: proc(d: ^Doc, path: string) -> bool {
	return os.write_entire_file(path, transmute([]byte)doc_text(d)) == nil
}

doc_destroy :: proc(d: ^Doc) {
	for l in d.lines do delete(l)
	delete(d.lines)
	delete(d.meta)
	delete(d.walk)
	delete(d.descs)
	delete(d.ambiences)
	delete(d.objects)
	delete(d.exits)
	delete(d.triggers)
	delete(d.scenery)
	delete(d.windows)
	delete(d.sides)
	d^ = {}
}

// A new room: a name, and a floor across the bottom third so there is
// somewhere to stand. No backdrop yet — the editor asks for one.
scene_template :: proc(name: string) -> string {
	return fmt.tprintf("# nengine scene\nscene %v\nwalk 20,384 1004,384 1004,595 20,595\n", name)
}

// --- What the lines mean ---

@(private = "file")
is_note :: proc(raw: string) -> bool {
	t := strings.trim_space(raw)
	return t == "" || t[0] == '#'
}

doc_index :: proc(d: ^Doc) {
	clear(&d.meta)
	clear(&d.walk)
	clear(&d.descs)
	clear(&d.ambiences)
	clear(&d.objects)
	clear(&d.exits)
	clear(&d.triggers)
	clear(&d.scenery)
	clear(&d.windows)
	clear(&d.sides)
	d.scene, d.bg, d.indoors, d.footstep, d.walk_at, d.strays = -1, -1, -1, -1, -1, 0

	for raw, i in d.lines {
		m := Line_Meta{owner = -1}
		defer append(&d.meta, m)
		if is_note(raw) do continue
		l := ne.parse_line(raw)
		m.key = l.key
		first := l.words[0] if len(l.words) > 0 else ""
		switch l.key {
		case "scene":    if d.scene < 0 do d.scene = i
		case "bg":       d.bg = i // the last one is the one the engine keeps
		case "indoors":  d.indoors = i
		case "footstep": d.footstep = i
		case "desc":     append(&d.descs, i)
		case "ambience": append(&d.ambiences, i)
		case "walk":
			if d.walk_at < 0 do d.walk_at = i
			for w in l.words do if p, good := ne.parse_vec2(w); good do append(&d.walk, p)
		case "obj", "peep":
			o := Doc_Object {
				line    = i,
				name    = first,
				peep    = l.key == "peep",
				pos     = ne.field_vec2(l, "pos"),
				walk_to = ne.field_vec2(l, "walk_to"),
				block   = ne.field_shape(l, "block"),
				reach   = ne.field_shape(l, "reach"),
				base    = ne.field_f32(l, "base"),
				fps     = ne.field_f32(l, "fps"),
				frame   = i32(ne.field_int(l, "frame")),
				glow    = ne.field_bool(l, "glow"),
				text    = -1,
				last    = i,
			}
			o.sprite, _ = ne.field(l, "sprite")
			o.char, o.person = ne.field(l, "char")
			o.pose, _ = ne.field(l, "pose")
			o.only, _ = ne.field(l, "when")
			if f, has := ne.field(l, "facing"); has do o.facing = ne.parse_facing(f)
			o.depth = .Normal
			if dv, has := ne.field(l, "depth"); has {
				switch dv {
				case "back", "behind": o.depth = .Back
				case "front":          o.depth = .Front
				}
			}
			append(&d.objects, o)
		case "text", "on", "routine", "step":
			at := latest_object(d, first)
			if at < 0 {
				d.strays += 1
				continue
			}
			m.owner = at
			d.objects[at].last = i
			if l.key == "text" do d.objects[at].text = i
		case "scenery":
			s := Doc_Scenery{line = i, name = first}
			s.only, _ = ne.field(l, "when")
			append(&d.scenery, s)
		case "exit":
			e := Doc_Exit{line = i, name = first, last = i}
			if r := ne.field_rect(l, "area"); r.ok do e.area, e.has_area = r.rect, true
			e.to, _ = ne.field(l, "to")
			e.arrive = ne.field_vec2(l, "arrive")
			e.at = ne.field_vec2(l, "at")
			e.closed = ne.field_bool(l, "closed")
			e.only, _ = ne.field(l, "when")
			append(&d.exits, e)
		case "shut":
			// Every exit of that name above it, as the engine has it; the
			// latest one is the one it is drawn as belonging to.
			for &e, n in d.exits do if e.name == first {
				m.owner = n
				e.last = i
			}
			// Or the sides that way above it: `shut south Padlocked.`
			if m.owner < 0 {
				dir, is_dir := ne.compass_of(first)
				side := false
				if is_dir do for s in d.sides do if s.dir == dir do side = true
				if !side do d.strays += 1
			}
		case "side":
			dir, is_dir := ne.compass_of(first)
			if !is_dir {
				d.strays += 1
				continue
			}
			s := Doc_Side{line = i, dir = dir}
			s.to, _ = ne.field(l, "to")
			span := ne.field_vec2(l, "span")
			s.span = {min(span.x, span.y), max(span.x, span.y)}
			s.gate, _ = ne.field(l, "gate")
			s.name, _ = ne.field(l, "name")
			s.only, _ = ne.field(l, "when")
			if _, has := ne.field(l, "arrive"); has {
				s.arrive = ne.field_vec2(l, "arrive")
				s.has_arrive = true
			}
			append(&d.sides, s)
		case "window":
			win := Doc_Window{line = i, name = first}
			if r := ne.field_rect(l, "glass"); r.ok do win.glass, win.has_glass = r.rect, true
			win.feet = ne.field_f32(l, "feet")
			win.frame, _ = ne.field(l, "frame")
			win.only, _ = ne.field(l, "when")
			append(&d.windows, win)
		case "trigger":
			t := Doc_Trigger{line = i, name = first}
			if r := ne.field_rect(l, "area"); r.ok do t.area = r.rect
			t.action, _ = ne.field(l, "action")
			t.only, _ = ne.field(l, "when")
			append(&d.triggers, t)
		}
	}
}

@(private = "file")
latest_object :: proc(d: ^Doc, name: string) -> int {
	#reverse for o, i in d.objects do if o.name == name do return i
	return -1
}

// The lines of `key` that belong to object `obj`, in file order.
doc_attached :: proc(d: ^Doc, obj: int, key: string, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, allocator)
	for m, i in d.meta do if m.owner == obj && m.key == key && is_attached(key) do append(&out, i)
	return out[:]
}

@(private = "file")
is_attached :: proc(key: string) -> bool {
	switch key {
	case "text", "on", "routine", "step": return true
	}
	return false
}

// The `shut` lines that say what exit `e` says when it is shut.
doc_shuts :: proc(d: ^Doc, e: int, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, allocator)
	if e < 0 || e >= len(d.exits) do return out[:]
	ex := d.exits[e]
	for m, i in d.meta {
		if m.key != "shut" || i < ex.line do continue
		l := ne.parse_line(d.lines[i])
		if len(l.words) > 0 && l.words[0] == ex.name do append(&out, i)
	}
	return out[:]
}

// The comments straight above a line, which in these files say why the thing
// under them is there.
doc_notes_above :: proc(d: ^Doc, line: int, allocator := context.temp_allocator) -> []string {
	start := line
	for start > 0 {
		t := strings.trim_space(d.lines[start - 1])
		if t == "" || t[0] != '#' do break
		start -= 1
	}
	out := make([dynamic]string, allocator)
	for i in start ..< line do append(&out, strings.trim_space(strings.trim_left(strings.trim_space(d.lines[i]), "#")))
	return out[:]
}

// --- A line, taken apart for changing ---

// A line in four parts: the keyword, its plain words, its `key=value` fields
// in the order they came, and the free text at the end, for the lines that
// have one (a description, an object's text, what an `on` says).
Parts :: struct {
	key:    string,
	head:   [dynamic]string,
	fields: [dynamic][2]string,
	text:   string,
}

// How many plain words come before a line's free text; -1 for lines that have
// none, where every word is a word. Matches what the engine skips before it
// reads the text (scene_file.odin, line_rest).
@(private = "file")
words_before_text :: proc(key: string, head: []string) -> int {
	switch key {
	case "desc":                    return 0
	case "text", "scenery", "shut": return 1
	case "on":                      return 2
	case "step":
		// `step elena say Hello.` is the one step with words of its own.
		if len(head) >= 2 && head[1] == "say" do return 2
		return -1 if len(head) >= 2 else 99
	}
	return -1
}

parts_of :: proc(raw: string) -> (p: Parts) {
	p.head = make([dynamic]string, context.temp_allocator)
	p.fields = make([dynamic][2]string, context.temp_allocator)
	s := strings.trim_space(raw)
	i := 0
	for i < len(s) {
		for i < len(s) && s[i] == ' ' do i += 1
		if i >= len(s) do break
		start := i
		for i < len(s) && s[i] != ' ' do i += 1
		tok := s[start:i]
		if p.key == "" {
			p.key = tok
			continue
		}
		if eq := strings.index_byte(tok, '='); eq > 0 {
			append(&p.fields, [2]string{tok[:eq], tok[eq + 1:]})
			continue
		}
		n := words_before_text(p.key, p.head[:])
		if n < 0 || len(p.head) < n {
			append(&p.head, tok)
			continue
		}
		p.text = strings.trim_space(s[start:])
		break
	}
	return
}

parts_text :: proc(p: Parts, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, p.key)
	for w in p.head {
		strings.write_byte(&b, ' ')
		strings.write_string(&b, w)
	}
	for f in p.fields {
		if f[1] == "" do continue
		fmt.sbprintf(&b, " %v=%v", f[0], f[1])
	}
	if p.text != "" {
		strings.write_byte(&b, ' ')
		strings.write_string(&b, p.text)
	}
	return strings.to_string(b)
}

parts_field :: proc(p: Parts, name: string) -> (string, bool) {
	for f in p.fields do if f[0] == name do return f[1], true
	return "", false
}

// Sets a field where it already is, or adds it at the end of the fields; an
// empty value takes it off.
parts_set :: proc(p: ^Parts, name, value: string) {
	for &f, i in p.fields do if f[0] == name {
		if value == "" {
			ordered_remove(&p.fields, i)
		} else {
			f[1] = value
		}
		return
	}
	if value != "" do append(&p.fields, [2]string{name, value})
}

// A field's value on line `line`.
doc_field :: proc(d: ^Doc, line: int, name: string) -> string {
	if line < 0 || line >= len(d.lines) do return ""
	v, _ := parts_field(parts_of(d.lines[line]), name)
	return v
}

doc_line_text :: proc(d: ^Doc, line: int) -> string {
	if line < 0 || line >= len(d.lines) do return ""
	return parts_of(d.lines[line]).text
}

doc_head :: proc(d: ^Doc, line: int, i: int) -> string {
	if line < 0 || line >= len(d.lines) do return ""
	p := parts_of(d.lines[line])
	return p.head[i] if i < len(p.head) else ""
}

// --- Changing lines ---
//
// Every change goes through these, and every one leaves the document indexed.

// Puts `raw` in place of line `line`, unless it says the same thing — so an
// edit that changes nothing leaves the line exactly as it was written.
doc_replace :: proc(d: ^Doc, line: int, raw: string) {
	if line < 0 || line >= len(d.lines) do return
	if d.lines[line] == raw do return
	if parts_text(parts_of(d.lines[line])) == raw do return
	delete(d.lines[line])
	d.lines[line] = strings.clone(raw)
	doc_index(d)
}

doc_set_field :: proc(d: ^Doc, line: int, name, value: string) {
	if line < 0 || line >= len(d.lines) do return
	p := parts_of(d.lines[line])
	old, had := parts_field(p, name)
	if had && old == value do return
	if !had && value == "" do return
	parts_set(&p, name, value)
	doc_replace(d, line, parts_text(p))
}

doc_set_head :: proc(d: ^Doc, line: int, i: int, value: string) {
	if line < 0 || line >= len(d.lines) do return
	p := parts_of(d.lines[line])
	if i < len(p.head) {
		if p.head[i] == value do return
		p.head[i] = value
	} else {
		for len(p.head) < i do append(&p.head, "_")
		append(&p.head, value)
	}
	doc_replace(d, line, parts_text(p))
}

// Every plain word at once: the corners of a floor.
doc_set_heads :: proc(d: ^Doc, line: int, words: []string) {
	if line < 0 || line >= len(d.lines) do return
	p := parts_of(d.lines[line])
	clear(&p.head)
	append(&p.head, ..words)
	doc_replace(d, line, parts_text(p))
}

doc_set_line_text :: proc(d: ^Doc, line: int, text: string) {
	if line < 0 || line >= len(d.lines) do return
	p := parts_of(d.lines[line])
	t := strings.trim_space(text)
	if p.text == t do return
	p.text = t
	doc_replace(d, line, parts_text(p))
}

doc_insert :: proc(d: ^Doc, at: int, raw: string) -> int {
	where_ := clamp(at, 0, len(d.lines))
	inject_at(&d.lines, where_, strings.clone(raw))
	if where_ == len(d.lines) - 1 && len(d.lines) == 1 do d.newline_at_end = true
	doc_index(d)
	return where_
}

doc_remove :: proc(d: ^Doc, line: int) {
	if line < 0 || line >= len(d.lines) do return
	delete(d.lines[line])
	ordered_remove(&d.lines, line)
	doc_index(d)
}

// Removes several lines at once, whatever order they are given in.
doc_remove_lines :: proc(d: ^Doc, lines: []int) {
	sorted := make([dynamic]int, context.temp_allocator)
	append(&sorted, ..lines)
	for i in 1 ..< len(sorted) {
		for j := i; j > 0 && sorted[j - 1] < sorted[j]; j -= 1 do sorted[j - 1], sorted[j] = sorted[j], sorted[j - 1]
	}
	last := -1
	for l in sorted {
		if l == last || l < 0 || l >= len(d.lines) do continue
		delete(d.lines[l])
		ordered_remove(&d.lines, l)
		last = l
	}
	doc_index(d)
}

doc_swap :: proc(d: ^Doc, a, b: int) {
	if a < 0 || b < 0 || a >= len(d.lines) || b >= len(d.lines) || a == b do return
	d.lines[a], d.lines[b] = d.lines[b], d.lines[a]
	doc_index(d)
}

// The line after the last of `keys`, or after the first `then` that has any,
// or the end of the file. Where a new line of a kind goes: with the others of
// its kind, in the order the files are written in.
doc_after_last :: proc(d: ^Doc, keys: []string, then: ..[]string) -> int {
	find :: proc(d: ^Doc, keys: []string) -> int {
		#reverse for m, i in d.meta {
			for k in keys do if m.key == k do return i
		}
		return -1
	}
	if at := find(d, keys); at >= 0 do return at + 1
	for t in then do if at := find(d, t); at >= 0 do return at + 1
	return len(d.lines)
}

// --- Changing the room ---

// A name that is not taken by anything in the room yet: lamp, lamp2, lamp3.
// Two objects may share a name on purpose (one per condition), but a new one
// that does by accident would answer to the wrong lines.
doc_free_name :: proc(d: ^Doc, want: string) -> string {
	taken :: proc(d: ^Doc, n: string) -> bool {
		for o in d.objects do if o.name == n do return true
		for e in d.exits do if e.name == n do return true
		for t in d.triggers do if t.name == n do return true
		for s in d.scenery do if s.name == n do return true
		for w in d.windows do if w.name == n do return true
		return false
	}
	base := clean_name(want)
	if base == "" do base = "thing"
	if !taken(d, base) do return base
	for n in 2 ..< 1000 {
		try := fmt.tprintf("%v%v", base, n)
		if !taken(d, try) do return try
	}
	return base
}

// Names are one word: what the parser matches, and the first word of every
// line that belongs to the thing.
clean_name :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in strings.trim_space(s) {
		switch {
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9', c == '_': strings.write_rune(&b, c)
		case c >= 'A' && c <= 'Z':                                strings.write_rune(&b, c + 32)
		case c == ' ' || c == '-':                                strings.write_byte(&b, '_')
		}
	}
	return strings.to_string(b)
}

num :: proc(v: f32) -> string {
	return fmt.tprintf("%v", v)
}

vec :: proc(v: [2]f32) -> string {
	return fmt.tprintf("%v,%v", v.x, v.y)
}

rect_text :: proc(r: [4]f32) -> string {
	return fmt.tprintf("%v,%v,%v,%v", r[0], r[1], r[2], r[3])
}

// Where a new object's lines go: after the last line of the last object, so
// objects stay together, or else after the room's own lines.
@(private = "file")
object_slot :: proc(d: ^Doc) -> int {
	last := -1
	for o in d.objects do last = max(last, o.last)
	if last >= 0 do return last + 1
	return doc_after_last(d, {"walk"}, {"footstep"}, {"ambience"}, {"desc"}, {"indoors"}, {"bg"}, {"scene"})
}

// A new `obj` (or `peep`) line; returns the object's index.
doc_add_object :: proc(d: ^Doc, key, name: string, pos: [2]f32, fields: ..[2]string) -> int {
	p := Parts{key = key}
	p.head = make([dynamic]string, context.temp_allocator)
	p.fields = make([dynamic][2]string, context.temp_allocator)
	append(&p.head, name)
	append(&p.fields, [2]string{"pos", vec(pos)})
	append(&p.fields, ..fields)
	at := object_slot(d)
	// A blank line between groups, as the files are written.
	if at > 0 && at <= len(d.lines) && !is_note(d.lines[at - 1]) && len(d.objects) > 0 {
		doc_insert(d, at, "")
		at += 1
	}
	doc_insert(d, at, parts_text(p))
	for o, i in d.objects do if o.line == at do return i
	return len(d.objects) - 1
}

// Every line of object `i`: its own and the ones that belong to it.
doc_object_lines :: proc(d: ^Doc, i: int, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, allocator)
	if i < 0 || i >= len(d.objects) do return out[:]
	append(&out, d.objects[i].line)
	for m, l in d.meta do if m.owner == i && is_attached(m.key) do append(&out, l)
	return out[:]
}

doc_remove_object :: proc(d: ^Doc, i: int) {
	doc_remove_lines(d, doc_object_lines(d, i))
}

// Renames an object and every line that belongs to it.
doc_rename_object :: proc(d: ^Doc, i: int, to: string) {
	if i < 0 || i >= len(d.objects) do return
	name := clean_name(to)
	if name == "" || name == d.objects[i].name do return
	lines := doc_object_lines(d, i)
	keep := make([dynamic]string, context.temp_allocator)
	for l in lines {
		p := parts_of(d.lines[l])
		if p.key == "obj" || p.key == "peep" || len(p.head) == 0 {
			if len(p.head) > 0 do p.head[0] = name
		} else {
			p.head[0] = name
		}
		append(&keep, strings.clone(parts_text(p), context.temp_allocator))
	}
	for l, n in lines {
		delete(d.lines[l])
		d.lines[l] = strings.clone(keep[n])
	}
	doc_index(d)
}

// The object's LOOK AT text: set, added under the object, or taken away.
doc_set_object_text :: proc(d: ^Doc, i: int, text: string) {
	if i < 0 || i >= len(d.objects) do return
	o := d.objects[i]
	t := strings.trim_space(text)
	switch {
	case o.text >= 0 && t == "": doc_remove(d, o.text)
	case o.text >= 0:            doc_set_line_text(d, o.text, t)
	case t != "":                doc_insert(d, o.line + 1, fmt.tprintf("text %v %v", o.name, t))
	}
}

// A new `on` line for object `i`, after its last one; returns the line.
doc_add_on :: proc(d: ^Doc, i: int, verb: string) -> int {
	if i < 0 || i >= len(d.objects) do return -1
	o := d.objects[i]
	v, _ := strings.replace_all(strings.trim_space(verb), " ", "_", context.temp_allocator)
	if v == "" do v = "look"
	return doc_insert(d, o.last + 1, fmt.tprintf("on %v %v", o.name, v))
}

// A new `step` for a person's routine, after the last one.
doc_add_step :: proc(d: ^Doc, i: int, step: string) -> int {
	if i < 0 || i >= len(d.objects) do return -1
	o := d.objects[i]
	at := o.last + 1
	steps := doc_attached(d, i, "step")
	if len(steps) > 0 do at = steps[len(steps) - 1] + 1
	return doc_insert(d, at, fmt.tprintf("step %v %v", o.name, step))
}

// `routine <name> loop`, on or off.
doc_set_routine_loop :: proc(d: ^Doc, i: int, loop: bool) {
	if i < 0 || i >= len(d.objects) do return
	lines := doc_attached(d, i, "routine")
	has := false
	for l in lines do for w in parts_of(d.lines[l]).head do if w == "loop" do has = true
	if has == loop do return
	if loop {
		at := d.objects[i].text + 1 if d.objects[i].text >= 0 else d.objects[i].line + 1
		doc_insert(d, at, fmt.tprintf("routine %v loop", d.objects[i].name))
	} else {
		doc_remove_lines(d, lines)
	}
}

doc_add_exit :: proc(d: ^Doc, name: string, area: [4]f32, to: string, arrive: [2]f32) -> int {
	at := doc_after_last(d, {"exit", "shut"})
	if at == len(d.lines) {
		last := -1
		for o in d.objects do last = max(last, o.last)
		if last >= 0 do at = last + 1
	}
	line := fmt.tprintf("exit %v area=%v to=%v arrive=%v", name, rect_text(area), to if to != "" else "nowhere", vec(arrive))
	doc_insert(d, at, line)
	for e, i in d.exits do if e.line == at do return i
	return len(d.exits) - 1
}

// An exit and its `shut` lines — unless another exit of the same name still
// needs them.
doc_remove_exit :: proc(d: ^Doc, i: int) {
	if i < 0 || i >= len(d.exits) do return
	lines := make([dynamic]int, context.temp_allocator)
	append(&lines, d.exits[i].line)
	shared := false
	for e, n in d.exits do if n != i && e.name == d.exits[i].name do shared = true
	if !shared do append(&lines, ..doc_shuts(d, i))
	doc_remove_lines(d, lines[:])
}

doc_rename_exit :: proc(d: ^Doc, i: int, to: string) {
	if i < 0 || i >= len(d.exits) do return
	name := clean_name(to)
	if name == "" || name == d.exits[i].name do return
	shared := false
	for e, n in d.exits do if n != i && e.name == d.exits[i].name do shared = true
	shuts := doc_shuts(d, i)
	line := d.exits[i].line
	if !shared do for l in shuts do doc_set_head(d, l, 0, name)
	doc_set_head(d, line, 0, name)
}

// What exit `i` says when it is shut: set, added under it, or taken away.
doc_set_shut :: proc(d: ^Doc, i: int, text: string) {
	if i < 0 || i >= len(d.exits) do return
	shuts := doc_shuts(d, i)
	t := strings.trim_space(text)
	switch {
	case len(shuts) > 0 && t == "": doc_remove_lines(d, shuts)
	case len(shuts) > 0:            doc_set_line_text(d, shuts[len(shuts) - 1], t)
	case t != "":                   doc_insert(d, d.exits[i].line + 1, fmt.tprintf("shut %v %v", d.exits[i].name, t))
	}
}

// A new `side` line, after the other sides (and their `shut` lines), or after
// the exits; returns the side's index.
doc_add_side :: proc(d: ^Doc, dir: ne.Compass, to: string, span: [2]f32) -> int {
	at := doc_after_last(d, {"side", "shut"}, {"exit"})
	if at == len(d.lines) {
		last := -1
		for o in d.objects do last = max(last, o.last)
		if last >= 0 do at = last + 1
	}
	lo, hi := min(span[0], span[1]), max(span[0], span[1])
	doc_insert(d, at, fmt.tprintf("side %v to=%v span=%v,%v", ne.COMPASS_WORDS[dir], to if to != "" else "nowhere", num(lo), num(hi)))
	for s, i in d.sides do if s.line == at do return i
	return len(d.sides) - 1
}

// The `shut <dir>` lines below side `i`: what the sides that way say shut.
doc_side_shuts :: proc(d: ^Doc, i: int, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, allocator)
	if i < 0 || i >= len(d.sides) do return out[:]
	s := d.sides[i]
	for m, n in d.meta {
		if m.key != "shut" || n < s.line do continue
		l := ne.parse_line(d.lines[n])
		if len(l.words) > 0 && l.words[0] == ne.COMPASS_WORDS[s.dir] do append(&out, n)
	}
	return out[:]
}

// A side and its `shut` lines, unless another side that way still needs them.
doc_remove_side :: proc(d: ^Doc, i: int) {
	if i < 0 || i >= len(d.sides) do return
	lines := make([dynamic]int, context.temp_allocator)
	append(&lines, d.sides[i].line)
	shared := false
	for s, n in d.sides do if n != i && s.dir == d.sides[i].dir do shared = true
	if !shared do append(&lines, ..doc_side_shuts(d, i))
	doc_remove_lines(d, lines[:])
}

// What side `i` says when its gate is shut: set, added under it, or taken away.
doc_set_side_shut :: proc(d: ^Doc, i: int, text: string) {
	if i < 0 || i >= len(d.sides) do return
	shuts := doc_side_shuts(d, i)
	t := strings.trim_space(text)
	switch {
	case len(shuts) > 0 && t == "": doc_remove_lines(d, shuts)
	case len(shuts) > 0:            doc_set_line_text(d, shuts[len(shuts) - 1], t)
	case t != "":                   doc_insert(d, d.sides[i].line + 1, fmt.tprintf("shut %v %v", ne.COMPASS_WORDS[d.sides[i].dir], t))
	}
}

doc_set_side_span :: proc(d: ^Doc, i: int, span: [2]f32) {
	if i < 0 || i >= len(d.sides) do return
	lo, hi := min(span[0], span[1]), max(span[0], span[1])
	doc_set_field(d, d.sides[i].line, "span", fmt.tprintf("%v,%v", num(lo), num(hi)))
}

// Which way side `i` faces, changed: its `shut` lines go with it when no other
// side still faces the old way.
doc_set_side_dir :: proc(d: ^Doc, i: int, dir: ne.Compass) {
	if i < 0 || i >= len(d.sides) || d.sides[i].dir == dir do return
	shared := false
	for s, n in d.sides do if n != i && s.dir == d.sides[i].dir do shared = true
	shuts := doc_side_shuts(d, i)
	line := d.sides[i].line
	if !shared do for l in shuts do doc_set_head(d, l, 0, ne.COMPASS_WORDS[dir])
	doc_set_head(d, line, 0, ne.COMPASS_WORDS[dir])
}

doc_add_trigger :: proc(d: ^Doc, name: string, area: [4]f32, action: string) -> int {
	at := doc_after_last(d, {"trigger"}, {"exit", "shut"})
	line := fmt.tprintf("trigger %v area=%v", name, rect_text(area))
	if action != "" do line = fmt.tprintf("%v action=%v", line, action)
	doc_insert(d, at, line)
	for t, i in d.triggers do if t.line == at do return i
	return len(d.triggers) - 1
}

doc_add_scenery :: proc(d: ^Doc, name, text: string) -> int {
	at := doc_after_last(d, {"scenery"})
	if at == len(d.lines) {
		last := -1
		for o in d.objects do last = max(last, o.last)
		if last >= 0 do at = last + 1
	}
	doc_insert(d, at, fmt.tprintf("scenery %v %v", name, text if text != "" else "Nothing much."))
	for s, i in d.scenery do if s.line == at do return i
	return len(d.scenery) - 1
}

// A new `window` line: with the others, or after the last object (its frame
// is usually one), or at the end. Returns the window's index.
doc_add_window :: proc(d: ^Doc, name: string, glass: [4]f32) -> int {
	at := doc_after_last(d, {"window"})
	if at == len(d.lines) {
		last := -1
		for o in d.objects do last = max(last, o.last)
		if last >= 0 do at = last + 1
	}
	doc_insert(d, at, fmt.tprintf("window %v glass=%v", name, rect_text(glass)))
	for w, i in d.windows do if w.line == at do return i
	return len(d.windows) - 1
}

// Where a figure outside window `w` stands: its `feet`, or the default the
// engine gives it (ne.window_feet) for a person of PERSON_H.
doc_window_feet :: proc(w: Doc_Window) -> f32 {
	return ne.window_feet(ne.Window{glass = {w.glass[0], w.glass[1], w.glass[2], w.glass[3]}, feet = w.feet}, PERSON_H)
}

// A person on a 1024-wide canvas, 52 art pixels at 3.2: what the default
// feet line is drawn for. The figure the game sends past may be a little
// taller or shorter.
PERSON_H :: f32(166)

doc_add_desc :: proc(d: ^Doc, only, text: string) -> int {
	at := doc_after_last(d, {"desc"}, {"indoors"}, {"bg"}, {"scene"})
	line := fmt.tprintf("desc when=%v %v", only, text) if only != "" else fmt.tprintf("desc %v", text)
	return doc_insert(d, at, line)
}

doc_add_ambience :: proc(d: ^Doc, name, only: string) -> int {
	at := doc_after_last(d, {"ambience"}, {"desc"}, {"indoors"}, {"bg"}, {"scene"})
	line := fmt.tprintf("ambience when=%v %v", only, name) if only != "" else fmt.tprintf("ambience %v", name)
	return doc_insert(d, at, line)
}

// A one-word room line — `bg`, `footstep` — set, added or taken away.
doc_set_room_word :: proc(d: ^Doc, key, value: string) {
	at := -1
	switch key {
	case "bg":       at = d.bg
	case "footstep": at = d.footstep
	case "scene":    at = d.scene
	}
	v := strings.trim_space(value)
	switch {
	case at >= 0 && v == "": doc_remove(d, at)
	case at >= 0:            doc_set_head(d, at, 0, v)
	case v != "":
		where_: int
		switch key {
		case "scene":    where_ = doc_after_last(d, {})
		case "bg":       where_ = doc_after_last(d, {"scene"})
		case "footstep": where_ = doc_after_last(d, {"ambience"}, {"desc"}, {"indoors"}, {"bg"}, {"scene"})
		}
		if key == "scene" && len(d.lines) > 0 && strings.has_prefix(d.lines[0], "#") do where_ = 1
		doc_insert(d, where_, fmt.tprintf("%v %v", key, v))
	}
}

doc_set_indoors :: proc(d: ^Doc, on: bool) {
	if on == (d.indoors >= 0) do return
	if on {
		doc_insert(d, doc_after_last(d, {"bg"}, {"scene"}), "indoors")
	} else {
		doc_remove(d, d.indoors)
	}
}

// The floor: every corner on the first `walk` line, and any other `walk`
// lines (the engine joins them) folded into it.
doc_set_walk :: proc(d: ^Doc, points: [][2]f32) {
	words := make([dynamic]string, context.temp_allocator)
	for p in points do append(&words, vec(p))
	if d.walk_at < 0 {
		at := doc_after_last(d, {"footstep"}, {"ambience"}, {"desc"}, {"indoors"}, {"bg"}, {"scene"})
		doc_insert(d, at, strings.concatenate({"walk ", strings.join(words[:], " ", context.temp_allocator)}, context.temp_allocator))
		return
	}
	first := d.walk_at
	others := make([dynamic]int, context.temp_allocator)
	for m, i in d.meta do if m.key == "walk" && i != first do append(&others, i)
	doc_set_heads(d, first, words[:])
	if len(others) > 0 do doc_remove_lines(d, others[:])
}

// The lines of object `i`, as text, to copy.
doc_object_block :: proc(d: ^Doc, i: int, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for l in doc_object_lines(d, i) {
		strings.write_string(&b, d.lines[l])
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// Puts a copied object back, renamed so it doesn't answer to the original's
// lines, and moved along so it isn't hidden under it. Returns its index.
doc_paste_object :: proc(d: ^Doc, block: string, offset: [2]f32) -> int {
	lines := strings.split_lines(strings.trim_right(block, "\n"), context.temp_allocator)
	if len(lines) == 0 do return -1
	first := parts_of(lines[0])
	if (first.key != "obj" && first.key != "peep") || len(first.head) == 0 do return -1
	name := doc_free_name(d, first.head[0])
	at := object_slot(d)
	if at > 0 && at <= len(d.lines) && !is_note(d.lines[at - 1]) {
		doc_insert(d, at, "")
		at += 1
	}
	for raw, n in lines {
		p := parts_of(raw)
		if len(p.head) > 0 do p.head[0] = name
		if n == 0 {
			if v, has := parts_field(p, "pos"); has {
				if pos, good := ne.parse_vec2(v); good do parts_set(&p, "pos", vec(pos + offset))
			}
			if v, has := parts_field(p, "walk_to"); has {
				if w, good := ne.parse_vec2(v); good do parts_set(&p, "walk_to", vec(w + offset))
			}
		}
		inject_at(&d.lines, at + n, strings.clone(parts_text(p)))
	}
	doc_index(d)
	for o, i in d.objects do if o.line == at do return i
	return -1
}

// --- Fields, by kind ---
//
// What each kind of line can say, in the order the panel shows it. A field a
// line has that is not on its list is shown too, under "other", so nothing in
// a file is ever out of sight of the editor.

OBJ_FIELDS :: []string{"pos", "sprite", "char", "pose", "facing", "speed", "frame", "fps", "walk_to", "block", "reach", "base", "depth", "glow", "show", "loop", "tick", "ticks", "when"}
PEEP_FIELDS :: []string{"pos", "into", "dress", "kind", "blind", "frame", "near", "sprite", "char", "pose", "facing", "speed", "fps", "walk_to", "block", "reach", "base", "depth", "glow", "show", "loop", "tick", "ticks", "when"}
EXIT_FIELDS :: []string{"area", "to", "arrive", "closed", "when", "anim", "at", "face", "arrive_anim"}
TRIGGER_FIELDS :: []string{"area", "action", "when"}
WINDOW_FIELDS :: []string{"glass", "feet", "frame", "when"}
ON_FIELDS :: []string{"with", "when", "action", "anim"}
WHEN_ONLY :: []string{"when"}

// The fields line `line` has that its kind does not list.
doc_other_fields :: proc(d: ^Doc, line: int, known: []string, allocator := context.temp_allocator) -> [][2]string {
	out := make([dynamic][2]string, allocator)
	if line < 0 || line >= len(d.lines) do return out[:]
	for f in parts_of(d.lines[line]).fields {
		found := false
		for k in known do if k == f[0] do found = true
		if !found do append(&out, f)
	}
	return out[:]
}
