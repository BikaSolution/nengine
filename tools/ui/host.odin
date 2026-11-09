package ui

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import ne "../.."
import rl "vendor:raylib"

// The window an editor runs in.
//
// All three editors are the same shape: open a window, run one frame at a
// time until the user backs out, and understand a couple of flags for taking
// a picture of themselves without anybody sitting in front of them. That is
// what this is. What differs — which file types, which panels, which keys —
// belongs to each program.

// One frame of whatever the program is showing. False when it is finished.
Frame_Proc :: proc(app: rawptr, status: ^Status) -> bool

// Everything the program has to let go of. It runs here, and not from a
// `defer` in main, because raylib's window and audio device are shut down on
// the way out of `run`: a texture or a sound unloaded after that is unloaded
// against nothing, and the program dies on the way out with a segfault that
// looks like it came from nowhere.
Close_Proc :: proc(app: rawptr)

Window :: struct {
	title:  string,
	size:   [2]i32, // 0,0 for the default
	shot:   string, // save a picture here after `frames` and quit
	frames: int,
	events: string, // --events: a script of input to play instead of a person's
}

DEFAULT_SIZE :: [2]i32{1280, 800}

// How long a script without a `quit` runs on past its last line.
EVENTS_TAIL :: 3

// Opens the window, runs `frame` until it says stop, then closes everything —
// the program's own things first, while there is still a window for them to
// belong to.
//
// The host owns the frame: it begins the drawing, the program draws, any
// question the program asked (ui/leave.odin) is drawn over the top, and the
// host ends it. A program never calls BeginDrawing or EndDrawing itself.
// They used to, and a frame that returned before drawing — every editor's Esc
// did — never ended, so raylib never read the keyboard again before the next
// one, and the same Esc arrived twice: once to leave the editor and once more
// to quit the browser it had just gone back to.
run :: proc(w: Window, app: rawptr, frame: Frame_Proc, close: Close_Proc = nil) {
	// A script that can't be read stops the tool before it opens a window,
	// with an exit code that says so: half a script played is a picture of
	// something nobody asked for.
	if w.events != "" && !events_load(w.events) do os.exit(2)
	defer events_destroy()

	size := w.size if w.size.x > 0 && w.size.y > 0 else DEFAULT_SIZE
	// NENGINE_HIDDEN=1: never shown, never focused — see nengine.window_flags.
	flags := ne.window_flags({.WINDOW_RESIZABLE, .VSYNC_HINT})
	rl.SetConfigFlags(flags)
	ne.hidden_guard() // a hidden tool dies with whatever started it
	// Opened small and then grown: a window taller than the screen has room for
	// (1280x800 on a 1280x800 laptop, under its menu bar) is centred at a
	// negative position, which macOS refuses outright and aborts on. A hidden
	// window is not grown: resized unseen, its framebuffer keeps the old size.
	first := [2]i32{min(size.x, 1024), min(size.y, 600)}
	rl.InitWindow(first.x, first.y, strings.clone_to_cstring(w.title, context.temp_allocator))
	defer rl.CloseWindow()
	if first != size && .WINDOW_HIDDEN not_in flags {
		m := rl.GetCurrentMonitor()
		room := [2]i32{rl.GetMonitorWidth(m) - 40, rl.GetMonitorHeight(m) - 100}
		fit := [2]i32{min(size.x, room.x), min(size.y, room.y)}
		if fit.x > first.x || fit.y > first.y {
			rl.SetWindowSize(max(fit.x, first.x), max(fit.y, first.y))
			rl.SetWindowPosition((room.x + 40 - max(fit.x, first.x)) / 2, max(0, (room.y + 100 - max(fit.y, first.y)) / 2))
		}
	}
	rl.InitAudioDevice()
	defer rl.CloseAudioDevice()
	// Deferred last, so it runs first: before the audio device goes, and well
	// before the window does.
	defer if close != nil do close(app)
	defer leave_reset()
	rl.SetExitKey(.KEY_NULL) // Esc leaves the editor; it doesn't kill the window

	// What this tool remembered last time: the folder it was browsing, how
	// wide the columns were dragged. Written back on the way out.
	settings_open(w.title)
	defer settings_close()

	status: Status
	defer status_destroy(&status)

	// A script decides when it is over; otherwise --shot is taken after
	// `frames`, and a hidden window with nothing to do stops there too.
	scripted := replaying()
	shot_at := w.frames if w.frames > 0 else 10
	stop_at := replay_last_frame() + EVENTS_TAIL
	for n := 1; !rl.WindowShouldClose(); n += 1 {
		input_begin(n)
		rl.BeginDrawing()
		rl.ClearBackground(BG)
		running := frame(app, &status)
		leave_draw(n)
		rl.EndDrawing()
		free_all(context.temp_allocator)
		if !running do break

		if scripted {
			for path in replay_shots() do save_screenshot(path)
			if replay_quit() || n >= stop_at {
				if w.shot != "" do save_screenshot(w.shot)
				break
			}
		} else {
			if w.shot != "" && n >= shot_at {
				save_screenshot(w.shot)
				break
			}
			// Hidden and with no shot to take, nobody is there to close it.
			if ne.hidden() && w.shot == "" && n >= shot_at do break
		}
		if ne.hidden_overdue() do break
	}
}

// raylib's TakeScreenshot glues the working directory onto whatever it is
// given, so an absolute path becomes /home/you/project//tmp/shot.png and the
// write fails with a warning nobody reads. Grabbing the frame and exporting
// it ourselves honours the path as typed, which is what `--shot /tmp/x.png`
// plainly means.
save_screenshot :: proc(path: string) -> bool {
	img := rl.LoadImageFromScreen()
	defer rl.UnloadImage(img)
	ok := rl.ExportImage(img, strings.clone_to_cstring(path, context.temp_allocator))
	if !ok do fmt.eprintfln("could not write %v", path)
	return bool(ok)
}

// --- Command lines ---

// The flags every editor understands, pulled off the argument list.
Flags :: struct {
	window: [2]i32,
	shot:   string,
	frames: int,
	find:   string,   // pre-fill the browser's search box
	events: string,   // a script of input, or the file holding one
	rest:   []string, // everything that wasn't a flag
}

// `--window 900x600 --shot out.png --frames 30 --find lamp --events s.txt`.
// Anything else is left in `rest`, in order, for the program to make sense of.
parse_flags :: proc(args: []string, allocator := context.allocator) -> (f: Flags) {
	rest := make([dynamic]string, allocator)
	for i := 0; i < len(args); i += 1 {
		value := args[i + 1] if i + 1 < len(args) else ""
		switch args[i] {
		case "--window":
			if x := strings.index_byte(value, 'x'); x > 0 {
				w, _ := strconv.parse_int(value[:x])
				h, _ := strconv.parse_int(value[x + 1:])
				f.window = {i32(w), i32(h)}
			}
			i += 1
		case "--shot":
			f.shot = value
			i += 1
		case "--frames":
			f.frames, _ = strconv.parse_int(value)
			i += 1
		case "--find":
			f.find = value
			i += 1
		case "--events":
			f.events = value
			i += 1
		case:
			append(&rest, args[i])
		}
	}
	f.rest = rest[:]
	return
}

// Complain and return false, so a command can be one line:
//     if len(args) < 2 do return fail("sprite new: need a file")
fail :: proc(format: string, args: ..any) -> bool {
	fmt.eprintfln(format, ..args)
	return false
}

// The nth argument as a number, or `fallback`.
num :: proc(args: []string, i: int, fallback: int) -> int {
	if i >= len(args) do return fallback
	if v, ok := strconv.parse_int(args[i]); ok do return v
	return fallback
}

// "assets/sprites/lamp.sprite" -> "lamp"
base_name :: proc(path: string) -> string {
	name := path
	if slash := strings.last_index_byte(name, '/'); slash >= 0 do name = name[slash + 1:]
	if dot := strings.last_index_byte(name, '.'); dot > 0 do name = name[:dot]
	return name
}

// Walk up from a file until an "assets" folder turns up. The tools are run
// both from the repo root and from inside a game folder, and a game's own
// instruments, sprites and sounds all live under there.
assets_root :: proc(path: string) -> string {
	dir := path
	for _ in 0 ..< 6 {
		slash := strings.last_index_byte(dir, '/')
		if slash <= 0 do break
		dir = dir[:slash]
		if strings.has_suffix(dir, "/assets") || dir == "assets" do return dir
	}
	return ""
}

// What the argument after the program's name means. A folder is somewhere to
// go looking; a file is the thing to open. `Missing` is its own answer because
// a typo'd folder would otherwise be reported as a file of the wrong kind,
// which sends you looking at the extension rather than at the spelling.
Target :: enum {
	Nothing,
	Missing,
	Folder,
	File,
}

target_of :: proc(path: string) -> Target {
	switch {
	case path == "":      return .Nothing
	case os.is_dir(path): return .Folder
	case !os.exists(path): return .Missing
	case:                 return .File
	}
}
