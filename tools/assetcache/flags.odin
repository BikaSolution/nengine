package assetcache

import ne "../../"
import "core:slice"
import "core:strings"

// A room as a set of flags has it: a way of looking at a room, shared by the
// room editor and the cutscene editor.
//
// One room file covers five acts: the chest shut in act two and open in
// three, Elena at the desk in the afternoon and gone at night, each a line
// with a `when=`. Drawn all at once, a room like the office is five people
// standing on one spot. So a few flags are turned on, and whatever's `when=`
// does not hold under them is dimmed or hidden. Whether a condition holds is
// the engine's own reading of it (ne.condition_met), so the room shown is the
// room the game would show. Nothing is written to any file.

Flag_Mode :: enum {
	Off,  // everything drawn, whatever its when= says
	Dim,  // what does not hold is drawn faint
	Hide, // ...or not at all
}

FLAG_MODE_NAMES := [Flag_Mode]string{.Off = "off", .Dim = "dim", .Hide = "hide"}

Flag_View :: struct {
	mode:  Flag_Mode,
	world: ^ne.World, // the flags turned on, in a World of their own for ne.condition_met
}

flags_destroy :: proc(f: ^Flag_View) {
	if f.world != nil {
		for k in f.world.flags do delete(k)
		delete(f.world.flags)
		free(f.world)
	}
	f^ = {}
}

flag_is :: proc(f: ^Flag_View, name: string) -> bool {
	return f.world != nil && ne.flag(f.world, name)
}

flag_toggle :: proc(f: ^Flag_View, name: string) {
	if f.world == nil do f.world = new(ne.World)
	if f.world.flags == nil do f.world.flags = make(map[string]bool)
	if name in f.world.flags {
		f.world.flags[name] = !f.world.flags[name]
	} else {
		f.world.flags[strings.clone(name)] = true
	}
}

// Whether a `when=` holds under the flags turned on, view or no view.
condition_holds :: proc(f: ^Flag_View, cond: string) -> bool {
	if cond == "" do return true
	if f.world == nil {
		w: ne.World
		return ne.condition_met(&w, cond)
	}
	return ne.condition_met(f.world, cond)
}

// Whether a `when=` holds in the room as shown: always, with the view off.
holds :: proc(f: ^Flag_View, cond: string) -> bool {
	if f.mode == .Off do return true
	return condition_holds(f, cond)
}

Showing :: enum {
	Shown,
	Dimmed,
	Hidden,
}

showing :: proc(f: ^Flag_View, cond: string) -> Showing {
	if holds(f, cond) do return .Shown
	return .Dimmed if f.mode == .Dim else .Hidden
}

// Adds the flags a condition names to `out`, once each: `act3,!body_moved`
// names act3 and body_moved.
cond_flags :: proc(cond: string, out: ^[dynamic]string) {
	// `a,b|c` names a, b and c: `|` separates alternatives (nengine flags.odin).
	plain, _ := strings.replace_all(cond, "|", ",", context.temp_allocator)
	rest := plain
	outer: for term in strings.split_iterator(&rest, ",") {
		name := strings.trim_left(strings.trim_space(term), "!")
		if name == "" do continue
		for have in out do if have == name do continue outer
		append(out, strings.clone(name, context.temp_allocator))
	}
}

// Every flag a room's conditions name, sorted: the ones there are to turn on.
scene_flags :: proc(s: ^ne.Scene, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for o in s.objects {
		cond_flags(o.only, &out)
		for it in o.on do cond_flags(it.only, &out)
	}
	for x in s.exits do cond_flags(x.only, &out)
	for x in s.sides do cond_flags(x.only, &out)
	for t in s.triggers do cond_flags(t.only, &out)
	for sc in s.scenery do cond_flags(sc.only, &out)
	for d in s.said do cond_flags(d.only, &out)
	for a in s.ambiences do cond_flags(a.only, &out)
	slice.sort(out[:])
	return out[:]
}
