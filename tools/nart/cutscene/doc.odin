package cutscene

import ne "../../../"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// A .cut file as the cutscene editor holds it: its lines.
//
// The engine's writer (ne.cutscene_text) writes a cutscene from what it
// parsed, and a parse keeps what the game needs: the comments go, and the
// cues are put in time order. These files are written in groups — a comment
// saying which node and why, then the cues that stage it — and a group can
// start a little before the last one ended, so the file is not in time order
// and should not be made to be. An editor that rewrote it on the first save
// would be an editor nobody could use.
//
// So the editor keeps the lines, as the room editor does (nscene/doc.odin). A
// line nobody touched is written back exactly as it was read; a line that was
// changed is written again with only what changed being different: a cue's
// time is its first word and the rest is left as it was, a `cast` or `cut`
// line has the one field changed where it stands, and a cue whose action
// changed is written again after its time by the engine's own line writer
// (ne.cue_body_text). Opening a cutscene and saving it changes nothing.
//
// What the lines mean is worked out again after every change by doc_index,
// one line at a time through the engine's own reader (ne.parse_cutscene), so
// the editor and the game never disagree about a line.

Cut_Doc :: struct {
	lines:          [dynamic]string, // owned, each without its line break
	newline_at_end: bool,

	// doc_index's, rebuilt after every change. Owned.
	head:    int, // the `cut` line (the last, which is the one the engine keeps); -1 for none
	name:    string,
	scene:   string,
	people:  [dynamic]Doc_Cast, // the `cast` lines
	cues:    [dynamic]Doc_Cue, // in file order
	order:   [dynamic]int, // cue indices in the order they fire: by time, then file order
	ignored: [dynamic]int, // lines the engine reads as nothing (a misspelt verb)
}

Doc_Cast :: struct {
	line: int,
	m:    ne.Cast_Member,
}

Doc_Cue :: struct {
	line: int,
	q:    ne.Cue,
}

// --- Reading and writing ---

doc_load :: proc(d: ^Cut_Doc, path: string) -> bool {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return false
	doc_set_text_all(d, string(data))
	return true
}

doc_set_text_all :: proc(d: ^Cut_Doc, text: string) {
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

doc_text :: proc(d: ^Cut_Doc, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for l, i in d.lines {
		strings.write_string(&b, l)
		if i + 1 < len(d.lines) || d.newline_at_end do strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

doc_save :: proc(d: ^Cut_Doc, path: string) -> bool {
	return os.write_entire_file(path, transmute([]byte)doc_text(d)) == nil
}

doc_destroy :: proc(d: ^Cut_Doc) {
	doc_forget_index(d)
	for l in d.lines do delete(l)
	delete(d.lines)
	delete(d.people)
	delete(d.cues)
	delete(d.order)
	delete(d.ignored)
	d^ = {}
}

@(private = "file")
doc_forget_index :: proc(d: ^Cut_Doc) {
	delete(d.name)
	delete(d.scene)
	d.name, d.scene = "", ""
	for c in d.people {
		delete(c.m.name)
		delete(c.m.character)
	}
	for &c in d.cues do ne.cue_destroy(&c.q)
	clear(&d.people)
	clear(&d.cues)
	clear(&d.order)
	clear(&d.ignored)
}

// --- What the lines mean ---

is_note :: proc(raw: string) -> bool {
	t := strings.trim_space(raw)
	return t == "" || t[0] == '#'
}

// The first word of a line, and whether it is a time: a cue.
@(private = "file")
first_word :: proc(raw: string) -> string {
	t := strings.trim_left_space(raw)
	end := 0
	for end < len(t) && t[end] != ' ' && t[end] != '\t' do end += 1
	return t[:end]
}

is_cue_line :: proc(raw: string) -> bool {
	if is_note(raw) do return false
	_, ok := strconv.parse_f32(first_word(raw))
	return ok
}

doc_index :: proc(d: ^Cut_Doc) {
	doc_forget_index(d)
	d.head = -1
	d.name = strings.clone("")
	d.scene = strings.clone("")
	for raw, i in d.lines {
		if is_note(raw) do continue
		// One line through the engine's reader, so the editor sees exactly
		// what the game will.
		c, _ := ne.parse_cutscene(raw)
		switch {
		case first_word(raw) == "cut":
			d.head = i
			delete(d.name)
			delete(d.scene)
			d.name, d.scene = c.name, c.scene
			c.name, c.scene = "", ""
		case first_word(raw) == "cast" && len(c.people) == 1:
			append(&d.people, Doc_Cast{i, c.people[0]})
			clear(&c.people)
		case len(c.cues) == 1:
			append(&d.cues, Doc_Cue{i, c.cues[0]})
			clear(&c.cues)
		case:
			append(&d.ignored, i)
		}
		ne.cutscene_destroy(&c)
	}
	// The order they fire in: by time, and lines at the same time in the
	// order they are written (the engine's sort keeps it).
	for _, i in d.cues do append(&d.order, i)
	for i in 1 ..< len(d.order) {
		k := d.order[i]
		j := i - 1
		for j >= 0 && d.cues[d.order[j]].q.at > d.cues[k].q.at {
			d.order[j + 1] = d.order[j]
			j -= 1
		}
		d.order[j + 1] = k
	}
}

doc_member :: proc(d: ^Cut_Doc, name: string) -> int {
	for c, i in d.people do if c.m.name == name do return i
	return -1
}

doc_cue_at_line :: proc(d: ^Cut_Doc, line: int) -> int {
	for c, i in d.cues do if c.line == line do return i
	return -1
}

// When the last thing happens, as ne.cutscene_length has it: an `end` sets it
// outright, otherwise the last cue and a breath.
doc_length :: proc(d: ^Cut_Doc) -> f32 {
	last := f32(0)
	for i in d.order {
		q := d.cues[i].q
		if q.action == .End do return q.at
		last = max(last, q.at)
	}
	return last + 2
}

// The comments straight above a line.
doc_notes_above :: proc(d: ^Cut_Doc, line: int, allocator := context.temp_allocator) -> []string {
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

// --- A line, changed in place ---
//
// A word or a field is replaced where it stands, so the spacing and the order
// of everything else on the line stay as the author wrote them.

@(private = "file")
Token :: struct {
	start, end: int,
}

@(private = "file")
tokens_of :: proc(raw: string) -> []Token {
	out := make([dynamic]Token, context.temp_allocator)
	i := 0
	for i < len(raw) {
		for i < len(raw) && (raw[i] == ' ' || raw[i] == '\t') do i += 1
		if i >= len(raw) do break
		start := i
		for i < len(raw) && raw[i] != ' ' && raw[i] != '\t' do i += 1
		append(&out, Token{start, i})
	}
	return out[:]
}

// `raw` with field `name` set to `value`: replaced where it is, added at the
// end, or — for "" — taken off with the space before it.
line_with_field :: proc(raw, name, value: string) -> string {
	for t in tokens_of(raw) {
		tok := raw[t.start:t.end]
		eq := strings.index_byte(tok, '=')
		if eq <= 0 || tok[:eq] != name do continue
		if value == "" {
			from := t.start
			for from > 0 && (raw[from - 1] == ' ' || raw[from - 1] == '\t') do from -= 1
			return strings.concatenate({raw[:from], raw[t.end:]}, context.temp_allocator)
		}
		return strings.concatenate({raw[:t.start], name, "=", value, raw[t.end:]}, context.temp_allocator)
	}
	if value == "" do return raw
	return strings.concatenate({strings.trim_right_space(raw), " ", name, "=", value}, context.temp_allocator)
}

line_field :: proc(raw, name: string) -> (string, bool) {
	for t in tokens_of(raw) {
		tok := raw[t.start:t.end]
		if eq := strings.index_byte(tok, '='); eq > 0 && tok[:eq] == name do return tok[eq + 1:], true
	}
	return "", false
}

// `raw` with its `n`th plain word after the keyword (from 0) replaced.
line_with_word :: proc(raw: string, n: int, value: string) -> string {
	seen := -1
	for t, i in tokens_of(raw) {
		if i == 0 do continue
		if strings.index_byte(raw[t.start:t.end], '=') > 0 do continue
		seen += 1
		if seen == n do return strings.concatenate({raw[:t.start], value, raw[t.end:]}, context.temp_allocator)
	}
	return strings.concatenate({strings.trim_right_space(raw), " ", value}, context.temp_allocator)
}

// A cue line's time, written as the engine writes one.
time_text :: proc(t: f32) -> string {
	return fmt.tprintf("%.2f", t)
}

// --- Changing lines ---

doc_replace :: proc(d: ^Cut_Doc, line: int, raw: string) {
	if line < 0 || line >= len(d.lines) || d.lines[line] == raw do return
	delete(d.lines[line])
	d.lines[line] = strings.clone(raw)
	doc_index(d)
}

doc_insert :: proc(d: ^Cut_Doc, at: int, raw: string) -> int {
	where_ := clamp(at, 0, len(d.lines))
	inject_at(&d.lines, where_, strings.clone(raw))
	if len(d.lines) == 1 do d.newline_at_end = true
	doc_index(d)
	return where_
}

doc_remove_lines :: proc(d: ^Cut_Doc, lines: []int) {
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

doc_swap :: proc(d: ^Cut_Doc, a, b: int) {
	if a < 0 || b < 0 || a >= len(d.lines) || b >= len(d.lines) || a == b do return
	d.lines[a], d.lines[b] = d.lines[b], d.lines[a]
	doc_index(d)
}

// --- The cut line ---

// `cut <name>`, or `scene=<room>` on it. A file with no `cut` line gets one.
doc_set_head :: proc(d: ^Cut_Doc, name, scene: string) {
	if d.head < 0 {
		at := 0
		for at < len(d.lines) && is_note(d.lines[at]) && strings.trim_space(d.lines[at]) != "" do at += 1
		line := fmt.tprintf("cut %v", name if name != "" else "cut")
		if scene != "" do line = fmt.tprintf("%v scene=%v", line, scene)
		doc_insert(d, at, line)
		return
	}
	raw := d.lines[d.head]
	if name != "" && name != d.name do raw = line_with_word(raw, 0, name)
	if scene != d.scene do raw = line_with_field(raw, "scene", scene)
	doc_replace(d, d.head, raw)
}

// --- The cast ---

doc_add_cast :: proc(d: ^Cut_Doc, name: string) -> int {
	last := -1
	for c in d.people do last = max(last, c.line)
	if last >= 0 {
		doc_insert(d, last + 1, fmt.tprintf("cast %v", name))
		return doc_member(d, name)
	}
	// The first: under the head, with a blank line either side of the cast,
	// as the files are written.
	at := d.head + 1 if d.head >= 0 else 0
	if at < len(d.lines) && strings.trim_space(d.lines[at]) == "" {
		at += 1
	} else if d.head >= 0 {
		doc_insert(d, at, "")
		at += 1
	}
	doc_insert(d, at, fmt.tprintf("cast %v", name))
	if at + 1 < len(d.lines) && strings.trim_space(d.lines[at + 1]) != "" do doc_insert(d, at + 1, "")
	return doc_member(d, name)
}

doc_set_cast_field :: proc(d: ^Cut_Doc, i: int, name, value: string) {
	if i < 0 || i >= len(d.people) do return
	doc_replace(d, d.people[i].line, line_with_field(d.lines[d.people[i].line], name, value))
}

// Renames somebody, and every cue aimed at them.
doc_rename_cast :: proc(d: ^Cut_Doc, i: int, to: string) {
	if i < 0 || i >= len(d.people) || to == "" || doc_member(d, to) >= 0 do return
	old := strings.clone(d.people[i].m.name, context.temp_allocator)
	line := d.people[i].line
	cues := make([dynamic]int, context.temp_allocator)
	for c in d.cues do if c.q.who == old do append(&cues, c.line)
	delete(d.lines[line])
	d.lines[line] = strings.clone(line_with_word(d.lines[line], 0, to))
	doc_index(d)
	for l in cues {
		c := doc_cue_at_line(d, l)
		if c < 0 do continue
		was := d.cues[c].q
		q := was
		q.who = to
		line, _ := cue_line(d.lines[l], was, q)
		delete(d.lines[l])
		d.lines[l] = strings.clone(line)
	}
	doc_index(d)
}

// Somebody and every cue aimed at them. Returns how many cues went.
doc_remove_cast :: proc(d: ^Cut_Doc, i: int) -> int {
	if i < 0 || i >= len(d.people) do return 0
	lines := make([dynamic]int, context.temp_allocator)
	append(&lines, d.people[i].line)
	for c in d.cues do if c.q.who == d.people[i].m.name do append(&lines, c.line)
	doc_remove_lines(d, lines[:])
	return len(lines) - 1
}

// --- Cues ---

// --- What a cue line says after what the engine reads ---
//
// The engine reads a cue's words up to what its verb needs — `walk_to` one
// point, `face` one facing, `play` a part and how long, `line` a node and its
// lines, `sound` a name, `camera shake` a length, `end` nothing — and leaves
// the rest of the line alone. So an author can write a note after them:
//
//     12.50 line A2.GT.FENCE 3     the node's third line
//
// The editor keeps it. A cue changed is written as its time, the engine's
// words for it, and the note after them with its spacing as it was. The verbs
// whose words run to the end of the line (say, think, narrate) have no note:
// everything after the verb is what is said.

// How many words (not `key=value` fields) after its time a cue's verb reads,
// as the engine's parse_cue does; -1 for one that reads the rest of the line.
@(private = "file")
words_read :: proc(q: ne.Cue, words_there: int) -> int {
	switch q.action {
	case .End:                   return 1 // end
	case .Sound:                 return 2 // sound NAME
	case .Line:                  return 3 // line NODE N-M
	case .Shot:                  return 2 if q.text == "" else min(3, max(words_there, 2)) // shot off, shot NAME [FRAME]
	case .Shake:                 return 3 // camera shake SECS
	case .Walk_To, .Face, .Leave: return 3 // WHO walk_to X,Y, WHO leave DIR
	case .Play:                  return min(4, max(words_there, 3)) // WHO play PART [N]
	case .Say, .Think, .Narrate: return -1
	}
	return -1
}

// The note after what the engine reads of cue line `raw` (which says `q`),
// with the space before it; "" for none. A `tag=` in it is the cue's own.
cue_note :: proc(raw: string, q: ne.Cue) -> string {
	is_field :: proc(tok: string) -> bool {return strings.index_byte(tok, '=') > 0}
	toks := tokens_of(raw)
	words := 0
	for t, i in toks do if i > 0 && !is_field(raw[t.start:t.end]) do words += 1
	want := words_read(q, words)
	if want < 0 do return ""
	// A shot's frame is a number: a word after its picture that is not one
	// is the start of the note, as the engine reads it.
	if q.action == .Shot && want == 3 {
		seen := 0
		for t, i in toks {
			if i == 0 || is_field(raw[t.start:t.end]) do continue
			seen += 1
			if seen < 3 do continue
			if _, is_frame := strconv.parse_int(raw[t.start:t.end]); !is_frame do want = 2
			break
		}
	}
	end, seen := -1, 0
	for t, i in toks {
		if i == 0 || is_field(raw[t.start:t.end]) do continue
		seen += 1
		if seen == want {
			end = t.end
			break
		}
	}
	if end < 0 do return ""
	note := raw[end:]
	// A `line` cue's own fields are written with its words, not kept as a
	// note: its `tag=`, `shot=` and `frames=`.
	if q.action == .Line {
		for {
			cut := false
			for t in tokens_of(note) {
				tok := note[t.start:t.end]
				if !strings.has_prefix(tok, "tag=") && !strings.has_prefix(tok, "shot=") && !strings.has_prefix(tok, "frames=") do continue
				from := t.start
				for from > 0 && (note[from - 1] == ' ' || note[from - 1] == '\t') do from -= 1
				note = strings.concatenate({note[:from], note[t.end:]}, context.temp_allocator)
				cut = true
				break
			}
			if !cut do break
		}
	}
	if strings.trim_space(note) == "" do return ""
	return note
}

// The line for `q` in place of `raw`, which said `was`: its time as written,
// the engine's words for `q`, and the note `raw` had after them. A note that
// a verb reading to the end of the line would swallow comes back as `orphan`,
// for a comment over the line.
cue_line :: proc(raw: string, was, q: ne.Cue) -> (line: string, orphan: string) {
	note := cue_note(raw, was)
	if note != "" && words_read(q, 4) < 0 {
		orphan = strings.trim_space(note)
		note = ""
	}
	// The time and the space after it, as written.
	t := strings.trim_left_space(raw)
	end := 0
	for end < len(t) && t[end] != ' ' && t[end] != '\t' do end += 1
	if end == 0 do return strings.concatenate({ne.cue_text(q), note}, context.temp_allocator), orphan
	gap := end
	for gap < len(t) && (t[gap] == ' ' || t[gap] == '\t') do gap += 1
	head := raw[:len(raw) - len(t) + gap]
	if gap == end do head = strings.concatenate({head, " "}, context.temp_allocator)
	return strings.concatenate({head, ne.cue_body_text(q), note}, context.temp_allocator), orphan
}

// Changes what cue `i` does, keeping its time as written and any note after
// it. A note the new verb would read as its words goes above the line as a
// comment: the format has no comment at the end of a line, and a `#` after a
// `say` would be said.
doc_set_cue :: proc(d: ^Cut_Doc, i: int, q: ne.Cue) {
	if i < 0 || i >= len(d.cues) do return
	line := d.cues[i].line
	if ne.cue_body_text(q) == ne.cue_body_text(d.cues[i].q) do return
	raw, orphan := cue_line(d.lines[line], d.cues[i].q, q)
	if orphan == "" {
		doc_replace(d, line, raw)
		return
	}
	lead := d.lines[line][:len(d.lines[line]) - len(strings.trim_left_space(d.lines[line]))]
	comment := fmt.tprintf("%v# %v", lead, orphan)
	delete(d.lines[line])
	d.lines[line] = strings.clone(raw)
	inject_at(&d.lines, line, strings.clone(comment))
	doc_index(d)
}

// Moves cue `i` in time: its first word, and nothing else on the line.
// `place` puts the line where its new time belongs among the cues around it
// (see doc_place_cue). Returns the cue's index after.
doc_set_cue_time :: proc(d: ^Cut_Doc, i: int, at: f32, place := true) -> int {
	if i < 0 || i >= len(d.cues) do return i
	line := d.cues[i].line
	raw := d.lines[line]
	if d.cues[i].q.at != at {
		t := strings.trim_left_space(raw)
		end := 0
		for end < len(t) && t[end] != ' ' && t[end] != '\t' do end += 1
		lead := raw[:len(raw) - len(t)]
		doc_replace(d, line, strings.concatenate({lead, time_text(at), t[end:]}, context.temp_allocator))
	}
	if !place do return doc_cue_at_line(d, line)
	return doc_place_cue(d, doc_cue_at_line(d, line))
}

// A cue's line moved up or down among the cue lines it is written with — the
// run of cues with no comment or blank line between them — until its time is
// in order with its neighbours'. It never leaves its group: the comment over
// a group says what the group is, and a cue dragged a little late is still
// part of it. Returns the cue's index after.
doc_place_cue :: proc(d: ^Cut_Doc, i: int) -> int {
	if i < 0 || i >= len(d.cues) do return i
	line := d.cues[i].line
	at := d.cues[i].q.at
	for line > 0 && is_cue_line(d.lines[line - 1]) {
		prev := doc_cue_at_line(d, line - 1)
		if prev < 0 || d.cues[prev].q.at <= at do break
		d.lines[line], d.lines[line - 1] = d.lines[line - 1], d.lines[line]
		doc_index(d)
		line -= 1
	}
	for line + 1 < len(d.lines) && is_cue_line(d.lines[line + 1]) {
		next := doc_cue_at_line(d, line + 1)
		if next < 0 || d.cues[next].q.at >= at do break
		d.lines[line], d.lines[line + 1] = d.lines[line + 1], d.lines[line]
		doc_index(d)
		line += 1
	}
	return doc_cue_at_line(d, line)
}

// A new cue, after the last cue written at or before its time — or before
// the first, or at the end of a file with none. Returns its index.
doc_add_cue :: proc(d: ^Cut_Doc, q: ne.Cue) -> int {
	after := -1
	first := len(d.lines)
	for c in d.cues {
		if c.q.at <= q.at do after = max(after, c.line)
		first = min(first, c.line)
	}
	at := after + 1 if after >= 0 else first
	return doc_cue_at_line(d, doc_insert(d, at, ne.cue_text(q)))
}

doc_remove_cue :: proc(d: ^Cut_Doc, i: int) {
	if i < 0 || i >= len(d.cues) do return
	doc_remove_lines(d, {d.cues[i].line})
}

// Swaps cue `i`'s line with the cue line above (`up`) or below it, for two
// cues at one time, which fire in the order they are written. Returns its
// index after.
doc_move_cue :: proc(d: ^Cut_Doc, i: int, up: bool) -> int {
	if i < 0 || i >= len(d.cues) do return i
	line := d.cues[i].line
	other := -1
	if up {
		for c in d.cues do if c.line < line do other = max(other, c.line)
	} else {
		other = len(d.lines)
		for c in d.cues do if c.line > line do other = min(other, c.line)
		if other == len(d.lines) do other = -1
	}
	if other < 0 do return i
	doc_swap(d, line, other)
	return doc_cue_at_line(d, other)
}
