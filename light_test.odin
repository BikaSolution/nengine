package nengine

import "core:testing"

@(private = "file", thread_local)
now: Light

@(private = "file")
grounds :: proc() -> World {
	w: World
	append(&w.scenes, Scene{name = "lawn"}, Scene{name = "path"}, Scene{name = "hall", indoors = true})
	w.on_light_now = proc(w: ^World) -> Light {return now}
	now = .Day
	relight(&w)
	return w
}

@(test)
nobody_watches_the_lawn_go_dark :: proc(t: ^testing.T) {
	w := grounds()
	defer destroy_world(&w)

	now = .Sunset
	tick(&w) // on the lawn, the clock runs on
	testing.expect_value(t, w.light, Light.Day)

	go_to(&w, 1, {}) // across the grass: one behind, and it waits
	testing.expect_value(t, w.light, Light.Day)

	go_to(&w, 2, {}) // in through a door
	testing.expect_value(t, w.light, Light.Sunset)

	now = .Night
	tick(&w) // indoors, the light keeps up with the clock
	testing.expect_value(t, w.light, Light.Night)

	go_to(&w, 0, {}) // and out again, into the dark
	testing.expect_value(t, w.light, Light.Night)
}

@(test)
two_behind_catches_up_at_the_next_doorway :: proc(t: ^testing.T) {
	w := grounds()
	defer destroy_world(&w)
	now = .Night // day to night without going in: two behind
	tick(&w)
	testing.expect_value(t, w.light, Light.Day)
	go_to(&w, 1, {})
	testing.expect_value(t, w.light, Light.Night)
}

@(test)
a_cut_is_the_games_to_make :: proc(t: ^testing.T) {
	w := grounds()
	defer destroy_world(&w)
	now = .Sunset
	relight(&w) // "the light goes all at once"
	testing.expect_value(t, w.light, Light.Sunset)
	testing.expect_value(t, light_steps(.Night, .Day), 2)
	testing.expect_value(t, light_steps(.Sunrise, .Day), 1)
}

@(test)
a_missing_painting_borrows :: proc(t: ^testing.T) {
	day := Sprite{frame_w = 1}
	dusk := Sprite{frame_w = 2}
	a: Assets
	defer delete(a.sprites)
	a.sprites["lamp"] = day
	a.sprites["lamp.sunset"] = dusk
	ls := lit_sprite(&a, "lamp")
	testing.expect_value(t, ls.painted, bit_set[Light]{.Day, .Sunset})
	testing.expect_value(t, ls.by[.Night].frame_w, 1)   // night: day's
	testing.expect_value(t, ls.by[.Sunrise].frame_w, 2) // sunrise: sunset's, shadows and all
}

@(private = "file")
dusk_now :: proc(w: ^World) -> Light {
	return .Sunset if clock_minute(w) >= 18 * 60 else .Day
}

@(test)
the_light_flags_follow_the_latch_not_the_clock :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	append(&w.scenes, Scene{name = "yard"}, Scene{name = "kitchen", indoors = true})
	w.clock_start, w.clock_step = 17 * 60 + 50, 1
	w.on_light_now = dusk_now
	relight(&w)
	testing.expect(t, flag(&w, "light_day"))
	testing.expect(t, !flag(&w, "light_sunset"))

	tick(&w, 15) // the clock is past six; out here the painting has not changed
	testing.expect_value(t, light_now(&w), Light.Sunset)
	testing.expect(t, flag(&w, "light_day"), "the words match the painting she is looking at")

	go_to(&w, 1, {}) // indoors, where the light catches up
	testing.expect(t, flag(&w, "light_sunset"))
	testing.expect(t, !flag(&w, "light_day"))
}
