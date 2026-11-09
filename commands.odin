package nengine

import "core:strconv"

// The mechanical half of the standard verbs.
//
// The engine ships LOOK, SAVE, RESTORE and the rest as words, and a game
// decides what they say — because the reply to "look at the fire" is a line of
// the protagonist's, and a game where the replies are the engine's is a game
// with nobody in it. But the *work* behind those words is the same in every
// game, and a game that has to write it again gets it wrong in the same way
// every time. So the work is here and the wording is not:
//
//     case "look":
//         if !ne.look_command(w, cmd) do ne.say(w, "There's no such thing here.")
//
//     case "save", "restore":
//         outcome, slot := ne.slot_command(w, cmd, title)
//         switch outcome { ...a line of hers for each... }

// LOOK: the room, with no noun; an object or a piece of scenery, with one.
// False only if there is nothing here by that name, so the game can say so in
// its own voice.
//
// Scenery is the trap this closes. It is painted into the backdrop and is not
// an object, and a game's LOOK that only checked its own switch answered "you
// can't see that here" for half of every room. It happened in this engine's
// first game; lessons.md has it.
look_command :: proc(w: ^World, cmd: Command) -> bool {
	scene := current_scene(w)
	if cmd.noun == "" {
		say(w, scene_description(w, scene))
		return true
	}
	if text, found := describe(scene, cmd.noun); found {
		say(w, text)
		return true
	}
	// Something she is carrying, which is here because she is.
	for it in w.items {
		if it.name == cmd.noun && carrying(w, it.name) {
			say(w, it.description)
			return true
		}
	}
	return false
}

// What SAVE or RESTORE came to. The engine does the saving; the game says how
// it went, and each of these wants a different line.
Slot_Outcome :: enum {
	No_Slot,      // "save" with no number, or a number that is not a slot
	Saved,
	Not_Saved,    // the disk said no
	Nothing_There,
	Restored,
	Not_Restored, // there was a file and it would not read
}

// The numbered slot a noun names, or 0. The digits are in the standard
// vocabulary so that "save 3" parses; this only turns the word back into a
// number, and refuses one that is not a slot the player owns.
slot_of :: proc(noun: string) -> int {
	n, ok := strconv.parse_int(noun)
	if !ok || n < 1 || n > SAVE_SLOTS do return 0
	return n
}

// SAVE n or RESTORE n. `title` is what the slot list shows for it — the hour
// in a game with a story clock, the room name in one without.
slot_command :: proc(w: ^World, cmd: Command, title := "") -> (outcome: Slot_Outcome, slot: int) {
	slot = slot_of(cmd.noun)
	if slot == 0 do return .No_Slot, 0
	return slot_act(w, cmd.verb == "save", slot, title), slot
}

// SAVE or RESTORE, once the slot is known: what slot_command does with the
// number, and what the Save and Load screens do with a click (screens.odin),
// so the two cannot come to disagree. Saving is into the player's own eight
// only; restoring may be from the autosaves too, which is what the Load
// screen lists and a typed number cannot reach.
slot_act :: proc(w: ^World, save: bool, slot: int, title := "") -> Slot_Outcome {
	owned := slot >= 1 && slot <= SAVE_SLOTS
	if save {
		if !owned do return .No_Slot
		return .Saved if save_game(w, slot, title) else .Not_Saved
	}
	if !owned && slot != AUTOSAVE && slot != AUTOSAVE_PREVIOUS do return .No_Slot
	if !save_exists(w, slot) do return .Nothing_There
	return .Restored if load_game(w, slot) else .Not_Restored
}
