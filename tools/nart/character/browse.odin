package character

import ne "../../../"
import px "../../pixel"
import "core:fmt"

// What the file browser says about a .char before you open it.

detail :: proc(path: string) -> string {
	c, ok := ne.load_character(path)
	if !ok do return "unreadable"
	defer ne.character_destroy(&c)
	drawn := 0
	for &part in c.parts do if part_drawn(&part) do drawn += 1
	return fmt.aprintf("%vx%v  %v/%v poses", c.w, c.h, drawn, len(c.parts))
}

fill_browse :: proc(b: ^px.Browse, path: string) {
	c, ok := ne.load_character(path)
	if !ok {
		px.browse_failed(b, path)
		return
	}
	defer ne.character_destroy(&c)

	drawn := 0
	best: ^ne.Character_Part
	for &part in c.parts {
		if !part_drawn(&part) do continue
		drawn += 1
		// Front first, then whatever else has been drawn: a character sheet
		// is recognisable by its front pose and not much else.
		if best == nil || part.name == "front" do best = &part
	}
	if best == nil && len(c.parts) > 0 do best = &c.parts[0]
	if best == nil {
		px.browse_failed(b, path)
		return
	}
	px.browse_set(b, path, px.clone_data(&best.data), fmt.tprintf("%v of %v poses drawn", drawn, len(c.parts)))
}

// Any pixel that isn't palette index 0. A pose nobody has touched is all
// zeroes, and showing a blank square as the preview helps nobody.
@(private)
part_drawn :: proc(part: ^ne.Character_Part) -> bool {
	for v in part.data.pixels do if v != 0 do return true
	return false
}
