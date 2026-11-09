package nengine

import "core:testing"

@(private = "file")
POOL := [?]Announcement {
	{name = "an_pool", room = "pool", only = "bodies_found", title = "The pool", text = "Two of them."},
}

@(test)
a_body_is_announced_once_where_it_lies :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	append(&w.scenes, Scene{name = "path"}, Scene{name = "pool"})
	w.announcements = POOL[:]

	testing.expect(t, !open_announcement(&w)) // nothing found yet, and on the path
	set_flag(&w, "bodies_found", true)
	testing.expect(t, !open_announcement(&w)) // found, but not here

	go_to(&w, 1, {})
	testing.expect(t, open_announcement(&w))
	testing.expect(t, announcing(&w))
	testing.expect(t, flag(&w, "an_pool")) // and it saves
	testing.expect(t, !open_announcement(&w)) // not twice at once

	close_announcement(&w)
	go_to(&w, 0, {})
	go_to(&w, 1, {})
	testing.expect(t, !open_announcement(&w)) // once
}

@(private = "file")
SEEN := [?]Announcement {
	{name = "an_hawkes", room = "", only = "hawkes_dead", title = "In the grass", text = "A man, face down.", in_ride = true},
	{name = "an_moore", room = "", only = "moore_dead", title = "The post", text = "Sitting, as he always sat."},
}

@(test)
an_announcement_marked_in_ride_plays_on_the_glance :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	append(&w.scenes, Scene{name = "row"})
	w.announcements = SEEN[:]
	set_flag(&w, "hawkes_dead", true)
	w.ride.phase = .Riding // through a otter's eyes, as a glance finds him
	testing.expect(t, !open_announcement(&w), "the frame does not open it by itself mid-ride")
	testing.expect(t, announce_now(&w, "an_hawkes"))
	testing.expect(t, announcing(&w))
	testing.expect(t, flag(&w, "an_hawkes"))
	close_announcement(&w)
	testing.expect(t, !announce_now(&w, "an_hawkes"), "once")
}

@(test)
an_announcement_not_marked_waits_for_the_ride :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	append(&w.scenes, Scene{name = "row"})
	w.announcements = SEEN[:]
	set_flag(&w, "moore_dead", true)
	w.ride.phase = .Riding
	testing.expect(t, !announce_now(&w, "an_moore"))
	testing.expect(t, !flag(&w, "an_moore"), "kept for when she is back")
	w.ride.phase = .None
	testing.expect(t, open_announcement(&w))
	testing.expect_value(t, w.announcing.name, "an_moore")
}

@(private = "file")
WRITTEN := [?]Announcement {
	{name = "an_post", room = "gap", only = "moore_dead", title = "The post", text = "Sitting.", on_play = proc(w: ^World) {
		note(w, {id = "the_key", tab = "things", text = "The key on his belt."})
	}},
	{name = "an_grass", room = "", only = "surviving", title = "The grass", text = "Grass.", in_ride = true, on_play = proc(w: ^World) {
		set_flag(w, "grass_written", true)
	}},
}

@(test)
an_announcement_writes_its_note_as_it_opens_and_once :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	append(&w.scenes, Scene{name = "gap"})
	w.announcements = WRITTEN[:]

	set_flag(&w, "moore_dead", true)
	testing.expect(t, !noted(&w, "the_key"))
	testing.expect(t, open_announcement(&w))
	testing.expect(t, noted(&w, "the_key")) // as it opens, not when it closes
	close_announcement(&w)
	testing.expect(t, !open_announcement(&w))

	// By name, from a glance: the same.
	set_flag(&w, "surviving", true)
	testing.expect(t, announce_now(&w, "an_grass"))
	testing.expect(t, flag(&w, "grass_written"))
	close_announcement(&w)
	set_flag(&w, "grass_written", false)
	testing.expect(t, !announce_now(&w, "an_grass")) // once
	testing.expect(t, !flag(&w, "grass_written"))
}
