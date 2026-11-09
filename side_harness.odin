package nengine

import "core:fmt"
import "core:strconv"
import "core:strings"

// The harness's sides (script.odin): what this room's are, and a crossing
// walked out in real steps, undrawn. The strip shot, two neighbours side by
// side for checking that their paintings meet, is probe.odin's `!strip`.
//
//     !sides                        every side here: where it goes, its span
//                                   and brink, its gate, its partner
//     !cross <dir> [at=c] [by=go|arrow|click]
//                                   across that side as typed (GO NORTH, the
//                                   default), as the arrow key, or as a click
//                                   just beyond the brink; `at=` is where along
//                                   the side (she is stood a step in from it
//                                   first, for go and arrow)

// `!sides`.
@(private)
sides_bang :: proc(w: ^World) -> string {
	sc := current_scene(w)
	if len(sc.sides) == 0 do return "no sides"
	b := strings.builder_make(context.temp_allocator)
	for &s, i in sc.sides {
		if i > 0 do strings.write_string(&b, " | ")
		to := s.to_name if s.to_name != "" else fmt.tprintf("%v", s.to)
		fmt.sbprintf(&b, "%v -> %v span %.0f..%.0f", COMPASS_WORDS[s.dir], to, s.span[0], s.span[1])
		lo, ok_lo := side_brink(sc, s.dir, s.span[0])
		hi, ok_hi := side_brink(sc, s.dir, s.span[1])
		if ok_lo && ok_hi {
			fmt.sbprintf(&b, " brink %.0f,%.0f..%.0f,%.0f", lo.x, lo.y, hi.x, hi.y)
		} else {
			strings.write_string(&b, " brink MISSING at an end")
		}
		if s.name != "" do fmt.sbprintf(&b, " name %v", s.name)
		if s.gate != "" {
			if gate_shut(w, s.gate) {
				fmt.sbprintf(&b, " gate %v SHUT %q", s.gate, side_shut_text(w, &s))
			} else {
				fmt.sbprintf(&b, " gate %v open", s.gate)
			}
		}
		if k := kept_out(w, s.to); k != nil do fmt.sbprintf(&b, " KEPT OUT %q", k.text)
		if s.hidden do fmt.sbprintf(&b, " (hidden: when=%v)", s.only)
		switch {
		case s.has_arrive:
			fmt.sbprintf(&b, " long walk to %.0f,%.0f", s.arrive.x, s.arrive.y)
		case side_partner(w, w.current, &s) != nil:
			strings.write_string(&b, " partner ok")
		case:
			strings.write_string(&b, " NO PARTNER")
		}
	}
	return strings.to_string(b)
}

// `!cross <dir> [at=c] [by=go|arrow|click]`.
@(private)
cross_bang :: proc(w: ^World, arg: string) -> string {
	USAGE :: "!cross north|east|south|west [at=c] [by=go|arrow|click]"
	words := strings.fields(arg, context.temp_allocator)
	if len(words) == 0 do return USAGE
	d, ok := compass_of(words[0])
	if !ok do return USAGE
	by := "go"
	at: Maybe(f32)
	for word in words[1:] {
		switch {
		case strings.has_prefix(word, "by="):
			by = word[3:]
		case strings.has_prefix(word, "at="):
			v, good := strconv.parse_f32(word[3:])
			if !good do return USAGE
			at = v
		case:
			return USAGE
		}
	}
	sc := current_scene(w)
	i := side_facing(sc, d)
	if i < 0 do return fmt.tprintf("no side %v", COMPASS_WORDS[d])
	s := sc.sides[i]
	c := (s.span[0] + s.span[1]) / 2
	if v, has := at.?; has do c = v
	b, on := side_brink(sc, d, c)
	if !on do return fmt.tprintf("no floor at %.0f along the %v side", c, COMPASS_WORDS[d])
	cancel_approach(w)
	w.exit_walk = {}
	w.player.moving = false
	w.player.heading = {}
	switch by {
	case "go":
		if _, has := at.?; has do stand_in_from(w, sc, d, b)
		w.message_len = 0
		w.stepped_over = ""
		w.crossed = nil
		from := w.current
		if !head_for_side(w, d) do return fmt.tprintf("no way %v", COMPASS_WORDS[d])
		finish_walk(w)
		return walked_aloud(w, from)
	case "arrow":
		stand_in_from(w, sc, d, b)
		ARROWS := [Compass]string{.North = "up", .East = "right", .South = "down", .West = "left"}
		return arrow_bang(w, ARROWS[d])
	case "click":
		q := b + outward(d) * 4
		return click_bang(w, fmt.tprintf("%v,%v", q.x, q.y))
	}
	return USAGE
}

// A step in from the brink at `b`, on the floor: where `!cross` starts her.
@(private = "file")
stand_in_from :: proc(w: ^World, sc: ^Scene, d: Compass, b: [2]f32) {
	p := clamp_to_polygon(b - outward(d) * 48, sc.walk_area)
	w.player.pos = p
	w.player.path_ready = false
}
