package main

import ac "../assetcache"
import "core:slice"

// The room as these flags have it (assetcache/flags.odin, shared with the
// cutscene editor).
//
// One room file covers five acts: the chest is shut in act two and open in
// three, Elena is at the desk in the afternoon and gone at night, each of them
// a line with a `when=`. Drawn all at once, a room like the office is five
// people standing on one spot. So the room can be shown as a given set of
// flags has it: a few flags turned on in the room's panel, and every object,
// exit and trigger whose `when=` does not hold under them is dimmed — still
// there to click and edit — or hidden. The descriptions say which one the
// room would read. Nothing here is written to the file: the flags are a way
// of looking.

// Every flag the room's conditions name, once each, in order: the ones there
// are to turn on. Read from the lines, so it is what the file says now.
room_flags :: proc(d: ^Doc, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for _, i in d.lines {
		if d.meta[i].key == "" do continue
		ac.cond_flags(doc_field(d, i, "when"), &out)
	}
	slice.sort(out[:])
	return out[:]
}
