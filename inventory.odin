package nengine

import "core:strings"

// What the protagonist is carrying.
//
// A game declares the things that can be carried — a name the parser knows,
// and what it looks like — and the engine keeps which of them she has. Having
// one is a flag, `carrying_<name>`, so it saves by itself and a room can read
// it: `when=carrying_offal`.
//
//     w.items = ITEMS[:]   // {"offal", "kitchen scraps", "Scraps in a newspaper, and they smell."}
//     ne.carry(w, "offal")
//     ne.carrying(w, "offal")  // true
//     ne.lose(w, "offal")      // put down, given away, used up
//
// LOOK AT a carried thing says its description, wherever she is. PUT OFFAL ON
// THE BINS is the bins' interaction, `on bins put with=offal`: an object that
// is not in the room hands the command to the second noun's object, which is
// what makes a carried thing usable on something that is.
//
// **A thing has a picture**, which is what the inventory screen shows
// (screens.odin): a sprite called `item_<name>` (`item_offal`), found among
// the game's sprites by that name, or the sprite `icon` names when two things
// share one. A thing with no sprite yet is shown as a plain tag with its
// label on it, so nothing carried is ever invisible.
Item :: struct {
	name:        string, // the noun
	label:       string, // what it is called in a list: "kitchen scraps"
	description: string, // LOOK AT it
	icon:        string, // its picture's sprite; "" is item_<name>
}

// The sprite a thing is drawn with on the inventory screen.
item_icon :: proc(it: Item) -> string {
	if it.icon != "" do return it.icon
	return strings.concatenate({"item_", it.name}, context.temp_allocator)
}

carry :: proc(w: ^World, name: string) {
	set_flag(w, carry_flag(name), true)
}

lose :: proc(w: ^World, name: string) {
	set_flag(w, carry_flag(name), false)
}

carrying :: proc(w: ^World, name: string) -> bool {
	return flag(w, carry_flag(name))
}

// What she has, in the order the game declared them.
carried :: proc(w: ^World, allocator := context.temp_allocator) -> []Item {
	out := make([dynamic]Item, allocator)
	for it in w.items do if carrying(w, it.name) do append(&out, it)
	return out[:]
}

@(private = "file")
carry_flag :: proc(name: string) -> string {
	return strings.concatenate({"carrying_", name}, context.temp_allocator)
}
