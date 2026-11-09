package nengine

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

// Hints, as a Sierra hint book gave them: the first thing she can still do
// to earn points, said three ways, each plainer than the last. A nudge (where
// to go, who to see), then what to do there, then the very words to type.
// The menu's HINT opens it, over a few lines of how she is getting on: the
// score, the hour, where she is and what is still to be had.
//
// The game writes the table; the engine picks from it. Each entry leads to
// one award and says when it can be had:
//
//     HINTS := [?]ne.Hint {
//         {award = "the_photograph", needs = "act2", place = "banda",
//          nudge = "The banda has a wall I have not looked at.",
//          clearer = "There is a photograph on it, and nobody has dusted it.",
//          answer = "In the banda, the photograph on the wall.",
//          does = "look at photograph"},
//     }
//     w.hints = HINTS[:]
//
// **The first entry that can be done now is the hint**, with one twist: an
// award that can be lost (its `until` is set) is hinted before one that will
// wait, so that the photograph on the wall, which will be there all night,
// is never the reason she misses the kiss at twenty-five past five. Within
// each, the table's order. An entry can be done
// when its award has not been earned, the award's own `only` holds (the other
// branch's is nobody's to find), its `needs` hold (flags, as `when=` reads
// them: the act, a thing carried, somebody where they have to be), the story
// clock is inside its window, and its `can`, if it has one, says so. The
// window is the entry's `from` and `until`, or the award's when both are 0;
// a held clock (a boat with no hours, `clock_held`) has no window at all.
// So the table is in the order the story is best played in, and a player
// who follows the hints plays it in that order, skipping what is done.
//
// An entry with no award is an idle one: nothing it says earns anything, it
// is how the story goes on (sleep, take the truck), and it is only the hint
// when no award's entry can be done. A game that leaves none gets the
// engine's shrug.
//
// Asking costs nothing and moves nothing: no tick, no flag, no score. The
// grades shown stay shown until the hint is a different one.

Hint :: struct {
	award:   string,                    // the score key it leads to; "" for an idle entry
	needs:   string,                    // flags, as condition_met reads them
	from:    int,                       // the story clock's window for it; 0 and 0: the award's own
	until:   int,
	can:     proc(w: ^World) -> bool, // anything the flags cannot say; nil for nothing more
	place:   string,                    // the room the answer is typed in (scene name), or "" for wherever she is
	nudge:   string,                    // grade 1: where to go, who to see
	clearer: string,                    // grade 2: what to do there
	answer:  string,                    // grade 3, in words; the typed commands follow it
	does:    string,                    // what she types there, `;` between commands
}

// Which hint is up, and how much of it she has asked for.
Hint_Shown :: struct {
	index: int, // into w.hints, -1 for none
	grade: int, // 1 to 3
}

// A line of the status at the top of the hint: "Score", "845 of 1960".
Status_Line :: struct {
	label, text: string,
}

HINT_GRADES :: 3

// --- Which ---

@(private)
award_declared :: proc(w: ^World, name: string) -> (Award, bool) {
	for a in w.awards do if a.name == name do return a, true
	return {}, false
}

// The entry's window on the story clock: its own, or its award's.
hint_window :: proc(w: ^World, h: Hint) -> (from, until: int) {
	if h.from != 0 || h.until != 0 do return h.from, h.until
	if a, ok := award_declared(w, h.award); ok do return a.from, a.until
	return 0, 0
}

// Can she do it now? Not earned, her branch, its flags, its hour.
hint_possible :: proc(w: ^World, h: Hint) -> bool {
	if h.award != "" {
		a, declared := award_declared(w, h.award)
		if !declared || has_award(w, h.award) do return false
		if a.only != "" && !condition_met(w, a.only) do return false
	}
	if !condition_met(w, h.needs) do return false
	// Never to a room the story keeps her out of now (keep_out.odin).
	if i, known := scene_index(w, h.place); h.place != "" && known && kept_out(w, i) != nil do return false
	if !clock_is_held(w) {
		m := clock_minute(w)
		from, until := hint_window(w, h)
		if from != 0 && m < from do return false
		if until != 0 && m >= until do return false
	}
	if h.can != nil && !h.can(w) do return false
	return true
}

// The hint: the first entry that can be done now for an award that will
// not wait (its `until` is set: it can be lost), then the first for one that
// will, then the first idle entry. -1 if there is none of them.
first_hint :: proc(w: ^World) -> int {
	for h, i in w.hints do if h.award != "" && award_closes(w, h.award) && hint_possible(w, h) do return i
	for h, i in w.hints do if h.award != "" && !award_closes(w, h.award) && hint_possible(w, h) do return i
	for h, i in w.hints do if h.award == "" && hint_possible(w, h) do return i
	return -1
}

// An award that can be lost: it has an hour it goes at.
@(private)
award_closes :: proc(w: ^World, name: string) -> bool {
	a, ok := award_declared(w, name)
	return ok && a.until != 0
}

// What she types, as the answer prints it: LOOK AT THE PHOTOGRAPH, then ...
hint_typed :: proc(does: string, allocator := context.temp_allocator) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	rest := does
	for cmd in strings.split_iterator(&rest, ";") {
		if c := strings.trim_space(cmd); c != "" do append(&parts, strings.to_upper(c, context.temp_allocator))
	}
	return strings.join(parts[:], ", then ", allocator)
}

// One grade of a hint, from 1.
hint_text :: proc(h: Hint, grade: int, allocator := context.temp_allocator) -> string {
	switch grade {
	case 1: return h.nudge
	case 2: return h.clearer
	}
	if h.does == "" do return h.answer
	return fmt.aprintf("%v\nType: %v.", h.answer, hint_typed(h.does), allocator = allocator)
}

// What is still to be had, at most: the points of every award not yet earned
// whose hour has not gone, and whose branch is this one (or has not yet been
// decided against it).
points_open :: proc(w: ^World) -> (points, finds: int) {
	m := clock_minute(w)
	for a in w.awards {
		if a.points <= 0 || has_award(w, a.name) do continue
		if a.only != "" && !condition_met(w, a.only) && !flag(w, award_open_flag(a.name)) do continue
		if !clock_is_held(w) && a.until != 0 && m >= a.until do continue
		points += a.points
		finds += 1
	}
	return
}

// The lines at the top of the hint: the game's, or the score, what is still
// out there, the hour and the room.
status_lines :: proc(w: ^World) -> []Status_Line {
	if w.screen_words.status != nil do return w.screen_words.status(w)
	out := make([dynamic]Status_Line, context.temp_allocator)
	append(&out, Status_Line{"Score", score_text(w)})
	if pts, n := points_open(w); n > 0 do append(&out, Status_Line{"Still to find", fmt.tprintf("up to %v points, in %v finds", pts, n)})
	if !clock_is_held(w) do append(&out, Status_Line{"When", clock_face(clock_minute(w))})
	if w.current >= 0 && w.current < len(w.scenes) do append(&out, Status_Line{"Where", room_label(w, current_scene(w).name)})
	return out[:]
}

// --- The screen ---

open_hint_screen :: proc(w: ^World) {
	open_screen(w, .Hint)
	i := first_hint(w)
	if i != w.hint.index || w.hint.grade < 1 do w.hint = {index = i, grade = 1}
	w.screen.hover = 0
}

// The next grade, as the screen's button and `!hint 2` give it.
hint_more :: proc(w: ^World) {
	if w.hint.index >= 0 do w.hint.grade = min(w.hint.grade + 1, HINT_GRADES)
}

@(private) HINT_LEFT :: 14
@(private) HINT_W :: 292
@(private) HINT_LABEL_GAP :: 6
@(private) HINT_BUTTON_W :: 112

// The hint screen's rows are its two buttons: another hint, and back to the
// menu.
@(private)
hint_rows :: proc(w: ^World) -> int {return 2}

@(private)
hint_line_h :: proc() -> f32 {
	return letter_line() / ui_scale()
}

// What the panel says, as lines: the status, then each grade shown so far.
@(private)
Hint_Para :: struct {
	label: string,
	lines: []string,
	head:  bool, // a status line
}

@(private)
hint_label_w :: proc(paras: []Hint_Para) -> f32 {
	most := f32(0)
	for p in paras do most = max(most, letters_width(p.label))
	return most + gx(HINT_LABEL_GAP)
}

@(private)
hint_paras :: proc(w: ^World) -> []Hint_Para {
	return hint_paras_for(w, w.hint.index, w.hint.grade)
}

@(private)
hint_paras_for :: proc(w: ^World, index, grade: int) -> []Hint_Para {
	out := make([dynamic]Hint_Para, context.temp_allocator)
	for s in status_lines(w) {
		one := make([]string, 1, context.temp_allocator)
		one[0] = s.text
		append(&out, Hint_Para{label = s.label, lines = one, head = true})
	}
	labels := [HINT_GRADES]string{"Nudge", "Clearer", "Answer"}
	text_room := gx(HINT_W - 16)
	if WIDTH > 0 do text_room -= hint_label_w(out[:])
	if index < 0 || index >= len(w.hints) {
		append(&out, Hint_Para{label = "Hint", lines = wrap_measured("Nothing I can see to be had just now.", text_room, letters_width)})
		return out[:]
	}
	h := w.hints[index]
	for g in 1 ..= grade do append(&out, Hint_Para{label = labels[g - 1], lines = wrap_measured(hint_text(h, g), text_room, letters_width)})
	return out[:]
}

@(private)
hint_panel :: proc(w: ^World) -> rl.Rectangle {
	h := min(hint_panel_height(hint_paras(w)), HINT_TALLEST)
	return {HINT_LEFT, math.floor((200 - h) / 2), HINT_W, h}
}

@(private) HINT_TALLEST :: 196

// How tall the panel wants to be for these lines, in grid pixels.
@(private)
hint_panel_height :: proc(paras: []Hint_Para) -> f32 {
	n := 0
	for p in paras do n += len(p.lines)
	body := f32(n) * hint_line_h() + 6
	return math.ceil(f32(SCREEN_HEAD) + body + MENU_H + 8 + SCREEN_FOOT)
}

@(private)
hint_row_rect :: proc(w: ^World, row: int) -> rl.Rectangle {
	p := hint_panel(w)
	y := p.y + p.height - SCREEN_FOOT - MENU_H - 2
	gap := f32(12)
	x := p.x + math.floor((p.width - 2 * HINT_BUTTON_W - gap) / 2)
	return {x + f32(row) * (HINT_BUTTON_W + gap), y, HINT_BUTTON_W, MENU_H}
}

@(private)
hint_button_label :: proc(w: ^World, row: int) -> (label: string, ready: bool) {
	if row == 1 do return "Back to the menu", true
	if w.hint.index < 0 do return "No more", false
	if w.hint.grade >= HINT_GRADES do return "That is all", false
	return "Another hint", true
}

@(private)
hint_pick :: proc(w: ^World, row: int) {
	switch row {
	case 0: hint_more(w)
	case 1: open_menu_screen(w)
	}
}

@(private)
draw_hint_screen :: proc(w: ^World) -> string {
	c := the_comic
	p := hint_panel(w)
	paras := hint_paras(w)
	label_w := hint_label_w(paras)
	x := gx(p.x + 8)
	y := gx(p.y + SCREEN_HEAD)
	bottom := gx(hint_row_rect(w, 0).y - 2)
	lh := letter_line()
	ruled := false
	for para in paras {
		if !para.head && !ruled {
			// A rule between how she is doing and what to do next.
			ruled = true
			ry := math.round(y / ui_scale()) + 1
			grid_fill(p.x + 8, ry, p.x + p.width - 9, ry, c.panel.aside)
			y += gx(4)
		}
		for line, i in para.lines {
			if y + lh > bottom do break
			if i == 0 do letters_draw(para.label, x, y, c.panel.name)
			// The words to type are the answer's last line: lettered as the
			// prompt's own, so they read as something to type.
			ink := c.panel.ink
			if strings.has_prefix(line, "Type:") && para.label == "Answer" do ink = c.panel.name
			letters_draw(line, x + label_w, y, ink)
			y += lh
		}
	}
	for row in 0 ..< hint_rows(w) {
		r := hint_row_rect(w, row)
		label, ready := hint_button_label(w, row)
		rc := rl.Rectangle{gx(r.x), gx(r.y), gx(r.x + r.width) - gx(r.x), gx(r.y + r.height) - gx(r.y)}
		draw_comic_button(rc, label, row == w.screen.hover && ready, ready)
	}
	if w.hint.grade >= HINT_GRADES do return "Asking costs nothing.  Esc goes back to the game."
	return "Another hint is plainer.  Esc goes back to the game."
}

@(private)
hint_screen_report :: proc(w: ^World) -> string {
	b := strings.builder_make(context.temp_allocator)
	for para in hint_paras(w) {
		fmt.sbprintf(&b, "\n    %v: %v", para.label, strings.join(para.lines, " / ", context.temp_allocator))
	}
	for row in 0 ..< hint_rows(w) {
		label, ready := hint_button_label(w, row)
		fmt.sbprintf(&b, "\n    %v [%v]%v", "> " if row == w.screen.hover else "  ", label, "" if ready else " (greyed)")
	}
	return strings.to_string(b)
}

// --- The harness ---
//
//     !status          the status lines, as the hint screen shows them
//     !hint [1|2|3]    the hint at that grade, and which entry it is
//     !hint list       every entry that could be done now, in order
//     !hint try        the hint's answer, done in a copy of the game: what it earned
//     !hint check      for a walk through a script: what was earned since the
//                      last check, whether the hint before it had seen it
//                      coming, and the hint's answer tried, quietly
//     !hint check all  the same, and every other entry that could be done
//                      now tried as well
//     !hint coverage   every award with points has an entry, every entry's
//                      award is declared, and every entry has its words

@(private)
hint_name :: proc(w: ^World, i: int) -> string {
	if i < 0 do return "none"
	h := w.hints[i]
	where_ := h.place if h.place != "" else "here"
	return fmt.tprintf("#%v %v, in %v", i + 1, h.award if h.award != "" else "(idle)", where_)
}

status_report :: proc(w: ^World) -> string {
	b := strings.builder_make(context.temp_allocator)
	for s, i in status_lines(w) do fmt.sbprintf(&b, "%v%v: %v", "" if i == 0 else "; ", s.label, s.text)
	return strings.to_string(b)
}

// What the walk remembers between checks: what had been earned, and which
// awards an entry could have been done for.
@(private) hint_walk_earned: map[string]bool
@(private) hint_walk_possible: map[string]bool
@(private) hint_walk_started: bool

@(private)
hint_bang :: proc(w: ^World, arg: string, on_bang: Bang) -> string {
	if len(w.hints) == 0 do return "this game has no hints"
	switch arg {
	case "", "1", "2", "3":
		grade := 1
		if arg != "" do grade, _ = strconv.parse_int(arg)
		i := first_hint(w)
		if i < 0 do return "no hint: nothing can be done now"
		return fmt.tprintf("[hint %v] %v\n    %v", grade, hint_name(w, i), hint_text(w.hints[i], grade))
	case "list":
		b := strings.builder_make(context.temp_allocator)
		n := 0
		for h, i in w.hints {
			if !hint_possible(w, h) do continue
			fmt.sbprintf(&b, "\n    %v", hint_name(w, i))
			n += 1
		}
		return fmt.tprintf("%v entr%v could be done now%v", n, "y" if n == 1 else "ies", strings.to_string(b))
	case "try":
		i := first_hint(w)
		if i < 0 || w.hints[i].award == "" do return "nothing to try"
		v, _ := hint_try(w, w.hints[i], false, on_bang)
		return fmt.tprintf("tried %v: %v", hint_name(w, i), v)
	case "check":
		return hint_check(w, on_bang)
	case "check all":
		return hint_check(w, on_bang, every = true)
	case "coverage":
		return hint_coverage(w)
	}
	return "!hint [1|2|3|list|try|check|coverage]"
}

@(private)
hint_check :: proc(w: ^World, on_bang: Bang, every := false) -> string {
	b := strings.builder_make(context.temp_allocator)
	// What has been earned since the last check, and whether the table saw
	// each of them coming: an award earned while no entry for it could be
	// done is a hole in the table.
	if hint_walk_started {
		for a in w.awards {
			if !has_award(w, a.name) || a.name in hint_walk_earned do continue
			if a.points <= 0 do continue
			seen := a.name in hint_walk_possible
			fmt.sbprintf(&b, "\n  [hint earned] %v%v", a.name, "" if seen else " -- GAP: no entry for it could be done at the last check")
		}
	}
	clear(&hint_walk_earned)
	clear(&hint_walk_possible)
	hint_walk_started = true
	for a in w.awards do if has_award(w, a.name) do hint_walk_earned[a.name] = true
	for h in w.hints do if h.award != "" && hint_possible(w, h) do hint_walk_possible[h.award] = true

	i := first_hint(w)
	at := fmt.tprintf("%v %v", clock_face(clock_minute(w)), current_scene(w).name)
	switch {
	case i < 0:
		fmt.sbprintf(&b, "\n  [hint check] %v: NONE (nothing can be done, not even an idle entry)", at)
	case w.hints[i].award == "":
		fmt.sbprintf(&b, "\n  [hint check] %v: idle %v", at, hint_name(w, i))
	case:
		v, _ := hint_try(w, w.hints[i], true, on_bang)
		fmt.sbprintf(&b, "\n  [hint check] %v: %v: %v", at, hint_name(w, i), v)
	}
	// `!hint check all`: every other entry that could be done now is tried
	// too, as if it were the hint, so an entry is proved wherever it is
	// possible and not only where it comes first.
	if every && i >= 0 {
		for h, j in w.hints {
			if j == i || h.award == "" || !hint_possible(w, h) do continue
			v, _ := hint_try(w, h, true, on_bang)
			fmt.sbprintf(&b, "\n  [hint also] %v: %v: %v", at, hint_name(w, j), v)
		}
	}
	return strings.trim_left_space(strings.to_string(b))
}

// The hint's answer, done as typed, in a copy of the game (hint_fork), so
// that nothing in this one changes. What it earned.
@(private)
hint_try :: proc(w: ^World, h: Hint, quiet: bool, on_bang: Bang) -> (verdict: string, ok: bool) {
	if w.pending != "" do return "skipped: a question is waiting for its answer", false
	if talking(w) || cutting(w) || riding(w) do return "skipped: something is playing", false
	return hint_fork(w, h, quiet, on_bang)
}

// In the copy: go there, type it, and say what came of it.
@(private)
hint_try_here :: proc(w: ^World, h: Hint, on_bang: Bang) -> string {
	before := score(w)
	had := make(map[string]bool, context.temp_allocator)
	for a in w.awards do if has_award(w, a.name) do had[a.name] = true
	if overlay_open(w) do close_overlay(w)
	if h.place != "" && current_scene(w).name != h.place do script_line(w, fmt.tprintf("!room %v", h.place), on_bang)
	rest := h.does
	for cmd in strings.split_iterator(&rest, ";") {
		if c := strings.trim_space(cmd); c != "" do script_line(w, c, on_bang)
		if w.dead do break
	}
	got := make([dynamic]string, context.temp_allocator)
	for a in w.awards do if has_award(w, a.name) && !(a.name in had) do append(&got, a.name)
	gained := strings.join(got[:], " ", context.temp_allocator)
	switch {
	case w.dead:
		return fmt.tprintf("FAIL: she died (%v)", w.death.reason)
	case has_award(w, h.award):
		return fmt.tprintf("ok +%v (%v)", score(w) - before, gained)
	case len(got) > 0:
		return fmt.tprintf("FAIL: earned %v instead (+%v)", gained, score(w) - before)
	}
	return "FAIL: earned nothing"
}

@(private)
hint_coverage :: proc(w: ^World) -> string {
	b := strings.builder_make(context.temp_allocator)
	scored, hinted := 0, 0
	missing := make([dynamic]string, context.temp_allocator)
	for a in w.awards {
		if a.points <= 0 do continue
		scored += 1
		found := false
		for h in w.hints do if h.award == a.name do found = true
		if found do hinted += 1
		else do append(&missing, a.name)
	}
	bad := make([dynamic]string, context.temp_allocator)
	for h, i in w.hints {
		if h.award != "" {
			if _, ok := award_declared(w, h.award); !ok do append(&bad, fmt.tprintf("#%v names no award: %v", i + 1, h.award))
			if h.does == "" do append(&bad, fmt.tprintf("#%v %v: nothing to type", i + 1, h.award))
		}
		if h.nudge == "" || h.clearer == "" || h.answer == "" do append(&bad, fmt.tprintf("#%v %v: a grade with no words", i + 1, h.award))
		// All three grades, under the status, must fit the screen. Lettering
		// needs a window to be measured, which the harness has.
		if WIDTH > 0 && hint_panel_height(hint_paras_for(w, i, HINT_GRADES)) > HINT_TALLEST {
			append(&bad, fmt.tprintf("#%v %v: too long for the screen at the third grade", i + 1, h.award))
		}
		if _, known := scene_index(w, h.place); h.place != "" && len(w.scenes) > 0 && !known do append(&bad, fmt.tprintf("#%v %v: no room %v", i + 1, h.award, h.place))
	}
	fmt.sbprintf(&b, "%v awards with points, %v with a hint; %v entries", scored, hinted, len(w.hints))
	if len(missing) == 0 && len(bad) == 0 {
		strings.write_string(&b, "; coverage ok")
		return strings.to_string(b)
	}
	if len(missing) > 0 do fmt.sbprintf(&b, "\n    no hint: %v", strings.join(missing[:], " ", context.temp_allocator))
	for s in bad do fmt.sbprintf(&b, "\n    %v", s)
	return strings.to_string(b)
}
