package nengine

import "core:fmt"
import "core:strings"

// Dialogue nodes: the script, read from the writers' own files.
//
// A node is a short scene of lines with an id, written in a Markdown file the
// way a script is written, and played by its id from game code:
//
//     ### A2.GT.SPEECH · Moore states the impossibility
//     > when: act2 16:00  needs: —  gives: F1  once  [the case hangs on this]
//     MOORE: Before anyone unpacks. Two gates. Main gate, pool gate.
//     (He shows it. He does not hand it over.)
//     ADA: (writing) Two gates, one key.
//     [sets: heard_the_fence]
//
//     ne.play_node(w, "A2.GT.SPEECH")
//
// `### ID · title` opens a node and the next heading closes it. `SPEAKER:` is
// somebody talking, looked up among World.speakers by name (MARGARET is
// Margaret, HARGREAVE is Mrs Hargreave); a name nobody declared stays on the
// line, so it still reads. A line in brackets on its own, `(He goes.)`, is
// a stage direction, shown with no speaker. `[sets: a, b]` sets those flags
// when the node ends; any other `[...]` is a note for the builder and is not
// shown. `*emphasis*` loses its asterisks. Prose, tables and code between
// nodes are the writers' commentary and are skipped.
//
// The header line keeps what the node says about itself: `when`, `needs`,
// `gives` (a clue id the game can award from World.on_node), `once`, `tick`.
// The engine does not enforce them; the game reads them.
//
// `>> Choice` starts a branch, and the lines indented under it are its lines:
//
//     >> Tell Mr Moore
//         MOORE: Dead?
//     >> Say nothing
//         ADA: Not mine to report.
//
// play_node plays the lines above the first branch; node_choose plays one,
// and then any lines written after the branches, unindented, which are what
// happens whichever was chosen.

Node :: struct {
	id:      string,
	title:   string,
	when_:   string, // the header's `when:` as written
	needs:   string,
	gives:   string, // "" for —
	once:    bool,
	tick:    bool,
	lines:   []Talk_Line,
	tags:    []string, // one per line: "" for every telling, or the variant it belongs to
	sets:    []string,
	choices: []Node_Choice,
	// Lines written after the branches and not indented under any of them:
	// what is said whichever branch was taken ("Either way: ..."). node_choose
	// plays them after the branch's own.
	after:   []Talk_Line,
}

Node_Choice :: struct {
	label: string,
	lines: []Talk_Line,
	tags:  []string,
	sets:  []string,
}

// Reads every node in a dialogue file into the world. The speakers must be
// set first. Returns how many it read; a file that cannot be read is 0.
load_nodes :: proc(w: ^World, path: string) -> int {
	text, ok := read_data_file(path)
	if !ok do return 0
	return parse_nodes(w, text)
}

parse_nodes :: proc(w: ^World, text: string) -> int {
	if w.nodes == nil do w.nodes = make(map[string]Node)
	count := 0
	cur: ^Node_Builder
	b: Node_Builder
	in_note := false // inside a builder's note that runs over several lines
	rest := text
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_right_space(raw)
		trimmed := strings.trim_space(line)
		if in_note {
			if strings.index_byte(trimmed, ']') >= 0 do in_note = false
			continue
		}
		if strings.has_prefix(trimmed, "#") || trimmed == "---" {
			if cur != nil {
				finish_node(w, cur)
				count += 1
				cur = nil
			}
			if strings.has_prefix(trimmed, "### ") {
				b = {}
				head := strings.trim_space(trimmed[4:])
				id, title := head, ""
				if sep := strings.index(head, " · "); sep >= 0 {
					id, title = strings.trim_space(head[:sep]), strings.trim_space(head[sep + len(" · "):])
				}
				id = strings.trim_space(strings.split(id, " ", context.temp_allocator)[0])
				id, _ = strings.replace_all(id, "*", "", context.temp_allocator)
				// A node's id has a dot in it (A2.GT.SPEECH, AN.POOL); a heading
				// without one (### The lodge, inside the wire) is the writers'.
				if id == "" || strings.index_byte(id, '.') < 0 do continue
				b.id, b.title = id, title
				cur = &b
			}
			continue
		}
		if cur == nil || trimmed == "" do continue
		indented := len(line) > 0 && (line[0] == ' ' || line[0] == '\t')
		// A note opened and not closed on this line runs on to the line that
		// closes it: the rest of this line before it is kept, the note is not.
		if open := strings.last_index_byte(trimmed, '['); open >= 0 && strings.index_byte(trimmed[open:], ']') < 0 {
			in_note = true
			trimmed = strings.trim_space(trimmed[:open])
			if trimmed == "" do continue
		}
		switch {
		case strings.has_prefix(trimmed, ">>"):
			label := strip_emphasis(strings.trim_space(trimmed[2:]))
			append(&cur.choices, Builder_Choice{label = label})
		case strings.has_prefix(trimmed, ">"):
			if len(cur.lines) == 0 && len(cur.choices) == 0 do read_node_header(cur, strings.trim_space(trimmed[1:]))
		case strings.has_prefix(trimmed, "[") && strings.has_suffix(trimmed, "]"):
			sets := node_sets(trimmed)
			if indented && len(cur.choices) > 0 {
				append(&cur.choices[len(cur.choices) - 1].sets, ..sets)
			} else {
				append(&cur.sets, ..sets)
			}
		case:
			in_choice := indented && len(cur.choices) > 0
			after := !in_choice && len(cur.choices) > 0
			for item in node_items(w, trimmed) {
				if after {
					if item.tag == "" do append(&cur.after, item.line)
				} else if in_choice {
					append(&cur.choices[len(cur.choices) - 1].lines, item.line)
					append(&cur.choices[len(cur.choices) - 1].tags, item.tag)
				} else {
					append(&cur.lines, item.line)
					append(&cur.tags, item.tag)
				}
			}
		}
	}
	if cur != nil {
		finish_node(w, cur)
		count += 1
	}
	return count
}

@(private = "file")
Builder_Choice :: struct {
	label: string,
	lines: [dynamic]Talk_Line,
	tags:  [dynamic]string,
	sets:  [dynamic]string,
}

@(private = "file")
Node_Builder :: struct {
	id, title:            string,
	when_, needs, gives:  string,
	once, tick:           bool,
	lines:                [dynamic]Talk_Line,
	tags:                 [dynamic]string,
	sets:                 [dynamic]string,
	choices:              [dynamic]Builder_Choice,
	after:                [dynamic]Talk_Line,
}

// `when: act2 16:00  needs: —  gives: F1  once  [notes]`
@(private = "file")
read_node_header :: proc(b: ^Node_Builder, h: string) {
	head := h
	if br := strings.index_byte(head, '['); br >= 0 do head = head[:br]
	words := strings.fields(head, context.temp_allocator)
	field := ""
	vals := make([dynamic]string, context.temp_allocator)
	flush :: proc(b: ^Node_Builder, field: string, vals: []string) {
		v := strings.join(vals, " ", context.temp_allocator)
		if v == "—" || v == "-" do v = ""
		switch field {
		case "when": b.when_ = v
		case "needs": b.needs = v
		case "gives": b.gives = v
		}
	}
	for word in words {
		switch word {
		case "when:", "needs:", "gives:", "at:", "into:", "kind:", "shot:", "blind:", "turn:", "passer:":
			flush(b, field, vals[:])
			clear(&vals)
			field = word[:len(word) - 1]
			continue
		case "once":
			b.once = true
			continue
		case "tick":
			b.tick = true
			continue
		}
		append(&vals, word)
	}
	flush(b, field, vals[:])
}

// `[sets: a, b]` gives a and b; any other note gives nothing.
@(private = "file")
node_sets :: proc(note: string) -> []string {
	inner := strings.trim(note, "[] ")
	if !strings.has_prefix(inner, "sets:") do return nil
	out := make([dynamic]string, context.temp_allocator)
	body := inner[len("sets:"):]
	if dot := strings.index_byte(body, '.'); dot >= 0 do body = body[:dot]
	for part in strings.split(body, ",", context.temp_allocator) {
		name := strings.trim_space(part)
		name = strings.trim_left(name, "+")
		if sp := strings.index_byte(name, ' '); sp >= 0 do name = name[:sp]
		if name != "" do append(&out, name)
	}
	return out[:]
}

// One written line can be several lines, and can say which telling it
// belongs to:
//
//     — PERCY: Cut the wire.                      a bullet: one of a list
//     — **Early (to 00:30):** PERCY: Ask me in the morning.   tagged "early"
//     [open] ELENA: Elena Vale. Nine years.        tagged "open"
//     — PICKETT: *May.* · LUCY: *When Norm's leave came through.*   two lines
//     — Act II: someone walking the fence line.    a tagged stage direction
//
// `[close-up, ...]` before a line is how it is framed, not which telling, and
// is dropped.
@(private = "file")
Node_Item :: struct {
	line: Talk_Line,
	tag:  string,
}

@(private = "file")
node_items :: proc(w: ^World, s: string) -> []Node_Item {
	out := make([dynamic]Node_Item, context.temp_allocator)
	rest := s
	bullet := false
	for p in ([?]string{"— ", "- ", "* ", "• "}) {
		if strings.has_prefix(rest, p) {
			rest = strings.trim_space(rest[len(p):])
			bullet = true
			break
		}
	}
	tag := ""
	// [open] ELENA: ...
	if strings.has_prefix(rest, "[") {
		if close := strings.index_byte(rest, ']'); close > 0 {
			inner := strings.trim_space(rest[1:close])
			if !strings.has_prefix(inner, "close-up") do tag = strings.to_lower(inner, context.temp_allocator)
			rest = strings.trim_space(rest[close + 1:])
		}
	}
	// **Early (to 00:30):** PERCY: ...   or   Act II: prose
	if bullet {
		label, after, ok := bullet_label(rest)
		if ok {
			tag = label
			rest = after
		}
	}
	// Notes out first: a note can have a ` · ` in it, which is not two lines.
	rest = strip_emphasis(rest)
	if rest == "" do return out[:]
	for part in strings.split(rest, " · ", context.temp_allocator) {
		piece := strings.trim_space(part)
		if tl, is_line := node_line(w, piece); is_line {
			append(&out, Node_Item{tl, tag})
		} else if bullet && tag != "" {
			append(&out, Node_Item{Talk_Line{text = strip_emphasis(piece)}, tag})
		}
	}
	return out[:]
}

// A bullet's label, if it has one: `**Early (to 00:30):**`, `**Branch A:**`,
// `Act II:`, `day:`. Not a speaker's name, which is in capitals.
@(private = "file")
bullet_label :: proc(s: string) -> (label, rest: string, ok: bool) {
	body := s
	raw, after: string
	if strings.has_prefix(body, "**") {
		// **Early (to 00:30):** or **17:30:**: the label is all of the bold,
		// colons in it and all, less the one it ends with.
		end := strings.index(body[2:], "**")
		if end < 0 do return "", s, false
		raw = strings.trim_right(strings.trim_space(body[2:2 + end]), ":")
		after = body[2 + end + 2:]
		if !strings.has_suffix(strings.trim_space(body[2:2 + end]), ":") {
			// **Elena**, if earned: ADA: ... : bold, then the label's colon after it.
			// The condition after the bold may run as long as it likes
			// ("**Lucy**, if Ada went out to Billy at one and ...:"), but if
			// the colon closes a speaker's name it was a line, not a label:
			// "**Edmund** at the bar. EDMUND: Drink?"
			colon := strings.index(after, ": ")
			if colon < 0 do return "", s, false
			words := strings.fields(after[:colon], context.temp_allocator)
			if len(words) > 0 {
				last := words[len(words) - 1]
				caps := len(last) > 1
				for c in last do if !(c >= 'A' && c <= 'Z') && c != '\'' && c != '.' do caps = false
				if caps do return "", s, false
			}
			raw = fmt.tprintf("%v%v", raw, after[:colon])
			after = after[colon + 1:]
		}
	} else {
		// The first ": " outside brackets: a label can carry a note in them,
		// `night, dinner (on a loop, three deep, v1's):`, and the note does not
		// count towards how long a label can be.
		colon, depth, bare := -1, 0, 0
		for i in 0 ..< len(body) {
			switch body[i] {
			case '(': depth += 1
			case ')': depth = max(depth - 1, 0)
			case ':':
				if depth == 0 && i + 1 < len(body) && body[i + 1] == ' ' do colon = i
			case:
				if depth == 0 do bare += 1
			}
			if colon >= 0 do break
		}
		if colon <= 0 || bare > 48 do return "", s, false
		raw = body[:colon]
		all_caps := true
		for c in raw do if c >= 'a' && c <= 'z' do all_caps = false
		if all_caps do return "", s, false // SPEAKER: a line, not a label
		after = body[colon + 1:]
	}
	if paren := strings.index_byte(raw, '('); paren >= 0 do raw = raw[:paren]
	return strings.to_lower(strings.trim_space(strip_emphasis(raw)), context.temp_allocator), strings.trim_space(after), true
}

// `MOORE: Aye.` or `(He goes.)`. False for anything else: prose, a table row.
@(private = "file")
node_line :: proc(w: ^World, s: string) -> (Talk_Line, bool) {
	if strings.has_prefix(s, "(") do return {text = strip_emphasis(s)}, true
	colon := strings.index_byte(s, ':')
	if colon <= 0 || colon > 32 do return {}, false
	name := s[:colon]
	// A speaker is written in capitals: ADA, MRS HARGREAVE, CAPTAIN MOSS.
	for c in name do if !(c >= 'A' && c <= 'Z') && c != ' ' && c != '\'' && c != '.' do return {}, false
	text := strip_emphasis(strings.trim_space(s[colon + 1:]))
	if name == "NARRATION" || name == "NARRATOR" do return {text = text}, true
	if who := speaker_named(w, strings.to_lower(name, context.temp_allocator)); who != nil do return {who = who, text = text}, true
	for sp in w.speakers do if strings.equal_fold(sp.name, name) do return {who = sp, text = text}, true
	pretty := strings.to_lower(name, context.temp_allocator)
	if len(pretty) > 0 do pretty = fmt.tprintf("%v%v", strings.to_upper(pretty[:1], context.temp_allocator), pretty[1:])
	return {text = fmt.tprintf("%v: %v", pretty, text)}, true
}

@(private = "file")
strip_emphasis :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "**", "", context.temp_allocator)
	out, _ = strings.replace_all(out, "*", "", context.temp_allocator)
	out, _ = strings.replace_all(out, "`", "", context.temp_allocator)
	// A note inside a line, `PERCY: Ask me in the morning. [deflects]`, is the
	// builder's and is not said.
	for {
		open := strings.index_byte(out, '[')
		if open < 0 do break
		close := strings.index_byte(out[open:], ']')
		if close < 0 do break
		out = strings.trim_space(fmt.tprintf("%v%v", out[:open], out[open + close + 1:]))
	}
	return out
}

@(private = "file")
finish_node :: proc(w: ^World, b: ^Node_Builder) {
	n := Node {
		id    = strings.clone(b.id),
		title = strings.clone(b.title),
		when_ = strings.clone(b.when_),
		needs = strings.clone(b.needs),
		gives = strings.clone(b.gives),
		once  = b.once,
		tick  = b.tick,
	}
	n.lines = clone_lines(b.lines[:])
	n.tags = clone_strings(b.tags[:])
	n.sets = clone_strings(b.sets[:])
	choices := make([]Node_Choice, len(b.choices))
	for c, i in b.choices {
		choices[i] = {label = strings.clone(c.label), lines = clone_lines(c.lines[:]), tags = clone_strings(c.tags[:]), sets = clone_strings(c.sets[:])}
		delete(c.lines)
		delete(c.tags)
		delete(c.sets)
	}
	n.choices = choices
	n.after = clone_lines(b.after[:])
	delete(b.after)
	delete(b.lines)
	delete(b.tags)
	delete(b.sets)
	delete(b.choices)
	if old, had := w.nodes[n.id]; had {
		node_destroy(&old)
		w.nodes[n.id] = n
	} else {
		w.nodes[strings.clone(n.id)] = n
	}
}

@(private = "file")
clone_lines :: proc(lines: []Talk_Line) -> []Talk_Line {
	out := make([]Talk_Line, len(lines))
	for l, i in lines {
		out[i] = l
		out[i].text = strings.clone(l.text)
	}
	return out
}

@(private = "file")
clone_strings :: proc(ss: []string) -> []string {
	out := make([]string, len(ss))
	for s, i in ss do out[i] = strings.clone(s)
	return out
}

@(private = "file")
node_destroy :: proc(n: ^Node) {
	delete(n.id)
	delete(n.title)
	delete(n.when_)
	delete(n.needs)
	delete(n.gives)
	for l in n.lines do delete(l.text)
	delete(n.lines)
	for t in n.tags do delete(t)
	delete(n.tags)
	for s in n.sets do delete(s)
	delete(n.sets)
	for c in n.choices {
		delete(c.label)
		for l in c.lines do delete(l.text)
		delete(c.lines)
		for t in c.tags do delete(t)
		delete(c.tags)
		for s in c.sets do delete(s)
		delete(c.sets)
	}
	delete(n.choices)
	for l in n.after do delete(l.text)
	delete(n.after)
}

// Frees every node. destroy_world calls it.
nodes_destroy :: proc(w: ^World) {
	for key, &n in w.nodes {
		node_destroy(&n)
		delete(key)
	}
	delete(w.nodes)
	w.nodes = nil
	for key in w.bark_next do delete(key)
	delete(w.bark_next)
	w.bark_next = nil
}

// --- Playing them ---

node :: proc(w: ^World, id: string) -> (^Node, bool) {
	n, has := &w.nodes[id]
	return n, has
}

// The flag a node sets the first time it plays: `said_A2.GT.SPEECH`.
node_said_flag :: proc(id: string) -> string {
	return fmt.tprintf("said_%v", id)
}

node_said :: proc(w: ^World, id: string) -> bool {
	return flag(w, node_said_flag(id))
}

// Plays a node's lines (those above its first branch) as a conversation. Its
// `[sets: ...]` flags are set when it ends, and `on_end` runs after. False if
// there is no node by that id. A `tick` node spends one the first time.
// With `shot`, every line is that close-up (frame 0); a sprite that was never
// drawn (no texture) is no shot, and the lines play over the room as before.
play_node :: proc(w: ^World, id: string, on_end: proc(w: ^World) = nil, tag := "", shot: ^Sprite = nil) -> bool {
	n, has := node(w, id)
	if !has do return false
	first := !node_said(w, id)
	set_flag(w, node_said_flag(id))
	if first && n.tick do tick(w)
	if w.on_node != nil do w.on_node(w, n)
	w.node_end = on_end
	w.node_sets = n.sets
	lines := node_telling(w, n.lines, n.tags, tag)
	if shot != nil && shot.texture.id != 0 do for &l in lines do l.shot = shot
	if len(lines) == 0 {
		node_ended(w)
		return true
	}
	begin_conversation(w, &w.node_talk, lines, node_ended)
	return true
}

// Everything playing a node does except saying it: marks it said, spends its
// tick the first time, tells `on_node`, sets its `[sets:]` flags. For a node
// whose lines a cutscene says (`line` cues): play the cut, and call this in
// its `then`, so the world is as if the node had played. False if no node.
node_done :: proc(w: ^World, id: string) -> bool {
	n, has := node(w, id)
	if !has do return false
	first := !node_said(w, id)
	set_flag(w, node_said_flag(id))
	if first && n.tick do tick(w)
	if w.on_node != nil do w.on_node(w, n)
	for s in n.sets do set_flag(w, s)
	return true
}

// The lines of one telling: every untagged line, and those tagged `tag`.
// With no tag asked for, untagged lines only.
@(private = "file")
node_telling :: proc(w: ^World, lines: []Talk_Line, tags: []string, tag: string) -> []Talk_Line {
	clear(&w.node_lines)
	for l, i in lines {
		t := tags[i] if i < len(tags) else ""
		if t == "" || (tag != "" && t == tag) do append(&w.node_lines, l)
	}
	return w.node_lines[:]
}

// The lines a node gives a person, whatever their tag: a list of barks,
// one each, picked by who is in the room.
node_lines_of :: proc(w: ^World, id: string, who: string, allocator := context.temp_allocator) -> []Talk_Line {
	out := make([dynamic]Talk_Line, allocator)
	n, has := node(w, id)
	if !has do return out[:]
	for l in n.lines do if l.who != nil && strings.equal_fold(l.who.name, who) do append(&out, l)
	return out[:]
}

// --- Barks: said near the player, not to her ---
//
// A node can be a list of ambient lines for a place: who is there and what
// they are doing, a line each, tagged by when (`- day: OTTO: ...`,
// `- night, act3: LUCY: ...`). `bark` says the next one whose tag and line
// `fits` (the game decides what "night, act3" means, and whether the person is
// in the room), going round the list a line at a time, so coming back into a
// room gives the next thing somebody there is doing and not the same one. It
// is a timed message (`say`, or `say_as` for a person), not a conversation:
// nothing waits for Enter and nothing costs a tick. False if no line fits.
//
//     ne.bark(w, "BARK.FIREPIT", fits_now)   // on arrival, or LISTEN
//
// Where each list has got to is not saved: a bark is colour, and after a
// restore the loop starts again.
Bark_Fits :: proc(w: ^World, tag: string, line: Talk_Line) -> bool

bark :: proc(w: ^World, id: string, fits: Bark_Fits = nil) -> bool {
	l, ok := next_bark(w, id, fits)
	if !ok do return false
	if l.who != nil do say_as(w, l.who, l.text)
	else do say(w, l.text)
	return true
}

// The line `bark` would say, and the list moved on past it.
next_bark :: proc(w: ^World, id: string, fits: Bark_Fits = nil) -> (Talk_Line, bool) {
	n, has := node(w, id)
	if !has || len(n.lines) == 0 do return {}, false
	start := w.bark_next[id] if w.bark_next != nil else 0
	for k in 0 ..< len(n.lines) {
		i := (start + k) % len(n.lines)
		tag := n.tags[i] if i < len(n.tags) else ""
		if fits != nil && !fits(w, tag, n.lines[i]) do continue
		if w.bark_next == nil do w.bark_next = make(map[string]int)
		if id in w.bark_next do w.bark_next[id] = i + 1
		else do w.bark_next[strings.clone(id)] = i + 1
		return n.lines[i], true
	}
	return {}, false
}

// The tags a node's lines carry, in order, once each: its tellings.
node_tags :: proc(w: ^World, id: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	n, has := node(w, id)
	if !has do return out[:]
	outer: for t in n.tags {
		if t == "" do continue
		for have in out do if have == t do continue outer
		append(&out, t)
	}
	return out[:]
}

// Plays the `which`th branch of a node (from 0). False if there is none.
node_choose :: proc(w: ^World, id: string, which: int, on_end: proc(w: ^World) = nil) -> bool {
	n, has := node(w, id)
	if !has || which < 0 || which >= len(n.choices) do return false
	c := &n.choices[which]
	w.node_end = on_end
	w.node_sets = c.sets
	lines := node_telling(w, c.lines, c.tags, "")
	append(&w.node_lines, ..n.after)
	lines = w.node_lines[:]
	if len(lines) == 0 {
		node_ended(w)
		return true
	}
	begin_conversation(w, &w.node_talk, lines, node_ended)
	return true
}

@(private = "file")
node_ended :: proc(w: ^World) {
	for s in w.node_sets do set_flag(w, s)
	w.node_sets = nil
	then := w.node_end
	w.node_end = nil
	if then != nil do then(w)
}
