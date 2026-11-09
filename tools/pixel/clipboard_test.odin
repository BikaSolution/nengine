package pixel

import ne "../../"
import "core:testing"

@(test)
pasting_matches_colours_rather_than_indices :: proc(t: ^testing.T) {
	defer clipboard_destroy()

	// Copy from a document where red is index 1.
	from := ne.sprite_data_new("from", 2, 1, 1)
	defer ne.sprite_data_destroy(&from)
	append(&from.palette, ne.Palette_Entry{'#', {255, 0, 0, 255}})
	ne.sprite_data_at(&from, 0, 0, 0)^ = 1
	clip_copy(&from, 0, {0, 0, 2, 1})

	// Paste into one where index 1 is blue and red isn't there at all.
	into := ne.sprite_data_new("into", 2, 1, 1)
	defer ne.sprite_data_destroy(&into)
	append(&into.palette, ne.Palette_Entry{'#', {0, 0, 255, 255}})
	testing.expect(t, clip_paste(&into, 0, 0, 0))

	// The pasted pixel must still be red: a new palette entry, not index 1.
	landed := ne.sprite_data_at(&into, 0, 0, 0)^
	testing.expect_value(t, into.palette[int(landed)].color, ne.rl_color(255, 0, 0, 255))
	testing.expect_value(t, into.palette[1].color, ne.rl_color(0, 0, 255, 255))

	// And a transparent source pixel leaves the destination alone.
	testing.expect_value(t, ne.sprite_data_at(&into, 0, 1, 0)^, u8(0))
}
