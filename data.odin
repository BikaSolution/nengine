package nengine

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// Text data files.
//
// Sprites, songs and scenes all live in plain text files with the same
// shape: one thing per line, a keyword first, then bare words and/or
// key=value pairs.
//
//     obj lamp pos=232,158 fps=6 block=circle:10 reach=circle:48
//
// The point of the format is that three different things can edit it: the
// editors (nart, nsound, nscene), those same programs' command lines, and
// you, by hand, in any text editor. It diffs well, so a change to a scene
// shows up in git as the one line that changed.

// A parsed line: the keyword, the bare words after it, and any key=value pairs.
Line :: struct {
	key:   string,
	words: []string,
	pairs: [][2]string,
}

// Splits file text into lines, dropping blank ones and # comments.
data_lines :: proc(text: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		trimmed := strings.trim_space(line)
		if trimmed == "" || strings.has_prefix(trimmed, "#") do continue
		append(&out, trimmed)
	}
	return out[:]
}

parse_line :: proc(raw: string, allocator := context.temp_allocator) -> (l: Line) {
	words := make([dynamic]string, allocator)
	pairs := make([dynamic][2]string, allocator)
	parts := strings.fields(raw, allocator)
	for p, i in parts {
		if i == 0 {
			l.key = p
			continue
		}
		if eq := strings.index_byte(p, '='); eq > 0 {
			append(&pairs, [2]string{p[:eq], p[eq + 1:]})
		} else {
			append(&words, p)
		}
	}
	l.words = words[:]
	l.pairs = pairs[:]
	return
}

// Everything after the first `skip` words, joined back together. For the
// lines that end in free text: descriptions, messages.
line_tail :: proc(raw: string, skip: int, allocator := context.temp_allocator) -> string {
	parts := strings.fields(raw, allocator)
	if len(parts) <= skip do return ""
	joined, _ := strings.join(parts[skip:], " ", allocator)
	return joined
}

field :: proc(l: Line, name: string) -> (string, bool) {
	for p in l.pairs {
		if p[0] == name do return p[1], true
	}
	return "", false
}

field_f32 :: proc(l: Line, name: string, fallback: f32 = 0) -> f32 {
	if s, ok := field(l, name); ok {
		if v, good := strconv.parse_f32(s); good do return v
	}
	return fallback
}

field_int :: proc(l: Line, name: string, fallback: int = 0) -> int {
	if s, ok := field(l, name); ok {
		if v, good := strconv.parse_int(s); good do return v
	}
	return fallback
}

field_bool :: proc(l: Line, name: string, fallback := false) -> bool {
	if s, ok := field(l, name); ok do return s == "true" || s == "1" || s == "yes"
	return fallback
}

// "5,7" — a list of whole numbers, for things like which animation frames tick.
field_ints :: proc(l: Line, name: string, allocator := context.temp_allocator) -> []int {
	s, ok := field(l, name)
	if !ok do return {}
	out := make([dynamic]int, allocator)
	for part in strings.split(s, ",", context.temp_allocator) {
		if v, good := strconv.parse_int(strings.trim_space(part)); good do append(&out, v)
	}
	return out[:]
}

// "232,158"
parse_vec2 :: proc(s: string) -> (v: [2]f32, ok: bool) {
	parts := strings.split(s, ",", context.temp_allocator)
	if len(parts) != 2 do return {}, false
	x, xo := strconv.parse_f32(strings.trim_space(parts[0]))
	y, yo := strconv.parse_f32(strings.trim_space(parts[1]))
	return {x, y}, xo && yo
}

field_vec2 :: proc(l: Line, name: string, fallback: [2]f32 = {}) -> [2]f32 {
	if s, ok := field(l, name); ok {
		if v, good := parse_vec2(s); good do return v
	}
	return fallback
}

// "0,157,320,43"
field_rect :: proc(l: Line, name: string) -> (r: Rect_Value) {
	s, ok := field(l, name)
	if !ok do return
	parts := strings.split(s, ",", context.temp_allocator)
	if len(parts) != 4 do return
	vals: [4]f32
	for p, i in parts {
		v, good := strconv.parse_f32(strings.trim_space(p))
		if !good do return
		vals[i] = v
	}
	return {{vals[0], vals[1], vals[2], vals[3]}, true}
}

Rect_Value :: struct {
	rect: [4]f32, // x, y, w, h
	ok:   bool,
}

// "box:30,8,0,-3" or "circle:26,0,-3" (the last two numbers, the offset, are optional)
field_shape :: proc(l: Line, name: string) -> Shape {
	s, ok := field(l, name)
	if !ok do return {}
	colon := strings.index_byte(s, ':')
	if colon <= 0 do return {}
	kind, rest := s[:colon], s[colon + 1:]
	parts := strings.split(rest, ",", context.temp_allocator)
	nums: [4]f32
	for p, i in parts {
		if i >= 4 do break
		v, _ := strconv.parse_f32(strings.trim_space(p))
		nums[i] = v
	}
	switch kind {
	case "box":
		if len(parts) >= 4 do return box(nums[0], nums[1], {nums[2], nums[3]})
		return box(nums[0], nums[1])
	case "circle":
		if len(parts) >= 3 do return circle(nums[0], {nums[1], nums[2]})
		return circle(nums[0])
	}
	return {}
}

// --- Writing ---

// Turns a shape back into "box:30,8,0,-3" form. Empty string if there isn't one.
shape_text :: proc(s: Shape, allocator := context.temp_allocator) -> string {
	switch s.kind {
	case .None:
		return ""
	case .Box:
		if s.offset == {} do return fmt.aprintf("box:%v,%v", s.size.x, s.size.y, allocator = allocator)
		return fmt.aprintf("box:%v,%v,%v,%v", s.size.x, s.size.y, s.offset.x, s.offset.y, allocator = allocator)
	case .Oval:
		if s.offset == {} do return fmt.aprintf("circle:%v", s.size.x, allocator = allocator)
		return fmt.aprintf("circle:%v,%v,%v", s.size.x, s.offset.x, s.offset.y, allocator = allocator)
	}
	return ""
}

read_data_file :: proc(path: string, allocator := context.temp_allocator) -> (text: string, ok: bool) {
	bytes, err := os.read_entire_file(path, allocator)
	if err != nil do return "", false
	return string(bytes), true
}

write_data_file :: proc(path, text: string) -> bool {
	return os.write_entire_file(path, transmute([]byte)text) == nil
}

// The free text at the end of a line that also carries `key=value` fields.
//
// `line_tail` counts words from the left, which breaks as soon as a field sits
// between the words and the text: in `on door unlock with=key The lock gives`,
// the text starts at "The", and no fixed word count finds it. This walks the
// line instead, skipping fields wherever they are, and returns everything from
// the first plain word after the `skip`th one.
//
// `skip` counts from the very start of the line, so the key counts as one:
// `text lamp It flickers.` wants a skip of 2, not 1.
line_rest :: proc(raw: string, skip: int) -> string {
	words, i := 0, 0
	for i < len(raw) {
		for i < len(raw) && raw[i] == ' ' do i += 1
		if i >= len(raw) do break
		start := i
		for i < len(raw) && raw[i] != ' ' do i += 1
		token := raw[start:i]
		// A field can appear anywhere and is never part of the text.
		if strings.index_byte(token, '=') > 0 do continue
		words += 1
		if words > skip do return strings.trim_space(raw[start:])
	}
	return ""
}
