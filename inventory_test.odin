package nengine

import "core:testing"

@(private = "file")
ITEMS := [?]Item{{"offal", "scraps", "Scraps, in a newspaper.", ""}, {"key", "a key", "A key.", ""}}

@(test)
carrying_is_a_flag_and_look_finds_it :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	w.items = ITEMS[:]
	@(static) words := [?]Word{{.Noun, "offal", ""}, {.Noun, "key", ""}, {.Noun, "bins", ""}}
	w.vocab = vocab_join(words[:], context.temp_allocator)
	append(&w.scenes, Scene{name = "yard"})

	testing.expect(t, !carrying(&w, "offal"))
	carry(&w, "offal")
	testing.expect(t, carrying(&w, "offal"))
	testing.expect(t, flag(&w, "carrying_offal"))
	testing.expect_value(t, len(carried(&w)), 1)

	// A game's LOOK goes through look_command, which knows what she carries.
	testing.expect(t, look_command(&w, {verb = "look", noun = "offal"}))
	testing.expect_value(t, message(&w), "Scraps, in a newspaper.")

	lose(&w, "offal")
	testing.expect(t, !carrying(&w, "offal"))
	clear_flags(&w)
}

@(private = "file", thread_local)
baited: bool

@(test)
putting_a_carried_thing_on_something_is_its_business :: proc(t: ^testing.T) {
	w: World
	defer {
		for &s in w.scenes do for &o in s.objects do delete(o.on)
		destroy_world(&w)
	}
	w.items = ITEMS[:]
	@(static) words := [?]Word{{.Noun, "offal", ""}, {.Noun, "bins", ""}}
	w.vocab = vocab_join(words[:], context.temp_allocator)
	sc := Scene{name = "yard"}
	bins := Object{name = "bins", pos = {100, 100}}
	append(&bins.on, Interaction{verb = "put", with = "offal", on_do = proc(w: ^World, o: ^Object) {baited = true}})
	append(&sc.objects, bins)
	append(&w.scenes, sc)
	baited = false

	carry(&w, "offal")
	run_command(&w, "put offal on bins")
	testing.expect(t, baited)
	clear_flags(&w)
}
