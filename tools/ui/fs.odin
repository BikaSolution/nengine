package ui

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

// Finding files, and the paths that name them.
//
// The editors are run from the repo root, from inside a game folder, and
// occasionally from somewhere else entirely, so nothing here trusts the
// working directory for anything but a starting guess. Every path the
// browser holds on to is absolute and cleaned, because two spellings of one
// folder that don't compare equal turn into two entries in the sidebar and
// a "you are already here" that isn't true.

// --- Paths ---

// Absolute and cleaned. The result is owned by the caller.
abs_path :: proc(path: string, allocator := context.allocator) -> string {
	if path == "" {
		cwd, err := os.get_working_directory(context.temp_allocator)
		if err != nil do return strings.clone(".", allocator)
		return strings.clone(cwd, allocator)
	}
	full, abs_err := filepath.abs(path, context.temp_allocator)
	if abs_err != nil do full = path
	cleaned, clean_err := filepath.clean(full, context.temp_allocator)
	if clean_err != nil do cleaned = full
	return strings.clone(cleaned, allocator)
}

// The folder above, or the same path when there is nothing above it. Callers
// compare the two to know they've hit the top rather than looping forever.
parent_dir :: proc(path: string) -> string {
	if path == "" || path == "/" do return path
	slash := strings.last_index_byte(path, '/')
	switch {
	case slash < 0:  return path
	case slash == 0: return "/"
	case:            return path[:slash]
	}
}

// Joined with a single separator, whatever the pieces end in.
path_join :: proc(dir, name: string, allocator := context.temp_allocator) -> string {
	if dir == "" do return strings.clone(name, allocator)
	if strings.has_suffix(dir, "/") {
		return strings.concatenate({dir, name}, allocator)
	}
	return strings.concatenate({dir, "/", name}, allocator)
}

// ".sprite" for "assets/sprites/lamp.sprite", "" when there is no dot in the
// last component. Lower-cased, so a stray .PNG still matches.
ext_of :: proc(path: string, allocator := context.temp_allocator) -> string {
	name := path
	if slash := strings.last_index_byte(name, '/'); slash >= 0 do name = name[slash + 1:]
	dot := strings.last_index_byte(name, '.')
	if dot <= 0 do return ""
	return strings.to_lower(name[dot:], allocator)
}

// The last component: "lamp.sprite".
file_of :: proc(path: string) -> string {
	if slash := strings.last_index_byte(path, '/'); slash >= 0 do return path[slash + 1:]
	return path
}

// `path` written relative to `root` when it is underneath it, otherwise
// unchanged. For showing a long absolute path as something readable.
under :: proc(root, path: string) -> string {
	if root == "" || !strings.has_prefix(path, root) do return path
	rest := path[len(root):]
	return strings.trim_prefix(rest, "/")
}

// Folders that are never counted and never searched, though you can still
// walk into one if you mean to. `examples` is other people's repositories,
// cloned for reading: three songs in there would otherwise be most of what a
// count of the checkout found, and would drag a tool's opening folder off to
// somewhere nobody wanted to go.
SKIPPED_DIRS := [?]string{"examples"}

skipped :: proc(name: string) -> bool {
	for s in SKIPPED_DIRS do if name == s do return true
	return false
}

// --- What's in a folder ---

Entry :: struct {
	name:  string, // what to show: a base name, or a relative path when searching
	path:  string, // absolute
	dir:   bool,
	size:  i64,
	mtime: i64, // unix nanoseconds
	kind:  int, // index into the browser's kinds; -1 for a folder or a stranger
	count: int, // folders only: matching files somewhere below, -1 if not counted
}

entries_destroy :: proc(list: ^[dynamic]Entry) {
	for e in list {
		delete(e.name)
		delete(e.path)
	}
	clear(list)
}

// Which of `suffixes` a name ends in, or -1. Checked longest-first so a
// ".char" never loses to a shorter suffix that also matches.
kind_of :: proc(name: string, suffixes: []string) -> int {
	best, best_len := -1, 0
	lower := strings.to_lower(name, context.temp_allocator)
	for s, i in suffixes {
		if s == "" do continue
		if strings.has_suffix(lower, s) && len(s) > best_len {
			best, best_len = i, len(s)
		}
	}
	return best
}

// Everything directly inside `dir`: folders first, then files whose name ends
// in one of `suffixes`. Files of no interest are left out entirely — a
// browser for sprites listing a stray .wav is noise, and the sidebar and the
// folder counts are how you find the .wav's home instead.
list_dir :: proc(out: ^[dynamic]Entry, dir: string, suffixes: []string, hidden := false) {
	infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil do return
	for fi in infos {
		if !hidden && strings.has_prefix(fi.name, ".") do continue
		is_dir := fi.type == .Directory
		kind := -1
		if !is_dir {
			kind = kind_of(fi.name, suffixes)
			if kind < 0 do continue
		}
		append(out, Entry {
			name  = strings.clone(fi.name),
			path  = abs_path(path_join(dir, fi.name)),
			dir   = is_dir,
			size  = fi.size,
			mtime = time.to_unix_nanoseconds(fi.modification_time),
			kind  = kind,
			count = -1,
		})
	}
}

// Every matching file at or below `dir`, named by its path relative to `dir`.
// This is what the filter box searches, so that looking for "lamp" finds it
// three folders down without anybody having to guess where it lives.
//
// `limit` stops a browser pointed at a home directory from walking all of it.
list_tree :: proc(out: ^[dynamic]Entry, dir: string, suffixes: []string, limit := 4000, depth := 8, hidden := false) {
	walk(out, dir, "", suffixes, limit, depth, hidden)
}

@(private = "file")
walk :: proc(out: ^[dynamic]Entry, dir, prefix: string, suffixes: []string, limit, depth: int, hidden: bool) {
	if depth <= 0 || len(out) >= limit do return
	infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil do return
	for fi in infos {
		if len(out) >= limit do return
		if !hidden && strings.has_prefix(fi.name, ".") do continue
		if fi.type == .Directory && skipped(fi.name) do continue
		shown := fi.name if prefix == "" else strings.concatenate({prefix, "/", fi.name}, context.temp_allocator)
		if fi.type == .Directory {
			walk(out, path_join(dir, fi.name), shown, suffixes, limit, depth - 1, hidden)
			continue
		}
		kind := kind_of(fi.name, suffixes)
		if kind < 0 do continue
		append(out, Entry {
			name  = strings.clone(shown),
			path  = abs_path(path_join(dir, fi.name)),
			dir   = false,
			size  = fi.size,
			mtime = time.to_unix_nanoseconds(fi.modification_time),
			kind  = kind,
			count = -1,
		})
	}
}

// How many matching files are somewhere below `dir`. Shown beside a folder so
// you can see which way to go before you go there — the single thing the old
// picker could not tell you.
count_below :: proc(dir: string, suffixes: []string, depth := 6, cap_at := 999) -> int {
	if depth <= 0 do return 0
	infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil do return 0
	n := 0
	for fi in infos {
		if strings.has_prefix(fi.name, ".") do continue
		if fi.type == .Directory {
			if skipped(fi.name) do continue
			n += count_below(path_join(dir, fi.name), suffixes, depth - 1, cap_at - n)
		} else if kind_of(fi.name, suffixes) >= 0 {
			n += 1
		}
		if n >= cap_at do return cap_at
	}
	return n
}

// --- Sorting ---

Sort_Mode :: enum {
	Name,
	Size,
	Modified,
	Kind,
}

// Folders always lead, whatever the sort: they are how you leave the folder
// you are in, so they must not be scattered through the files.
sort_entries :: proc(list: []Entry, mode: Sort_Mode, reverse := false) {
	sort_mode = mode
	slice.sort_by(list, sort_less)
	if reverse {
		// Only the files turn round. Folders keep their own order at the top.
		first_file := len(list)
		for e, i in list do if !e.dir {
			first_file = i
			break
		}
		slice.reverse(list[first_file:])
	}
}

// slice.sort_by takes a plain proc with nothing captured, so the mode is a
// file-scope variable rather than an argument.
@(private = "file")
sort_mode: Sort_Mode

@(private = "file")
sort_less :: proc(a, b: Entry) -> bool {
	if a.dir != b.dir do return a.dir
	switch sort_mode {
	case .Size:
		if a.size != b.size do return a.size > b.size
	case .Modified:
		if a.mtime != b.mtime do return a.mtime > b.mtime
	case .Kind:
		if a.kind != b.kind do return a.kind < b.kind
	case .Name:
	}
	return natural_less(a.name, b.name)
}

// Compares names the way a person reads them, with runs of digits weighed as
// numbers: thing_2 before thing_10, not after it. Plain lexical order puts
// every file named with a number in the wrong place, which is most of them.
natural_less :: proc(a, b: string) -> bool {
	i, j := 0, 0
	for i < len(a) && j < len(b) {
		if is_digit(a[i]) && is_digit(b[j]) {
			// Leading zeros don't change a number's size, so skip them before
			// comparing, and fall back to length when the digits run equal.
			for i < len(a) && a[i] == '0' do i += 1
			for j < len(b) && b[j] == '0' do j += 1
			ai, bj := i, j
			for ai < len(a) && is_digit(a[ai]) do ai += 1
			for bj < len(b) && is_digit(b[bj]) do bj += 1
			if ai - i != bj - j do return ai - i < bj - j
			for i < ai {
				if a[i] != b[j] do return a[i] < b[j]
				i += 1
				j += 1
			}
			continue
		}
		ca, cb := lower(a[i]), lower(b[j])
		if ca != cb do return ca < cb
		i += 1
		j += 1
	}
	return len(a) - i < len(b) - j
}

@(private = "file")
is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

@(private = "file")
lower :: proc(c: u8) -> u8 {
	return c + 32 if c >= 'A' && c <= 'Z' else c
}

// --- Copying, for duplicate ---

copy_file :: proc(from, to: string) -> bool {
	data, read_err := os.read_entire_file(from, context.temp_allocator)
	if read_err != nil do return false
	return os.write_entire_file(to, data) == nil
}

// "lamp.sprite" -> "lamp 2.sprite" -> "lamp 3.sprite", skipping what exists.
free_name :: proc(dir, name: string, allocator := context.temp_allocator) -> string {
	stem, ext := name, ""
	if dot := strings.last_index_byte(name, '.'); dot > 0 {
		stem, ext = name[:dot], name[dot:]
	}
	for n := 2; n < 1000; n += 1 {
		try := strings.concatenate({stem, " ", itoa(n), ext}, context.temp_allocator)
		if !os.exists(path_join(dir, try)) do return strings.clone(try, allocator)
	}
	return strings.clone(name, allocator)
}

@(private = "file")
itoa :: proc(n: int) -> string {
	buf := make([]u8, 8, context.temp_allocator)
	v, i := n, len(buf)
	if v == 0 {
		i -= 1
		buf[i] = '0'
	}
	for v > 0 && i > 0 {
		i -= 1
		buf[i] = u8('0' + v % 10)
		v /= 10
	}
	return string(buf[i:])
}

// --- Human-readable ---

// "412 B", "4.1 K", "1.2 M". Sizes sit in a narrow column, so three or four
// characters and a unit beats exact bytes nobody reads.
size_text :: proc(n: i64, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	switch {
	case n < 1024:
		strings.write_i64(&b, n)
		strings.write_string(&b, " B")
	case n < 1024 * 1024:
		write_tenths(&b, f64(n) / 1024)
		strings.write_string(&b, " K")
	case:
		write_tenths(&b, f64(n) / (1024 * 1024))
		strings.write_string(&b, " M")
	}
	return strings.to_string(b)
}

@(private = "file")
write_tenths :: proc(b: ^strings.Builder, v: f64) {
	whole := i64(v)
	tenth := i64((v - f64(whole)) * 10 + 0.5)
	if tenth >= 10 {
		whole += 1
		tenth = 0
	}
	strings.write_i64(b, whole)
	if whole < 100 {
		strings.write_byte(b, '.')
		strings.write_i64(b, tenth)
	}
}

// "just now", "6m", "3h", "2d", "14 Mar". Relative while it's recent, because
// what you want to know is which file you touched last.
age_text :: proc(mtime: i64, allocator := context.temp_allocator) -> string {
	if mtime <= 0 do return ""
	secs := (time.to_unix_nanoseconds(time.now()) - mtime) / 1e9
	b := strings.builder_make(allocator)
	switch {
	case secs < 60:
		strings.write_string(&b, "just now")
	case secs < 3600:
		strings.write_i64(&b, secs / 60)
		strings.write_string(&b, "m ago")
	case secs < 86400:
		strings.write_i64(&b, secs / 3600)
		strings.write_string(&b, "h ago")
	case secs < 86400 * 30:
		strings.write_i64(&b, secs / 86400)
		strings.write_string(&b, "d ago")
	case:
		y, m, d := time.date(time.Time{_nsec = mtime})
		this_year, _, _ := time.date(time.now())
		strings.write_int(&b, d)
		strings.write_string(&b, " ")
		strings.write_string(&b, MONTHS[int(m) - 1])
		if y != this_year {
			strings.write_string(&b, " ")
			strings.write_int(&b, y)
		}
	}
	return strings.to_string(b)
}

@(private = "file")
MONTHS := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}

// --- Places ---
//
// The tree down the side of the browser. The tools are started from wherever
// is convenient, so rather than trusting one guess at a starting folder and
// stranding you there when it's wrong — which is exactly what the old picker
// did — this offers every game in the checkout and lets you pick.
//
// It follows you. It used to be built once, at start, with every game's
// whole assets tree opened out one after another — so the first game in the
// alphabet (the old one) filled the column, and the game you were actually
// working in was somewhere off the bottom of it, out of reach. Now only the
// game you are in is opened, and only along the way to the folder you are
// in: its top folders, the folders inside each folder you are in, and the one
// you are in lit. Every other game is one closed line with its count, a click
// away. Moving into another game, or out of the checkout, builds it again for
// there.

Place_Kind :: enum {
	Root,      // the top of the checkout
	Game,      // <game>/assets, named for the game
	Folder,    // a folder inside one of those
	Elsewhere, // somewhere outside the checkout, where you happen to be
}

Place :: struct {
	label:  string,
	path:   string,
	depth:  int,
	count:  int, // matching files at or below it
	parent: int, // index of the place it sits in, -1 at the top
	kind:   Place_Kind,
	kids:   bool, // has folders inside it, so it can open
}

places_destroy :: proc(list: ^[dynamic]Place) {
	for p in list {
		delete(p.label)
		delete(p.path)
	}
	clear(list)
}

// The top of the checkout: the nearest folder at or above the working
// directory that has a justfile or an nengine in it. Falls back to the
// working directory, so this always answers something.
workspace_root :: proc(allocator := context.allocator) -> string {
	cwd := abs_path("", context.temp_allocator)
	if found := workspace_root_of(cwd, context.temp_allocator); found != "" {
		return strings.clone(found, allocator)
	}
	return strings.clone(cwd, allocator)
}

// The same, looking up from `dir`; "" when there is none above it.
workspace_root_of :: proc(dir: string, allocator := context.allocator) -> string {
	at := dir
	for _ in 0 ..< 12 {
		if os.exists(path_join(at, "justfile")) || os.is_dir(path_join(at, "nengine")) {
			return strings.clone(at, allocator)
		}
		up := parent_dir(at)
		if up == at do break
		at = up
	}
	return strings.clone("", allocator)
}

// `dir` is `path`, or somewhere inside it.
inside :: proc(path, dir: string) -> bool {
	if path == "" do return false
	if dir == path do return true
	if path == "/" do return strings.has_prefix(dir, "/")
	return len(dir) > len(path) && strings.has_prefix(dir, path) && dir[len(path)] == '/'
}

// What the tree is built for: the game (a folder directly under the root)
// that `dir` is in, the root itself, or — outside the checkout — `dir`. When
// this changes the tree is built again; while it doesn't, moving about only
// changes which of its rows are open.
places_scope :: proc(root, dir: string, allocator := context.temp_allocator) -> string {
	if root == "" || !inside(root, dir) do return strings.clone(dir, allocator)
	rest := under(root, dir)
	if rest == "" do return strings.clone(root, allocator)
	if slash := strings.index_byte(rest, '/'); slash >= 0 do rest = rest[:slash]
	return strings.clone(path_join(root, rest, context.temp_allocator), allocator)
}

// Builds the tree for somebody standing in `dir` of the checkout at `root`.
// `all` opens every game rather than just the one `dir` is in, for the
// folder-with-the-most search that picks where a tool starts.
discover_places :: proc(out: ^[dynamic]Place, suffixes: []string, root, dir: string, all := false) {
	places_destroy(out)
	scope := places_scope(root, dir)

	if root != "" {
		top := add_place(out, file_of(root), root, 0, -1, .Root, suffixes)

		// An assets folder at the top, or one inside any folder directly below
		// it: `assets/` for a lone game, `<game>/assets/` for one of several.
		infos, err := os.read_directory_by_path(root, -1, context.temp_allocator)
		if err == nil {
			sort_by_name(infos)
			for fi in infos {
				if fi.type != .Directory || strings.has_prefix(fi.name, ".") do continue
				if skipped(fi.name) do continue
				here := path_join(root, fi.name)
				assets := path_join(here, "assets")
				open := all || scope == here
				if fi.name == "assets" {
					at := add_place(out, "assets", here, 1, top, .Game, suffixes)
					add_kids(out, at, open, suffixes)
				} else if os.is_dir(assets) {
					at := add_place(out, fi.name, assets, 1, top, .Game, suffixes)
					add_kids(out, at, open, suffixes)
				}
			}
		}

		// The engine's shipped instruments, which are the one thing that lives
		// outside a game's assets folder and still gets edited.
		if insts := path_join(root, "nengine/instruments"); os.is_dir(insts) {
			if count_below(insts, suffixes) > 0 {
				at := add_place(out, "nengine/instruments", insts, 1, top, .Game, suffixes)
				add_kids(out, at, all || scope == path_join(root, "nengine"), suffixes)
			}
		}
	}

	// Outside the checkout: where you are and what is in it, so there is still
	// a row lit and somewhere to go from it.
	if root == "" || !inside(root, dir) {
		label := dir
		if home := os.get_env("HOME", context.temp_allocator); home != "" && inside(home, dir) {
			label = strings.concatenate({"~/", under(home, dir)}, context.temp_allocator)
		}
		at := add_place(out, label, dir, 0, -1, .Elsewhere, suffixes)
		add_kids(out, at, false, suffixes, 1)
	}
}

// One row, unless that folder already has one.
@(private = "file")
add_place :: proc(out: ^[dynamic]Place, label, path: string, depth, parent: int, kind: Place_Kind, suffixes: []string) -> int {
	for p, i in out do if p.path == path do return i
	append(out, Place {
		label  = strings.clone(label),
		path   = strings.clone(path),
		depth  = depth,
		count  = count_below(path, suffixes),
		parent = parent,
		kind   = kind,
	})
	return len(out) - 1
}

// The folders inside place `at`, to the bottom when `deep`: the game you are
// in is read through once, so walking about inside it costs nothing. Not deep,
// it is only found out whether there are any — enough to draw it as closed —
// or, with `levels`, that many levels of them.
@(private = "file")
add_kids :: proc(out: ^[dynamic]Place, at: int, deep: bool, suffixes: []string, levels := 0) {
	path := strings.clone(out[at].path, context.temp_allocator)
	depth := out[at].depth
	infos, err := os.read_directory_by_path(path, -1, context.temp_allocator)
	if err != nil do return
	sort_by_name(infos)
	for fi in infos {
		if fi.type != .Directory || strings.has_prefix(fi.name, ".") || skipped(fi.name) do continue
		out[at].kids = true
		if !deep && levels <= 0 do return
		kid := add_place(out, fi.name, path_join(path, fi.name), depth + 1, at, .Folder, suffixes)
		add_kids(out, kid, deep, suffixes, levels - 1)
	}
}

// Whether a row is drawn for somebody standing in `dir`: the top rows and the
// games always, anything else when the folder it is in is one you are in.
// That is the whole of opening and closing; there is nothing to click.
place_shown :: proc(places: []Place, i: int, dir: string) -> bool {
	p := places[i]
	if p.parent < 0 do return true
	up := places[p.parent]
	return up.kind == .Root || inside(up.path, dir)
}

// Whether a row is drawn open: it is, or holds, the folder you are in, and
// its folders are on the list.
place_open :: proc(places: []Place, i: int, dir: string) -> bool {
	p := places[i]
	if !p.kids || !inside(p.path, dir) do return false
	for q in places do if q.parent == i do return true
	return false
}

@(private = "file")
sort_by_name :: proc(infos: []os.File_Info) {
	slice.sort_by(infos, proc(a, b: os.File_Info) -> bool {
		return strings.compare(a.name, b.name) < 0
	})
}

// --- Remembering where you were ---
//
// An editor that opens on the same empty folder every time is an editor you
// fight before you use. The last folder browsed is kept per tool, outside the
// repo, in the usual cache place — it is a convenience, so nothing depends on
// it being there and a failure to write it is silent.

@(private)
cache_dir :: proc(allocator := context.temp_allocator) -> string {
	if x := os.get_env("XDG_CACHE_HOME", context.temp_allocator); x != "" {
		return path_join(x, "nengine", allocator)
	}
	if home := os.get_env("HOME", context.temp_allocator); home != "" {
		return path_join(path_join(home, ".cache", context.temp_allocator), "nengine", allocator)
	}
	return ""
}

// The folder this tool was last browsing, or "" if that isn't known or the
// folder has since gone.
recall_dir :: proc(allocator := context.allocator) -> string {
	path := setting_text("dir", "")
	if path == "" || !os.is_dir(path) do return ""
	return strings.clone(path, allocator)
}

remember_dir :: proc(path: string) {
	if path != "" do setting_set_text("dir", path)
}

// Points a tool's "where the browser starts" at the folder holding `path`, so
// backing out of an editor lands on the file you were just working on rather
// than wherever the tool first guessed.
reset_dir :: proc(dir: ^string, path: string) {
	if path == "" do return
	delete(dir^)
	dir^ = strings.clone(parent_dir(abs_path(path, context.temp_allocator)))
}
