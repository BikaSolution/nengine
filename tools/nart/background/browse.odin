package background

import ne "../../../"
import px "../../pixel"
import "core:fmt"

// What the file browser says about a backdrop before you open it. Same file
// format as a sprite, so the difference is what's worth saying about it: not
// how many frames (there is one), but which room uses it.

detail :: proc(path: string) -> string {
	d, ok := ne.load_sprite_data(path)
	if !ok do return "unreadable"
	defer ne.sprite_data_destroy(&d)
	return fmt.aprintf("backdrop  %vx%v", d.w, d.h)
}

fill_browse :: proc(b: ^px.Browse, path: string) {
	d, ok := ne.load_sprite_data(path)
	if !ok {
		px.browse_failed(b, path)
		return
	}
	// Which room it belongs to is the thing you want to know, and the thing a
	// list of files cannot tell you.
	r: Room
	defer room_close(&r)
	room_find(&r, path)
	note := "no room uses it yet"
	if r.ok do note = fmt.tprintf("%v: %v objects, %v exits", r.name, len(r.objects), len(r.exits))
	px.browse_set(b, path, d, note)
}
