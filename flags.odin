package nengine

import "core:strings"

// Flags, and the conditions that read them.
//
// A flag is a name the game turns on: "act3", "found_body", "gate_locked".
// The engine never sets one and never knows what any of them mean. What it
// does is let the contents of a scene depend on them, so that a room can
// change between acts without being a second copy of the room.
//
//     ne.set_flag(w, "act3", true)
//
//     obj shoe pos=210,180 when=act3
//     obj elena char=elena when=act2
//     desc when=act4 Cold.
//
// A condition is a comma-separated list of flag names, all of which must be
// on, and a name may be negated with `!`:
//
//     when=act3              during act three
//     when=act3,!body_moved  during act three, until the bodies are moved
//     (nothing)              always
//
// That is the whole language, on purpose. Anything that needs more than "all
// of these, none of those" is a decision, and decisions belong in game code
// where they can be read.

set_flag :: proc(w: ^World, name: string, on := true) {
	if name == "" do return
	if w.flags == nil do w.flags = make(map[string]bool)
	if _, had := w.flags[name]; had {
		w.flags[name] = on
	} else {
		w.flags[strings.clone(name)] = on
	}
	// What is in a room depends on the flags, so changing one changes the
	// rooms. Doing it here means a game can never forget to.
	// Live: a person this changes, in the room she is in, can walk off or on
	// through a side (side.odin) rather than go or come at once.
	w.flag_live = true
	refresh_world(w)
	w.flag_live = false
}

flag :: proc(w: ^World, name: string) -> bool {
	return w.flags[name] or_else false
}

// Turns one of a set of flags on and the rest off. For the states a game is
// only ever in one of at a time, which is most of them: an act, a time of
// day, whose side somebody has come down on.
//
//     ne.set_only(w, "act3", {"act1", "act2", "act3", "act4", "act5"})
set_only :: proc(w: ^World, on: string, group: []string) {
	for name in group do set_flag(w, name, name == on)
	set_flag(w, on, true)
}

// **One room, worn several ways.** Six tents built from the same plan are six
// near-identical rooms, and a doorway moved in six files ends up different in
// two of them. So a game builds one tent and *dresses* it: `tent_3` on, every
// other `tent_*` off, and the room's own `when=tent_3` lines put the luggage
// in. Entering flap three is `ne.dress(w, "tent", "3")`.
//
// No declaration and no count: every flag that begins `<group>_` is part of
// the group — so a group's name has to be its own. Awards set flags of their
// own names, and an award called `fire_warden` would be taken off by dressing
// the fire. Name groups for the room they dress and name awards for what was
// found, and they do not meet. And no game state either — flags go into saves by themselves, so
// the dressing a room was wearing comes back with a restore and a game has
// nothing of its own to keep.
dress :: proc(w: ^World, group, which: string) {
	prefix := strings.concatenate({group, "_"}, context.temp_allocator)
	wanted := strings.concatenate({prefix, which}, context.temp_allocator)
	// Collect first: set_flag refreshes the world, and a map should not be
	// written to while it is being walked.
	off := make([dynamic]string, context.temp_allocator)
	for name, on in w.flags {
		if on && name != wanted && strings.has_prefix(name, prefix) do append(&off, name)
	}
	for name in off do set_flag(w, name, false)
	set_flag(w, wanted, true)
}

// Which dressing a group is wearing — the part after `<group>_` — or "".
dressing :: proc(w: ^World, group: string) -> string {
	prefix := strings.concatenate({group, "_"}, context.temp_allocator)
	for name, on in w.flags {
		if on && strings.has_prefix(name, prefix) do return name[len(prefix):]
	}
	return ""
}

// True the first time it is asked about a name, and never again — because it
// sets the flag. For the line said in full once and shortly after that, which
// is most refusals worth writing:
//
//     if ne.first_time(w, "refused_a_name") do ne.say(w, LONG) else do ne.say(w, SHORT)
//
// It is a flag, so it saves, and a restored game does not repeat itself.
first_time :: proc(w: ^World, name: string) -> bool {
	if flag(w, name) do return false
	set_flag(w, name, true)
	return true
}

// Every trigger in the game that a checkpoint should fire: set the state, and
// the rooms follow. Named for what it is used for rather than what it does,
// because "the act turned" is the thing a game means.
checkpoint :: proc(w: ^World, name: string) {
	set_flag(w, name, true)
}

clear_flags :: proc(w: ^World) {
	for name in w.flags do delete(name)
	delete(w.flags)
	w.flags = nil
}

// Is this condition satisfied right now? An empty condition always is, which
// is what makes `when=` optional on everything.
condition_met :: proc(w: ^World, cond: string) -> bool {
	if cond == "" do return true
	// `a,b|c`: all of a and b, or else c. Without a `|`, one set of terms.
	if strings.index_byte(cond, '|') >= 0 {
		alts := cond
		for alt in strings.split_iterator(&alts, "|") {
			if strings.trim_space(alt) == "" do continue
			if all_met(w, alt) do return true
		}
		return false
	}
	return all_met(w, cond)
}

// Every comma-separated term of `cond` holds: a name is on, `!name` is off.
@(private = "file")
all_met :: proc(w: ^World, cond: string) -> bool {
	rest := cond
	for term in strings.split_iterator(&rest, ",") {
		name := strings.trim_space(term)
		if name == "" do continue
		if strings.has_prefix(name, "!") {
			if flag(w, name[1:]) do return false
		} else if !flag(w, name) {
			return false
		}
	}
	return true
}

// Every flag that is on, as a sorted, comma-separated line — for putting in a
// save, and for reading one back.
flags_text :: proc(w: ^World, allocator := context.temp_allocator) -> string {
	names := make([dynamic]string, context.temp_allocator)
	for name, on in w.flags do if on do append(&names, name)
	// Sorted, so a save file doesn't churn on the whim of a hash table.
	for i in 1 ..< len(names) {
		v := names[i]
		j := i - 1
		for j >= 0 && strings.compare(names[j], v) > 0 {
			names[j + 1] = names[j]
			j -= 1
		}
		names[j + 1] = v
	}
	joined, _ := strings.join(names[:], ",", allocator)
	return joined
}

set_flags_text :: proc(w: ^World, text: string) {
	clear_flags(w)
	rest := text
	for term in strings.split_iterator(&rest, ",") {
		if name := strings.trim_space(term); name != "" do set_flag(w, name, true)
	}
	refresh_world(w)
}
