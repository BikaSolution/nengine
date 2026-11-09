package nengine

import "core:math"
import rl "vendor:raylib"

// Seeing through something else's eyes.
//
// The protagonist goes under wherever she is standing, and the screen becomes
// what a *host* is looking at — an animal, a camera on a pole, a ghost, a
// sister's power the next game has not named yet. She is a passenger. The host
// looks at what it wants, in its own order, on a loop the player can learn and
// cannot steer: that loop is the mechanic.
//
//     ne.Host{
//         name      = "stoat",                  // the noun: RIDE STOAT
//         from      = 20 * 60, until = 28 * 60, // on the story clock: 20:00 to 04:00
//         camera    = {zoom = 1.6, tilt = -4, sway = 6},
//         colours   = ne.palette_map_tones({0, 1, 8, 7, 15}, 2.2),
//         attention = STOAT_LOOKS[:],
//     }
//
//     STOAT_LOOKS := [?]ne.Glance{
//         {look = "beam", room = "tent_row", at = {520, 300}, secs = 3, line = "Along the beam."},
//         {look = "moth", room = "tent_row", at = {700, 250}, secs = 4},
//     }
//
// What the engine does: checks the host is here and awake, records where the
// body was left, takes the screen down (her own view greys and tilts, and the
// host's dissolves up through it — the handover is always seen, so the player
// always knows the body is where it was), runs the loop, and brings her back.
// Each glance may say a line, once a ride. A glance marked `leaves` is the host
// breaking off: a raised voice, a moth, a shot.
//
// While riding, WAIT moves on to the next glance, STAND, WAKE and EXIT come
// back, LOOK says again what this glance is, and anything else goes to the
// game's `on_ride_command` — which is where a game says what its power cannot
// do. The people in the room she is looking at go on with their routines; so
// do the people in the room her body is in.
//
// What is the game's: which hosts there are, what they look at, what riding
// costs (`ne.tick` after `ne.ride` returns `.Started`), what she says going
// under and coming back (`on_ride_end`), and what her body being *there* means
// — `ride_body` says where it was left, and saves say it too.
//
// **Colours stay inside the palette.** A host's `colours` maps each of the
// sixteen bEGA colours to another of them, so a near-monochrome night view is
// still sixteen-colour art. `palette_map_tones` builds one from a few tones and
// a sensitivity. Anything not in bEGA is taken to its nearest first.

Host :: struct {
	name:      string,       // the noun, and an object in the room by that name
	only:      string,       // condition, as `when=` on anything in a scene
	from:      int,          // story-clock minutes it can be ridden: [from, until).
	until:     int,          // Both 0: any time. May run past 1440.
	anywhere:  bool,         // needs no object in the room: a scripted ride
	room:      string,       // "": any room with an object by its name. Set, only that room —
	                         // the same animal in two places, looking at two things
	camera:    Ride_Camera,
	colours:   Palette_Map,  // zero value is the identity — see palette_map_same
	attention: []Glance,
}

// What the host looks at, and for how long.
Glance :: struct {
	look:   string,  // a name for it: the harness prints it, a game may test it
	room:   string,  // the scene it is looking into; "" is the room the body is in
	at:     [2]f32,  // canvas point in that scene the view centres on
	secs:   f32,
	line:   string,  // said the first time this glance comes round in a ride
	zoom:   f32,     // 0: the host's own
	leaves: bool,    // when it is over, the ride is over
	only:   string,  // a condition: a glance that is false is skipped, so a
	                 // loop can look into tent three only while somebody is in it
	on_look: proc(w: ^World), // each time it comes round: what seeing it finds
}

// How a host sees: how close, at what angle, and how much it cannot keep still.
Ride_Camera :: struct {
	zoom: f32, // 1 is the room as the player sees it; less than 1 is taken as 1
	tilt: f32, // degrees
	sway: f32, // canvas pixels of drift
}

// A colour transform that cannot leave the palette: for each bEGA colour, in
// BEGA order, the index of the colour it becomes.
Palette_Map :: [16]u8

Ride_Phase :: enum {
	None,
	Going,  // her view greys and tilts, and the host's comes up through it
	Riding,
	Coming, // the same, backwards
}

Ride_Outcome :: enum {
	Started,
	Unknown,  // no host by that name
	Not_Here, // a host, but not in this room
	Not_Now,  // here, but asleep, away, or ruled out by its condition
	Already,  // riding already
}

Ride :: struct {
	phase:     Ride_Phase,
	host:      int,     // into w.hosts
	glance:    int,
	t:         f32,     // into the phase, or into the glance while riding
	cam:       [2]f32,  // where the view is centred, easing towards the glance
	cam_room:  int,
	said:      u64,     // glances whose line has been said this ride

	// Where the body was left, last time. Kept after the ride, and saved:
	// a game's third act may want to know.
	has_body:  bool,
	body_room: int,
	body_pos:  [2]f32,
}

@(private) GOING_SECS :: f32(1.6)
@(private) COMING_SECS :: f32(1.2)

// Goes under, if the host can be ridden. The game words every outcome.
ride :: proc(w: ^World, name: string) -> Ride_Outcome {
	if riding(w) do return .Already
	// A host may be declared more than once — the same animal at different
	// hours, or in a moment only a scene makes — and the first declaration
	// that is here and awake is the one ridden. Otherwise the nearest miss.
	outcome := Ride_Outcome.Unknown
	i := -1
	for &h, k in w.hosts {
		if h.name != name do continue
		switch {
		case len(h.attention) == 0 || (!h.anywhere && object_here(current_scene(w), name) == nil),
		     h.room != "" && h.room != current_scene(w).name:
			if outcome == .Unknown do outcome = .Not_Here
		case !host_awake(w, &h):
			outcome = .Not_Now
		case:
			i = k
		}
		if i >= 0 do break
	}
	if i < 0 do return outcome
	h := &w.hosts[i]

	p := &w.player
	cancel_approach(w)
	if w.after_anim.active {
		actor_stop_anim(p)
		run_after_anim(w) // what the gesture was for happens before she goes under
	}
	actor_stop_anim(p)
	w.exit_walk = {}
	p.moving, p.heading = false, {}
	w.ride = {
		phase     = .Going,
		host      = i,
		has_body  = true,
		body_room = w.current,
		body_pos  = p.pos,
	}
	g := h.attention[next_glance(w, h, -1)]
	w.ride.cam, w.ride.cam_room = g.at, glance_room(w, g)
	return .Started
}

riding :: proc(w: ^World) -> bool {
	return w.ride.phase != .None
}

// The host being ridden, or nil.
ride_host :: proc(w: ^World) -> ^Host {
	if !riding(w) do return nil
	return &w.hosts[w.ride.host]
}

// What it is looking at now, or nil while going under or coming back.
ride_glance :: proc(w: ^World) -> ^Glance {
	if w.ride.phase != .Riding do return nil
	return &ride_host(w).attention[w.ride.glance]
}

// Where the body was left the last time she went under.
ride_body :: proc(w: ^World) -> (room: string, pos: [2]f32, ok: bool) {
	if !w.ride.has_body || w.ride.body_room >= len(w.scenes) do return "", {}, false
	return w.scenes[w.ride.body_room].name, w.ride.body_pos, true
}

// Can it be ridden now? Its condition, and its hours on the story clock.
host_awake :: proc(w: ^World, h: ^Host) -> bool {
	if !condition_met(w, h.only) do return false
	if h.from == 0 && h.until == 0 do return true
	m := clock_minute(w)
	return m >= h.from && m < h.until
}

host_index :: proc(w: ^World, name: string) -> (int, bool) {
	for h, i in w.hosts do if h.name == name do return i, true
	return 0, false
}

// Starts back. Also what STAND, WAKE and EXIT do while riding.
come_back :: proc(w: ^World) {
	if w.ride.phase == .Going || w.ride.phase == .Riding {
		w.ride.phase, w.ride.t = .Coming, 0
	}
}

// --- Palette maps ---

palette_map_same :: proc() -> (m: Palette_Map) {
	for i in 0 ..< 16 do m[i] = u8(i)
	return
}

// Each colour becomes whichever of `tones` is nearest it in lightness, after
// its lightness is multiplied by `gain`. Tones {0, 8, 7, 15} and a gain of 1
// is plain greyscale; a gain above 1 is an eye that sees more than we do.
palette_map_tones :: proc(tones: []u8, gain: f32 = 1) -> (m: Palette_Map) {
	if len(tones) == 0 do return palette_map_same()
	for c, i in BEGA {
		want := min(lightness(c) * gain, 1)
		best, dist := tones[0], f32(2)
		for t in tones {
			if d := abs(lightness(BEGA[t]) - want); d < dist do best, dist = t, d
		}
		m[i] = best
	}
	return
}

// Perceived lightness, 0..1: relative luminance, brought back towards how an
// eye grades it.
@(private)
lightness :: proc(c: rl.Color) -> f32 {
	l := linear_of(c)
	return math.pow(0.2126 * l[0] + 0.7152 * l[1] + 0.0722 * l[2], 1 / 2.2)
}

// The map a host actually uses: its own, or the identity if it gave none.
@(private)
host_map :: proc(h: ^Host) -> Palette_Map {
	if h.colours == {} do return palette_map_same()
	return h.colours
}

// --- Running it ---

@(private)
update_ride :: proc(w: ^World, dt: f32) {
	// A glance that comes round by itself is the ride's own row in the play log.
	w.log.source = "(ride)"
	defer w.log.source = ""
	r := &w.ride
	h := ride_host(w)
	r.t += dt

	switch r.phase {
	case .None:
	case .Going:
		if r.t >= GOING_SECS do begin_glance(w, next_glance(w, h, -1))
	case .Riding:
		g := &h.attention[r.glance]
		// Ease towards what it is looking at: a head turning, not a cut.
		r.cam += (g.at - r.cam) * min(1, dt * 3)
		if r.t >= g.secs {
			if g.leaves {
				come_back(w)
			} else {
				begin_glance(w, next_glance(w, h, r.glance))
			}
		}
	case .Coming:
		if r.t >= COMING_SECS do end_ride(w)
	}

	// Life goes on where she is looking, and where she is sitting.
	update_people(w, current_scene(w), dt)
	if r.phase != .None && r.cam_room != w.current do update_people(w, &w.scenes[r.cam_room], dt)
}

@(private)
begin_glance :: proc(w: ^World, i: int) {
	r := &w.ride
	g := ride_host(w).attention[i]
	r.phase, r.glance, r.t = .Riding, i, 0
	// A different room is a cut, because there is no turning a head into it.
	if room := glance_room(w, g); room != r.cam_room do r.cam, r.cam_room = g.at, room
	if g.line != "" && i < 64 && (r.said & (1 << uint(i))) == 0 {
		r.said |= 1 << uint(i)
		say(w, g.line)
	}
	if g.on_look != nil do g.on_look(w)
}

// The glance after `after` whose condition holds, going round. -1 is the
// start. If none holds, the one after anyway: a host always looks somewhere.
@(private)
next_glance :: proc(w: ^World, h: ^Host, after: int) -> int {
	n := len(h.attention)
	for k in 1 ..= n {
		i := (after + k) %% n
		if condition_met(w, h.attention[i].only) do return i
	}
	return (after + 1) %% n
}

@(private)
end_ride :: proc(w: ^World) {
	h := w.ride.host
	broke_off := false
	if w.ride.phase == .Coming && w.ride.glance < len(w.hosts[h].attention) {
		broke_off = w.hosts[h].attention[w.ride.glance].leaves
	}
	w.ride.phase = .None
	if w.on_ride_end != nil do w.on_ride_end(w, &w.hosts[h], broke_off)
}

// Commands while riding. The parser still runs — the player types, as ever —
// but the only things a passenger can do are wait and leave.
@(private)
ride_command :: proc(w: ^World, cmd: Command) {
	switch cmd.verb {
	case "wait":
		if w.ride.phase == .Riding {
			h := ride_host(w)
			g := h.attention[w.ride.glance]
			if g.leaves {
				come_back(w)
			} else {
				begin_glance(w, next_glance(w, h, w.ride.glance))
			}
		}
		return
	case "stand", "wake", "exit":
		come_back(w)
		return
	case "look":
		if cmd.noun == "" {
			if g := ride_glance(w); g != nil && g.line != "" {
				say(w, g.line)
				return
			}
		}
	}
	if w.on_ride_command != nil && w.on_ride_command(w, cmd) do return
	log_gap(w, "ride-refused")
	say(w, "You can only wait, or come back.")
}

// For the harness, which has no frames: whatever transition is under way,
// finish it now.
@(private)
settle_ride :: proc(w: ^World) {
	switch w.ride.phase {
	case .Going:
		begin_glance(w, next_glance(w, ride_host(w), -1))
	case .Coming:
		end_ride(w)
	case .None, .Riding:
	}
}

@(private)
glance_room :: proc(w: ^World, g: Glance) -> int {
	if g.room != "" {
		if i, ok := scene_index(w, g.room); ok do return i
	}
	return w.ride.body_room
}

// --- Drawing it ---

@(private) ride_world_tex: rl.RenderTexture2D
@(private) ride_view_tex: rl.RenderTexture2D
@(private) ride_shader: rl.Shader

// Each pixel becomes the colour its nearest palette colour is mapped to, and
// only the pixels under `amount` on a 4x4 ordered pattern are drawn at all —
// so one view dissolves into another in the palette's own dither rather than
// in a blend it could not show.
@(private)
RIDE_SHADER :: `#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
uniform sampler2D texture0;
uniform vec3 from[16];
uniform vec3 to[16];
uniform float amount;
uniform float cell;
out vec4 finalColor;
const float bayer[16] = float[16](0.,8.,2.,10.,12.,4.,14.,6.,3.,11.,1.,9.,15.,7.,13.,5.);
void main() {
	ivec2 p = ivec2(floor(gl_FragCoord.xy / cell)) & 3;
	if ((bayer[p.y * 4 + p.x] + 0.5) / 16.0 > amount) discard;
	vec4 c = texture(texture0, fragTexCoord);
	int best = 0;
	float bd = 1e9;
	for (int i = 0; i < 16; i++) {
		vec3 d = c.rgb - from[i];
		float dd = dot(d, d);
		if (dd < bd) { bd = dd; best = i; }
	}
	finalColor = vec4(to[best], c.a);
}`

@(private)
ride_draw_setup :: proc() {
	if ride_shader.id != 0 do return
	ride_world_tex = rl.LoadRenderTexture(WIDTH, HEIGHT)
	ride_view_tex = rl.LoadRenderTexture(WIDTH, HEIGHT)
	rl.SetTextureFilter(ride_world_tex.texture, .POINT)
	rl.SetTextureFilter(ride_view_tex.texture, .POINT)
	ride_shader = rl.LoadShaderFromMemory(nil, RIDE_SHADER)
}

@(private)
ride_draw_shutdown :: proc() {
	if ride_shader.id == 0 do return
	rl.UnloadRenderTexture(ride_world_tex)
	rl.UnloadRenderTexture(ride_view_tex)
	rl.UnloadShader(ride_shader)
	ride_shader = {}
}

// A frame while riding: both views into their own textures, then composed on
// the canvas through the shader, then the prompt and the box over the top.
@(private)
draw_ride :: proc(w: ^World) {
	ride_draw_setup()
	r := &w.ride
	h := ride_host(w)

	// How far the handover has got: 0 is her own eyes, 1 is the host's.
	handover := f32(1)
	switch r.phase {
	case .Going:  handover = r.t / GOING_SECS
	case .Coming: handover = 1 - r.t / COMING_SECS
	case .None, .Riding:
	}
	handover = clamp(handover, 0, 1)
	grey := clamp(handover / 0.35, 0, 1)        // her view greys first
	shown := clamp((handover - 0.4) / 0.6, 0, 1) // then the host's comes up

	if handover < 1 {
		// Her own room, tilting as she goes.
		tilt := rl.Camera2D{offset = {f32(WIDTH) / 2, f32(HEIGHT) / 2}, target = {f32(WIDTH) / 2, f32(HEIGHT) / 2}, rotation = grey * 8, zoom = 1}
		draw_room_through(w, current_scene(w), true, tilt, ride_world_tex)
	}
	if shown > 0 do draw_host_view(w, h)

	begin_canvas()
	rl.ClearBackground(rl.BLACK)
	src := rl.Rectangle{0, 0, f32(WIDTH), -f32(HEIGHT)}
	if handover < 1 {
		rl.DrawTextureRec(ride_world_tex.texture, src, {}, rl.WHITE)
		greys := palette_map_tones({0, 8, 7, 15})
		draw_mapped(ride_world_tex, greys, grey)
	}
	if shown > 0 do draw_mapped(ride_view_tex, host_map(h), shown)
	// A tilted camera spills the room into the band under the picture, and a
	// host's colours would turn the band itself blue. After both, keep it black.
	band := i32(room_height(current_scene(w)))
	rl.DrawRectangle(0, band, WIDTH, HEIGHT - band, rl.BLACK)
	draw_ui(w)
	if w.overlay.draw != nil do w.overlay.draw(w)
	draw_announcement(w) // one marked in_ride, over the host's view
	end_canvas(w.shake, w.time)
}

@(private)
draw_mapped :: proc(tex: rl.RenderTexture2D, m: Palette_Map, amount: f32) {
	if amount <= 0 do return
	from, to: [16][3]f32
	for c, i in BEGA {
		from[i] = {f32(c.r), f32(c.g), f32(c.b)} / 255
		t := BEGA[m[i] & 15]
		to[i] = {f32(t.r), f32(t.g), f32(t.b)} / 255
	}
	a, cell := amount, f32(WIDTH) / 320 // one art pixel
	s := ride_shader
	rl.SetShaderValueV(s, rl.GetShaderLocation(s, "from"), &from, .VEC3, 16)
	rl.SetShaderValueV(s, rl.GetShaderLocation(s, "to"), &to, .VEC3, 16)
	rl.SetShaderValue(s, rl.GetShaderLocation(s, "amount"), &a, .FLOAT)
	rl.SetShaderValue(s, rl.GetShaderLocation(s, "cell"), &cell, .FLOAT)
	rl.BeginShaderMode(s)
	rl.DrawTextureRec(tex.texture, {0, 0, f32(WIDTH), -f32(HEIGHT)}, {}, rl.WHITE)
	rl.EndShaderMode()
}

// The same, fully, for one rectangle of the texture drawn into another of the
// canvas. A peep's far half, as shapes. See peep.odin.
@(private)
draw_mapped_rect :: proc(tex: rl.RenderTexture2D, m: Palette_Map, src, dst: rl.Rectangle) {
	from, to: [16][3]f32
	for c, i in BEGA {
		from[i] = {f32(c.r), f32(c.g), f32(c.b)} / 255
		t := BEGA[m[i] & 15]
		to[i] = {f32(t.r), f32(t.g), f32(t.b)} / 255
	}
	a, cell := f32(1), f32(WIDTH) / 320
	s := ride_shader
	rl.SetShaderValueV(s, rl.GetShaderLocation(s, "from"), &from, .VEC3, 16)
	rl.SetShaderValueV(s, rl.GetShaderLocation(s, "to"), &to, .VEC3, 16)
	rl.SetShaderValue(s, rl.GetShaderLocation(s, "amount"), &a, .FLOAT)
	rl.SetShaderValue(s, rl.GetShaderLocation(s, "cell"), &cell, .FLOAT)
	rl.BeginShaderMode(s)
	rl.DrawTexturePro(tex.texture, src, dst, {}, 0, rl.WHITE)
	rl.EndShaderMode()
}

// The room the host is looking into, through its camera, into ride_view_tex.
// Her body is drawn if it is in that room — the player should always be able
// to find it.
@(private)
draw_host_view :: proc(w: ^World, h: ^Host) {
	r := &w.ride
	sc := &w.scenes[r.cam_room]
	room_h := room_height(sc)

	zoom := max(h.camera.zoom, 1)
	if g := ride_glance(w); g != nil && g.zoom > 0 do zoom = max(g.zoom, 1)
	drift := h.camera.sway * [2]f32{math.sin(w.time * 1.3), math.cos(w.time * 0.9)}

	// Keep the view inside the picture: a host cannot see past the edge of
	// what was painted.
	half := [2]f32{f32(WIDTH) / 2, room_h / 2} / zoom
	at := r.cam + drift
	at.x = clamp(at.x, half.x, f32(WIDTH) - half.x)
	at.y = clamp(at.y, half.y, room_h - half.y)

	cam := rl.Camera2D {
		offset   = {f32(WIDTH) / 2, room_h / 2},
		target   = at,
		rotation = h.camera.tilt + math.sin(w.time * 0.7) * h.camera.sway * 0.1,
		zoom     = zoom,
	}
	draw_room_through(w, sc, r.cam_room == r.body_room, cam, ride_view_tex)
}

// A room seen through a camera that tilts and zooms, into `into`. Each sprite
// is drawn through it the way the blown-up pictures were (sprite_camera), so
// it turns and zooms with every art pixel where it always was.
@(private)
draw_room_through :: proc(w: ^World, sc: ^Scene, player: bool, cam: rl.Camera2D, into: rl.RenderTexture2D) {
	rl.BeginTextureMode(into)
	rl.ClearBackground(rl.BLACK)
	rl.BeginMode2D(cam)
	sprite_camera = true
	draw_room(w, sc, player)
	sprite_camera = false
	rl.EndMode2D()
	rl.EndTextureMode()
}

// How tall the picture of a room is. Below it is the band the prompt lives in.
@(private)
room_height :: proc(sc: ^Scene) -> f32 {
	if sc.background.texture.id != 0 do return f32(sc.background.frame_h)
	return f32(HEIGHT)
}

// --- Saving where the body was ---

@(private)
ride_save :: proc(w: ^World, s: ^Save) {
	room, pos, ok := ride_body(w)
	if !ok do return
	save_put(s, "body", room)
	save_put_int(s, "body_x", int(pos.x))
	save_put_int(s, "body_y", int(pos.y))
}

@(private)
ride_load :: proc(w: ^World, s: ^Save) {
	w.ride = {}
	if i, ok := scene_index(w, save_text(s, "body")); ok {
		w.ride.has_body, w.ride.body_room = true, i
		w.ride.body_pos = {save_f32(s, "body_x"), save_f32(s, "body_y")}
	}
}
