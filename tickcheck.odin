package nengine

import "core:fmt"
import "core:slice"
import "core:strings"

// Does every tick change somebody? The harness's `!ticks HH:MM` steps the
// story clock one tick at a time up to that hour and says, for each, what in
// the world is different afterwards — anyone who has appeared, gone or moved,
// a room that reads or sounds different — or that nothing is. A tick after
// which nothing has changed is a tick the player paid for and got nothing:
// a game where time is made of clues should have none.

// One line per thing that can be seen or heard, room by room.
@(private)
world_print :: proc(w: ^World, allocator := context.temp_allocator) -> []string {
	lines := make([dynamic]string, allocator)
	for &sc in w.scenes {
		refresh_scene(w, &sc)
		append(&lines, fmt.aprintf("%v | reads | %v", sc.name, sc.description, allocator = allocator))
		if sc.ambience_name != "" do append(&lines, fmt.aprintf("%v | sounds | %v", sc.name, sc.ambience_name, allocator = allocator))
		for o in sc.objects {
			if o.hidden || (o.sprite_name == "" && !o.walks) do continue // only what is drawn
			what := o.char_name if o.walks else o.sprite_name
			append(&lines, fmt.aprintf("%v | %v | %v %v at %.0f,%.0f", sc.name, o.name, what, o.rest_pose, o.pos.x, o.pos.y, allocator = allocator))
		}
	}
	slice.sort(lines[:])
	return lines[:]
}

// What is in one and not the other, as "+ ..." and "- ..." lines.
@(private)
world_diff :: proc(before, after: []string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for a in after do if !slice.contains(before, a) do append(&out, strings.concatenate({"+ ", a}, allocator))
	for b in before do if !slice.contains(after, b) do append(&out, strings.concatenate({"- ", b}, allocator))
	return out[:]
}
