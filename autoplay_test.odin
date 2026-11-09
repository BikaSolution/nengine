package nengine

import "core:strings"
import "core:testing"

// Autoplay against what a game puts on the screen: a cutscene, a card, a
// conversation that comes up while she types, a ride the story starts and one
// the script starts, a deadline, and the last screen of the game. The world's
// own update needs a window, so `frames` stands in for it: the clock, and the
// ride's loop.

@(private = "file")
LOOKS := [?]Glance {
	{look = "beam", secs = 3, at = {100, 100}, line = "Along the beam."},
	{look = "moth", secs = 4, at = {300, 120}},
	{look = "yard", secs = 2, at = {50, 50}},
}

@(private = "file")
HOSTS := [?]Host{{name = "cat", attention = LOOKS[:]}}

// What reached the game, as "verb noun", in order, and the glance a ride came
// back from. One each: the tests run side by side.
@(private = "file")
Stage :: struct {
	heard:          [dynamic]string,
	came_back_from: string,
}

@(private = "file")
stage :: proc(script: string, st: ^Stage) -> (w: World, ap: Autoplay) {
	w.vocab = vocab_join({{.Verb, "ride", ""}, {.Noun, "cat", ""}, {.Noun, "lamp", ""}}, context.temp_allocator)
	w.hosts = HOSTS[:]
	w.user = st
	w.on_command = proc(w: ^World, cmd: Command) {
		if cmd.verb == "ride" {
			ride(w, cmd.noun)
			return
		}
		st := cast(^Stage)w.user
		append(&st.heard, strings.concatenate({cmd.verb, " ", cmd.noun}))
	}
	w.on_ride_end = proc(w: ^World, h: ^Host, broke_off: bool) {
		(cast(^Stage)w.user).came_back_from = h.attention[w.ride.glance].look
	}
	house := Scene{name = "house"}
	append(&house.objects, Object{name = "cat"}, Object{name = "lamp"})
	append(&w.scenes, house)
	w.player.pos = {200, 400}
	return w, autoplay_new(script)
}

@(private = "file")
strike :: proc(w: ^World, ap: ^Autoplay, st: ^Stage) {
	autoplay_destroy(ap)
	destroy_world(w)
	for h in st.heard do delete(h)
	delete(st.heard)
}

// The frames that would have passed: autoplay first, as the loop has it, then
// the world's clock and a ride's loop.
@(private = "file")
frames :: proc(w: ^World, ap: ^Autoplay, secs: f32) {
	DT :: f32(1.0 / 60)
	for t := f32(0); t < secs; t += DT {
		autoplay_step(w, ap, DT)
		w.time += DT
		if riding(w) do update_ride(w, DT)
	}
}

@(test)
nothing_is_typed_while_a_cutscene_plays :: proc(t: ^testing.T) {
	st: Stage
	w, ap := stage("look at cat", &st)
	defer strike(&w, &ap, &st)
	w.cut.world, w.cut.running = true, true

	frames(&w, &ap, 10)
	testing.expect_value(t, len(st.heard), 0)
	testing.expect_value(t, w.input_len, 0) // not even begun on

	w.cut.running = false // it ends
	frames(&w, &ap, 3)
	testing.expect_value(t, len(st.heard), 1)
	if len(st.heard) == 1 do testing.expect_value(t, st.heard[0], "look cat")
}

@(test)
a_card_is_held_for_reading_and_then_enter :: proc(t: ^testing.T) {
	st: Stage
	w, ap := stage("look at cat", &st)
	defer strike(&w, &ap, &st)
	c: Conversation
	lines := []Talk_Line{{text = "Mora, four days later. The coastal train.", card = true}, {text = "(The notebook, closed.)"}}
	begin_conversation(&w, &c, lines)

	frames(&w, &ap, 1)
	testing.expect_value(t, c.at, 0) // still being read
	testing.expect_value(t, len(st.heard), 0)
	frames(&w, &ap, 2.5) // 1 + 41/22 seconds, and a breath
	testing.expect_value(t, c.at, 1)
	frames(&w, &ap, 3)
	testing.expect(t, !talking(&w))
	frames(&w, &ap, 2)
	testing.expect_value(t, len(st.heard), 1) // and only then the next command
}

@(test)
the_next_conversation_in_the_same_place_is_read_too :: proc(t: ^testing.T) {
	st: Stage
	w, ap := stage("", &st)
	defer strike(&w, &ap, &st)
	@(static) c: Conversation
	@(static) second := []Talk_Line{{text = "The second, which starts where the first one was."}}
	first := []Talk_Line{{text = "One line."}}
	begin_conversation(&w, &c, first, proc(w: ^World) {begin_conversation(w, &c, second)})

	frames(&w, &ap, 1.6) // 1 + 9/22: the first is read and gone
	testing.expect(t, talking(&w))
	testing.expect_value(t, c.lines[0].text, second[0].text)
	frames(&w, &ap, 1)
	testing.expect(t, talking(&w)) // given its own time, not skipped on the old one's
	frames(&w, &ap, 3)
	testing.expect(t, !talking(&w))
}

@(test)
a_line_half_typed_waits_for_a_conversation :: proc(t: ^testing.T) {
	st: Stage
	w, ap := stage("look at the cat", &st)
	defer strike(&w, &ap, &st)
	frames(&w, &ap, 0.5) // the empty screen's breath, and a few letters
	testing.expect(t, ap.typing != "")
	testing.expect(t, ap.typed > 0 && ap.typed < len(ap.typing))

	c: Conversation
	begin_conversation(&w, &c, []Talk_Line{{text = "Somebody comes in."}})
	frames(&w, &ap, 1)
	testing.expect_value(t, len(st.heard), 0) // not run under it
	frames(&w, &ap, 4)
	testing.expect(t, !talking(&w))
	testing.expect_value(t, len(st.heard), 1) // and in it goes, afterwards
}

@(test)
wait_in_her_own_ride_lets_the_glance_run_out :: proc(t: ^testing.T) {
	st: Stage
	w, ap := stage("ride cat; wait; stand up", &st)
	defer strike(&w, &ap, &st)
	frames(&w, &ap, 2.5) // typed, and going under
	testing.expect(t, riding(&w))
	testing.expect(t, ap.own_ride)

	// The beam is up for three seconds; WAIT is not typed over it.
	frames(&w, &ap, 2)
	testing.expect(t, riding(&w))
	testing.expect_value(t, ride_glance(&w).look, "beam")
	testing.expect_value(t, ap.at, 1)

	// It turns to the moth by itself, and that was the WAIT; then she stands.
	frames(&w, &ap, 8)
	testing.expect(t, !riding(&w))
	testing.expect_value(t, st.came_back_from, "moth")
}

@(test)
a_ride_the_story_starts_is_watched_to_its_end :: proc(t: ^testing.T) {
	st: Stage
	w, ap := stage("look at cat", &st)
	defer strike(&w, &ap, &st)
	testing.expect_value(t, ride(&w, "cat"), Ride_Outcome.Started) // a beat's, not a line's

	frames(&w, &ap, 12)
	testing.expect(t, riding(&w))
	testing.expect(t, !ap.own_ride)
	testing.expect_value(t, len(st.heard), 0)

	come_back(&w) // the host breaks off
	frames(&w, &ap, 4)
	testing.expect(t, !riding(&w))
	testing.expect_value(t, len(st.heard), 1)
}

@(test)
she_skims_while_a_deadline_runs :: proc(t: ^testing.T) {
	long := strings.repeat("The grass, wet, and the wire, and a lamp going away along it. ", 4, context.temp_allocator)
	c: Conversation

	// Without one: eleven seconds or so for a line that long.
	{
		st: Stage
		w, ap := stage("", &st)
		defer strike(&w, &ap, &st)
		begin_conversation(&w, &c, []Talk_Line{{text = long}, {text = "Next."}})
		frames(&w, &ap, 4)
		testing.expect_value(t, c.at, 0)
	}
	// With one: a quarter of it.
	{
		st: Stage
		w, ap := stage("", &st)
		defer strike(&w, &ap, &st)
		deadline(&w, "drug_lands", 25, nil)
		testing.expect(t, racing(&w))
		begin_conversation(&w, &c, []Talk_Line{{text = long}, {text = "Next."}})
		frames(&w, &ap, 4)
		testing.expect(t, c.at >= 1)
		cancel_timer(&w, "drug_lands")
		testing.expect(t, !racing(&w))
	}
	// `after` is not a deadline.
	{
		st: Stage
		w, ap := stage("", &st)
		defer strike(&w, &ap, &st)
		after(&w, "engine_builds", 30, nil)
		testing.expect(t, !racing(&w))
	}
}

@(private = "file")
keep_open :: proc(w: ^World, dt: f32) -> bool {return true}

@(test)
the_last_screen_stays_up_when_the_script_is_done :: proc(t: ^testing.T) {
	// With lines still to go, an overlay is looked at and closed.
	{
		st: Stage
		w, ap := stage("look at cat", &st)
		defer strike(&w, &ap, &st)
		open_overlay(&w, {update = keep_open})
		frames(&w, &ap, 6)
		testing.expect(t, !overlay_open(&w))
		testing.expect_value(t, len(st.heard), 1)
	}
	// With none, it stays for the watcher, and nothing more is typed.
	{
		st: Stage
		w, ap := stage("look at cat", &st)
		defer strike(&w, &ap, &st)
		frames(&w, &ap, 3)
		testing.expect_value(t, len(st.heard), 1)
		open_overlay(&w, {update = keep_open}) // the score, at the end
		frames(&w, &ap, 20)
		testing.expect(t, overlay_open(&w))
		testing.expect(t, ap.ended)
	}
}

@(test)
what_comes_after_the_last_line_still_plays_out :: proc(t: ^testing.T) {
	st: Stage
	w, ap := stage("look at cat", &st)
	defer strike(&w, &ap, &st)
	frames(&w, &ap, 3)
	testing.expect(t, ap.ended)
	c: Conversation
	begin_conversation(&w, &c, []Talk_Line{{text = "I don't know."}, {text = "A card.", card = true}})
	frames(&w, &ap, 6)
	testing.expect(t, !talking(&w)) // read to the end, the card too
	testing.expect_value(t, len(st.heard), 1)
}

// RIDE whose ride begins only after a line of hers (Act V's "Something.
// Anything."): still her ride, so the next line is typed while she rides,
// not watched to its end.
@(test)
a_ride_she_asked_for_is_hers_even_after_a_line :: proc(t: ^testing.T) {
	st: Stage
	w, ap := stage("ride cat; look at lamp", &st)
	defer strike(&w, &ap, &st)
	w.on_command = proc(w: ^World, cmd: Command) {
		if cmd.verb == "ride" {
			@(static) first := [?]Talk_Line{{text = "Something. Anything."}}
			begin_conversation(w, &w.node_talk, first[:], proc(w: ^World) {ride(w, "cat")})
			return
		}
		st := cast(^Stage)w.user
		append(&st.heard, strings.concatenate({cmd.verb, " ", cmd.noun}))
	}
	frames(&w, &ap, 6) // typed, the line read, and going under
	testing.expect(t, riding(&w))
	testing.expect(t, ap.own_ride)
	frames(&w, &ap, 4)
	testing.expect_value(t, ap.at, 2) // LOOK AT LAMP typed while she rode, not after
}
