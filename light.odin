package nengine

import "core:strings"
import rl "vendor:raylib"

// Light: the four a room is painted in.
//
// A room is not dimmed as the clock runs. It is painted again for each light
// it is seen in, and the right painting is shown:
//
//     pool_deck.sprite           day
//     pool_deck.sunset.sprite    the sun low, shadows long one way
//     pool_deck.night.sprite     the moon, or the lamps
//     pool_deck.sunrise.sprite   the sun low, shadows long the other way
//
// The same goes for any sprite an object wears: `sprite=lamp_glow` looks for
// `lamp_glow.night` at night. A lamp is then nothing by day, a little at dusk
// and a pool of light at midnight, because somebody painted it so. Objects
// marked `glow` are drawn as painted in every light.
//
// A painting that is missing falls back: sunrise to sunset, then either to
// day. Whatever is drawn from a fallback — and every person, who is never
// repainted — goes through the game's tint for that room and light
// (`World.light_tint`), so a room half-painted still reads as evening, and
// people stand in the light they are in. The tint is for people: keep it
// gentle, and paint the rooms.
//
// **The light outside is latched.** The game says what the light is
// (`World.light_now`, from its clock). Indoors the player sees that, always.
// Outdoors the light they see changes only when they come in from, or go out
// to, a room marked `indoors` — so nobody stands on a lawn and watches it go
// dark — or when the game cuts on purpose with `relight` (a sleep, a boat
// going dark). If they stay outdoors long enough for the light to be two
// behind, the next doorway between two outdoor rooms catches it up.

Light :: enum u8 {
	Day,
	Sunset,
	Night,
	Sunrise,
}

// The file-name suffix for a light's painting: "" for day.
LIGHT_SUFFIX := [Light]string {
	.Day     = "",
	.Sunset  = ".sunset",
	.Night   = ".night",
	.Sunrise = ".sunrise",
}

// A picture in every light, with the fallbacks already filled in, and which
// of them were actually painted.
Lit_Sprite :: struct {
	by:      [Light]Sprite,
	painted: bit_set[Light],
}

// The light a missing painting borrows.
light_fallback :: proc(l: Light) -> Light {
	switch l {
	case .Sunrise: return .Sunset
	case .Sunset, .Night, .Day: return .Day
	}
	return .Day
}

// Looks up `name` and its painted versions.
lit_sprite :: proc(a: ^Assets, name: string) -> (ls: Lit_Sprite) {
	for l in Light {
		key := strings.concatenate({name, LIGHT_SUFFIX[l]}, context.temp_allocator)
		if s, ok := a.sprites[key]; ok {
			ls.by[l] = s
			ls.painted += {l}
		}
	}
	fill_fallbacks(&ls.by, ls.painted)
	return
}

// Missing lights borrow, in an order that lets a borrowed one be borrowed
// again: sunrise takes sunset's, which may be day's.
fill_fallbacks :: proc(by: ^[Light]$T, painted: bit_set[Light]) {
	for l in ([]Light{.Night, .Sunset, .Sunrise}) {
		if l not_in painted do by[l] = by[light_fallback(l)]
	}
}

// How far the light has moved on from `seen` to `now`, round the day.
light_steps :: proc(seen, now: Light) -> int {
	return (int(now) - int(seen) + len(Light)) % len(Light)
}

// The light the game says it is, or day if it says nothing.
light_now :: proc(w: ^World) -> Light {
	return w.on_light_now(w) if w.on_light_now != nil else .Day
}

// What the player sees, now, in the room they are in: the latched light.
// Cut to it: the light catches up with the clock. For the game's deliberate
// cuts, and for the engine's own (a new game, a restore, the clock set).
relight :: proc(w: ^World) {
	latch_light(w, light_now(w))
}

// After a room change. Indoors, or across a threshold, the light catches up;
// between two outdoor rooms it waits, unless it is two behind.
@(private)
// Sets the light she sees, and the four flags a `when=` reads it by:
// `light_day`, `light_sunset`, `light_night`, `light_sunrise`. An outdoor
// room's description reads these, not the clock, so the words match the
// painting she is looking at, which is a door behind the clock on purpose.
latch_light :: proc(w: ^World, l: Light) {
	w.light = l
	names := [Light]string{.Day = "light_day", .Sunset = "light_sunset", .Night = "light_night", .Sunrise = "light_sunrise"}
	for name, which in names {
		on := which == l
		if flag(w, name) != on do set_flag(w, name, on)
	}
}

follow_light :: proc(w: ^World, from, to: ^Scene) {
	if to.indoors || from == nil || from.indoors || light_steps(w.light, light_now(w)) >= 2 {
		relight(w)
	}
}

// After the clock moves: indoors, the light keeps up with it.
@(private)
light_after_tick :: proc(w: ^World) {
	if len(w.scenes) > 0 && current_scene(w).indoors do relight(w)
}

// Which light a room is drawn in: the player's room in what they have seen,
// any other room (through a host's eyes) as it is now.
room_light :: proc(w: ^World, scene: ^Scene) -> Light {
	if len(w.scenes) > 0 && scene == current_scene(w) do return w.light
	return light_now(w)
}

// The tint for the things in a room that were not painted for its light.
room_tint :: proc(w: ^World, scene: ^Scene, l: Light) -> Palette_Map {
	if w.light_tint == nil do return palette_map_same()
	return w.light_tint(w, scene, l)
}

// --- Drawing through a tint ---

@(private)
tint_is_plain :: proc(m: Palette_Map) -> bool {
	return m == {} || m == palette_map_same()
}

// Everything drawn between these two goes through the palette map.
@(private)
begin_tint :: proc(m: Palette_Map) {
	ride_draw_setup()
	from, to: [16][3]f32
	for c, i in BEGA {
		from[i] = {f32(c.r), f32(c.g), f32(c.b)} / 255
		t := BEGA[m[i] & 15]
		to[i] = {f32(t.r), f32(t.g), f32(t.b)} / 255
	}
	tint_on = true
	if sprite_camera {
		sprite_map_begin(&from, &to) // through a camera, every sprite goes through the up shader, which maps too
		return
	}
	a, cell := f32(1), f32(WIDTH) / 320
	// Behind the room's depth, if a mask is on (priority.odin): the masked twin.
	s := depth_shader(.Tint) if depth_mask.on else ride_shader
	rl.SetShaderValueV(s, rl.GetShaderLocation(s, "from"), &from, .VEC3, 16)
	rl.SetShaderValueV(s, rl.GetShaderLocation(s, "to"), &to, .VEC3, 16)
	rl.SetShaderValue(s, rl.GetShaderLocation(s, "amount"), &a, .FLOAT)
	rl.SetShaderValue(s, rl.GetShaderLocation(s, "cell"), &cell, .FLOAT)
	rl.BeginShaderMode(s)
	if depth_mask.on do depth_mask_uniforms(s)
}

@(private)
end_tint :: proc() {
	tint_on = false
	if sprite_camera {
		sprite_map_end()
		return
	}
	rl.EndShaderMode()
}
