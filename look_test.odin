package nengine

import "core:testing"
import rl "vendor:raylib"

// The comic's layout is arithmetic with the measuring handed in, so it is
// tested here with a font where every character is ten canvas pixels wide,
// on a 1024-wide canvas: 3.2 canvas pixels a grid pixel, 30 a line.

@(private = "file")
tens :: proc(text: string) -> f32 {
	return f32(len(text)) * 10
}

@(private = "file")
M :: Comic_Metrics{scale = 3.2, line = 30, grid_w = 320, measure = tens}

@(private = "file")
LONG :: "(chalking a tally on the hatch coaming as each sack goes down) Nine. Ten. (to a hand) Mind the box with the paint on it. It's somebody's. And the next one, and the one after that, all the way down the hold until the light goes, which it will, because it always does on this river at this hour."

@(test)
lettering_wraps_to_its_width_and_keeps_breaks :: proc(t: ^testing.T) {
	lines := wrap_measured("Two glasses.\nOne full, lipstick, and one empty with flies in it.", 200, tens)
	testing.expect_value(t, lines[0], "Two glasses.")
	testing.expect(t, len(lines) >= 3, "the long line should have wrapped")
	for l in lines do testing.expect(t, tens(l) <= 200, "a line came out wider than asked for")
	blank := wrap_measured("TIMES\n\nlate", 200, tens)
	testing.expect_value(t, len(blank), 3)
	testing.expect_value(t, blank[1], "")
}

@(test)
a_balloon_goes_on_the_speakers_side :: proc(t: ^testing.T) {
	// Where they stand decides it...
	testing.expect(t, balloon_on_right({at = 280, side = .Left}, 320))
	testing.expect(t, !balloon_on_right({at = 40, side = .Right}, 320))
	// ...unless they stand in the middle, or are nowhere on screen: then
	// their Speaker.side, so two people talking still take a side each.
	testing.expect(t, !balloon_on_right({at = 160, side = .Left}, 320))
	testing.expect(t, balloon_on_right({at = 170, side = .Right}, 320))
	testing.expect(t, balloon_on_right({side = .Right}, 320))
	testing.expect(t, !balloon_on_right({side = .Left}, 320))
}

@(test)
a_balloon_sits_at_the_top_flush_to_its_side :: proc(t: ^testing.T) {
	right := plan_balloon({text = "Nine. Ten. Mind the box.", name = "Finn", portrait = true, at = 280}, M)
	testing.expect(t, right.right)
	testing.expect(t, right.inset)
	testing.expect_value(t, right.y, 6)
	testing.expect_value(t, right.x + right.w, 312) // eight in from the edge, as the mockup
	testing.expect_value(t, right.inset_at, [2]f32{right.x - 47, 6}) // the portrait on its left

	left := plan_balloon({text = "Nine. Ten. Mind the box.", name = "Otto", portrait = true, at = 90}, M)
	testing.expect(t, !left.right)
	testing.expect_value(t, left.inset_at.x, 7) // its frame four in from the edge
	testing.expect_value(t, left.x, 54)

	// A bigger face gets a bigger inset, and the balloon steps over it.
	big := plan_balloon({text = "Nine. Ten. Mind the box.", name = "Otto", portrait = true, portrait_size = {60, 72}, at = 90}, M)
	testing.expect_value(t, big.inset_size, [2]f32{60, 72})
	testing.expect_value(t, big.inset_at.x, 7)
	testing.expect_value(t, big.x, 70)
	bigr := plan_balloon({text = "Nine. Ten. Mind the box.", name = "Finn", portrait = true, portrait_size = {60, 72}, at = 280}, M)
	testing.expect_value(t, bigr.inset_at, [2]f32{bigr.x - 63, 6})

	bare := plan_balloon({text = "That's the wind.", name = "Brand", at = 250}, M)
	testing.expect(t, !bare.inset)
	testing.expect_value(t, bare.x + bare.w, 316)
}

@(test)
a_balloon_is_as_wide_as_its_words_and_widens_before_it_grows :: proc(t: ^testing.T) {
	short := plan_balloon({text = "Right.", name = "Ada", portrait = true, side = .Left}, M)
	testing.expect_value(t, short.w, 40) // the narrowest there is
	testing.expect_value(t, len(short.lines), 1)
	// One line and the name: two rows of 30 canvas pixels, and the margins.
	testing.expect_value(t, short.h, 26)

	// Long words: wider than the 210 it starts at, up to all there is room
	// for beside the inset, rather than ten lines down the painting.
	long := plan_balloon({text = LONG, name = "Finn", portrait = true, at = 280}, M)
	testing.expect(t, long.w > 210, "a long line should have widened its balloon")
	testing.expect(t, long.w <= 320 - 4 - 8 - 50, "wider than there is room for")
	for l in long.lines do testing.expect(t, tens(l) <= (long.w - 14) * 3.2, "a line wider than its balloon")
	rows := f32(len(long.lines) + 1)
	testing.expect_value(t, long.h, f32(int(rows * 30 / 3.2)) + 8)
}

@(test)
a_balloon_keeps_off_the_speakers_face :: proc(t: ^testing.T) {
	// Finn at the top of the gangway, his head where the balloon would be.
	head := Balloon_Ask{text = "Nine. Ten.", name = "Finn", portrait = true, at = 280}
	head.head = rl.Rectangle{270, 20, 20, 15}
	b := plan_balloon(head, M)
	testing.expect(t, !balloon_covers(b, head.head.?), "the balloon is over his face")
	left, right := balloon_span(b)
	testing.expect(t, left >= 4 && right <= 316, "pushed off the screen")
	// Nobody's head in the way: it stays flush to its side.
	clear := plan_balloon({text = "Nine. Ten.", name = "Finn", portrait = true, at = 280, head = rl.Rectangle{270, 120, 20, 15}}, M)
	testing.expect_value(t, clear.x + clear.w, 312)
}

@(test)
an_offscreen_voice_has_no_inset :: proc(t: ^testing.T) {
	b := plan_balloon({text = "Lost the next bit.", name = "a man", portrait = true, voice = true, side = .Right}, M)
	testing.expect(t, !b.inset)
	testing.expect(t, b.right)
	testing.expect_value(t, b.x + b.w, 316)
}

@(test)
a_caption_hugs_its_words_and_widens_past_four_lines :: proc(t: ^testing.T) {
	c := plan_caption("Silent, dark.", M)
	testing.expect_value(t, [2]f32{c.x, c.y}, [2]f32{4, 4})
	testing.expect_value(t, len(c.lines), 1)
	testing.expect_value(t, c.h, 18) // floor(30 / 3.2) + 9
	long := plan_caption(LONG, M)
	testing.expect(t, long.w > 190, "a long caption should have widened")
	testing.expect(t, long.x + long.w <= 316, "wider than the screen")
	titled := plan_caption("Silent, dark.", M, label = "Tent two")
	testing.expect_value(t, titled.h, 27) // floor(60 / 3.2) + 9
}

@(test)
the_comic_knows_a_balloon_from_a_caption :: proc(t: ^testing.T) {
	w: World
	defer destroy_world(&w)
	sc := Scene{}
	face := Sprite{texture = {id = 1}, frame_w = 141, frame_h = 166, frames = 1}
	append(&sc.objects, Object{name = "finn", pos = {900, 500}, sprite = Sprite{frame_w = 80, frame_h = 160, frames = 1}})
	append(&w.scenes, sc)
	finn := Speaker{name = "Finn", portrait = face, side = .Right}
	hargreave := Speaker{name = "Mrs Hargreave", portrait = face, side = .Right}
	voice := Speaker{name = "a man", side = .Right}

	// The game's own words, and a stage direction: captions.
	say(&w, "The bar: whitewash and a tin roof.")
	_, balloon := comic_ask(&w, message(&w), 3.2)
	testing.expect(t, !balloon)
	say_as(&w, nil, "(He does not put the rifle down.)")
	_, balloon = comic_ask(&w, message(&w), 3.2)
	testing.expect(t, !balloon)

	// Somebody in the room, with a face: placed by where they stand.
	say_as(&w, &finn, "Nine. Ten.")
	ask, ok := comic_ask(&w, message(&w), 3.2)
	testing.expect(t, ok && ask.portrait && !ask.voice)
	testing.expect_value(t, ask.name, "Finn")
	testing.expect_value(t, ask.at.?, f32(900 / 3.2))
	testing.expect(t, ask.head != nil)

	// A face, but nobody of that name here: their side, still a balloon.
	say_as(&w, &hargreave, "Well, I can't possibly.")
	ask, ok = comic_ask(&w, message(&w), 3.2)
	testing.expect(t, ok && ask.portrait && !ask.voice && ask.at == nil)

	// Heard through a wall, named on the box: a voice, the name taken off
	// the words and put over them.
	say_as(&w, &voice, "a man: Lost the next bit.")
	ask, ok = comic_ask(&w, message(&w), 3.2)
	testing.expect(t, ok && ask.voice && !ask.portrait)
	testing.expect_value(t, ask.text, "Lost the next bit.")
	testing.expect_value(t, ask.name, "a man")

	// In a close-up the face is the picture: no inset, but still named.
	say_as(&w, nil, "Mrs Hargreave: Well, I can't possibly.")
	w.message_speaker = &hargreave
	ask, ok = comic_ask(&w, message(&w), 3.2)
	testing.expect(t, ok && !ask.portrait && !ask.voice)
	testing.expect_value(t, ask.text, "Well, I can't possibly.")
}

@(test)
hold_finds_its_line :: proc(t: ^testing.T) {
	otto := Speaker{name = "Otto"}
	line := Talk_Line{who = &otto, text = "Five o'clock, stoked, and banked at the back."}
	testing.expect(t, hold_here("2", 2, line))
	testing.expect(t, !hold_here("3", 2, line))
	testing.expect(t, hold_here("FIVE O'CLOCK", 1, line))
	testing.expect(t, hold_here("otto", 1, line))
	testing.expect(t, !hold_here("blood warm", 1, line))
}

// Every colour a comic theme comes with is one of the sixteen.
@(private = "file")
comic_colours :: proc(c: Comic) -> [dynamic]rl.Color {
	out := make([dynamic]rl.Color, context.temp_allocator)
	for s in ([]Surface{c.balloon, c.caption, c.prompt, c.bar, c.panel, c.row, c.picked, c.title, c.tag}) {
		append(&out, s.paper.a, s.paper.b, s.ink, s.name, s.aside, s.faded)
		if s.rule.a != 0 do append(&out, s.rule)
	}
	append(&out, c.line, c.ground, c.heading, c.subtitle, c.note)
	return out
}

@(test)
the_comic_themes_are_bega :: proc(t: ^testing.T) {
	for theme in ([]Comic{COMIC_BEGA, COMIC_PARCHMENT}) {
		for col in comic_colours(theme) {
			found := false
			for b in BEGA do if b == col do found = true
			testing.expectf(t, found, "%v is not a bEGA colour", col)
		}
	}
	// The default is the white comic as it always was: no weave, no rule.
	testing.expect_value(t, COMIC_BEGA.balloon.paper.a, BEGA[15])
	testing.expect_value(t, COMIC_BEGA.balloon.paper.weave, Weave.Solid)
	testing.expect_value(t, COMIC_BEGA.balloon.rule.a, u8(0))
	testing.expect_value(t, COMIC_BEGA.caption.paper.a, BEGA[14])
	// Parchment: cream woven of white and yellow, sepia names, a brown rule;
	// the caption still yellow.
	p := COMIC_PARCHMENT
	testing.expect(t, p.balloon.paper == Paper{a = BEGA[15], b = BEGA[14], weave = .Checker})
	testing.expect_value(t, p.balloon.name, BEGA[6])
	testing.expect_value(t, p.balloon.rule, BEGA[6])
	testing.expect_value(t, p.caption.paper.a, BEGA[14])
	testing.expect_value(t, p.row.rule.a, u8(0))
}

@(test)
parchment_by_the_light_moves_only_the_rule_and_the_caption :: proc(t: ^testing.T) {
	for theme, l in COMIC_PARCHMENT_LIT {
		for col in comic_colours(theme) {
			found := false
			for b in BEGA do if b == col do found = true
			testing.expectf(t, found, "%v: %v is not a bEGA colour", l, col)
		}
		// The paper, the inks and the small boxes never move.
		for s in ([]Surface{theme.balloon, theme.prompt, theme.bar, theme.panel}) {
			testing.expect(t, s.paper == COMIC_PARCHMENT.balloon.paper, "the cream should stay put")
			testing.expect_value(t, s.ink, COMIC_PARCHMENT.balloon.ink)
			testing.expect_value(t, s.name, COMIC_PARCHMENT.balloon.name)
		}
		testing.expect(t, theme.row == COMIC_PARCHMENT.row && theme.picked == COMIC_PARCHMENT.picked && theme.tag == COMIC_PARCHMENT.tag)
		testing.expect(t, theme.caption == theme.title)
	}
	testing.expect(t, COMIC_PARCHMENT_LIT[.Day] == COMIC_PARCHMENT)
	testing.expect_value(t, COMIC_PARCHMENT_LIT[.Sunset].balloon.rule, BEGA[4])
	testing.expect_value(t, COMIC_PARCHMENT_LIT[.Night].balloon.rule, BEGA[1])
	testing.expect_value(t, COMIC_PARCHMENT_LIT[.Night].caption.paper.a, BEGA[11])
	testing.expect_value(t, COMIC_PARCHMENT_LIT[.Sunrise].balloon.rule, BEGA[5])
}

@(test)
the_comic_follows_the_light_only_when_lit :: proc(t: ^testing.T) {
	old_look, old_comic, old_lit := the_look, the_comic, comic_lit
	defer {the_look, the_comic, comic_lit = old_look, old_comic, old_lit}
	w: World
	defer destroy_world(&w)

	// One theme: the light changes nothing, and the default is the white.
	set_look(.Comic)
	w.light = .Night
	comic_follow_light(&w)
	testing.expect(t, the_comic == COMIC_BEGA)

	// A theme each: day's before there is a world, then the light's.
	lit := COMIC_PARCHMENT_LIT
	set_look_lit(.Comic, lit)
	testing.expect(t, the_comic == COMIC_PARCHMENT)
	for l in Light {
		w.light = l
		comic_follow_light(&w)
		testing.expect(t, the_comic == lit[l])
	}
	// And back to one.
	set_look(.Comic)
	w.light = .Sunset
	comic_follow_light(&w)
	testing.expect(t, the_comic == COMIC_BEGA)
}

@(test)
a_weave_is_on_the_grid :: proc(t: ^testing.T) {
	// The checker is half the pixels, alternating along a row and down a
	// column; the quarter one in four; solid none.
	on: [Weave]int
	for y in i32(0) ..< 4 do for x in i32(0) ..< 4 do for w in Weave do if weave_on(w, x, y) do on[w] += 1
	testing.expect_value(t, on[.Solid], 0)
	testing.expect_value(t, on[.Checker], 8)
	testing.expect_value(t, on[.Quarter], 4)
	testing.expect(t, weave_on(.Checker, 0, 0) != weave_on(.Checker, 1, 0))
	testing.expect(t, weave_on(.Checker, 0, 0) != weave_on(.Checker, 0, 1))
}
