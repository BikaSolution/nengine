package cutscene

import ne "../../../"
import ui "../../ui"
import "core:fmt"
import rl "vendor:raylib"

// What the file browser says about a .cut before you open it. A cutscene has
// no pixels, so it draws its own summary instead of going through the pixel
// engine's preview pane: the cast, and the cues as the timeline they are.

detail :: proc(path: string) -> string {
	c, ok := ne.load_cutscene(path)
	if !ok do return "unreadable"
	defer ne.cutscene_destroy(&c)
	return fmt.aprintf("%.0fs  %v cast  %v cues", ne.cutscene_length(&c), len(c.people), len(c.cues))
}

preview :: proc(path: string, area: rl.Rectangle) -> bool {
	c, ok := ne.load_cutscene(path)
	if !ok {
		ui.label(i32(area.x), i32(area.y), "could not read it", ui.DIM, ui.SMALL)
		return true
	}
	defer ne.cutscene_destroy(&c)

	y := i32(area.y)
	room := c.scene if c.scene != "" else "(no room set)"
	ui.label(i32(area.x), y, ui.ellipsize(room, area.width, ui.SMALL), ui.INK, ui.SMALL)
	y += 20
	secs := ne.cutscene_length(&c)
	ui.label(i32(area.x), y, fmt.tprintf("%.1f seconds, %v cues", secs, len(c.cues)), ui.DIM, ui.SMALL)
	y += 26

	// The timeline in miniature: one row per person, so the shape of the scene
	// — who talks, who moves, where the gaps are — reads before you open it.
	rows := len(c.people) + 1
	row_h := f32(14)
	box := rl.Rectangle{area.x, f32(y), area.width, f32(rows) * row_h + 4}
	rl.DrawRectangleRec(box, {20, 20, 26, 255})
	rl.DrawRectangleLinesEx(box, 1, ui.EDGE)
	for q in c.cues {
		row := 0
		if q.who != "" {
			if i := ne.cutscene_member(&c, q.who); i >= 0 do row = i + 1
		}
		x := box.x + 2 + (box.width - 8) * q.at / max(secs, 0.001)
		rl.DrawRectangleRec({x, box.y + 2 + f32(row) * row_h, 4, row_h - 3}, colour_of(q.action))
	}
	y += i32(box.height) + 10

	for m in c.people {
		if f32(y) > area.y + area.height - 18 do break
		lines := 0
		for q in c.cues do if q.who == m.name do lines += 1
		ui.label(i32(area.x), y, ui.ellipsize(m.name, area.width * 0.5, ui.SMALL), ui.INK, ui.SMALL)
		right := fmt.tprintf("%v cues", lines)
		ui.label(i32(area.x + area.width) - ui.measure(right, ui.SMALL), y, right, ui.DIM, ui.SMALL)
		y += 18
	}
	return true
}

@(private = "file")
colour_of :: proc(a: ne.Cue_Action) -> rl.Color {
	#partial switch a {
	case .Walk_To: return {120, 190, 255, 255}
	case .Say:     return {150, 220, 140, 255}
	case .Think:   return {200, 180, 240, 255}
	case .Narrate: return {220, 210, 150, 255}
	case .Line:    return {170, 230, 190, 255}
	case .Shake:   return {240, 150, 130, 255}
	case .Sound:   return {240, 190, 120, 255}
	}
	return {170, 170, 190, 255}
}
