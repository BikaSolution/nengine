package nengine

// Listening through a wall: a conversation the protagonist is not part of,
// heard from one place, in one window, once.
//
//     ne.overhear(w, {name = "heard_retainer", from = 17*60+25, until = 17*60+40,
//                     cost = 1, lines = RETAINER[:]}, &talk)
//
// The game puts it on the spot it is heard from — an object with a `listen`
// interaction and a `walk_to`, so the player walks to the wood stack before
// anything is heard — and words every outcome but `Heard`, because what she
// hears through canvas when nobody is talking is a line of hers.
//
// `name` is a flag, set when it is heard: rooms can read it with `when=`, it
// saves by itself, and it is what makes it once. `cost` is ticks of the story
// clock, spent before the first line. The lines are an ordinary conversation;
// give the speakers no portraits and names like "A woman" and the player hears
// voices, which is the point of a wall.
Overheard :: struct {
	name:  string,
	from:  int, // the window on the story clock, [from, until). Both 0: always
	until: int,
	cost:  int,
	lines: []Talk_Line,
}

Overhear_Outcome :: enum {
	Heard,
	Already,   // once
	Too_Early,
	Too_Late,
}

overhear :: proc(w: ^World, o: Overheard, c: ^Conversation, on_end: proc(w: ^World) = nil) -> Overhear_Outcome {
	if flag(w, o.name) do return .Already
	if o.from != 0 || o.until != 0 {
		m := clock_minute(w)
		if m < o.from do return .Too_Early
		if m >= o.until do return .Too_Late
	}
	set_flag(w, o.name, true)
	tick(w, o.cost)
	begin_conversation(w, c, o.lines, on_end)
	return .Heard
}
