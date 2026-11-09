package ui

import "core:os"
import "core:strings"
import "core:testing"

// The browser is a window and can't be tested here, but everything it stands
// on is plain string and filesystem work, and that is where its bugs were.

@(test)
parent_dir_walks_up_and_stops :: proc(t: ^testing.T) {
	testing.expect_value(t, parent_dir("/a/b/c"), "/a/b")
	testing.expect_value(t, parent_dir("/a"), "/")
	// The top must answer itself, or "go up" loops forever.
	testing.expect_value(t, parent_dir("/"), "/")
	testing.expect_value(t, parent_dir(""), "")
}

@(test)
path_join_never_doubles_the_slash :: proc(t: ^testing.T) {
	testing.expect_value(t, path_join("/a/b", "c"), "/a/b/c")
	testing.expect_value(t, path_join("/a/b/", "c"), "/a/b/c")
	testing.expect_value(t, path_join("/", "c"), "/c")
	testing.expect_value(t, path_join("", "c"), "c")
}

@(test)
ext_and_file_split_the_last_part :: proc(t: ^testing.T) {
	testing.expect_value(t, ext_of("assets/sprites/lamp.sprite"), ".sprite")
	testing.expect_value(t, ext_of("assets/LAMP.SPRITE"), ".sprite") // case doesn't matter
	testing.expect_value(t, ext_of("assets/sprites/lamp"), "")
	// A dot in a folder name is not an extension on the file.
	testing.expect_value(t, ext_of("a.b/lamp"), "")
	testing.expect_value(t, file_of("/a/b/lamp.sprite"), "lamp.sprite")
	testing.expect_value(t, file_of("lamp.sprite"), "lamp.sprite")
}

@(test)
under_shortens_only_what_is_inside :: proc(t: ^testing.T) {
	testing.expect_value(t, under("/home/p", "/home/p/assets/x.sprite"), "assets/x.sprite")
	testing.expect_value(t, under("/home/p", "/home/p"), "")
	// Outside the root it must come back whole, or the breadcrumbs claim a
	// folder belongs to a project it has nothing to do with.
	testing.expect_value(t, under("/home/p", "/tmp/x.sprite"), "/tmp/x.sprite")
	testing.expect_value(t, under("", "/tmp/x.sprite"), "/tmp/x.sprite")
}

@(test)
kind_of_prefers_the_longest_suffix :: proc(t: ^testing.T) {
	suffixes := [?]string{".sound", ".song"}
	testing.expect_value(t, kind_of("thud.sound", suffixes[:]), 0)
	testing.expect_value(t, kind_of("theme.song", suffixes[:]), 1)
	testing.expect_value(t, kind_of("notes.txt", suffixes[:]), -1)

	// ".char" must not lose to a shorter suffix that also matches the tail.
	two := [?]string{".ar", ".char"}
	testing.expect_value(t, kind_of("ada.char", two[:]), 1)
}

@(test)
size_text_is_short_and_rounds_up :: proc(t: ^testing.T) {
	testing.expect_value(t, size_text(0), "0 B")
	testing.expect_value(t, size_text(412), "412 B")
	testing.expect_value(t, size_text(1024), "1.0 K")
	testing.expect_value(t, size_text(1024 * 1024), "1.0 M")
	// Rounding a whisker under the next unit must not print "1024.0 K".
	testing.expect_value(t, size_text(1024 * 1024 - 1), "1024 K")
}

@(test)
free_name_skips_what_is_already_there :: proc(t: ^testing.T) {
	dir := temp_dir(t, "free_name")
	defer os.remove_all(dir)

	testing.expect_value(t, free_name(dir, "lamp.sprite"), "lamp 2.sprite")
	write(t, path_join(dir, "lamp 2.sprite"), "x")
	testing.expect_value(t, free_name(dir, "lamp.sprite"), "lamp 3.sprite")
	// A name with no extension keeps its shape too.
	testing.expect_value(t, free_name(dir, "lamp"), "lamp 2")
}

@(test)
listing_a_folder_keeps_only_what_was_asked_for :: proc(t: ^testing.T) {
	dir := temp_dir(t, "list_dir")
	defer os.remove_all(dir)
	write(t, path_join(dir, "lamp.sprite"), "x")
	write(t, path_join(dir, "ada.char"), "x")
	write(t, path_join(dir, "notes.txt"), "x")
	if os.make_directory(path_join(dir, "deeper")) != nil do return
	write(t, path_join(dir, "deeper/hat.sprite"), "x")

	entries: [dynamic]Entry
	defer {
		entries_destroy(&entries)
		delete(entries)
	}
	suffixes := [?]string{".sprite"}
	list_dir(&entries, dir, suffixes[:])

	// The folder, and the one sprite beside it. Not the .char, not the .txt,
	// and not the sprite one level down — that one you walk to.
	names := make(map[string]bool, 8, context.temp_allocator)
	for e in entries do names[e.name] = e.dir
	testing.expect_value(t, len(entries), 2)
	testing.expect(t, "lamp.sprite" in names, "the sprite is listed")
	testing.expect(t, "deeper" in names, "the folder is listed")
	testing.expect(t, names["deeper"], "the folder knows it is one")
	testing.expect(t, !("notes.txt" in names), "a file of another kind is left out")
}

@(test)
searching_reaches_into_subfolders :: proc(t: ^testing.T) {
	dir := temp_dir(t, "list_tree")
	defer os.remove_all(dir)
	if os.make_directory(path_join(dir, "a")) != nil do return
	if os.make_directory(path_join(dir, "a/b")) != nil do return
	write(t, path_join(dir, "top.sprite"), "x")
	write(t, path_join(dir, "a/mid.sprite"), "x")
	write(t, path_join(dir, "a/b/deep.sprite"), "x")
	write(t, path_join(dir, "a/b/ignored.txt"), "x")

	entries: [dynamic]Entry
	defer {
		entries_destroy(&entries)
		delete(entries)
	}
	suffixes := [?]string{".sprite"}
	list_tree(&entries, dir, suffixes[:])
	testing.expect_value(t, len(entries), 3)

	// Found files are named by the path you'd have to walk, so two files of
	// the same name in different folders stay apart in the list.
	found := false
	for e in entries do if e.name == "a/b/deep.sprite" do found = true
	testing.expect(t, found, "a file three deep is named by its path")

	testing.expect_value(t, count_below(dir, suffixes[:]), 3)
	testing.expect_value(t, count_below(path_join(dir, "a"), suffixes[:]), 2)
}

@(test)
folders_lead_whichever_way_the_sort_runs :: proc(t: ^testing.T) {
	list := [?]Entry {
		{name = "zeta.sprite", size = 10, mtime = 300},
		{name = "beta", dir = true},
		{name = "alpha.sprite", size = 90, mtime = 100},
		{name = "aardvark", dir = true},
	}

	sort_entries(list[:], .Name)
	testing.expect_value(t, list[0].name, "aardvark")
	testing.expect_value(t, list[1].name, "beta")
	testing.expect_value(t, list[2].name, "alpha.sprite")

	sort_entries(list[:], .Size)
	testing.expect(t, list[0].dir && list[1].dir, "folders still lead")
	testing.expect_value(t, list[2].name, "alpha.sprite") // biggest first

	// Reversing turns the files round and leaves the folders where they are,
	// because a folder is how you leave, not something you are ranking.
	sort_entries(list[:], .Size, true)
	testing.expect(t, list[0].dir && list[1].dir, "folders are not reversed into the middle")
	testing.expect_value(t, list[2].name, "zeta.sprite")
}

@(test)
examples_is_counted_by_nobody :: proc(t: ^testing.T) {
	dir := temp_dir(t, "skipped")
	defer os.remove_all(dir)
	if os.make_directory(path_join(dir, "examples")) != nil do return
	write(t, path_join(dir, "examples/theirs.sprite"), "x")
	write(t, path_join(dir, "ours.sprite"), "x")

	suffixes := [?]string{".sprite"}
	// Other people's repositories must not drag a tool's opening folder off
	// to a checkout of somebody else's game.
	testing.expect_value(t, count_below(dir, suffixes[:]), 1)

	entries: [dynamic]Entry
	defer {
		entries_destroy(&entries)
		delete(entries)
	}
	list_tree(&entries, dir, suffixes[:])
	testing.expect_value(t, len(entries), 1)
	testing.expect_value(t, entries[0].name, "ours.sprite")
}

@(test)
inside_means_inside_not_merely_a_prefix :: proc(t: ^testing.T) {
	testing.expect(t, inside("/a/game", "/a/game"), "a folder is inside itself")
	testing.expect(t, inside("/a/game", "/a/game/assets/x"), "below")
	// `game_v2` starts with `game` and is not in it: the old game and the new
	// one would both light up for either.
	testing.expect(t, !inside("/a/game", "/a/game_v2"), "a longer name is not inside")
	testing.expect(t, inside("/", "/tmp"), "everything is under /")
	testing.expect(t, !inside("", "/tmp"), "nothing is under nothing")
}

@(test)
the_scope_is_the_game_you_are_in :: proc(t: ^testing.T) {
	testing.expect_value(t, places_scope("/r", "/r/game_v2/assets/scenes/admin"), "/r/game_v2")
	testing.expect_value(t, places_scope("/r", "/r/game_v2"), "/r/game_v2")
	testing.expect_value(t, places_scope("/r", "/r"), "/r")
	// Outside the checkout it is wherever you are.
	testing.expect_value(t, places_scope("/r", "/tmp/x"), "/tmp/x")
}

@(test)
places_open_the_game_you_are_in_and_close_the_rest :: proc(t: ^testing.T) {
	root := temp_dir(t, "places")
	defer os.remove_all(root)
	write(t, path_join(root, "justfile"), "")
	for d in ([?]string{
		"old", "old/assets", "old/assets/sprites", "old/assets/scenes", "old/assets/scenes/hall",
		"new", "new/assets", "new/assets/sprites", "new/assets/scenes", "new/assets/scenes/hall",
		"new/assets/scenes/yard", "new/assets/scenes/hall/props", "new/play",
		"nengine",
	}) {
		if os.make_directory(path_join(root, d)) != nil do testing.fail_now(t, "could not make a folder")
	}
	write(t, path_join(root, "old/assets/sprites/a.sprite"), "x")
	write(t, path_join(root, "new/assets/sprites/b.sprite"), "x")
	write(t, path_join(root, "new/assets/scenes/hall/c.sprite"), "x")

	suffixes := [?]string{".sprite"}
	places: [dynamic]Place
	defer {
		places_destroy(&places)
		delete(places)
	}
	here := path_join(root, "new/assets/scenes/hall")
	discover_places(&places, suffixes[:], root, here)

	find :: proc(places: []Place, path: string) -> int {
		for p, i in places do if p.path == path do return i
		return -1
	}
	top := find(places[:], root)
	old := find(places[:], path_join(root, "old/assets"))
	new := find(places[:], path_join(root, "new/assets"))
	hall := find(places[:], here)
	testing.expect(t, top >= 0 && old >= 0 && new >= 0 && hall >= 0, "the root, both games and the hall are there")
	if top < 0 || old < 0 || new < 0 || hall < 0 do return

	// A game is one row, named for the game, not "assets".
	testing.expect_value(t, places[new].label, "new")
	testing.expect_value(t, places[new].kind, Place_Kind.Game)
	testing.expect_value(t, places[top].count, 3)
	testing.expect_value(t, places[new].count, 2)

	// The game you are in is read through; the other is a closed row that
	// knows it has folders inside it.
	testing.expect(t, find(places[:], path_join(root, "old/assets/sprites")) < 0, "the old game is not opened")
	testing.expect(t, places[old].kids, "but it can be")
	testing.expect(t, find(places[:], path_join(root, "new/assets/scenes/hall/props")) >= 0, "the new one is read to the bottom")
	// A folder that is not anybody's assets is not a place.
	testing.expect(t, find(places[:], path_join(root, "new/play")) < 0, "new/play is not a place")
	testing.expect(t, find(places[:], path_join(root, "nengine")) < 0, "nor is nengine without instruments")

	// What is drawn: the way down to here, open; everything off it, closed.
	shown :: proc(places: []Place, path, dir: string) -> bool {
		for p, i in places do if p.path == path do return place_shown(places, i, dir)
		return false
	}
	testing.expect(t, shown(places[:], path_join(root, "old/assets"), here), "other games stay reachable")
	testing.expect(t, shown(places[:], path_join(root, "new/assets/sprites"), here), "this game's top folders")
	testing.expect(t, shown(places[:], path_join(root, "new/assets/scenes/yard"), here), "the folders beside here")
	testing.expect(t, shown(places[:], path_join(root, "new/assets/scenes/hall/props"), here), "and inside it")
	testing.expect(t, place_open(places[:], new, here), "the game is drawn open")
	testing.expect(t, place_open(places[:], hall, here), "so is here")
	testing.expect(t, !place_open(places[:], old, here), "the other game is drawn closed")

	// Walking up inside the game closes what you left without building again.
	up := path_join(root, "new/assets/sprites")
	testing.expect(t, !shown(places[:], path_join(root, "new/assets/scenes/hall/props"), up), "left behind, closed")
	testing.expect(t, shown(places[:], path_join(root, "new/assets/scenes"), up), "still a top folder")

	// Into the other game: built again, the other way round.
	there := path_join(root, "old/assets/scenes")
	discover_places(&places, suffixes[:], root, there)
	testing.expect(t, find(places[:], path_join(root, "old/assets/scenes/hall")) >= 0, "the old game opened")
	testing.expect(t, find(places[:], path_join(root, "new/assets/sprites")) < 0, "the new one closed")
}

@(test)
somewhere_outside_the_checkout_is_still_a_place :: proc(t: ^testing.T) {
	root := temp_dir(t, "places_root")
	defer os.remove_all(root)
	away := temp_dir(t, "places_away")
	defer os.remove_all(away)
	write(t, path_join(root, "justfile"), "")
	if os.make_directory(path_join(away, "inner")) != nil do testing.fail_now(t, "could not make a folder")

	suffixes := [?]string{".sprite"}
	places: [dynamic]Place
	defer {
		places_destroy(&places)
		delete(places)
	}
	discover_places(&places, suffixes[:], root, away)
	last := places[len(places) - 2] // the folder, then the one inside it
	testing.expect_value(t, last.path, away)
	testing.expect_value(t, last.kind, Place_Kind.Elsewhere)
	testing.expect_value(t, places[len(places) - 1].path, path_join(away, "inner"))
	testing.expect_value(t, places[0].path, root) // and the checkout is still there
}

// --- Scaffolding ---

@(private = "file")
temp_dir :: proc(t: ^testing.T, name: string) -> string {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" do base = "/tmp"
	dir := path_join(base, strings.concatenate({"nengine-test-", name}, context.temp_allocator))
	os.remove_all(dir)
	if err := os.make_directory(dir); err != nil {
		testing.fail_now(t, "could not make a temporary folder")
	}
	return dir
}

@(private = "file")
write :: proc(t: ^testing.T, path, text: string) {
	if os.write_entire_file(path, transmute([]u8)text) != nil {
		testing.fail_now(t, "could not write a test file")
	}
}
