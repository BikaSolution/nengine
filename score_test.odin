package nengine

import "core:os"
import "core:strings"
import "core:testing"

// Points go on the clues, because a mystery is scored on what the player
// worked out. The part worth testing hardest is that finding the same clue
// twice is worth what finding it once was — a score a player can feed by
// looking at a thing repeatedly is not a score.

@(private = "file")
AWARDS := [?]Award {
	{"field_book", "Fairbank's field book", 10, 0, 0, ""},
	{"photograph", "The 1948 photograph", 15, 0, 0, ""},
	{"boiler_log", "The boiler was lit at 23:40", 20, 23 * 60, 25 * 60, ""},
}

@(private = "file")
scored_world :: proc() -> World {
	w := World{awards = AWARDS[:]}
	return w
}

@(private = "file")
tidy :: proc(w: ^World) {
	clear_awards(w)
	clear_flags(w)
}

// A scored world with somewhere private of its own to save into.
@(private = "file")
saving_world :: proc(name: string) -> World {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" do base = "/tmp"
	dir := strings.concatenate({base, "/nengine-score-", name}, context.temp_allocator)
	os.remove_all(dir)
	w := World {
		awards    = AWARDS[:],
		save_name = strings.clone(dir, context.temp_allocator),
	}
	append(&w.scenes, Scene{name = "pool_deck"})
	return w
}

@(private = "file")
tidy_saving :: proc(w: ^World) {
	os.remove_all(save_dir(w))
	delete(w.scenes)
	clear_awards(w)
	clear_flags(w)
}

@(test)
the_total_is_known_before_anything_is_found :: proc(t: ^testing.T) {
	w := scored_world()
	defer tidy(&w)

	// "0 of 45" from the first minute, because the awards are declared rather
	// than discovered.
	testing.expect_value(t, score(&w), 0)
	testing.expect_value(t, score_max(&w), 45)
	testing.expect_value(t, score_text(&w), "0 of 45")
}

@(test)
finding_a_clue_scores_it_once_and_only_once :: proc(t: ^testing.T) {
	w := scored_world()
	defer tidy(&w)

	testing.expect(t, award(&w, "field_book"), "the first time counts")
	testing.expect_value(t, score(&w), 10)

	testing.expect(t, !award(&w, "field_book"), "and the second time does not")
	testing.expect(t, !award(&w, "field_book"))
	testing.expect_value(t, score(&w), 10)

	testing.expect(t, award(&w, "photograph"))
	testing.expect_value(t, score_text(&w), "25 of 45")
}

@(test)
a_clue_changes_the_world_as_well_as_the_score :: proc(t: ^testing.T) {
	w := scored_world()
	defer tidy(&w)

	// One call, one fact: the score goes up and a flag of the same name comes
	// on, so a room can say `when=field_book` without the game saying it
	// twice and getting them out of step.
	testing.expect(t, !flag(&w, "field_book"))
	award(&w, "field_book")
	testing.expect(t, flag(&w, "field_book"))
	testing.expect(t, condition_met(&w, "field_book"))
}

@(test)
an_award_that_was_wrong_can_be_taken_back :: proc(t: ^testing.T) {
	w := scored_world()
	defer tidy(&w)

	award(&w, "photograph")
	testing.expect_value(t, score(&w), 15)
	unaward(&w, "photograph")
	testing.expect_value(t, score(&w), 0)
	testing.expect(t, !flag(&w, "photograph"))
	// And it can be earned again afterwards.
	testing.expect(t, award(&w, "photograph"))
	testing.expect_value(t, score(&w), 15)
}

@(test)
a_name_nobody_declared_scores_nothing :: proc(t: ^testing.T) {
	w := scored_world()
	defer tidy(&w)

	// It is recorded, so a typo doesn't silently vanish, but it is worth
	// nothing because nothing said what it was worth.
	testing.expect(t, award(&w, "flibbertigibbet"))
	testing.expect_value(t, score(&w), 0)
	testing.expect_value(t, score_max(&w), 45)
}

@(test)
the_ending_can_list_what_was_found_and_what_was_missed :: proc(t: ^testing.T) {
	w := scored_world()
	defer tidy(&w)

	w.time = 300
	award(&w, "photograph")
	w.time = 100 // found earlier in a different order than declared
	award(&w, "boiler_log")

	found := awards_earned(&w)
	testing.expect_value(t, len(found), 2)
	// In the order the player lived them, not the order they were declared.
	testing.expect_value(t, found[0].name, "boiler_log")
	testing.expect_value(t, found[0].at, f32(100))
	testing.expect_value(t, found[1].name, "photograph")
	testing.expect_value(t, found[1].text, "The 1948 photograph")

	missed := awards_missed(&w)
	testing.expect_value(t, len(missed), 1)
	testing.expect_value(t, missed[0].name, "field_book")
	testing.expect_value(t, missed[0].points, 10)
}

@(test)
how_long_it_took_reads_the_way_somebody_would_say_it :: proc(t: ^testing.T) {
	testing.expect_value(t, playtime_text(38), "38s")
	testing.expect_value(t, playtime_text(252), "4m 12s")
	testing.expect_value(t, playtime_text(4980), "1h 23m")
	testing.expect_value(t, playtime_text(0), "0s")
	testing.expect_value(t, playtime_text(-5), "0s") // never a negative clock

	w := scored_world()
	defer tidy(&w)
	w.time = 4980
	testing.expect_value(t, playtime(&w), f32(4980))
}

@(test)
the_score_and_the_clock_come_back_with_a_save :: proc(t: ^testing.T) {
	// A score that does not survive a save is worse than no score, because
	// the player only finds out after reloading, having already lost it.
	w := saving_world("roundtrip")
	defer tidy_saving(&w)

	w.time = 1800
	award(&w, "field_book")
	w.time = 2400
	award(&w, "photograph")
	testing.expect_value(t, score(&w), 25)

	testing.expect(t, save_game(&w, 1, "the second night"))

	// Lose it all.
	clear_awards(&w)
	w.time = 0
	testing.expect_value(t, score(&w), 0)

	testing.expect(t, load_game(&w, 1))
	testing.expect_value(t, score(&w), 25)
	testing.expect_value(t, playtime(&w), f32(2400))
	testing.expect(t, has_award(&w, "field_book"))
	testing.expect(t, has_award(&w, "photograph"))
	testing.expect(t, !has_award(&w, "boiler_log"))

	// And when each one happened, so the ending still reads in order.
	found := awards_earned(&w)
	testing.expect_value(t, len(found), 2)
	testing.expect_value(t, found[0].name, "field_book")
	testing.expect_value(t, found[0].at, f32(1800))
	testing.expect_value(t, found[1].at, f32(2400))

	// The flags an award sets come back too, so a room that changed when the
	// clue was found is still changed.
	testing.expect(t, flag(&w, "field_book"))
}

@(test)
a_save_carries_its_score_for_a_menu_to_read :: proc(t: ^testing.T) {
	// A save-game window wants to show "25 points, 40m" without loading it.
	w := saving_world("line")
	defer tidy_saving(&w)

	w.time = 2400
	award(&w, "field_book")
	award(&w, "photograph")
	testing.expect(t, save_game(&w, 2, "the pool"))

	text, ok := read_data_file(save_path(&w, 2))
	testing.expect(t, ok)
	s := parse_save(text)
	defer save_destroy(&s)
	testing.expect_value(t, save_int(&s, "score"), 25)
	testing.expect_value(t, playtime_text(save_f32(&s, "played")), "40m 0s")
}

@(test)
missed_is_in_the_order_it_was_there_and_found_keeps_the_hour :: proc(t: ^testing.T) {
	late := [?]Award{{"late", "Late", 5, 25 * 60, 26 * 60, ""}, {"early", "Early", 5, 17 * 60, 18 * 60, ""}, {"any", "Any time", 5, 0, 0, ""}}
	w := World{awards = late[:], clock_start = 19 * 60, clock_step = 4}
	defer tidy(&w)
	missed := awards_missed(&w)
	testing.expect_value(t, missed[0].name, "any")
	testing.expect_value(t, missed[1].name, "early")
	testing.expect_value(t, missed[2].name, "late")

	tick(&w, 5)
	award(&w, "early")
	testing.expect_value(t, awards_earned(&w)[0].minute, 19 * 60 + 20)
}

@(test)
an_award_whose_only_never_held_is_not_missed :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	branches := [?]Award {
		{name = "percy_step", text = "On the step", points = 10, only = "third_death_percy"},
		{name = "pickett_cot", text = "On the cot", points = 10, only = "third_death_pickett"},
		{name = "glasses", text = "The glasses", points = 10},
	}
	w.awards = branches[:]
	set_flag(&w, "third_death_pickett", true) // this game, it was Pickett
	missed := awards_missed(&w)
	names := make([dynamic]string, context.temp_allocator)
	for a in missed do append(&names, a.name)
	testing.expect_value(t, len(missed), 2)
	testing.expect_value(t, names[0], "pickett_cot") // his branch: could have, did not
	testing.expect_value(t, names[1], "glasses")
	// The flag can come and go; that it held once is what counts.
	set_flag(&w, "third_death_pickett", false)
	testing.expect_value(t, len(awards_missed(&w)), 2)
}
