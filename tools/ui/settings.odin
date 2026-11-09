package ui

import "core:os"
import "core:strconv"
import "core:strings"

// The small things a tool should remember between runs: which folder you were
// browsing, how wide you dragged a column. None of it belongs in the repo —
// it is yours, not the project's — so it lives in the usual cache place, one
// file per tool, `key value` a line.
//
// There is one of these per process, opened by `run` and written on the way
// out. Nothing depends on it: a missing file, an unwritable cache or a value
// that no longer makes sense all fall back to the default, because a tool
// that refuses to start because it couldn't remember a column width would be
// a worse tool than one that forgets.

@(private)
Settings :: struct {
	tool:  string,
	pairs: map[string]string,
	dirty: bool,
	open:  bool,
}

@(private)
settings: Settings

@(private)
settings_open :: proc(tool: string) {
	settings_close()
	settings = {
		tool = strings.clone(tool),
		open = true,
	}
	data, err := os.read_entire_file(settings_path(tool), context.temp_allocator)
	if err != nil do return
	for line in strings.split_lines(string(data), context.temp_allocator) {
		text := strings.trim_space(line)
		if text == "" || strings.has_prefix(text, "#") do continue
		space := strings.index_byte(text, ' ')
		if space <= 0 do continue
		key := strings.trim_space(text[:space])
		value := strings.trim_space(text[space + 1:])
		if key == "" do continue
		settings.pairs[strings.clone(key)] = strings.clone(value)
	}
}

@(private)
settings_close :: proc() {
	if settings.open && settings.dirty do settings_write()
	for k, v in settings.pairs {
		delete(k)
		delete(v)
	}
	delete(settings.pairs)
	delete(settings.tool)
	settings = {}
}

@(private = "file")
settings_write :: proc() {
	dir := cache_dir()
	if dir == "" do return
	if !os.is_dir(dir) {
		if os.make_directory(dir) != nil do return
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "# nengine tools: remembered between runs. Safe to delete.\n")
	for k, v in settings.pairs {
		strings.write_string(&b, k)
		strings.write_byte(&b, ' ')
		strings.write_string(&b, v)
		strings.write_byte(&b, '\n')
	}
	_ = os.write_entire_file(settings_path(settings.tool), transmute([]u8)strings.to_string(b))
}

@(private = "file")
settings_path :: proc(tool: string) -> string {
	dir := cache_dir()
	if dir == "" do return ""
	return path_join(dir, strings.concatenate({tool, ".conf"}, context.temp_allocator))
}

// --- Reading and writing one value ---

// The stored text for `key`, or `fallback`. The result is borrowed from the
// store and is good until that key is set again.
setting_text :: proc(key, fallback: string) -> string {
	if have, ok := settings.pairs[key]; ok do return have
	return fallback
}

setting_set_text :: proc(key, value: string) {
	if have, ok := settings.pairs[key]; ok {
		if have == value do return
		delete(have)
		settings.pairs[key] = strings.clone(value)
		settings.dirty = true
		return
	}
	settings.pairs[strings.clone(key)] = strings.clone(value)
	settings.dirty = true
}

setting_num :: proc(key: string, fallback: f32) -> f32 {
	text, ok := settings.pairs[key]
	if !ok do return fallback
	if v, good := strconv.parse_f32(text); good do return v
	return fallback
}

setting_set_num :: proc(key: string, value: f32) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_f32(&b, value, 'f')
	setting_set_text(key, strings.to_string(b))
}
