package pixel

import ne "../../"
import "core:strings"
import rl "vendor:raylib"

// The little picture of the art as the game would draw it, shown beside the
// grid you are painting in. Every art editor wants one, so it lives here
// rather than in whichever of them happened to grow it first.

// Where the colours panel starts out, in every art editor. They share the
// remembered width too, because it is the same panel in each of them.
SIDE_W :: f32(220)

Preview :: struct {
	texture: rl.Texture2D,
	stale:   bool,
}

preview_destroy :: proc(p: ^Preview) {
	if p.texture.id != 0 do rl.UnloadTexture(p.texture)
	p^ = {}
}

// `fit` caps the width it may take up, so a 320-wide backdrop shrinks to
// fit a panel instead of running off the side of it.
preview_draw :: proc(p: ^Preview, d: ^ne.Sprite_Data, at: [2]f32, scale: f32 = 1, fit: f32 = 0) {
	if p.stale {
		if p.texture.id != 0 do rl.UnloadTexture(p.texture)
		sheet := ne.sprite_data_to_sprite(d, 1)
		p.texture = sheet.texture
		p.stale = false
	}
	if p.texture.id == 0 do return
	shown := scale
	if fit > 0 do shown = min(scale, fit / f32(p.texture.width))
	rl.DrawTextureEx(p.texture, at, 0, shown, rl.WHITE)
}

// "assets/sprites/lamp.sprite" -> "lamp"
asset_base :: proc(path: string) -> string {
	name := path
	if slash := strings.last_index_byte(name, '/'); slash >= 0 do name = name[slash + 1:]
	if dot := strings.last_index_byte(name, '.'); dot > 0 do name = name[:dot]
	return name
}


// Drawing one frame of the sheet, rather than all of them side by side.
preview_frame :: proc(p: ^Preview, d: ^ne.Sprite_Data, frame: i32, at: [2]f32, scale: f32) {
	if p.stale {
		if p.texture.id != 0 do rl.UnloadTexture(p.texture)
		sheet := ne.sprite_data_to_sprite(d, 1)
		p.texture = sheet.texture
		p.stale = false
	}
	if p.texture.id == 0 do return
	src := rl.Rectangle{f32(frame * d.w), 0, f32(d.w), f32(d.h)}
	rl.DrawTexturePro(p.texture, src, {at.x, at.y, f32(d.w) * scale, f32(d.h) * scale}, 0, 0, rl.WHITE)
}
