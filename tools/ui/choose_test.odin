package ui

import "core:testing"

// A search in a list asked from inside an editor (choose.odin): every word
// somewhere in the key, the label or the search text, without case.
@(test)
a_search_finds_every_word_anywhere_in_an_item :: proc(t: ^testing.T) {
	node := Choice{key = "A2.GT.FENCE", label = "A2.GT.FENCE  The fence line", search = "MOORE: Two gates, one key."}
	testing.expect(t, choose_matches(node, ""))
	testing.expect(t, choose_matches(node, "fence"))
	testing.expect(t, choose_matches(node, "a2.gt"))
	testing.expect(t, choose_matches(node, "two GATES"))
	testing.expect(t, choose_matches(node, "moore fence"))
	testing.expect(t, !choose_matches(node, "fence percy"))
	testing.expect(t, !choose_matches(Choice{key = "x", label = "x"}, "gates"))
}
