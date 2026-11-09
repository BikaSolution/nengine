package nengine

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

// Peeps: looking or listening through an aperture into somewhere else.
//
// A tent's mosquito net, a steam vent, a kitchen hatch, a window: the player
// stands at it and hears (and, through some, sees) people on the other side
// who do not know she is there. In a scene file an aperture is a `peep` line,
// an object in every other way, so the parser finds it by name and the player
// walks to its `walk_to` like anything else:
//
//     peep net5 pos=612,300 into=tent dress=5 kind=net blind=lamp_in_5 walk_to=612,330 reach=box:60,40 frame=net_frame
//
// `into` is the room on the far side, and `dress` which dressing of it when
// one room is worn several ways (the flag `tent_5`). `kind` picks the frame and
// whether looking gives faces: a vent, a hatch and a grating never do. `blind`
// is a condition: while it holds, the far side cannot see out, so nobody inside
// looks round and catches her. `always` and `never` are allowed.
//
// What is said at an aperture, and when, is a window the game declares:
//
//     ne.Peep_Window{name = "t5_name", peep = "net5", from = 25*60+30, until = 26*60+20,
//                    lines = T5_NAME[:], turn = 5, passer = "moore", passer_at = 5,
//                    cost = 1, on_play = heard_the_name, on_caught = caught_at_five}
//
// LISTEN AT NET5, LOOK THROUGH NET5 or PEEP NET5 walks her there and calls
// `peep`, which plays the window that holds now, once ever. Being caught is
// the window's `turn` line (somebody inside looks round, if the aperture is
// not blind) or its `passer_at` line (somebody walks past outside): the talk
// stops on that line and the game's `on_caught` says what it costs. Escape
// while it plays is leaving quietly: what was heard is kept and the rest is
// lost. There is no second hearing of anything.

Peep_Kind :: enum {
	Window,
	Net,
	Vent,
	Hatch,
	Grating,
	Door,
}

// The aperture half of an object. Zero for an object that is not one.
Peep_Info :: struct {
	is:      bool,
	into:    string, // the far room, by name
	into_at: int,    // its index, worked out at load by resolve_exits
	dress:   string, // which dressing of it: "5" is the flag `<into>_5`
	kind:    Peep_Kind,
	blind:   string, // a condition; "always" and "never" are allowed
	frame:   string, // the sprite the far half is framed by
	near:    string, // the sprite of her side of it, for the left half

	// Resolved from the assets when the scene is loaded. A missing one is a
	// zero Sprite, and the close-up draws a band instead.
	frame_art: Sprite, // `frame`, or peep_<kind>_frame
	blind_art: Sprite, // the frame's `_blind` variant: steam, a dark weave
	near_art:  Lit_Sprite, // `near`, or peep_<kind>_near, in every light her side can be in
}

// Looks up an aperture's art: the names it gives, or the kind's defaults.
peep_resolve_art :: proc(p: ^Peep_Info, a: ^Assets) {
	if a == nil do return
	frame := p.frame if p.frame != "" else fmt.tprintf("peep_%v_frame", peep_kind_name(p.kind))
	near := p.near if p.near != "" else fmt.tprintf("peep_%v_near", peep_kind_name(p.kind))
	p.frame_art = assets_sprite(a, frame)
	p.blind_art = assets_sprite(a, fmt.tprintf("%v_blind", frame))
	p.near_art = lit_sprite(a, near)
}

peep_kind_from_name :: proc(name: string) -> Peep_Kind {
	switch name {
	case "net":     return .Net
	case "vent":    return .Vent
	case "hatch":   return .Hatch
	case "grating": return .Grating
	case "door":    return .Door
	}
	return .Window
}

peep_kind_name :: proc(k: Peep_Kind) -> string {
	switch k {
	case .Window:  return "window"
	case .Net:     return "net"
	case .Vent:    return "vent"
	case .Hatch:   return "hatch"
	case .Grating: return "grating"
	case .Door:    return "door"
	}
	return "window"
}

// The flag a dressed far room is worn by: `tent_5`. "" for an undressed one.
peep_dress_flag :: proc(p: Peep_Info, allocator := context.temp_allocator) -> string {
	if p.dress == "" do return ""
	return fmt.aprintf("%v_%v", p.into, p.dress, allocator = allocator)
}

// Does this kind ever show faces? A vent is steam, a hatch is the back of a
// head, a grating is the tops of hats.
peep_kind_sees :: proc(k: Peep_Kind) -> bool {
	return k == .Window || k == .Net || k == .Door
}

@(private)
peep_condition :: proc(w: ^World, cond: string) -> bool {
	switch cond {
	case "always": return true
	case "never", "": return false
	}
	return condition_met(w, cond)
}

// --- Windows: what is said at an aperture, and when ---

Peep_Window :: struct {
	name:      string, // sets `heard_<name>` when it plays
	peep:      string, // the aperture object
	room:      string, // the room it is heard from, when two rooms have an aperture of that name; "" is any
	from:      int,    // story-clock minutes, [from, until); both 0 is any time
	until:     int,
	only:      string, // a condition: branches
	lines:     []Talk_Line,
	turn:      int,    // the line at which somebody inside looks round (0: never)
	turner:    string, // who looks; "" is the speaker of that line
	passer:    string, // who walks past outside ("": nobody)...
	passer_at: int,    // ...at which line
	blind_at:  string, // a condition that overrides the aperture's own blind
	shot:      ^Sprite, // optional painted far half (M3)
	near:      ^Lit_Sprite, // optional painted near half for this window only: her side of it, by her light
	near_who:  ^Speaker, // who talks on her side of it (the player, to herself): never faceless
	cost:      int,    // ticks, spent once when it plays
	on_play:   proc(w: ^World, lines_heard: int), // when it ends, however it ends
	on_caught: proc(w: ^World, who: string),      // after on_play, when it ends in a catch
}

Peep_Outcome :: enum {
	Played,
	Nobody,  // no window holds: the game says its line for the aperture, no tick
	Already, // heard once, which is the only time
	Too_Far, // not at the aperture
}

// The window playing now.
Peep_State :: struct {
	active:    bool,
	window:    int,    // index into World.peep_windows
	object:    string, // the aperture
	stop:      int,    // lines it plays: all of them, or up to the catching line
	caught_by: string, // who catches her at line `stop`; "" for nobody
	blind:     bool,   // the far side could not see out
	announced: bool,   // the harness has said so
}

// The flag a window sets when it plays.
peep_heard_flag :: proc(win: ^Peep_Window, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("heard_%v", win.name, allocator = allocator)
}

// The flag set by being caught at an aperture by somebody.
peep_caught_flag :: proc(peep, who: string, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("caught_%v_%v", peep, who, allocator = allocator)
}

// Is the window's hour now, and its condition true?
peep_window_open :: proc(w: ^World, win: ^Peep_Window) -> bool {
	if win.room != "" && len(w.scenes) > 0 && current_scene(w).name != win.room do return false
	if win.from != 0 || win.until != 0 {
		m := clock_minute(w)
		if m < win.from || m >= win.until do return false
	}
	return win.only == "" || condition_met(w, win.only)
}

// Can the far side see out, for this window, now?
peep_blind :: proc(w: ^World, o: ^Object, win: ^Peep_Window) -> bool {
	cond := win.blind_at if win.blind_at != "" else o.peep.blind
	return peep_condition(w, cond)
}

peeping :: proc(w: ^World) -> bool {
	return w.peeping.active
}

// LISTEN AT, LOOK THROUGH or PEEP at an aperture: plays the window that holds
// now, if there is one. The game words every outcome but Played.
peep :: proc(w: ^World, o: ^Object) -> Peep_Outcome {
	if !o.peep.is do return .Nobody
	if o.walk_to != {} && length(w.player.pos - o.walk_to) > CLOSE_ENOUGH do return .Too_Far
	heard_one := false
	for &win, i in w.peep_windows {
		if win.peep != o.name || !peep_window_open(w, &win) do continue
		if flag(w, peep_heard_flag(&win)) {
			heard_one = true
			continue
		}
		play_window(w, o, i)
		return .Played
	}
	return .Already if heard_one else .Nobody
}

@(private = "file")
play_window :: proc(w: ^World, o: ^Object, index: int) {
	win := &w.peep_windows[index]
	set_flag(w, peep_heard_flag(win)) // one hearing, ever, however it ends
	blind := peep_blind(w, o, win)

	// Who catches her, and at which line: whichever comes first, of somebody
	// inside looking round (only if they can see out) and somebody passing.
	stop, by := len(win.lines), ""
	if win.turn > 0 && !blind && win.turn <= stop {
		stop = win.turn
		by = win.turner
		if by == "" && win.lines[win.turn - 1].who != nil do by = win.lines[win.turn - 1].who.name
	}
	if win.passer != "" && win.passer_at > 0 && win.passer_at <= stop && (win.passer_at < stop || by == "") {
		stop, by = win.passer_at, win.passer
	}
	w.peeping = {active = true, window = index, object = o.name, stop = stop, caught_by = by, blind = blind}
	tick(w, win.cost)
	if stop <= 0 {
		end_window(w, 0)
		return
	}
	lines := win.lines[:stop]
	// Heard and not seen: the same lines, said by "a man" and "a woman" with
	// no faces. Each speaker keeps one voice for the whole window.
	if blind || !peep_kind_sees(o.peep.kind) do lines = faceless(w, lines, win.near_who)
	begin_conversation(w, &w.peep_talk, lines, window_read, window_left)
}

// Read to the end of what it played.
@(private = "file")
window_read :: proc(w: ^World) {
	end_window(w, w.peeping.stop, caught = true)
}

// Escape while it played: she stepped away. What was heard is kept, nobody
// caught her, the rest is lost, and it still counts as the one hearing.
@(private = "file")
window_left :: proc(w: ^World) {
	heard := min(w.peep_talk.at + 1, w.peeping.stop)
	end_window(w, heard)
}

@(private = "file")
faceless :: proc(w: ^World, lines: []Talk_Line, near_who: ^Speaker = nil) -> []Talk_Line {
	clear(&w.peep_lines)
	seen: [len(w.peep_voices)]^Speaker
	n := 0
	for line in lines {
		l := line
		// Her side of the aperture is not behind it: the window's `near_who`
		// keeps her name and face ("to herself" at a dark window is still her).
		if line.who != nil && (near_who == nil || line.who != near_who) {
			slot := -1
			for i in 0 ..< n do if seen[i] == line.who do slot = i
			if slot < 0 && n < len(seen) {
				slot = n
				seen[n] = line.who
				name := line.who.unseen if line.who.unseen != "" else "a voice"
				w.peep_voices[n] = Speaker{name = name, side = line.who.side}
				n += 1
			}
			if slot >= 0 do l.who = &w.peep_voices[slot]
		}
		append(&w.peep_lines, l)
	}
	return w.peep_lines[:]
}

@(private = "file")
end_window :: proc(w: ^World, heard: int, caught := false) {
	st := w.peeping
	w.peeping.active = false
	clear(&w.peep_lines)
	if st.window < 0 || st.window >= len(w.peep_windows) do return
	win := &w.peep_windows[st.window]
	if win.on_play != nil do win.on_play(w, heard)
	if caught && st.caught_by != "" {
		who := strings.to_lower(st.caught_by, context.temp_allocator)
		set_flag(w, peep_caught_flag(st.object, who))
		w.peep_caught_by = st.caught_by
		w.peep_caught_at = st.stop
		if win.on_caught != nil do win.on_caught(w, who)
	}
}

// Is this command a peep verb aimed at an aperture? LISTEN (at, to, through),
// PEEP, SEARCH and LOOK THROUGH; plain LOOK AT is its description.
peep_command_here :: proc(w: ^World, scene: ^Scene, cmd: Command) -> ^Object {
	if cmd.noun == "" do return nil
	// "look through" is one of SEARCH's own phrasings, so SEARCH at an
	// aperture is looking through it too.
	is_verb := cmd.verb == "listen" || cmd.verb == "peep" || cmd.verb == "search" || (cmd.verb == "look" && cmd.prep == "through")
	if !is_verb do return nil
	o := object_here(scene, cmd.noun)
	if o == nil || !o.peep.is do return nil
	return o
}

// Runs a peep verb and words what the game does not.
@(private)
do_peep :: proc(w: ^World, o: ^Object) {
	outcome := peep(w, o)
	if w.on_peep != nil {
		w.on_peep(w, o, outcome)
		return
	}
	switch outcome {
	case .Played:
	case .Nobody:
		log_gap(w, "peep-nobody")
		say(w, "Nobody is talking.")
	case .Already: say(w, "There is nothing more to hear.")
	case .Too_Far: say(w, "You would have to be standing at it.")
	}
}

// --- The split close-up ---
//
// While a window plays, the screen is two halves: her side of the aperture
// on the left (`near`, a 160x200 picture), and on the right the far room in
// its own light, as it is now, with whoever its `when=` lines put there,
// through the kind's frame. A window may paint its far half instead (`shot`).
// Heard and not seen, the far half is shapes, and the frame is the kind's
// blind one. A missing picture is a band, never a crash.

// What the close-up shows, worked out without drawing, so a test can ask.
Peep_View :: struct {
	near:     Sprite, // her side; a zero Sprite is a band
	far_shot: Sprite, // a painted far half, drawn instead of the room
	far_room: int,    // the room on the far side; -1 for none
	dress:    string, // the flag it is worn by, or ""
	light:    Light,  // the far room's own light
	frame:    Sprite, // over the far half; a zero Sprite is no frame
	faces:    bool,   // the far half is seen; false is shapes and voices
}

peep_view :: proc(w: ^World) -> (v: Peep_View, ok: bool) {
	if !w.peeping.active || w.peeping.window < 0 || w.peeping.window >= len(w.peep_windows) do return {}, false
	o := find_object(current_scene(w), w.peeping.object)
	if o == nil do return {}, false
	win := &w.peep_windows[w.peeping.window]
	v.faces = !w.peeping.blind && peep_kind_sees(o.peep.kind)
	// Her side is drawn in the light of the room she stands in: a net at
	// night is `closeup_ada_net.night`, and a light not painted borrows.
	near := win.near^ if win.near != nil else o.peep.near_art
	v.near = near.by[room_light(w, current_scene(w))]
	if win.shot != nil do v.far_shot = win.shot^
	v.far_room = o.peep.into_at if o.peep.into != "" else -1
	if v.far_room >= len(w.scenes) do v.far_room = -1
	v.dress = peep_dress_flag(o.peep)
	if v.far_room >= 0 do v.light = room_light(w, &w.scenes[v.far_room])
	// A painted far half is the picture the window is meant to be seen
	// as, so it wears the plain frame; the room itself, unseen, the blind one.
	seen := v.faces || v.far_shot.texture.id != 0
	v.frame = o.peep.frame_art if seen && o.peep.frame_art.texture.id != 0 else o.peep.blind_art
	return v, true
}

// The flat band a missing half is drawn as.
PEEP_BAND :: 1 // dark blue, BEGA

// Draws the close-up into the canvas. False if no window is playing.
@(private)
draw_peep :: proc(w: ^World) -> bool {
	v, ok := peep_view(w)
	if !ok do return false
	band := room_height(current_scene(w))
	half := f32(WIDTH) / 2

	// Her side.
	if v.near.texture.id != 0 {
		draw_sprite(v.near, 0, {half / 2, band})
	} else {
		rl.DrawRectangle(0, 0, i32(half), i32(band), BEGA[PEEP_BAND])
	}

	// The far side: painted, or the room itself in its own light, the middle
	// of it, through the frame.
	switch {
	case v.far_shot.texture.id != 0:
		draw_sprite(v.far_shot, 0, {half + half / 2, band})
	case v.far_room >= 0:
		draw_far_room(w, v, half, band)
	case:
		rl.DrawRectangle(i32(half), 0, i32(half), i32(band), BEGA[PEEP_BAND])
	}
	if v.frame.texture.id != 0 do draw_sprite(v.frame, 0, {half + half / 2, band})
	rl.DrawRectangle(i32(half) - 2, 0, 4, i32(band), rl.BLACK) // the seam
	rl.DrawRectangle(0, i32(band), WIDTH, HEIGHT - i32(band), rl.BLACK)
	return true
}

@(private = "file")
draw_far_room :: proc(w: ^World, v: Peep_View, half, band: f32) {
	ride_draw_setup() // the ride's offscreen canvas and recolouring; nobody rides while she peeps
	sc := &w.scenes[v.far_room]
	if v.dress == "" {
		draw_room_offscreen(w, sc, v, half, band)
		return
	}
	// A room worn several ways is worn this way while it is drawn: the
	// dressing's flag on and its siblings (the same name, another number) off,
	// for this room only, and then put back.
	if v.dress not_in w.flags do set_flag(w, v.dress, false) // a key that lives as long as the flags do
	prefix := v.dress[:strings.last_index_byte(v.dress, '_') + 1]
	saved := make([dynamic]string, context.temp_allocator)
	for name, on in w.flags do if on && strings.has_prefix(name, prefix) && name != v.dress do append(&saved, name)
	had := w.flags[v.dress]
	for name in saved do w.flags[name] = false
	w.flags[v.dress] = true
	refresh_scene(w, sc)
	draw_room_offscreen(w, sc, v, half, band)
	for name in saved do w.flags[name] = true
	w.flags[v.dress] = had
	refresh_scene(w, sc)
}

@(private = "file")
draw_room_offscreen :: proc(w: ^World, sc: ^Scene, v: Peep_View, half, band: f32) {
	rl.EndTextureMode() // out of the canvas, into the ride's offscreen one
	rl.BeginTextureMode(ride_world_tex)
	rl.ClearBackground(rl.BLACK)
	draw_room(w, sc, false)
	rl.EndTextureMode()
	begin_canvas()

	// The middle of the room, into the right half.
	src := rl.Rectangle{(f32(WIDTH) - half) / 2, f32(HEIGHT) - band, half, -band}
	dst := rl.Rectangle{half, 0, half, band}
	if v.faces {
		rl.DrawTexturePro(ride_world_tex.texture, src, dst, {}, 0, rl.WHITE)
		return
	}
	// Shapes: everything down to two darks, the way a lit room looks from a
	// dark place through steam or a net.
	draw_mapped_rect(ride_world_tex, palette_map_tones({0, 8}), src, dst)
}
