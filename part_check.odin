package nengine

import "core:fmt"

// Every part a world names, checked against the .char it will wear: a person
// line's `pose=` and `walk=`, a routine's `play`, a cut's `hold` and `play`. A
// misspelt part is otherwise silent: a `walk=` nobody drew falls back to the
// plain walk, and a held pose nobody drew draws nobody. For a game's own
// tests, over the files as read (no pictures loaded):
//
//     for f in ne.part_faults(w.scenes[:], cuts[:], chars) do testing.expectf(t, false, "%v", f)
//
// A part counts when it, or a version of it for one facing, is in the file.
// A line or cast member whose .char is not there at all is not this check's.
part_faults :: proc(scenes: []Scene, cuts: []Cutscene, chars: map[string]Character, allocator := context.temp_allocator) -> [dynamic]string {
	out := make([dynamic]string, allocator)
	for &sc in scenes {
		for &o in sc.objects {
			if !o.walks do continue
			c, has := chars[o.char_name]
			if !has do continue
			if o.rest_pose != "" && !char_has_part(&c, o.rest_pose) {
				append(&out, fmt.aprintf("%v: %v pose=%v: %v.char has no such part", sc.name, o.name, o.rest_pose, o.char_name, allocator = allocator))
			}
			if o.rest_walk != "" && !char_has_part(&c, o.rest_walk) {
				append(&out, fmt.aprintf("%v: %v walk=%v: %v.char has no such part", sc.name, o.name, o.rest_walk, o.char_name, allocator = allocator))
			}
			for st in o.routine.steps {
				if st.kind == .Play && !char_has_part(&c, st.pose) {
					append(&out, fmt.aprintf("%v: step %v play %v: %v.char has no such part", sc.name, o.name, st.pose, o.char_name, allocator = allocator))
				}
			}
		}
	}
	for &cut in cuts {
		room: ^Scene
		for &sc in scenes do if sc.name == cut.scene do room = &sc
		for q in cut.cues {
			if (q.action != .Hold && q.action != .Play) || q.text == "" do continue
			i := cutscene_member(&cut, q.who)
			if i < 0 do continue
			key := cut_wears(cut.people[i], room)
			c, has := chars[key]
			if !has do continue
			if !char_has_part(&c, q.text) {
				verb := "hold" if q.action == .Hold else "play"
				append(&out, fmt.aprintf("%v.cut: %v %v %v: %v.char has no such part", cut.name, q.who, verb, q.text, key, allocator = allocator))
			}
		}
	}
	return out
}

// The .char a cast member wears, read from the files as cast_art reads the
// world: their `char=`, else that of a person of their name in the cut's room,
// else their own name.
@(private = "file")
cut_wears :: proc(m: Cast_Member, room: ^Scene) -> string {
	if m.character != "" do return m.character
	if room != nil {
		for o in room.objects do if o.walks && o.name == m.name && o.char_name != "" do return o.char_name
	}
	return m.name
}

// The part, or a version of it for one facing.
@(private = "file")
char_has_part :: proc(c: ^Character, name: string) -> bool {
	if character_part(c, name) != nil do return true
	for f in Facing do if character_part(c, pose_turned(name, f)) != nil do return true
	return false
}
