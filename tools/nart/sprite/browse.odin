package sprite

import ne "../../../"
import px "../../pixel"
import "core:fmt"

// What the file browser says about a .sprite before you open it.

// The line in the list: enough to tell two sprites apart without opening
// either.
detail :: proc(path: string) -> string {
	d, ok := ne.load_sprite_data(path)
	if !ok do return "unreadable"
	defer ne.sprite_data_destroy(&d)
	if d.frames > 1 do return fmt.aprintf("%vx%v  %v frames", d.w, d.h, d.frames)
	return fmt.aprintf("%vx%v", d.w, d.h)
}

// Hands the preview pane the grid to draw.
fill_browse :: proc(b: ^px.Browse, path: string) {
	d, ok := ne.load_sprite_data(path)
	if !ok {
		px.browse_failed(b, path)
		return
	}
	note := "1 frame" if d.frames == 1 else fmt.tprintf("%v frames", d.frames)
	px.browse_set(b, path, d, note)
}
