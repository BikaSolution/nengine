# nengine's tools

**Three programs, one job each.**

| | | |
| --- | --- | --- |
| **nart** | art | four editors over one pixel engine: sprites, backdrops, characters, cutscenes |
| **nsound** | music | songs as a tracker grid or a sheet, and sound effects |
| **nscene** | rooms | objects, the floor you may walk on, exits and triggers |

**nart is four editors, not one.** Each lives in its own folder and they share
`tools/pixel`:

| Folder | Edits | What makes it its own editor |
| --- | --- | --- |
| `nart/sprite/` | `.sprite` | A thing: a lamp, a hat, a key. Frames, and a preview at game scale. |
| `nart/background/` | `.sprite`, 320x200 | A room. The floor, objects and exits of the `.scene` that uses it are drawn over the art while you paint, so you don't put a wall across a doorway. Thirds and a horizon. Exports the `.png` the game loads. |
| `nart/character/` | `.char` | A person: the ten standard poses plus as many extras as the character needs, sharing one palette, each with its own size and speed. |
| `nart/cutscene/` | `.cut` | A room, a cast and cues on a clock. No pixels in it at all — see below. |

**Every picture is drawn under a palette mode.** `bega` is the sixteen colours
an EGA card came up in, `fega` any of the sixty-four it can make, `vga` six bits
a channel. New files start in bEGA, because the game this was written for is
drawn in the sixteen and a constraint is the safer default: a palette can be
widened later, but a colour already used across three rooms is work to take
back out.

The strip offers the mode's gamut rather than the colours the file happens to
contain, and a colour only takes a palette slot once it is actually put on the
picture. Colours a file already holds that the mode does not allow are shown at
the end with a line through them, so old art can still be worked on.

**In sixteen colours you shade by dithering, not by picking something darker** —
there usually is no darker version of what you want. Two tones in a pattern read
as one the hardware cannot make, and sixteen colours taken in pairs is a few
hundred apparent ones.

| key | |
| --- | --- |
| `+` `-` | a bigger or smaller brush |
| `O` | a round brush or a square one (or click the button) |
| `B` | the dither on and off |
| `T` | which pattern: mixed, bayer2/4/8, noise |
| `M` | the next material; shift+M back to a plain pair |
| `,` `.` | less light, more light (shift: bigger steps) |
| shift `+` `-` | bigger or smaller palette swatches |

A brush of 1 is one pixel, 2 is the four neighbours without the corners, 3 a
small disc, and so on — round is every offset inside the radius, which is what
makes 2 a plus rather than a three-by-three block. The panel draws the
footprint at a fixed size beside the shape button, so you can see what one
click will cover.

**The swatch size is remembered between runs**, in `~/.cache/nengine/nart.conf`
rather than in the repo: it is a preference about the person looking, not about
the picture, and somebody who needs bigger swatches needs them every time. It
goes from 12 to 72 pixels.

Every one of them is printed next to the thing it controls — `colours (shift +
-)`, `brush 3 (+ -)`, `dither (B)` — **and** in the footer, from one string
(`px.BRUSH_KEYS`) that every painting editor appends to its own keys. They were
once left out of the footer because a single line of shortcuts ran off the end
of the window and took `Esc back` with it; the footer now wraps between key
groups onto as many lines as it needs (`ui.footer`, `ui.footer_h`), and the
editors lay themselves out around its height.

The dither and the brush shape are buttons as well as keys — `dither off/on`,
and the pattern's name, which cycles it — because somebody looking at the
palette is not looking for a keyboard shortcut.

The panel shows the two tones, the pattern drawn at actual size, and what the
mix reads as from across the room — which is the number you actually want, and
no amount of staring at a ratio tells you it.

`mixed` is the default: pure Bayer bands over a wide soft gradient, and the
obvious fix of averaging ordered with noise makes every light level lie. See
[lessons.md](../../.agents/lessons.md).

Changing a picture's mode and declaring its materials are deliberately *not*
keys — they want to be typed and read back rather than reachable by leaning on
the keyboard while drawing:

```sh
just art mode assets/sprites/lamp.sprite            # what it is, and what breaks it
just art mode assets/sprites/lamp.sprite bega       # change it, snapping colours to fit
just art ramp assets/sprites/lamp.sprite            # its materials
just art ramp assets/sprites/lamp.sprite brass 000000 AA5500 FFFF55
```

They are one program rather than four because they share a clipboard and a
palette, and lifting a patch of pixels out of a sprite and putting it into a
character is a thing you do constantly; four programs would each get their own
clipboard and that would stop working. Which editor opens follows from the
file rather than from a flag — and a `.sprite` the size of the screen is a
backdrop, because a room is 320x200 and a hat is not.

Each one opens an editor when you give it a file, and is a command line when
you give it a subcommand. Part of the engine: a game needs none of it to run,
but you need it to make one.

```sh
just art                                        # browse for something to open
just art mygame/assets/characters/ada.char   # straight into the editor
just art mygame/assets          # browse, starting there
just art --find lamp                            # browse, already searching
just sound mygame/assets/music/theme.song
just scene mygame/assets/scenes/veranda.scene
just art help                                   # its commands, listed
```

They used to be one program, `nstudio`, with all four editors inside the
game's window. They are separate now because they are separate jobs: a tool you open
to draw a hat should not carry a synthesiser and a MIDI importer around with
it, and having three windows open at once is the normal way to work. What
they share — the look, the buttons, undo, the file browser — is the `ui`
package.

`just build-tools` builds all three to the repo root, so `./nart` works from
anywhere. A game's title screen can start them the same way — it launches the
program and carries on, so the game keeps running behind the editor's
window.

**The same rule as the engine applies here: if the next game would want it, it
goes in the tools rather than in a script beside the game.** An editor, a CLI
command or a check that any game would want belongs in `nart`, `nsound` or
`nscene`, with nothing in it that knows what a leopard is. A one-off that only
makes sense for this case is a one-off, and it can live in the game's folder and
be thrown away.

Everything works on the plain-text formats in
[the engine's README](../README.md#asset-files). Nothing here is
needed to *ship* a game: it's all authoring. The game only ever reads the
files, so what you change in these editors is what you see when you press
Start. A game keeps its files in its own `assets/` folder; the examples
below call it `mygame/assets/`.

## The browser

Every tool that isn't given a file opens on the same file browser, and every
editor has a way back to it — the `< files` button at the top left, `^B`, or
Esc once there is nothing else for Esc to drop — so a second file is one
keypress away rather than another `just art`. It comes back on the folder the
file was in, with that file selected. A file with unsaved changes asks first:
**save**, **don't save** or **keep editing** (`S`, `D`, Esc), and the editor
underneath takes no input while it asks.

It replaced a picker that listed one folder's worth of one extension with no
way to go anywhere else. When that picker guessed the wrong folder — and with
one game, four asset folders and an engine full of instruments, it usually did
— there was nothing on screen to click and nothing to type. The browser is the
answer to that, and everything in it exists because of it:

| | |
| --- | --- |
| **Places**, down the left | A tree that follows you. Every game in the checkout is a row, named for the game, with a count of matching files beside it, so you can see which way to go before you go. The game you are in is open along the way to where you are — its top folders, the folders inside each one you are in, the one you are in lit — and every other game is one closed row (`+`), a click away. Go into another game and the tree is built again for that one. Outside the checkout, where you are gets a row of its own under the checkout's. The column scrolls with the wheel. |
| **Breadcrumbs**, along the top | Every folder from the checkout down to here, each one a button. A folder outside the checkout is shown from `/` instead, rather than pretending it hangs off the project. |
| **Find** | Searches every folder underneath the one you're in, not just what's on screen. Type `lamp` and stop caring which folder it was filed in; matches are named by the path you'd have walked. |
| **Preview**, down the right | The file itself. Sprites and characters animate on a checkerboard, with their palette and how big they are against the screen and against a person. A song draws as a piano roll, a sound effect as a waveform you can play with the space bar, a room as its backdrop with a mark where each thing stands. |
| **The bottom row** | Makes a new one, in the folder you are looking at, with its size or its tempo filled in beside the name. |
| **Keys** | Arrows move, enter opens, backspace goes up, `^F` finds, `^N` names a new one, `F2` renames in place, `^D` duplicates, `Del` erases (twice, deliberately), `F5` reloads, Esc backs out. The wheel scrolls whichever column the pointer is over. |

Folders with nothing in them are shown greyed rather than hidden, because an
empty `sounds/` that you can see is information and an empty `sounds/` that
you can't is a mystery. `examples/` is never counted or searched — it is other
people's repositories, and three of their songs would otherwise be most of
what a count of the checkout found.

Each tool remembers the folder it was last browsing, so it opens where you
left it. If that's gone, it falls back to whichever folder holds the most of
what it edits.

The places tree used to be built once, at start, with every game's whole
assets tree opened one after another. The old game comes first in the
alphabet, so it filled the column and the game being worked on was off the
bottom of it — and the column didn't scroll. The list in the middle didn't
scroll either, for a different reason: it was pulled back to the selected
row on every frame, so the wheel moved it and the next frame moved it
straight back. Following the selection is something to do when the selection
*moves*; `ui/scroll.odin` has the arithmetic, and its tests.

### Asking for a file from inside an editor

`ui/pick.odin` is the browser asked a question — *which backdrop, which
sprite, which character* — rather than being the way into an editor. It takes
the whole window while it is up, with places, breadcrumbs, find and the
preview as ever; nothing can be made, renamed or erased from it, its bottom row
is **choose** and **cancel**, and where it was left is not remembered as the
folder the tool was last browsing. Only the file under the cursor is opened,
by the preview the editor hands in.

```odin
// asking: a kind or two, where to start (a folder, or the current file), a preview
ui.pick_open(&e.pick, "bg", "Choose a backdrop", kinds, current_or_folder,
             preview = px.art_preview, ctx = &e.pick_art, accept = px.art_is_backdrop)

// every frame, first thing:
if ui.pick_active(&e.pick) {
    if a := ui.pick_step(&e.pick, status); a.done {
        px.browse_close(&e.pick_art)
        if a.path != "" && a.asking == "bg" do set_backdrop(e, a.path)
    }
    return true
}
```

`asking` says which question was answered, so one picker serves them all; a
cancel is an answer with no path. `accept` narrows what is listed past the
file's kind. `deep = true` lists every file of the kind below the folder
rather than those in it, as a search does — for rooms, each of which is in a
folder of its own, so the question is one list of every room in the game.

What a question shows is the one file under its cursor, through a preview
handed in:

| Preview | For | Where |
| --- | --- | --- |
| `px.art_preview` | a `.sprite`, or a `.char` by its front pose; with `px.ART_KINDS` and `px.art_is_backdrop`, which reads a sprite's `size` line and not its pixels | `pixel/pick.odin` |
| `ac.room_preview` | a room: its backdrop by day and a mark where each thing stands — the picture nscene's browser draws, from the same code (`ac.Room_Sketch`); with `ac.ROOM_KINDS` | `assetcache/room.odin` |
| `ac.sound_preview` | a sound: its waveform, a play button (or space), whether it is baked to the `.wav` or `.qoa` the game plays — nsound's pane; with `ac.SOUND_KINDS` and `ac.sound_listed`, which lists a `.sound` and its baked file once | `assetcache/sound.odin` |

nscene and the cutscene editor ask with it.

### Asking for one of a list

`ui/choose.odin` is the same kind of question when the answer is not a file:
which dialogue node a cue says. The whole window, a list with a search box
over it — typing searches at once, every word of it in an item's key, label
or `search` text, without case — and beside the list a pane the editor draws
for the item under the cursor, which may take clicks of its own. **choose**
and **cancel** along the bottom; arrows, Enter, a double click; Esc clears the
search and then cancels.

```odin
ui.choose_open(&e.choose, "node", "Choose the lines", items[:], current,
               detail = draw_node, ctx = e)
if ui.choose_active(&e.choose) {
    if a := ui.choose_step(&e.choose, status); a.done && a.key != "" do use(a.key)
    return true
}
```

## Columns

Every column in every tool is dragged by its edge, and each remembers how wide
you left it.

| | |
| --- | --- |
| **nart** | the poses list, and the colours panel; the cutscene editor's panel, and the line between its stage and its timeline |
| **nsound** | the track names, in both the grid and the sheet |
| **nscene** | the properties panel |
| the browser | places, and the preview |

They were all constants before, and a constant is the wrong kind of thing for
a column that has to hold a name: `triangle_bass` is longer than 150 pixels of
track column, so it ran out of its box and over the grid. Picking a bigger
number would only have moved the problem to the next name along. Now the text
is cut to its column with an ellipsis, and the column is yours to widen.

Grab within a few pixels of the line; it lights up and grows a grip when the
pointer is near. A width is clamped to what the current window can spare, so a
column dragged wide on a big screen doesn't strand a small one.

`ui/split.odin` has the widget. It is used in two halves, because a pane's
width must be known before anything inside it can be laid out, while its
handle has to be drawn after everything else or the panels cover it:

```odin
side := ui.split("nsound.side", 170, top, height, 110, 600)  // width, and dragging
// ... lay out and draw both panes ...
ui.splits_draw()                                             // the handles, on top
```

Anything else a tool should remember between runs goes through
`ui/settings.odin`: `key value` a line, one file per tool, in
`$XDG_CACHE_HOME/nengine/` (or `~/.cache/nengine/`). It is opened by `run` and
written on the way out. Nothing depends on it — a missing file, an unwritable
cache or a stale value all fall back to the default, because a tool that
wouldn't start because it couldn't remember a column width would be worse than
one that forgets.

## Why a CLI as well

Because most edits are one line, and typing one line beats opening a window,
finding the thing, dragging it, and saving:

```sh
just art sprite resize mygame/assets/sprites/lamp.sprite 20 60
just scene scene set mygame/assets/scenes/veranda.scene lamp block=circle:12 reach=circle:56
just sound song fill mygame/assets/music/theme.song bass 0 4 A2 A2 F2 G2
just sound song render mygame/assets/music/theme.song /tmp/hear-it.wav
just art character png mygame/assets/characters/ada.char /tmp/ada.png
```

It also means an agent can change a scene without writing any Odin, and the
change shows up in git as one readable line.

## Undo, and copy and paste

Every editor has both.

**Undo** is `^Z`, redo is `^Y` or `^⇧Z`, sixty-four steps deep. A step is kept
as *the text the document would be saved as* — the same string `save` writes.
That costs a little memory and buys certainty: what you undo to is exactly a
file that would have loaded, so undo can never leave an editor holding
something the format can't express. A brush stroke is one step, not four
hundred: the snapshot is taken as the button goes down.

**Copy and paste** is `^C`, `^X`, `^V`. Each program has its own clipboard —
they are separate processes, so there is nothing to share — but within nart a
patch of a sprite still pastes into a character's pose, because that is one
program.

| Editor | What gets copied |
| --- | --- |
| Pixel art, characters | The marked rectangle, or the whole frame if nothing is marked. **Shift-drag** marks one, `^A` marks everything, Esc drops it |
| Scenes | The selected object with every line that belongs to it (its text, its `on` lines, its routine), pasted a little along and renamed so two things never share a noun |
| Music | The current track's notes, its instrument and its volume, pasted over another track |

Pasted pixels **match by colour, not by index**: paste red into a document
where index 1 is blue and you get red, added to the palette if it wasn't
there. Otherwise every paste between documents would be confetti.

## The editors

Each runs one frame at a time inside a window the `ui` package opened for it,
which is how the same editor code serves both a file named on the command
line and the picker. `Esc` backs out, `Ctrl+S` saves, and the bar along the
bottom always lists the keys.

**The host owns the frame.** `ui.run` begins the drawing, calls the
program's frame, draws any question the program asked over the top, and ends
it; a program never calls `BeginDrawing` or `EndDrawing`. Every editor used to,
and its Esc returned before drawing — so that frame never ended, raylib never
read the keyboard again, and the same Esc arrived twice: once to leave the
editor and once more to quit the browser it had just gone back to.

Leaving goes through `ui/leave.odin`, the same in all six editors:

```odin
switch ui.leave_answer() {                       // first thing in the step
case .Save:    if save(e, status) do return false
case .Discard: return false
case .None:
}
// ... Esc with nothing pending, or ^B:
if ui.leave_request(e.dirty, ui.file_of(e.path)) do return false
// ... in the header:
leaving := ui.back_button() && ui.leave_request(e.dirty, ui.file_of(e.path))
```

**Pixel art** (`.sprite`) — paint with the left mouse button, rub out with the
right. `[` and `]` step through animation frames, `N` adds one and `Shift+N`
removes one.

The panel on the right resizes the grid: **w** and **h**, each with a minus
and a plus, and the number between them takes a typed value too. Holding
shift steps by eight. The art keeps whatever still fits — growing pads with
nothing, shrinking crops from the right and the bottom, and every frame
changes together. The same control sets the size of a single pose in the
character editor. Below it, the sheet at the size the game will draw it.

**Backdrops get their own editor.** A room's background is a 320x200 `.sprite`,
and one that size opens in `nart/background/` rather than here: same pixels,
but with the room's floor, objects and exits drawn over the art. **export
.png** (or `E`) writes it out at 3.2x as the 1024x640 picture a scene loads,
which is the one thing a backdrop must do that a sprite need not.

**Characters** (`.char`) — the same painting, with a list of poses down the
side: standing `front`, `back`, `left` and `right`, a `walk_` for each of
them, `talk`, and `face` for close-ups. Poses that are still blank say so.
Each has its own size and its own speed, so a face can be bigger and blink
slower than the body walks, and `P` plays the one you're on. The parts share
a palette, which is what keeps a character looking like one character.

**Under those ten come the extras**, in their own section of the list, and a
character can have as many as it needs: a ranger who sits in a chair for an
act, a drunk who slumps further as the night goes on, an old woman who takes
stairs one at a time. Nothing picks an extra automatically — a routine plays
it by name (`step moore play chair 4`), so does a cutscene cue, and game code
sets `Actor.pose`. The side panel says so on any extra you are looking at,
because a pose nobody asks for is a pose nobody sees.

| Key | |
| --- | --- |
| `A` | a new pose, blank |
| `D` | a copy of the pose you are on, under a new name — sitting is standing with the legs redone, and that is how most extras start |
| `R` | rename an extra |
| `Delete` | remove an extra; press again to mean it |

One text box does all the naming and says which job it is about to do. Names
are lower case, digits and underscores, because a part name is the second
word of a `part` line and is typed into routines and cues. **The ten cannot
be renamed or removed** — the engine looks those up by name, and a character
with no `walk_left` stops walking left. A new pose starts with the
character's own colours rather than an empty tray.

From the command line, when you know what six poses are called before you
draw any of them:

```sh
just art character part add    assets/characters/moore.char chair 2 1.5
just art character part copy   assets/characters/moore.char front sit
just art character part rename assets/characters/moore.char sit sit_chair
just art character part remove assets/characters/moore.char sit_chair
just art character info        assets/characters/moore.char    # marks the extras
```

**Scenes** (`.scene`) — the room as the game draws it, on the left, and
everything about whatever is selected in a panel on the right.

**It holds the file's lines, not a parse of them** (`nscene/doc.odin`). These
rooms are as much notes as numbers — `admin.scene` has sixty-five lines of
comment saying why each thing is where it is — and the engine's own writer
(`scene_text`) writes a room back from what the game needs: comments gone,
every `text` moved under its object, every trigger at the bottom, a field it
does not know dropped. So the editor keeps the lines. One nobody changed is
written back byte for byte; one that was changed is written again from its
parts — keyword, words, its fields in the order they came, the free text last
— with only the part that changed being different. Opening any room in either
game and saving it reproduces the file exactly, and `nscene/doc_test.odin`
checks that against every `.scene` in both games, and that the editor attaches
each `text`, `on` and `step` line to the same object the engine does. The
command line (`nscene scene set ...`) goes through the same lines, so it keeps
the comments too.

**It loads only what the room shows** (`assetcache/art.odin`, which the
cutscene editor shares). It used to load the game's whole assets folder to
open one room — every sprite, character and backdrop in every light, six
hundred megabytes for the office — so it could draw the dozen a room names and
show the rest on a shelf down the side. Now an index of the assets folder's
*names* is read once (file names and the first line of each file, no pixels),
and a picture is loaded the first time the room draws it and let go when
nothing has drawn it since the room last changed: an object given another
sprite, another light chosen, the editor closed. The office opens in about 85
MB. `NSCENE_TRACE=1` prints every load and unload.

The strip over the room:

| | |
| --- | --- |
| **day sunset night sunrise** | the room in that light: that backdrop, and every object's painting for it (`lamp.night.sprite`). A light the backdrop was not painted for is marked `~` and borrows, as the game does; a light with nothing painted for a lamp shows no lamp. `L` steps through them |
| **add** object, person, peep, exit, trigger, scenery, window | asks for a name (one word, the noun the parser will know it by), then a click in the room for where it stands — or a drag, for an exit or a trigger's patch of floor, or a window's glass. Scenery stands nowhere and goes straight in. A person asks for its character as soon as it is placed |
| **flags** | the room as a set of flags has it, at the right-hand end: lit while it is on. See below |

**The room as these flags have it** (`assetcache/flags.odin`, which the
cutscene editor's stage shares). One room file
covers five acts, each of its people and things a line with a `when=`, and
drawn all at once the office is five people standing on one spot. With nothing
selected, the room's panel has *show the room as these flags have it*: **off**,
**dim** or **hide**, and a chip for every flag the room's conditions name, lit
when it is on. Everything whose `when=` does not hold under those flags —
objects, exits, triggers — is drawn faint, or not at all and not under a click
(the selected one stays); the room's list greys it; each description says
whether it is the one the room reads, as the engine picks it (the first with a
`when=` that holds, else the first with none). Whether a condition holds is
`ne.condition_met`, the engine's own reading. The flags are a way of looking:
nothing is written to the file.

There is no shelf of art. **Choosing art is going to look for it**:
**Backdrop...** in the room's panel, **Sprite...** and **Character...** in an
object's, open the file browser as a question (`ui/pick.odin`, above), starting
where the current one is or in the room's own folder. The backdrop question
lists only sprites the size of a room. Choose `admin.night` and the room gets
`bg admin`, worn at night as painted. A new room asks for its backdrop as it
opens.

**Sounds and rooms are chosen the same way.** Every field that names one of
the game's sounds — each ambience, the footstep, an object's `loop=` and
`tick=` — has **Sound...** beside it: the game's sounds with a waveform and a
play button (`ac.sound_preview`), starting on the one the field names; an
exit's `to=` and a peep's `into=` have **Room...**: every room with its
picture. The name goes into the field as if it had been typed — one undo step,
the line changed only where the field is — and the field still takes typing,
for a sound or a room that has no file yet.

| Key | |
| --- | --- |
| `1` | select: click a thing to select it, click it again where several stand for the next one, drag to move it. Its handles are on top: the walk-to ring, the middle and edge of its `reach` (blue) and `block` (red) shapes, an exit or a trigger's far corner, an exit's `at`. A drag on nothing pans |
| `2` | the floor: drag a corner, click near an edge for a new one there, `Del` removes the selected one |
| `L` `N` `F` | next light; every object's name on the room (otherwise only the selected and the hovered); fit the room to the window |
| `Del` `^C` `^V` | remove what is selected; copy an object with every line that belongs to it, paste it renamed (`lamp2`) and moved along |
| Esc | stops adding, then drops the selection, then goes back to the files |

The wheel zooms about the pointer and the middle button pans, as before.

**The panel shows every field of the selected line and every line attached to
it**, each editable where it is shown. A field shows the value as the file says
it — `pos 407,488`, `reach box:2100,800` — because that is what you would type
and what you will read in the file afterwards; a value that is one of a few
words (depth, facing, a peep's kind, a pose) or on and off is a row of chips.
A field a line has that the panel has no row for is listed under *other
fields*, so nothing in a file is ever out of sight.

- **An object** (or a person, or a peep): the comments above it in the file,
  its name (renaming renames its `text`, `on`, `routine` and `step` lines with
  it), `when=`, its LOOK AT text, its sprite or character (with every pose the
  character has, and which way it faces) and a look at it in the light shown,
  `pos`, `walk_to`, `reach` and `block`, depth, `base`, `frame`, `fps`, `glow`,
  `show`, `loop`, `tick`, `ticks`; a peep's `into`, `dress`, `kind`, `blind`
  and `near`. Then **every `on` line** — verb, `when`, `action`, `with`,
  `anim` and what it says — to add, edit, move up and down (the first that fits
  is the one that answers) and remove; and a person's routine, its steps the
  same way.
- **An exit**: its name, `to`, `area`, `arrive`, `when`, closed and what it
  says when shut, and going through it as something she does: `anim`, `at`,
  `face`, `arrive_anim`.
- **A trigger**: name, `action`, `area`, `when`. **Scenery**: name, `when`,
  what LOOK AT says.
- **A window** (`window back glass=445,176,138,122 feet=390
  frame=win_back when=night`): an opening onto the outside, which somebody
  going past at night is drawn through (the engine's passer, `passer.odin`).
  In the room it is its glass in pale blue, a ghost of a person standing
  outside on its feet line — as much of them as the glass shows, so you can
  see the sill cut them at the waist — and the feet line itself, dashed while
  it is the default (the foot of the glass and half a person). Click the glass
  to select it (the frame's picture is over it, so the glass comes before
  pictures; the frame is still reached by its feet or the room's list), drag
  it to move it (a feet line that was set moves with it), its far corner to
  size it, the handle on the feet line to set `feet`. The panel has its name,
  `glass`, `feet` (and *back to the default*), `frame` — the object it is
  drawn just under, with a chip for each depth=back picture over the glass —
  and `when`. `nscene scene add-window` and `scene window <file> <name>
  feet=...` do the same from the command line.
- **The room**, with nothing selected: its name, backdrop (with the lights it
  was painted for), indoors, footstep, the flags it is shown as having (above),
  every description with its `when=` (the
  first whose condition holds is the one the room reads), every ambience with
  its `when=`, the floor, and a list of everything in the room — the only way
  to reach a thing with no picture, or the fourth of five people standing on
  one spot under five conditions.

Text is typed the way it is anywhere else: click to put the caret down, drag
or shift-arrow to select, `^A`, `^C` `^X` `^V`, `^` and an arrow for a word,
Home and End; a description wraps onto as many rows as it needs. Enter or
clicking elsewhere keeps the edit, Esc puts it back. Every change is one undo
step (`^Z`, `^Y`), drags included, and a click that changed nothing is not one.

The browser's preview of a room is its backdrop by day and a mark where each
thing stands — a figure for a person, a square for a sprite, a hollow square
for a thing with no art, an eye for a peep, a diamond for a light — with the
floor, the exits, the triggers and the windows' glass. Only the backdrop is loaded, and it is let
go when the selection moves: scrolling through all forty-five rooms stays
under 80 MB, and the list's detail column reads the lines alone.

**Music** (`.song`) — a tracker grid. Pick a note with up/down (PgUp/PgDn for
octaves), then click cells to lay it down; click a cell that already holds
that note to clear it. The `-` key holds the note before it — drawn as a tie
bar — which is how a chord sustains instead of being struck sixteen times.

The wheel scrolls sideways and there's a bar under the tracks showing where
you are in the song; `Home` and `End` jump to either end. While it plays the
view follows the playhead, a couple of steps ahead of the music, and `F` turns
that off if you'd rather stay put and edit.

`Space` plays the song through the engine's own synth, so what you hear is
what the game will play.

### Two views of one song

A song is notes on a time line, measured in ticks — not rows of a grid. That
is what lets the same song be edited two ways, and **`Tab` swaps between
them**:

**The grid** is the tracker above: tracks down the side, a cell to a
sixteenth, a note in each, `-` to hold. It is the right tool for drums and
short looping beds, which is most of what a game needs.

**The sheet** is four bars across with the whole piano range top to bottom.
One row per line-or-space — a staff step, not a semitone — A0 at the bottom to
C8 at the top. Every even step is a line, and that single fact makes one
continuous "super-staff" that already contains the treble clef, the bass clef
and middle C's ledger line between them. There is no clef switching because
every clef is always there; the treble and bass five-line groups are drawn
bold so the shape of a grand staff shows inside the ladder.

Pick a length on the left (`1`–`6`, or the buttons, `.` dotted, `,` triplet),
click a slot, and a note of that length drops in. Drag it to move it,
right-click to delete it, wheel over it to move it a semitone. A note snaps to
slots of **its own length** counted from the start of its bar — a quarter note
has four places to be in a 4/4 bar, an eighth-triplet has twelve — and a
dotted note snaps to half its undotted length, which is where dotted notes
actually fall in real music. Hold `Alt` for the 32nd grid.

Sharps and flats come from the key signature: in D major a click on an F row
makes an F♯. Hold `Shift` for a sharp, `Ctrl` for a flat, or set the mode in
the panel. Accidentals are drawn only where they differ from the key, as on
paper, and a note dragged to another row takes that row's key signature rather
than carrying its accidental with it.

Every track is drawn. The one you are editing is on top at full strength and
the rest are dim in their own colours, so you can see the chord you are
writing against; `M` and `S` mute and solo. Rows the active instrument cannot
reach are shaded and refuse clicks, and clicking the piano gutter down the
left plays that row, which is how you find a note by ear.

`[` and `]` turn the page, or click the page strip; with nothing selected the
arrow keys turn pages too. With a note selected, `↑`/`↓` move it a staff step,
`Shift`+`↑`/`↓` a semitone, `←`/`→` a slot, `Del` removes it.

### Instruments

`T` adds a track, and `I` — or clicking the instrument name beside a track —
opens the instrument picker: every instrument the `.inst` files could be found
for, with its family, the range it can actually reach, and a swatch of the
colour its notes are drawn in. Moving through the list **plays each one** on
the note you have selected, so you choose a sound by ear; `Enter` (or a second
click) sets it.

Instruments are files, not code — `nengine/instruments/*.inst`, plus anything
in the game's own `assets/instruments/`. `F5` re-reads them without losing the
song you're editing, so tuning a sound is a save and a keypress. The format is
in [the engine README](../README.md) and in [nengine/instruments/README.md](../instruments/README.md).

In the grid, notes are drawn in their instrument's colour, and a note the
instrument **cannot reach** is drawn in red. A small gold pip in the corner of
a cell means the note did not start on a cell boundary — it was written on the
sheet, or came from a MIDI file — so the grid is showing you an approximation
of something it cannot say exactly.

An instrument with `sustain 0` in its envelope is struck or plucked: it rings
for its own decay and ignores how long you hold the note, the way a harp
string does. Everything else sustains for exactly as long as you hold it.

### MIDI

Drop a `.mid` on the window and it replaces the song, opening in the sheet
view because it will be real music. There is also a CLI:

```sh
just sound song import tune.mid assets/music/tune.song
```

A game's theme lives beside its other assets, in
`<game>/assets/music/`, and the title screen plays it.

## The cutscene editor

A cutscene is a room, a cast and a list of cues on a clock — scripted actors on
a real scene, not a slideshow — so the editor is the room with the cast
standing in it, the clock underneath, and a panel down the right with
everything about whatever is selected.

- **The stage**, on top. The room in the light chosen (day, sunset, night,
  sunrise along the strip over it, `L`): its backdrop, and the things standing
  in it that are there under the flags turned on in the cut's panel — *the
  room as these flags have it*, as in nscene, hiding (or dimming) whatever's
  `when=` does not hold; with none on, what is there whatever happens and what
  a `when=!something` keeps until it does. Everybody in the cast where they would be at
  the moment the playhead is on, in the pose they would be in: walking the way
  they walk, turned the way they last turned, playing a part while it plays.
  Drag somebody to move where they start (that gives them an `at=`); drag the
  ring in front of them to move where a `walk_to` sends them. The floor is
  drawn over it. Somebody written without `at=` who is not standing in the
  room is an extra, brought on: they wait just off the side of the room nearer
  where they first walk to, as the game puts them (`ne.offstage_start`), and a
  tag on the room's edge (`< visitor`) says who is waiting there and is where
  to take hold of them. Anybody off the edge gets one. The player — whoever is
  cast in most of the cutscenes beside this one — starts where she stands,
  which the editor cannot know, so she is shown in the middle of the floor.
- **The timeline**, below. One row per person, plus a row for the things aimed
  at nobody — narration, the camera, sounds, and `line` cues, labelled with the
  node and its lines (`line A2.GT.FENCE 3-5 [percy]`). Every cue is a block,
  dragged left and right to change when it happens, and as long as it lasts: a
  `walk_to` as long as the walk takes, a `line` as long as its lines take to
  read (the engine's `line_secs` for each), a `play` as long as the part plays,
  a shake as long as it shakes — which is how you see that the next line lands
  before anybody arrives. A click on a name selects the person; the rows scroll
  when there are more people than fit.
- **The panel**, down the right. Every part of what is selected, each one
  editable where it is shown:
  - **The cut**, with nothing selected: the comments at the top of the file,
    its name, its room (**Room...**) with a look at the backdrop in this light,
    the flags it is shown under and what stands in it, how long it is and why, the cast and every cue in
    the order they fire (click one to select it), and any line the game would
    read as nothing.
  - **Somebody in the cast**: the comments above their line, their name
    (renaming renames every cue aimed at them), what they wear
    (**Character...**, or none of their own), who the engine will take them
    to be — the person of that name standing in the room, or an extra brought
    on — a look at them in any of their poses, where they start (**at** and
    `X,Y`, or **where they stand**), which way they face (**their own way**,
    or front, back, left, right), and every cue of theirs.
  - **A cue**: its time (or **to the playhead**), what kind it is — chips, so a
    `say` becomes a `think` without the line typed again — who it is for, and
    the fields of its kind: what is said; where a walk goes and how long it
    takes; which way to face; a `play`'s part, from the poses their character
    has, and once, so many times or so many seconds; a shake's length; a
    sound (**Sound...**); a `line`'s node (**Line...**), its lines, its telling,
    and the lines themselves. **up** and **dn** swap it with the cue above or
    below — two cues at one time fire in the order they are written — and the
    line as the file has it is at the bottom.

**Choosing anything is going to look for it.** There is no palette of the
game's art on screen. **Room...** asks the file browser (`ui/pick.odin`) for a
room, every room in the game in one list with the picture nscene's browser
draws of it; **Character...** for a `.char`, starting on the one they wear;
**Sound...** for one of the game's sounds, with its waveform and a play button,
starting on the one the cue names. **Line...** opens every dialogue node in the
game (`ui/choose.odin`), searchable by id, title or any word of its lines,
with the node's lines beside the list, numbered as a cue counts them in the
telling chosen: click a line to start there, shift-click to end there, and
choose. The dialogue is the game's `story/dialogue/*.md` beside its assets,
read by the engine's own reader (`ne.load_nodes`).

**It holds the file's lines, not a parse of them** (`nart/cutscene/doc.odin`),
as nscene does. The cutscenes are written in groups — a comment saying which
node and why, then the cues that stage it — and a group can start a little
before the last one ended, so the files are not in time order and are not
made to be. A line nobody touched is written back byte for byte; a cue whose
time changed has its first word changed and nothing else; a `cast` or `cut`
line has the one field changed where it stands; a cue whose action changed is
written after its time by the engine's own line writer (`ne.cue_body_text`),
and a note after what the engine reads of it (`12.50 line A2.GT.FENCE 3     the
node's third line`) stays after it, spaced as it was — unless the cue becomes
a `say`, `think` or `narrate`, which would read the note as its words: then
the note goes above the line as a comment, the format having no comment at
the end of a line. A
cue dragged in time moves among the cues it is written with, to keep their
times in order, but never out from under its comment. Every line is read
through the engine's reader one at a time, so the editor and the game agree
about every line; `nart/cutscene/doc_test.odin` opens and saves every `.cut`
in both games and checks each comes back exactly, with the cast and the cues
in the order they fire as the engine has them.

**It loads only what it shows.** It used to load the game's whole assets
folder to open one cutscene — 350 MB for `the_camp_wakes` or
`darting_talk` — and now reads the index of names (`assetcache`, shared with
nscene) and loads the room's backdrop, the things standing in it and the cast's
characters as the stage draws them, letting go of what it stops drawing: about
85 MB for either. `NART_TRACE=1` prints every load and unload.

| Key | |
| --- | --- |
| Space | play or stop |
| click, drag | a cue: select it, move it in time; the ruler: scrub; a name: select them; on the stage, somebody or their walk ring |
| `A` | a cue at the playhead for whoever is selected: a `say` for a person, `narrate` for nobody |
| `C` | somebody new: their name, then what they wear |
| `Del` | the selected cue, or the selected person and their cues |
| `L` `F` | the next light; fit the room to the stage |
| `^Z` `^Y` `^S` | undo, redo, save |
| Esc | stops adding, then drops the selection, then goes back to the files |

The format is [the engine's](../README.md), and it is plain enough to write by
hand:

```text
cut arrival scene=veranda
cast ada  char=ada  at=240,470 facing=right
cast heir char=heir at=760,470 facing=left

0.00 ada  walk_to 480,470
2.20 heir face left
2.60 heir say You're the agency girl.
4.40 ada  think He knows my name already.
5.00 line A1.VR.HEIR 2-4
6.00 camera shake 0.40
8.00 end
```

Times are seconds from the start. The game plays the cues in time order
whatever order they are written in, and the editor keeps them in the order
you wrote them, groups and comments and all. Nothing waits for anything else: a cutscene is a thing you *time*, not a thing you
program. That is what makes it drawable as a timeline, and what lets you read
the left-hand column and know what happens when.

## Files

| File | What's in it |
| --- | --- |
| `ui/ui.odin` | Colours, labels, panels, buttons, the status line |
| `ui/text.odin` | Typing into a field: the caret, selection, the clipboard, and a text area that wraps |
| `ui/pick.odin` | The browser as a question: choosing a file from inside an editor |
| `ui/choose.odin` | A list as a question: choosing one of a list of names, searched, with a pane the editor draws |
| `ui/view.odin` | Panning and zooming something bigger than the window |
| `ui/history.odin` | Undo, and the keys every editor answers to |
| `ui/browser.odin` | Choosing a file when there's no command line |
| `ui/fs.odin` | Paths, listings, searching, sorting, and the last-folder memory |
| `ui/host.odin` | The window, the run loop, and the flags all three understand |
| `ui/input.odin` | Every key, click and wheel turn the tools read, and the `--events` replay |
| `ui/leave.odin` | The way back to the browser, and the unsaved-changes question |
| `ui/scroll.odin` | Scrolling a column: clamping, the wheel, bringing a row into view |
| `ui/split.odin` | Columns dragged by their edge |
| `pixel/canvas.odin` | **The pixel engine**: the grid, painting it, selecting a rectangle of it, the palette |
| `pixel/clipboard.odin` | A patch of pixels, pasted by colour rather than by index |
| `pixel/preview.odin` | The little picture of the art as the game will draw it |
| `pixel/browse.odin` | What the browser shows about a piece of art, including the size comparison |
| `pixel/pick.odin` | The art preview, kinds and backdrop filter a picker asking for art uses |
| `assetcache/art.odin` | The assets folder's names, and the pictures a tool draws, loaded and let go: nscene's and the cutscene editor's |
| `assetcache/room.odin` | A room at a glance — backdrop and marks — for the browser and for a question asking for a room |
| `assetcache/sound.odin` | A sound's waveform and a play button, for nsound's browser and for a question asking for a sound |
| `assetcache/flags.odin` | A room as a set of flags has it: whether a `when=` holds, by the engine's reading, for nscene and the cutscene stage |
| `nart/main.odin` | The `nart` binary: its commands, and which of the four editors to open |
| `nart/sprite/` | The sprite editor, and what the browser says about a `.sprite` |
| `nart/background/` | The backdrop editor, and the room overlay it draws |
| `nart/character/` | The character editor |
| `nart/cutscene/` | The cutscene editor: the file as its lines (`doc.odin`), the stage, the timeline, the panel, and the game's dialogue for `line` cues (`lines.odin`) |
| `nsound/main.odin` | The `nsound` binary: its commands, and opening the editor |
| `nsound/browse_preview.odin` | The piano roll and the waveform the browser draws |
| `nsound/song_editor.odin` | The tracker grid, playback, the instrument picker |
| `nsound/sheet_view.odin` | The sheet of music |
| `nscene/main.odin` | The `nscene` binary: its commands, and opening the editor |
| `nscene/audit.odin` | `nscene audit`: every room read with its paintings, for drawing order and housekeeping |
| `nscene/browse_preview.odin` | The room the browser draws: its backdrop and a mark for each thing |
| `nscene/doc.odin` | A scene file as its lines: reading, writing back exactly, and changing a line at a time |
| `nscene/flags.odin` | The flags a room's lines name, for the room as a set of flags has it |
| `nscene/scene_editor.odin` | The room editor: its frame, keys, undo, adding things, the questions it asks |
| `nscene/canvas.odin` | The room drawn in its light, and every drag on it |
| `nscene/panel.odin` | The panel: every field and attached line of what is selected |

## Checking them without sitting in front of them

`nart <file> --shot out.png` draws a few frames, saves a picture and quits —
and so do `nsound` and `nscene`. The same trick the game uses for `just shot`,
and the only honest way to say an editor looks right. `--window 900x600` checks
it at a size it has to squeeze into, `--frames N` waits longer before the shot,
and `--find lamp` opens the browser already searching, so a picture can show
it doing something rather than sitting there.

`just smoke` starts every tool and the game, takes a picture of each, and
checks the **exit code**. That last part is the point: a crash on the way out
still leaves the picture behind, so a tool that segfaults as it closes looks
exactly like one that worked. One did, for a while.

The rule it guards: **a program's own teardown runs inside `ui.run`, not from a
`defer` in `main`.** `run` shuts the window and the audio device down as it
returns, and a `defer` in `main` runs after that — so a texture or a sound let
go there is let go against nothing, and the program dies on the way out. Hand
`run` a `Close_Proc` instead; it calls it while there is still a window.

The path is taken as written, absolute ones included. raylib's own
`TakeScreenshot` glues the working directory onto whatever it is handed, so
`--shot /tmp/x.png` used to fail with a warning in a log nobody reads; the
tools grab the frame and export it themselves instead.

### Auditing every room at once

`nscene audit <scenes-dir>` reads every room with its paintings — the backdrop
in every light, every sprite, every person's `.char`, every cutscene — and
lists what is probably drawn in the wrong order, ranked:

| | |
| --- | --- |
| a | furniture painted into the backdrop (a block, or a hole in the floor polygon) with no sprite over it and reachable floor behind it, within a person's height of what is painted there: she is drawn over it |
| b | a feet line that does not match its art: a block's front edge apart from it, empty rows under the picture, a negative base on something on the floor, two pictures drawn the wrong way round where they overlap (the one whose art reaches lower, or sits on the other, should be on top) |
| c | `depth=back` art that stands up, `depth=front` art people get in front of, a glow or a large overlay sorted over the people behind it — judged per pixel by where that column of the picture meets the floor |
| d | people's spots — `char=` lines, routines, cutscene marks — inside a block, off the floor, or behind painted furniture |
| e | a patch painted in colours the floor around it is not, on walkable floor with floor behind it: a rail or a post if it stands, a rug or a shadow if it lies |
| f | two pictures on one feet line that overlap, sorted only by file order |
| g | missing art, props not painted in a light the room is, walk_to points off the floor or cut off, exits with no floor in them, arrivals off the next room's floor or inside its exits, objects with no text |

`--tsv` and `--md` write the list; `--points <dir>` writes, per room, the
places worth standing somebody to see each suspect, as `!crowd` points; `--person
<char>` sizes the person by a character's front pose; `--only a,b` limits it.
It suspects and a picture decides: the game's harness draws her at those points
with `!crowd` (nengine/probe.odin), in the real draw. A game's own script says
which hours and lights to look at each room in.

### Driving them with a script

`--events` plays a script of input instead of a person, so a picture can be
taken of a tool *after* doing something: scrolled, clicked into a folder,
halfway through a question. It is how every change to these tools should be
checked, and it is the only way to check one in a hidden window.

```sh
nart mygame/assets/scenes --events script.txt
nart --events "5 move 400 300; 6 wheel -3; 8 shot /tmp/scrolled.png; 9 quit"
```

The argument is a file if there is one by that name, otherwise the script
itself, with `;` between lines. One event a line: the frame it happens on
(counting from 1), a verb, and what it needs. `+N` is N frames after the line
before. `#` starts a comment.

| | |
| --- | --- |
| `30 move 400 300` | the pointer, in window pixels |
| `31 click` / `click right` | pressed this frame, released the next (left unless named) |
| `31 down left` … `40 up left` | pressed and held, for a drag; `move` in between drags |
| `40 wheel -3` | notches, as raylib has them: negative is towards you, down a list |
| `50 key ESCAPE` | pressed this frame, released the next. raylib's names, any case, `KEY_` optional; `esc`, `del`, `bksp`, digits and `[ ] - = , .` work too |
| `51 key ctrl+s` | with modifiers held for the tap: `ctrl+`, `shift+`, `alt+` |
| `52 hold ctrl` … `60 let ctrl` | held across frames |
| `60 type hello` | characters, as a text field reads them (not key presses) |
| `61 drop /path/tune.mid` | a file dropped on the window |
| `90 shot /tmp/x.png` | a picture of that frame, once it is drawn |
| `120 quit` | stop |

While a script runs, the real mouse and keyboard are ignored, and the clock the
tools read (`ui.now`) is the frame count at sixty a second, so a caret's
blink, a double click and a playhead come out the same every run. A script
with no `quit` stops three frames after its last line; `--shot` with
`--events` is taken then. A mistake in the script stops the tool (exit 2) before the
window opens, naming the line. Pair it with `NENGINE_HIDDEN=1` and an
`XDG_CACHE_HOME` of your own, so the run neither shows nor moves the folder
and the column widths the tool remembers for you.

Every tool reads input through `ui` — `ui.mouse()`, `ui.mouse_pressed`,
`ui.mouse_down`, `ui.mouse_released`, `ui.wheel()`, `ui.key_pressed`,
`ui.key_down`, `ui.key_repeat`, `ui.char_pressed()`, `ui.dropped_files()`,
`ui.now()` — and never from raylib directly. A tool that reads raylib's input
itself cannot be scripted, and ignores the unsaved-changes question.
