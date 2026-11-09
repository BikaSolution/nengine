// nart: nengine's art tool.
//
// Four editors over one pixel engine, each in its own folder:
//
//     sprite/      .sprite   a thing: a lamp, a hat, a key
//     background/  .sprite   a room, 320x200, with its floor drawn over it
//     character/   .char     a person: ten poses sharing one palette
//     cutscene/    .cut      a room, a cast, and cues on a clock
//
// They are one program rather than four because they share a clipboard and a
// palette, and copying a patch of pixels out of a sprite and into a character
// is a thing you do constantly. Four programs would each get their own
// clipboard and that would stop working. What they actually share is in
// ../pixel: the grid, the palette, selection, copy and paste, and the little
// picture of how the game will draw it.
//
// Which editor opens follows from the file, not from a flag. A .sprite the
// size of the screen is a backdrop and gets the backdrop editor; a smaller one
// is a sprite.
//
//     nart                                  browse for something to open
//     nart assets/sprites/lamp.sprite       open that one
//     nart assets/scenes/veranda.sprite     ... in the backdrop editor
//     nart assets/cutscenes/arrival.cut
//
// Or drive it from the command line, which is the point of the text formats
// — no window, no mouse, and it composes with everything else:
//
//     nart sprite new assets/hat.sprite 12 10
//     nart sprite resize assets/hat.sprite 20 16
//     nart character png assets/characters/ada.char ada.png 4
//
// `nart help` lists the lot.
package main

import ne "../../"
import "../pixel"
import ui "../ui"
import "./background"
import "./character"
import "./cutscene"
import "./sprite"
import "core:fmt"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

main :: proc() {
	args := os.args[1:]
	if len(args) > 0 {
		switch args[0] {
		case "help", "-h", "--help":
			usage()
			return
		case "sprite", "background", "bg":
			if !sprite_cmd(args[1:]) do os.exit(1)
			return
		case "character", "char":
			if !character_cmd(args[1:]) do os.exit(1)
			return
		case "cutscene", "cut":
			if !cutscene_cmd(args[1:]) do os.exit(1)
			return
		case "mode":
			if !mode_cmd(args[1:]) do os.exit(1)
			return
		case "ramp":
			if !ramp_cmd(args[1:]) do os.exit(1)
			return
		case "dither":
			if !dither_cmd(args[1:]) do os.exit(1)
			return
		}
	}

	flags := ui.parse_flags(args)
	app := App{}

	// A file to open, a folder to go looking in, or neither.
	arg := flags.rest[0] if len(flags.rest) > 0 else ""
	switch ui.target_of(arg) {
	case .Nothing:
		app.browsing = true
	case .Folder:
		app.browsing = true
		app.dir = strings.clone(arg)
	case .Missing:
		fmt.eprintfln("nart: there is no %v", arg)
		fmt.eprintfln("      make one with `nart sprite new %v`, or run `nart` and browse", arg)
		os.exit(1)
	case .File:
		kind, known := kind_of_path(arg)
		if !known {
			fmt.eprintfln("nart: %v is not a .sprite, a .char or a .cut", arg)
			os.exit(1)
		}
		app.kind = kind
		app.path = strings.clone(arg)
	}

	app.find = flags.find
	ui.run({title = "nart", size = flags.window, shot = flags.shot, frames = flags.frames, events = flags.events}, &app, frame, app_close)
}

usage :: proc() {
	fmt.println(`nart - nengine's art tool: sprites, backdrops, characters, cutscenes

  nart                               browse for something to open
  nart <file>                        open it in the editor its kind wants
  nart <folder>                      browse, starting there
  nart --find lamp                   browse, already searching
  nart <file> --window 900x600 --shot out.png [--frames N]

sprite            (also: background, for one the size of the screen)
  sprite new <file> [w] [h] [frames] a blank sprite
  sprite info <file>                 size, frames, palette
  sprite resize <file> <w> <h>       change the grid, keeping what still fits
  sprite png <file> <out.png> [scale] export a picture of it

character
  character new <file> [name]        a character with every pose, blank
  character info <file>              its poses, and which are still empty
  character png <file> <out.png> [scale]  every pose on one sheet, to look at
  character part add <file> <name> [frames] [fps]   an extra pose, blank
  character part copy <file> <from> <to>            an extra, starting as a copy
  character part rename <file> <old> <new>          extras only
  character part remove <file> <name>               extras only
  character part hold <file> <name> <frame> <ticks>  how long one frame shows (1 is normal)

cutscene
  cutscene new <file> [name]         an empty cutscene
  cutscene info <file>               its cast and its cues, in time order

colour            (.sprite and .char alike)
  mode <file>                        which mode it is, and what breaks it
  mode <file> bega|fega|vga          change it, snapping every colour to fit
  ramp <file>                        its materials, and what each reads as
  ramp <file> <name> <hex>...        a material: its tones, darkest first
  ramp <file> remove <name>
  dither <file> <from> <with> <ratio> [pattern]
                                     make a flat colour a dither of two

  bega  the sixteen an EGA card came up in
  fega  any of the sixty-four it can make
  vga   six bits a channel

  Shade by dithering two tones of a ramp: B in any editor, then , and . for
  light. Sixteen colours in pairs is a few hundred apparent ones.`)
}

// --- The window ---

Kind :: enum {
	Sprite,
	Background,
	Character,
	Cutscene,
}

App :: struct {
	kind:     Kind,
	path:     string,
	dir:      string, // where the browser starts, if a folder was named
	browsing: bool,
	find:     string, // --find: what to put in the search box (borrowed from the command line)
	opened:   bool,
	browser:  ui.Browser,
	browse:   pixel.Browse,
	sprite:   sprite.Editor,
	backdrop: background.Editor,
	person:   character.Editor,
	cut:      cutscene.Editor,
}

// Everything nart edits is listed together, because you rarely know which one
// you want before you see it, and because a room is made of all four.
KINDS := [?]ui.File_Kind {
	{
		suffix = ".sprite",
		label = "sprite",
		color = {130, 200, 255, 255},
		blank = sprite_blank,
		fields = SPRITE_FIELDS[:],
	},
	{suffix = ".char", label = "char", color = {240, 190, 120, 255}, blank = character_blank},
	{suffix = ".cut", label = "cut", color = {200, 180, 240, 255}, blank = cutscene_blank},
}

SPRITE_FIELDS := [?]ui.New_Field {
	{label = "w", value = 16, lo = 1, hi = 512},
	{label = "h", value = 16, lo = 1, hi = 512},
	{label = "frames", value = 1, lo = 1, hi = 64},
}

// A .sprite is a backdrop if it fills the screen. Nothing in the format says
// which it is, and nothing needs to: a room is 320x200 and a hat is not.
kind_of_path :: proc(path: string) -> (Kind, bool) {
	switch {
	case strings.has_suffix(path, ".char"): return .Character, true
	case strings.has_suffix(path, ".cut"):  return .Cutscene, true
	case strings.has_suffix(path, ".sprite"):
		return .Background if background.is_backdrop(path) else .Sprite, true
	}
	return .Sprite, false
}

frame :: proc(data: rawptr, status: ^ui.Status) -> bool {
	app := cast(^App)data

	if !app.browsing {
		if !app.opened do open_editor(app)
		alive := false
		switch app.kind {
		case .Sprite:     alive = sprite.step(&app.sprite, status)
		case .Background: alive = background.step(&app.backdrop, status)
		case .Character:  alive = character.step(&app.person, status)
		case .Cutscene:   alive = cutscene.step(&app.cut, status)
		}
		if alive do return true
		back_to_browser(app)
		// The key or the click that left the editor has done its job. The
		// browser opens on this same frame rather than leaving one blank, and
		// must not see it too: an Esc that closed the editor would quit.
		ui.input_swallow()
	}

	if !app.browser.loaded {
		ui.browser_open(&app.browser, "Art", "nart", KINDS[:], app.dir, art_detail, art_preview, app, app.find)
		ui.browser_select(&app.browser, app.path)
	}
	path, chosen, running := ui.browser_step(&app.browser, status)
	if chosen {
		file := strings.clone(path, context.temp_allocator)
		ui.browser_close(&app.browser)
		pixel.browse_close(&app.browse)
		app.browsing = false
		delete(app.path)
		app.path = strings.clone(file)
		app.kind, _ = kind_of_path(file)
		open_editor(app)
		return true
	}
	if !running {
		ui.browser_close(&app.browser)
		pixel.browse_close(&app.browse)
		return false
	}
	return true
}

// Esc in an editor goes back to the list, not out of the program — so you can
// open a second file without starting the tool again, which is most of what
// anyone does with it. Esc from the list is what quits. ^B and the `< files`
// button do the same; all three ask first if there are unsaved changes (see
// ui/leave.odin), and the list opens on the folder the file is in, with the
// file selected.
back_to_browser :: proc(app: ^App) {
	close_editor(app)
	ui.reset_dir(&app.dir, app.path)
	// A --find is for the first look only, not for coming back to the list.
	// It is a slice of the command line, so it is dropped, never freed.
	app.find = ""
	app.browsing = true
}

open_editor :: proc(app: ^App) {
	app.opened = true
	switch app.kind {
	case .Sprite:     sprite.open(&app.sprite, app.path)
	case .Background: background.open(&app.backdrop, app.path)
	case .Character:  character.open(&app.person, app.path)
	case .Cutscene:   cutscene.open(&app.cut, app.path, assets_near(app.path))
	}
}

close_editor :: proc(app: ^App) {
	if !app.opened do return
	switch app.kind {
	case .Sprite:     sprite.close(&app.sprite)
	case .Background: background.close(&app.backdrop)
	case .Character:  character.close(&app.person)
	case .Cutscene:   cutscene.close(&app.cut)
	}
	app.opened = false
}

// Called by ui.run on the way out, while the window is still open. It takes a
// rawptr for the same reason `frame` does: the host knows nothing about App.
app_close :: proc(data: rawptr) {
	app := cast(^App)data
	ui.browser_close(&app.browser)
	pixel.browse_close(&app.browse)
	close_editor(app)
	pixel.clipboard_destroy()
	delete(app.path)
	delete(app.dir)
}

// --- What the browser shows ---
//
// Each format knows how to describe itself; this only picks which one to ask.

art_detail :: proc(ctx: rawptr, path: string, kind: int) -> string {
	k, known := kind_of_path(path)
	if !known do return ""
	switch k {
	case .Character:  return character.detail(path)
	case .Cutscene:   return cutscene.detail(path)
	case .Background: return background.detail(path)
	case .Sprite:     return sprite.detail(path)
	}
	return ""
}

art_preview :: proc(ctx: rawptr, path: string, kind: int, area: rl.Rectangle) -> bool {
	app := cast(^App)ctx
	k, known := kind_of_path(path)
	if !known do return false

	// A cutscene isn't pixels, so it draws its own summary rather than going
	// through the pixel engine's pane.
	if k == .Cutscene do return cutscene.preview(path, area)

	if !pixel.browse_showing(&app.browse, path) {
		switch k {
		case .Character:  character.fill_browse(&app.browse, path)
		case .Background: background.fill_browse(&app.browse, path)
		case .Sprite:     sprite.fill_browse(&app.browse, path)
		case .Cutscene:   // handled above
		}
	}
	return pixel.browse_draw(&app.browse, area)
}

// What the browser writes when you name a new file. A sprite takes its size
// from the boxes beside the name; the others have nothing to ask.
sprite_blank :: proc(path, name: string, opts: []int) -> bool {
	w := i32(opts[0]) if len(opts) > 0 else 16
	h := i32(opts[1]) if len(opts) > 1 else 16
	frames := i32(opts[2]) if len(opts) > 2 else 1
	return sprite.write_blank(path, name, w, h, frames)
}

character_blank :: proc(path, name: string, opts: []int) -> bool {
	return character.write_blank(path, name)
}

cutscene_blank :: proc(path, name: string, opts: []int) -> bool {
	return cutscene.write_blank(path, name)
}

// --- sprite ---

sprite_cmd :: proc(args: []string) -> bool {
	if len(args) < 2 do return ui.fail("sprite: need a command and a file")
	path := args[1]
	switch args[0] {
	case "new":
		w := ui.num(args, 2, 16)
		h := ui.num(args, 3, 16)
		frames := ui.num(args, 4, 1)
		name := ui.base_name(path)
		if !sprite.write_blank(path, name, i32(w), i32(h), i32(frames)) do return ui.fail("sprite new: could not write %v", path)
		fmt.printfln("%v: %v  %vx%v  %v frame(s)", path, name, w, h, frames)
		return true

	case "info":
		d, ok := ne.load_sprite_data(path)
		if !ok do return ui.fail("sprite info: could not read %v", path)
		defer ne.sprite_data_destroy(&d)
		fmt.printfln("%v  %vx%v  %v frame(s)  %v colours", d.name, d.w, d.h, d.frames, len(d.palette))
		used := 0
		for p in d.pixels do if p != 0 do used += 1
		fmt.printfln("%v of %v pixels painted", used, len(d.pixels))
		return true

	case "resize":
		if len(args) < 4 do return ui.fail("sprite resize: need a width and a height")
		d, ok := ne.load_sprite_data(path)
		if !ok do return ui.fail("sprite resize: could not read %v", path)
		defer ne.sprite_data_destroy(&d)
		was_w, was_h := d.w, d.h
		ne.sprite_data_resize(&d, i32(ui.num(args, 2, int(d.w))), i32(ui.num(args, 3, int(d.h))))
		if !ne.save_sprite_data(&d, path) do return ui.fail("sprite resize: could not write %v", path)
		fmt.printfln("%v: %vx%v -> %vx%v  (%v frame(s) kept)", path, was_w, was_h, d.w, d.h, d.frames)
		return true

	case "png":
		if len(args) < 3 do return ui.fail("sprite png: need an output file")
		d, ok := ne.load_sprite_data(path)
		if !ok do return ui.fail("sprite png: could not read %v", path)
		defer ne.sprite_data_destroy(&d)
		scale := i32(ui.num(args, 3, 4))
		// No window, so paint the image on the CPU rather than the GPU.
		img := rl.GenImageColor(d.w * d.frames * scale, d.h * scale, rl.BLANK)
		defer rl.UnloadImage(img)
		for f in 0 ..< d.frames {
			for y in 0 ..< d.h {
				for x in 0 ..< d.w {
					idx := int(ne.sprite_data_at(&d, f, x, y)^)
					if idx == 0 || idx >= len(d.palette) do continue
					rl.ImageDrawRectangle(&img, (f * d.w + x) * scale, y * scale, scale, scale, d.palette[idx].color)
				}
			}
		}
		if !rl.ExportImage(img, fmt.ctprintf("%v", args[2])) do return ui.fail("sprite png: could not write %v", args[2])
		fmt.printfln("wrote %v", args[2])
		return true
	}
	return ui.fail("sprite: don't know %v", args[0])
}

// --- character ---

character_cmd :: proc(args: []string) -> bool {
	if len(args) < 2 do return ui.fail("character: need a command and a file")
	path := args[1]
	switch args[0] {
	case "new":
		name := args[2] if len(args) > 2 else ui.base_name(path)
		if !character.write_blank(path, name) do return ui.fail("character new: could not write %v", path)
		fmt.printfln("%v: character %v, %v poses to draw", path, name, len(ne.CHAR_PARTS))
		return true

	case "info":
		c, ok := ne.load_character(path)
		if !ok do return ui.fail("character info: could not read %v", path)
		defer ne.character_destroy(&c)
		fmt.printfln("character %v", c.name)
		for &p in c.parts {
			drawn := 0
			for v in p.data.pixels do if v != 0 do drawn += 1
			fmt.printfln("  %-12v %vx%v  %v frame(s)%v  %-11v %v",
				p.name, p.data.w, p.data.h, p.data.frames,
				fmt.tprintf("  %v fps", p.fps) if p.fps > 0 else "",
				fmt.tprintf("%v pixels", drawn) if drawn > 0 else "empty",
				"" if ne.char_part_standard(p.name) else "extra")
		}
		// The ten are picked from the direction walked; the rest have to be
		// asked for, so say how, because that is the part people forget.
		if extras := ne.character_extras(&c); len(extras) > 0 {
			fmt.printfln("  -- %v extra pose(s): play by name, e.g. `step %v play %v 3`",
				len(extras), c.name, extras[0])
		}
		return true

	case "part":
		return character_part_cmd(args[1:])

	case "png":
		// Every pose, one per row, frames left to right: the whole character
		// on one sheet you can look at.
		if len(args) < 3 do return ui.fail("character png: need an output file")
		c, ok := ne.load_character(path)
		if !ok do return ui.fail("character png: could not read %v", path)
		defer ne.character_destroy(&c)
		scale := i32(ui.num(args, 3, 4))

		wide, tall: i32
		for &p in c.parts {
			wide = max(wide, p.data.w * p.data.frames)
			tall += p.data.h + 1
		}
		// Mid grey, so both the black hat and the white eyes show up.
		img := rl.GenImageColor(wide * scale, tall * scale, rl.Color{110, 110, 120, 255})
		defer rl.UnloadImage(img)
		y: i32
		for &p in c.parts {
			for f in 0 ..< p.data.frames {
				for py in 0 ..< p.data.h {
					for px in 0 ..< p.data.w {
						idx := int(ne.sprite_data_at(&p.data, f, px, py)^)
						if idx == 0 || idx >= len(p.data.palette) do continue
						rl.ImageDrawRectangle(&img, (f * p.data.w + px) * scale, (y + py) * scale,
							scale, scale, p.data.palette[idx].color)
					}
				}
			}
			y += p.data.h + 1
		}
		if !rl.ExportImage(img, fmt.ctprintf("%v", args[2])) do return ui.fail("character png: could not write %v", args[2])
		fmt.printfln("wrote %v  (%v poses, %vx%v)", args[2], len(c.parts), wide * scale, tall * scale)
		return true
	}
	return ui.fail("character: don't know %v", args[0])
}

// `character part ...`: the poses beyond the standard ten, from the command
// line. The editor does the same four things with A, D, R and Delete; this is
// for the times when a character needs six extras and you know their names.
character_part_cmd :: proc(args: []string) -> bool {
	if len(args) < 3 do return ui.fail("character part: need add|copy|rename|remove|hold, a file and a name")
	what, path := args[0], args[1]

	c, ok := ne.load_character(path)
	if !ok do return ui.fail("character part: could not read %v", path)
	defer ne.character_destroy(&c)

	switch what {
	case "add":
		name := args[2]
		if !ne.char_part_name_ok(name) do return ui.fail("character part add: %v is not a name a pose can have (letters, digits, _)", name)
		if ne.character_part(&c, name) != nil do return ui.fail("character part add: %v already has a pose called %v", path, name)
		frames := i32(max(ui.num(args, 3, 1), 1))
		fps: f32 // a pose can be slower than one frame a second, so not ui.num
		if len(args) > 4 do fps = ui.to_f32(args[4])
		ne.character_add_part(&c, name, frames, fps)
		if !ne.save_character(&c, path) do return ui.fail("character part add: could not write %v", path)
		fmt.printfln("%v: %v, %v frame(s)%v, blank", path, name, frames,
			fmt.tprintf(" at %v fps", fps) if fps > 0 else "")
		return true

	case "hold":
		// Frames count from 1, as the editor shows them.
		if len(args) < 5 do return ui.fail("character part hold: need a pose, a frame (from 1) and a number of ticks")
		part := ne.character_part(&c, args[2])
		if part == nil do return ui.fail("character part hold: %v has no pose called %v", path, args[2])
		frame := i32(ui.num(args, 3, 1)) - 1
		if frame < 0 || frame >= part.data.frames do return ui.fail("character part hold: %v has %v frame(s)", args[2], part.data.frames)
		ne.sprite_data_set_hold(&part.data, frame, i32(max(ui.num(args, 4, 1), 1)))
		if !ne.save_character(&c, path) do return ui.fail("character part hold: could not write %v", path)
		fmt.printfln("%v: %v frame %v holds for %v tick(s); %.2fs a time through", path, args[2], frame + 1,
			ne.sprite_data_hold(&part.data, frame), ne.anim_secs(part.data.frames, part.fps, part.data.holds[:]))
		return true

	case "copy":
		if len(args) < 4 do return ui.fail("character part copy: need a pose to copy and a name for the copy")
		from, to := args[2], args[3]
		if ne.character_part(&c, from) == nil do return ui.fail("character part copy: %v has no pose called %v", path, from)
		if ne.character_copy_part(&c, from, to) == nil do return ui.fail("character part copy: cannot call it %v", to)
		if !ne.save_character(&c, path) do return ui.fail("character part copy: could not write %v", path)
		fmt.printfln("%v: %v, a copy of %v", path, to, from)
		return true

	case "rename":
		if len(args) < 4 do return ui.fail("character part rename: need the old name and the new one")
		old, name := args[2], args[3]
		if ne.char_part_standard(old) do return ui.fail("character part rename: %v is one of the standard ten and is looked up by name", old)
		if ne.character_part(&c, old) == nil do return ui.fail("character part rename: %v has no pose called %v", path, old)
		if !ne.character_rename_part(&c, old, name) do return ui.fail("character part rename: cannot call it %v", name)
		if !ne.save_character(&c, path) do return ui.fail("character part rename: could not write %v", path)
		fmt.printfln("%v: %v is now %v", path, old, name)
		return true

	case "remove":
		name := args[2]
		if ne.char_part_standard(name) do return ui.fail("character part remove: %v is one of the standard ten; it stays, drawn or not", name)
		if !ne.character_remove_part(&c, name) do return ui.fail("character part remove: %v has no pose called %v", path, name)
		if !ne.save_character(&c, path) do return ui.fail("character part remove: could not write %v", path)
		fmt.printfln("%v: removed %v", path, name)
		return true
	}
	return ui.fail("character part: don't know %v", what)
}


// --- cutscene ---

cutscene_cmd :: proc(args: []string) -> bool {
	if len(args) < 2 do return ui.fail("cutscene: need a command and a file")
	path := args[1]
	switch args[0] {
	case "new":
		name := args[2] if len(args) > 2 else ui.base_name(path)
		if !cutscene.write_blank(path, name) do return ui.fail("cutscene new: could not write %v", path)
		fmt.printfln("%v: cutscene %v", path, name)
		return true

	case "info":
		c, ok := ne.load_cutscene(path)
		if !ok do return ui.fail("cutscene info: could not read %v", path)
		defer ne.cutscene_destroy(&c)
		fmt.printfln("cutscene %v  %.1fs  in %v", c.name, ne.cutscene_length(&c),
			c.scene if c.scene != "" else "(no room)")
		for m in c.people {
			fmt.printfln("  cast %-10v %-10v %v %v",
				m.name, m.character if m.character != "" else "(no art)",
				"where they stand" if m.keep_place else fmt.tprintf("at %v,%v", int(m.at.x), int(m.at.y)),
				"facing their own way" if m.keep_facing else fmt.tprintf("facing %v", ne.facing_text(m.facing)))
		}
		for q in c.cues {
			fmt.printfln("  %5.2fs %-8v %v", q.at, q.who if q.who != "" else "-", cue_line(q))
		}
		return true
	}
	return ui.fail("cutscene: don't know %v", args[0])
}

@(private = "file")
cue_line :: proc(q: ne.Cue) -> string {
	switch q.action {
	case .Walk_To: return fmt.tprintf("walk_to %v,%v", int(q.to.x), int(q.to.y))
	case .Face:    return fmt.tprintf("face %v", ne.facing_text(q.facing))
	case .Play:
		if q.times == 1 do return fmt.tprintf("play %v once", q.text)
		if q.times > 1 do return fmt.tprintf("play %v %vx", q.text, q.times)
		return fmt.tprintf("play %v %.2f", q.text, q.amount)
	case .Say:     return fmt.tprintf("say %v", q.text)
	case .Think:   return fmt.tprintf("think %v", q.text)
	case .Narrate: return fmt.tprintf("narrate %v", q.text)
	case .Line:
		if q.tag != "" do return fmt.tprintf("line %v %v tag=%v", q.text, ne.line_range_text(q.lines), q.tag)
		return fmt.tprintf("line %v %v", q.text, ne.line_range_text(q.lines))
	case .Shake:   return fmt.tprintf("shake %.2f", q.amount)
	case .Sound:   return fmt.tprintf("sound %v", q.text)
	case .Leave:   return fmt.tprintf("leave %v", ne.COMPASS_WORDS[q.dir])
	case .End:     return "end"
	}
	return ""
}

// Where a cutscene's room and character art live. An assets folder above the
// file if there is one, which is how a game is laid out; otherwise the folder
// above this one, which is how a scratch folder usually is. Guessing beats
// demanding a full path for something the file already implies.
assets_near :: proc(path: string) -> string {
	if root := ui.assets_root(path); root != "" do return root
	return ui.parent_dir(ui.parent_dir(ui.abs_path(path, context.temp_allocator)))
}
