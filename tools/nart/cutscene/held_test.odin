package cutscene

import ne "../../../"
import "core:testing"

// The stage draws what somebody holds as the game does (held_part asks the
// engine's own rules, nengine/actor.odin, the walk pair).

@(private = "file")
HELD_CHAR :: `character porter
size 2 2
pal # 10,20,30,255
part coat frames=1
frame 0
##
##
part coat_walk frames=1 step=8 faces=left
frame 0
##
##
part pail frames=1 step=10 faces=left mirror=ok
frame 0
##
##
part sit frames=1
frame 0
##
##
`

@(test)
the_stage_holds_a_part_as_the_game_does :: proc(t: ^testing.T) {
	c, ok := ne.parse_character(HELD_CHAR)
	testing.expect(t, ok)
	defer ne.character_destroy(&c)
	Case :: struct {
		held:        string,
		facing:      ne.Facing,
		facing_left: bool,
		walking:     bool,
		part:        string,
		flip, ok:    bool,
	}
	cases := []Case {
		{"coat", .Left, true, true, "coat_walk", false, true},   // its walk, drawn that way
		{"coat", .Right, false, true, "", false, true},          // nothing that way: the plain walk
		{"coat", .Front, true, true, "coat_walk", false, true},  // down the screen: the side last faced
		{"pail", .Right, false, true, "pail", true, true},       // mirror=ok: flipped
		{"pail", .Front, false, true, "pail", true, true},       // down after the mirrored side: still flipped
		{"sit", .Right, false, true, "", false, false},          // no walk: a walk puts it down
		{"coat", .Right, false, false, "coat", false, true},     // standing: as drawn
	}
	for k in cases {
		part, flip, good := held_part(&c, k.held, "", "", k.facing, k.facing_left, k.walking)
		testing.expectf(t, part == k.part && flip == k.flip && good == k.ok, "%v %v walking=%v: %q flip=%v ok=%v", k.held, k.facing, k.walking, part, flip, good)
	}
	// The line's walk= goes with the line's pose only.
	part, _, _ := held_part(&c, "sit", "coat_walk", "sit", .Left, true, true)
	testing.expect_value(t, part, "coat_walk")
	_, _, good := held_part(&c, "sit", "coat_walk", "coat", .Left, true, true)
	testing.expect(t, !good)
}
