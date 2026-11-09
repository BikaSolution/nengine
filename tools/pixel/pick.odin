package pixel

import ne "../../"
import ui "../ui"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

// The preview for a picker (ui/pick.odin) asking for art: a `.sprite` or a
// `.char`, the one file under the cursor and nothing else. An editor keeps
// one `Browse` for it and hands its address in as the picker's context:
//
//     ui.pick_open(&e.pick, "sprite", "Choose a sprite", ART_KINDS[:], dir,
//                  preview = px.art_preview, ctx = &e.pick_art)
//     ...
//     px.browse_close(&e.pick_art)   // when the picker has answered
//
// A character shows its front pose (or the first one drawn), which is the
// one a person is recognised by.

ART_KINDS := [?]ui.File_Kind {
	{suffix = ".sprite", label = "sprite", color = {120, 200, 230, 255}},
	{suffix = ".char", label = "char", color = {230, 170, 120, 255}},
}

// Just the sprites, or just the characters: ART_KINDS[:1], ART_KINDS[1:].

// For a picker's `accept`: a .sprite the size of a room (200x120 or more),
// read from the `size` line near the top of the file without its pixels.
art_is_backdrop :: proc(ctx: rawptr, path: string) -> bool {
	w, h := art_size(path)
	return w >= 200 && h >= 120
}

// A .sprite's size from its `size` line; 0, 0 if it does not say.
art_size :: proc(path: string) -> (w, h: int) {
	f, err := os.open(path)
	if err != nil do return
	defer os.close(f)
	buf: [4096]u8
	n, _ := os.read(f, buf[:])
	rest := string(buf[:n])
	for line in strings.split_lines_iterator(&rest) {
		t := strings.trim_space(line)
		if !strings.has_prefix(t, "size ") do continue
		parts := strings.fields(t, context.temp_allocator)
		if len(parts) >= 3 {
			w, _ = strconv.parse_int(parts[1])
			h, _ = strconv.parse_int(parts[2])
		}
		return
	}
	return
}

art_preview :: proc(ctx: rawptr, path: string, kind: int, area: rl.Rectangle) -> bool {
	b := cast(^Browse)ctx
	if b == nil do return false
	if b.path != path do art_fill(b, path)
	return browse_draw(b, area)
}

// Loads `path` into the pane, whichever kind of art it is.
art_fill :: proc(b: ^Browse, path: string) {
	if strings.has_suffix(path, ".char") {
		c, ok := ne.load_character(path)
		if !ok {
			browse_failed(b, path)
			return
		}
		defer ne.character_destroy(&c)
		best: ^ne.Character_Part
		drawn := 0
		for &part in c.parts {
			blank := true
			for v in part.data.pixels do if v != 0 {
				blank = false
				break
			}
			if blank do continue
			drawn += 1
			if best == nil || part.name == "front" do best = &part
		}
		if best == nil && len(c.parts) > 0 do best = &c.parts[0]
		if best == nil {
			browse_failed(b, path)
			return
		}
		browse_set(b, path, clone_data(&best.data), fmt.tprintf("%v: %v of %v poses drawn", c.name, drawn, len(c.parts)))
		return
	}
	d, ok := ne.load_sprite_data(path)
	if !ok {
		browse_failed(b, path)
		return
	}
	note := fmt.tprintf("%v frame%v", d.frames, "" if d.frames == 1 else "s")
	if d.w >= 200 && d.h >= 120 do note = "a backdrop"
	browse_set(b, path, d, note)
}
