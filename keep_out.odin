package nengine

import "core:fmt"

// Keeping her out: a room the story has people in, for a few minutes, that
// the game cannot draw without giving the case away. A gate shuts one way
// between two rooms; this shuts a whole room, from every side and every door
// into it, for a window on the story clock, with a line that turns her back.
//
//     w.keep_outs = KEEP_OUTS[:]
//
//     KEEP_OUTS := [?]ne.Keep_Out {
//         {room = "fuel_store", from = 17*60+36, until = 17*60+48, out_by = "south",
//          text = "Voices behind the store, kept low. It can finish without me.",
//          out  = "Voices, close. I'll come back."},
//     }
//
// While one holds (`from` <= the clock < `until`, both 0 for any hour, and
// its `only=` condition):
//
//   - **every way in refuses**: a side (try_side) or a door (check_exits)
//     that leads into the room stops her at its brink and says `text`, as a
//     shut gate does; GO TO <room> from next door walks her to the brink and
//     is told. A gate shut on the same side speaks first.
//   - **if she is in it** when it starts to hold, the screen being hers (no
//     conversation, ride, cutscene, announcement or overlay up), she says
//     `out` (or `text`) once and walks out by the side `out_by` names, or
//     the nearest open side, or failing that an open door; over the brink,
//     she is in the next room. Sent somewhere else on the way, she is turned
//     round and sent out again, without the line again (keep_out_step).
//   - **the developer is let through**: TELEPORT, or the harness's `!room`,
//     into a kept room takes her there and says so; she is not put out while
//     she stays (`keep_out_let`).
//
// The window is minutes on the story clock, not a flag, on purpose: a flag
// turning on is a change the clock stops at (clock.odin's `turn`), and a
// keep-out must not add turns to anybody's night. A keep-out keyed on the
// game's own flag (`only =`) costs nothing either, since the flag already
// turns.
Keep_Out :: struct {
	room:   string, // the room kept, by name
	from:   int,    // the window on the story clock, [from, until): both 0 for any hour
	until:  int,
	only:   string, // and this condition (flags.odin); "" for none
	text:   string, // said at the way in: what turns her back
	out:    string, // said if she is in the room as it shuts: then she goes; "" says `text`
	out_by: string, // the side she goes out by: "north", "south", ...; "" the nearest open
}

// What keeps her out of room `i` now, if anything: the first that holds.
kept_out :: proc(w: ^World, i: int) -> ^Keep_Out {
	if i < 0 || i >= len(w.scenes) || len(w.keep_outs) == 0 do return nil
	name := w.scenes[i].name
	m := clock_minute(w)
	for &k in w.keep_outs {
		if k.room != name do continue
		if (k.from != 0 || k.until != 0) && (m < k.from || m >= k.until) do continue
		if !condition_met(w, k.only) do continue
		return &k
	}
	return nil
}

// The developer's way in (TELEPORT, `!room`): into room `i` whatever keeps
// her out, and left there. True if something would have.
keep_out_let_through :: proc(w: ^World, i: int) -> bool {
	if kept_out(w, i) == nil do return false
	w.keep_out_let = w.scenes[i].name
	return true
}

// The room she is in has been shut on her, and the screen is hers: what shut
// it, or nil. Not while she has been let in (and that lapses once she is out).
keep_out_due :: proc(w: ^World) -> ^Keep_Out {
	if len(w.scenes) == 0 || w.current < 0 || w.current >= len(w.scenes) do return nil
	here := current_scene(w).name
	if w.keep_out_let != "" && w.keep_out_let != here do w.keep_out_let = ""
	k := kept_out(w, w.current)
	if k == nil {
		w.keep_out_going = false
		return nil
	}
	if w.keep_out_let == here do return nil
	if w.dead || talking(w) || riding(w) || cutting(w) || announcing(w) || overlay_open(w) do return nil
	return k
}

// Once a frame (update): put out of a room shut on her, on her own feet.
keep_out_step :: proc(w: ^World) {
	if k := keep_out_due(w); k != nil do put_out(w, k, walk = true)
}

// Out of the room `k` keeps: the line once, then over the way out, walking
// to it (`walk`) or at once (the harness, a test). True if she was sent or
// taken somewhere; false if she is already on her way, or there is no way out.
put_out :: proc(w: ^World, k: ^Keep_Out, walk: bool) -> bool {
	side, door := keep_out_way(w, k)
	p := &w.player
	if walk && side >= 0 && w.exit_walk.side.active && w.exit_walk.side.side == side && p.target == w.exit_walk.side.spot do return false
	if walk && door != "" && w.door_walk.active && w.door_walk.exit == door && p.target == w.door_walk.spot do return false
	if !w.keep_out_going {
		w.keep_out_going = true
		text := k.out if k.out != "" else k.text
		if text != "" do say(w, text)
	}
	sc := current_scene(w)
	switch {
	case side >= 0:
		if walk && head_for_side_at(w, side) do return true
		cross(w, side)
		return true
	case door != "":
		if walk do return head_for_exit(w, door)
		for e in sc.exits {
			if e.name != door do continue
			go_to(w, e.to, e.arrive)
			if w.on_arrive != nil do w.on_arrive(w)
			return true
		}
	}
	return false
}

// The way out of a kept room: the side `out_by` names if it is open, else the
// open side nearest her, else an open door. An open way is one that is there
// (`when=`), not shut by its gate, and not into another kept room.
@(private)
keep_out_way :: proc(w: ^World, k: ^Keep_Out) -> (side: int, door: string) {
	sc := current_scene(w)
	open :: proc(w: ^World, s: ^Side) -> bool {
		return !s.hidden && !gate_shut(w, s.gate) && kept_out(w, s.to) == nil
	}
	if d, ok := compass_of(k.out_by); ok {
		for &s, i in sc.sides do if s.dir == d && open(w, &s) do return i, ""
	}
	best, far := -1, f32(1e30)
	for &s, i in sc.sides {
		if !open(w, &s) do continue
		b, ok := side_brink(sc, s.dir, clamp(along(s.dir, w.player.pos), s.span[0], s.span[1]))
		if !ok do continue
		v := b - w.player.pos
		if d := v.x * v.x + v.y * v.y; d < far do best, far = i, d
	}
	if best >= 0 do return best, ""
	for e in sc.exits {
		if e.hidden || e.closed || kept_out(w, e.to) != nil do continue
		return -1, e.name
	}
	return -1, ""
}

// The harness's frame for it (script.odin's run_on): out at once, the line
// and where she went printed. True if she went.
@(private)
keep_out_aloud :: proc(w: ^World) -> bool {
	k := keep_out_due(w)
	if k == nil do return false
	from := current_scene(w).name
	before := w.keep_out_going
	if !put_out(w, k, walk = false) do return false
	if !before {
		text := k.out if k.out != "" else k.text
		if text != "" do fmt.printfln("  %v", text)
	}
	fmt.printfln("  [kept out of %v: to %v at %.0f,%.0f]", from, current_scene(w).name, w.player.pos.x, w.player.pos.y)
	return true
}
