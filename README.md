# nengine

A small engine for Sierra-style text parser adventure games, written in [Odin](https://odin-lang.org) on top of raylib.

Games draw into a canvas of whatever size they ask for — `ne.init("game", 1024, 640)` — which gets scaled up to the window with hard pixel edges. The player walks with the arrow keys or the mouse, and does everything else by typing.

**The window resizes; the canvas does not.** Drag the window bigger and you get the same picture, larger — never more of the room. Scenes are laid out in canvas pixels, so a canvas that changed size would move the furniture. The picture keeps its shape, sits in the middle, and whatever is left over is black bars. Clicks are mapped back through the same fit, so the mouse lands where the player aimed at any window size; `ne.mouse_pos()` is the only thing that needs to know, and game code never sees a window pixel.

The fit is fractional rather than whole-number. Whole-number scaling gives perfectly even pixels, but a 1024-wide canvas on a 1920-wide screen would only ever manage 1x and sit inside an enormous frame. At this canvas size a fractional scale reads as a touch of softness; at 320x200 it would shimmer, and the answer might be different.

Walking works the way it did in Sierra games. Tap an arrow and the character sets off in that direction and keeps going. Tap the same arrow again to stop. They also stop at the edge of the floor, at anything solid, when you click somewhere, or when they reach a new scene. Tapping a different arrow turns them.

The numpad works the same way, with diagonals, and 5 to stop:

```text
7 8 9
4 5 6
1 2 3
```

With Num Lock on, the digits it would type go to walking, not the prompt.

## What belongs in here

**If a second game would want it, it goes in the engine.**

This engine exists to be used more than once. *Death at Leopard's Rest* is one
case; there is a series behind it, in a different country with a different cast
every time, and the only things that carry over are the protagonist and this.
So the engine is not "the parts of the game that happen to be reusable" — it is
the default, and a thing earns its place in a game by being impossible to put
here.

**The test is whether you can describe it without naming anyone.** A notebook
that files entries under tabs, keeps their order, sorts them by a clock and
marks two that disagree: no names in that sentence, so it is the engine's. Which
tabs, which entries, and the fact that a woman said she had never been to
Morland: all names, all the game's. Mechanism here, content there, and the seam
is exactly where the proper nouns start.

**No game content in here, ever.** The engine is going to be open source. A
room, a character, a line of dialogue or a rule about 1948 in this directory is
a bug, however convenient.

Two things follow from this that are easy to get wrong:

- **Generalise when you move it, not later.** A system written for one game and
  parked in the engine unchanged is worse than one left in the game, because it
  looks shared and is not, and the second game will bend itself around it.
- **Move it before the second caller exists.** Afterwards there are two callers,
  a save format and somebody's afternoon in the way. The cheapest day to put
  something here is the day it is written.

## What it does

- **Text parser**: the player types a sentence; the engine turns it into a `Command` of verb, noun, preposition and second noun. The engine knows no words: the game supplies its own vocabulary, with synonyms and multi-word phrases. See below.
- **World**: all the scenes, which one you're in, and the player, who carries over between them.
- **Scenes**: a background, a walk area, objects, scenery and exits, plus a description for LOOK.
- **Walk areas**: a polygon the player's feet stay inside. Concave shapes are fine, and should be used: a half-moon clearing, a cross of paths, a U round a pool, a pier. Walking finds its way round the polygon's corners and round anything with a `block` (`scene_path`, walk.odin), so a click across a notch or past a table gets there. Clicking outside it walks you to the nearest reachable point. Because the floor is one polygon with no holes, something solid in the middle of it (a table) is an object with a `block`, which may have no name and no sprite at all.
- **Objects**: things drawn in the scene, static or animated. A static object shows whichever `frame` the game sets, so a door can be drawn open or shut. Each object's `name` is the noun the parser knows it by. Two optional floor shapes, a box or a circle:
  - `block`: floor the player can't walk through, so they walk round the cat, not through it.
  - `reach`: stand anywhere inside it to be `near()` the object, so the crate can be searched from any side. It is also the ring for walking over to things — see below.
- **Walking over to do things**: an object's `walk_to` is its interaction point. OPEN DOOR from inside the door's ring walks the player to the point, turns them to face it, and then opens it; from outside the ring it is too far. LOOK never walks. See "Walk over, then do it" below.
- **Scenery**: things painted into the background you can still LOOK AT, like a window or the moon.
- **Exits**: a patch of floor that takes you to another scene. They can be `closed` (a shut door), in which case walking into one shows its `closed_text` instead. As in Sierra's games, she goes through one only when she walks into it on purpose: a walk that means to (GO TO or ENTER it or a door whose spot is in its doorway, GO EAST or GO TO \<room\> when it is the way, a click in its doorway or on the door above it), the arrow keys into it, or being put in it. A walk to somewhere else passes over its patch, and stopping in it is standing in the doorway (`check_exits`, world.odin).
- **Triggers**: a patch of floor that runs a procedure the moment the player steps onto it. Traps, cutscenes, deaths.
- **Title screen**: the game's name over a parallax picture, layers drifting at different speeds, and a list of choices. See below.
- **Death**, Sierra style. The player dies, the death plays out in the scene, and then a box opens with a picture of the aftermath, a one-liner, and Restore, Restart and Quit. See below.
- **Depth**: everything is drawn in order of where its feet are, so characters walk behind and in front of things.
- **Sound**:
  - a background loop per scene, which carries on playing if the next scene uses the same one;
  - looping sounds attached to objects, louder as you get closer and panned to their side;
  - short sounds tied to animation frames, so a flicker, drip or tick lands on the matching frame;
  - footsteps, typing clicks, and anything else the game plays with `play()`.

  Sounds load from files, or are built from raw samples. See below.
- **Debug view** (F1): walkable floor in green, blocked areas in red, objects in yellow labelled with their nouns, exits in blue labelled with where they go (grey when closed), and triggers in orange. Also shows the scene name and the player's position.

## The parser

**The engine ships the vocabulary of the genre.** LOOK, TAKE, OPEN, GIVE, the
compass, "the", "with" — about sixty verbs and their synonyms, in
`vocab.odin`. A game adds its own nouns and whatever verbs its puzzles need:

```odin
WORDS := [?]ne.Word {
    {.Noun,      "lamp",  "light, lantern"},
    {.Noun,      "cat",   "kitty"},
    {.Adjective, "brass", ""},
    {.Verb,      "oil",   "grease, lubricate"},   // this game's own
}

vocab := ne.vocab_join(WORDS[:])   // the game's words, then the engine's
defer delete(vocab)
w.vocab = vocab
```

The engine still decides nothing. Knowing that "take" is a verb is not knowing
what taking *does*; the parser only takes a sentence apart.

| Typed | Command |
| --- | --- |
| `pick up the lantern` | `{verb = "take", noun = "lamp"}` |
| `give the plate to the cat` | `{verb = "give", noun = "plate", prep = "to", noun2 = "cat"}` |
| `give the cat the plate` | the same thing — see **recipients** below |
| `inspect boots with monocle` | `{verb = "look", noun = "boots", prep = "with", noun2 = "monocle"}` |
| `accuse the cook of the murder with the knife` | `{verb = "accuse", noun = "cook", prep = "of", noun2 = "murder", prep2 = "with", noun3 = "knife"}` |
| `look at the brass lamp` | `{verb = "look", adj = "brass", noun = "lamp"}` |
| `open it` | whatever *it* was last time |
| `north` | `{noun = "north"}`: no verb, the game decides what that means |
| `frobnicate` | the engine replies *I don't know the word "frobnicate".* |

The details:

- **Case and punctuation are ignored.**
- **The longest matching phrase wins**, so "look in" and "look at" can be different verbs. A phrase can be up to eight words: "take a picture of" and "i would have handed it in" are each one word to the game that wrote them.
- **A word that's both a verb and a noun** is read from context: in "light lamp", *light* is the verb; in "look at light", it's the noun. The same rule settles the one real ambiguity in the standard list — a bare `in` is a way to go, `look in the crate` is a preposition.
- **Adjectives** land in `adj` and `adj2`, on whichever side of the preposition they were said. The engine ships none: which lamp is the brass one is a game's business.
- **Recipients.** `{.Verb_Dative, "give", "hand, offer"}` marks a verb that can take its recipient first, so `give cat plate` is turned into `give plate to cat` before the game sees it. Without that, a parser reads it literally and has the player handing the cat to the plate. GIVE, SHOW and TELL are dative as standard.
- **A third noun.** A preposition after the second noun starts a third: `prep2` and `noun3` ("accuse X of Y with Z"). A fourth noun is dropped.
- **"it"** means the noun from the last command, which `World` remembers. With nothing to point at yet, the engine says so rather than guessing.
- **A game can overrule any word the engine ships** by naming it first — `{.Noun, "light", ""}` in a game about a lamp. Nothing is removed, only shadowed, so the synonyms the game didn't think about keep working.

Each command goes to the current scene's `on_command` first. If that returns false, the world's `on_command` gets it. That's where game-wide verbs and stock replies ("You can't take that.") live.

Keys at the prompt: Enter runs the command, Esc clears it, and F3 retypes the last one.

## Shapes

```odin
ne.Object{name = "crate", ..., block = ne.box(30, 8), reach = ne.box(56, 30)}
ne.Object{name = "cat",   ..., block = ne.circle(26), reach = ne.circle(56)}
```

Both are measured from the object's feet, with an optional offset. A circle on a floor seen at an angle looks like an oval twice as wide as it is deep, so that's the shape `circle()` gives you. Objects on walls, like a clock, get a `reach` on the floor below them and no `block`. The F1 view draws every reach in yellow and every block in red.

## Title screen

```odin
menu := ne.Menu{title = "MY GAME", layers = layers[:], items = items[:], music = &theme}
for ... {
    switch ne.update_menu(&menu, dt) {
    case 0: ne.leave_menu(&menu); start_the_game()
    case 1: quit()
    }
    ne.draw_menu(&menu)
}
```

Each `Layer` is a sprite (`sprite = assets.sprites["title_sky"]`) at least as wide as the screen whose left and right edges join up. It has a speed in pixels per second: 0 for the sky, a little for distant hills, more for the street. A layer of several frames with an `fps` plays them in a loop, with their holds, as a sprite does: moving water (`layer_frame`). A room can have drifting layers too (Drifting layers, below). Up/Down (or numpad 8/2) and Enter choose; so does the mouse. `extra` draws anything else over the layers, like something driving by.

**The lettering** is up to five lines, any of them left out: a small
`overline` over the title (who the story is about: "Ada Westcott in"), the
`title` big, the `subtitle` under it, the choices, and a small `byline` at the
very foot (who made it). In the comic look the byline stands over the busiest
part of the picture, so it is outlined in black all round, not only shadowed.

**Dusk: the title turning to night.** Give a layer a second painting of
itself in a later light, the same size (`night = assets.sprites["title_sky.night"]`),
and set `dusk_seconds`. From the moment the title first shows, every layer
dissolves from its first painting into its night one over that many seconds,
the Sierra way, while it goes on drifting; then it stays night. Leaving the
menu (Start) ends the dusk, and if the title ever comes up again it begins
again from the first painting. `dusk_seconds = 0` (the default) never
starts one.

```odin
layers := [?]ne.Layer{
    {sprite = assets.sprites["title_sky"], night = assets.sprites["title_sky.night"], speed = 0},
    {sprite = assets.sprites["title_plain"], night = assets.sprites["title_plain.night"], speed = 8},
}
menu := ne.Menu{title = "MY GAME", layers = layers[:], dusk_seconds = 10, lights = {.Sunset, .Night}, ...}
```

- **No fade, no tint** (light is paintings, light.odin). Each art pixel is
  wholly one painting or wholly the other. The pixels turn one at a time in
  a fixed order (dissolve.odin): the sixteen classes of a 4x4 ordered dither
  in turn, each class shuffled. So the turning is smooth, but at a quarter,
  a half and three quarters the picture is an even EGA dither of the two
  paintings rather than static. The order is over the painting's own pixels,
  so a drifting layer carries its half-turned pixels with it and nothing
  shimmers. Every pixel turns exactly once, and at the end all of them have.
  Each layer has its own seed, so the layers do not turn in step.
- **Trying a timing without a rebuild**: `NENGINE_TITLE_DUSK=30` in the
  environment overrides `dusk_seconds` (`TITLE_DUSK_ENV`,
  `menu_dusk_seconds`); it is read when the dusk begins. Anything that is not
  a number is ignored.
- **`lights`**, the light of the first painting and of the night one: in a
  comic with a theme for each light (`set_look_lit`), the title's boxes take
  the first light's theme and the second's once the dusk is half way, as a
  room's do when its painting changes. Left zero, day's throughout.
- `dissolve_order`, `dissolve_count`, `dusk_progress` and `dissolve_step` are
  the arithmetic, tested without a window (dissolve_test.odin); `Dissolve`
  (`dissolve_make`, `dissolve_set`, `dissolve_free`) reads two paintings back
  from the GPU and keeps the one shown. Anything else that wants one picture
  to become another the Sierra way can use them. Two paintings of different
  sizes cannot dissolve, and the menu cuts from one to the other half way.

**About.** `about = {title = "About", lines = ABOUT[:]}` is the game's page
about itself: paragraphs, `""` for a blank line between them, wrapped to fit.
The game opens it from one of its own choices (`ne.open_about(&f.menu)` in
`Front.on_menu`). It comes up over the title, which goes on drifting and
darkening behind it, as the screens do (screens.odin): the panel over the
picture darkened the EGA way, its tab over the corner, and "Esc goes back."
at the foot. Esc, Enter, Space or a click puts it away.

A game that wants its title in one light only gives the layers that
painting and no `night` and no `dusk_seconds`: the layers are shown as given.
The first game built on it does that: its title is night from the start, the
night paintings as its layers, `lights = {.Night, .Night}` so the About page
has the night theme too. The dusk stays here for the next game.

**Load Game.** `ne.title_load(w, f)`, from `Front.on_menu`, opens the same
Load screen the menu bar does (screens.odin) over the title: the autosave,
the one before it, and the eight slots, the empty ones greyed and not
pickable (with no saves at all, every row is). The title goes on drifting and
playing under it, and the screen has the keys and the mouse (`Menu.covered`).
Opening it begins the world afresh (`new_game` with the game's `start`, not
its intro), so a slot is loaded into a clean game and nothing a script or the
last game left comes with it. Picking a slot loads it as RESTORE would
(`slot_act`, which puts back the room, the clock, the light, the flags, the
score, the notebook and what she carries, and stops whatever cue was playing);
the screen sets `w.restored` and `run_game` leaves the title and goes straight
to play, in that room, saying "Restored." in the game's words. Esc, or a click
outside the panel, goes back to the title.

For a `--shot`, `!title [at=F] [about] [load [n]]` (the harness) shows the
title screen instead of play, whatever else the command line says, with its
dusk held F of the way to night, its About page up, or its Load screen up and
row n (from 1: the autosave, the previous one, then slots 1 to 8) picked. It
prints what the title is (`title_report`: how many layers are painted, the
dusk, the theme, the choices) and, after a load, where she is, the hour and
the score; a load it asked for that does not happen ends the run with exit
code 1, so a smoke row catches it:

```sh
just game --menu --shot --script '!title at=0.5'
just game --skip --shot --script '!act2; !room banda; save 5; !title load 7'
```

## Death

The game describes each way to die as a `Death` and calls `die(w, death)`:

```odin
ne.die(w, ne.Death {
    reason   = "You looked both ways. Unfortunately, you did it afterwards.",
    portrait = assets.sprites["road_death"], // a Sprite, shown in the box
    jingle   = sfx.trombone,    // plays as the box opens
    music    = "death_theme",   // a cue by name over the music as the box opens (play_over)
    update   = crash_update,    // every frame: proc(w, t, last) -> done
    draw     = crash_draw,      // every frame: proc(w, t), over the scene
})
```

The portrait is drawn at the size it was loaded: a face sits top left with the paragraph beside it; anything wider than half the box (a scene: a lamp in a doorway, a windsock) is centred across the top with the paragraph under it.

While a death plays, the engine ignores input and doesn't draw the player. The death's `draw` does that, however it likes. Its `update` gets `t`, seconds since the death began, and `last`, the previous frame's `t`. It returns true when the death is over.

Two helpers for animating one:

- **`just_passed(t, last, moment)`** fires exactly once as that moment goes by, for timing sounds.
- **`shake(w, seconds)`** shakes the screen.

In the box, the arrow keys move between buttons, Enter picks, and R and Q are shortcuts. The mouse works too. Restart and Quit only set `w.restart` or `w.quit`; the game acts on them in its main loop. Restart means calling `clear_world` and building the scenes again. Restore is greyed out until there's saving.

**A death can name its restore point** (`restore = "the gap"`): the box's
Restore goes back to that save rather than the newest one. See "Restore
points" under Saving: a game that autosaves on entering a room has always
just autosaved on the way into the trap, so for a death that happens a room
away from its cause, or long after it, the newest save is the wrong place.

## Boxes: speech, thought, and the prompt

What the game says, what a character thinks, and the line the player types
are all the same widget with a different style, so a game sets its look once
and everything matches:

```odin
w.speech_style = ne.Box_Style {
    fill = {30, 30, 36, 240}, edge = {214, 214, 220, 255}, ink = ne.WHITE,
    accent = {188, 188, 196, 255}, border = 1, pad = 4, font = 10,
    flourish = .Side_Bar, tail = true,
}
```

Leave them unset and you get the plain ones. Five flourishes — `None`,
`Corners`, `Side_Bar`, `Notch`, `Beads` — so the next game is green with cut
corners without touching a line of drawing code.

| Call | What it does |
| --- | --- |
| `say(w, text)` | The game talking to the player. No portrait |
| `say_as(w, &who, text)` | Somebody says it out loud, with their face beside the box |
| `think(w, &who, text)` | Somebody thinks it. Different style, bubbles instead of a tail |

### Two looks: boxes, or a comic

Everything above is the **Boxes** look, and it is the default. A game can
instead letter itself as a comic, once, before its first frame:

```odin
ne.set_look(.Comic)                         // white paper, COMIC_BEGA
ne.set_look(.Comic, ne.COMIC_PARCHMENT)     // cream paper ruled in sepia
ne.set_look(.Comic, my_comic)               // or the game's own theme
ne.set_look_lit(.Comic, ne.COMIC_PARCHMENT_LIT) // a theme for each light
```

The comic (look.odin) draws everything the engine says in it:

- **Speech** is a balloon with a black line round it, at the top of the
  screen on the speaker's side: their name over the words in red, stage
  directions — whatever is in brackets — in dark grey, and their portrait in
  an inset panel on the balloon's left, on a yellow ground. The panel is as
  big as the portrait (44x52 art pixels is the classic size; a 60x72 bust gets
  a 60x72 panel and the balloon steps over it). There is no tail. The side is where they stand: the player, or an object in the room
  whose name or `.char` answers to the speaker's name (the whole of it or its
  last word, as `speaker_named` reads it). Somebody standing in the middle of
  the floor, or nowhere on screen, goes by `Speaker.side`, so two people
  talking still take a side each and the balloons alternate. A balloon starts
  210 grid pixels wide, widens rather than run past four lines, and is no
  wider than its words. If it would cover the speaker's head it widens to all
  there is room for (fewer lines, so shorter) and then slides along the top
  clear of the head, when there is room to.
- **A voice** — a speaker with no face and nobody of that name on screen: a
  voice through a wall, "a man" at a vent — is a square balloon with a
  broken outline and no inset, named over the words.
- In a close-up or at an aperture the face is the picture: the balloon is
  named and has no inset (`World.message_speaker` says who, when the box
  shows no face).
- **Narration** — `say`, LOOK, a stage direction in a conversation, a
  cutscene's `narrate` — is a yellow caption box at top left with a black
  shadow, and an **announcement** a full-width caption with its title in red,
  under the close-up in a heavy frame, over the room dithered dark.
- **The typing line** is a panel across the band under the picture,
  with a red `>` and a block cursor, shown only while something is typed:
  an empty prompt draws nothing.
- **The death box** is a last panel: the picture framed, "You have died." in
  a caption over its corner, the reason in a caption under it, and Restore,
  Restart and Quit as small panels, the picked one yellow. The keys and the
  mouse work as they always did; only where the buttons are has moved.
- **The title screen**'s choices are the same small panels, and its title and
  line lettered; a **card** is lettered; `draw_panel` (a game's notebook or
  score page) is the panel's fill with a black line and a shadow.

The colours above are COMIC_BEGA's. **A comic's colours are a theme**, a
`ne.Comic`: one `Surface` for each kind of box, each a `Paper` and the inks
read on it, plus the black `line` the outlines and shadows are drawn in.

| Surface | What is drawn on it |
| --- | --- |
| `balloon` | speech, and a voice through a wall |
| `caption` | narration, an announcement, the death box's words, a thing's description in the inventory |
| `prompt` | the typing panel |
| `bar` | the menu bar's strip (its rule runs along the foot) |
| `panel` | a screen (save, load, inventory, menu), the heavy frame round a picture, a balloon's inset |
| `row` | a slot on the save and load screens, a button (the title screen's, the menu screen's, the death box's) |
| `picked` | whichever row, button, inventory cell or bar item is picked |
| `title` | a screen's title tab |
| `tag` | a thing's name by its cell in the inventory |

A `Surface` is `paper`, `ink` (the words), `name` (who is speaking, the `>`,
a caption's title, a slot's room), `aside` (a stage direction, a key, a play
time, a hint), `faded` (what cannot be picked) and `rule`: a thin line one
paper pixel inside the black one, or none when its alpha is 0. A caption
letters its stage directions in its ink, since nobody says them. A `Paper`
is `a`, or `a` with `b` woven over it on the reference grid (`Weave`:
`.Solid`, `.Checker` for a 50% EGA dither, `.Quarter` for one pixel in
four), so it lines up with the paintings' pixels; `weave_on` says which
pixels. The loose inks are `ground` (behind a portrait), and the title
screen's `heading`, `subtitle` and `note`.

The engine's themes, all in bEGA:

- **COMIC_BEGA**, the default: white paper, yellow captions and picks.
- **COMIC_PARCHMENT**: cream paper (white and yellow, checkered), black
  words, sepia names, a thin brown rule inside every balloon, caption,
  panel and the typing line and along the bar's foot; the captions and
  picks still yellow, the captions ruled too. The rows and buttons are
  cream without a rule.
- **COMIC_PARCHMENT_LIT**, a `[Light]Comic`: parchment by day, and in the
  other lights the same cream with only the rule and the caption (and the
  screens' title tabs) changed — at sunset a red rule and an apricot caption
  (yellow, light red one pixel in four), at night a blue rule and a light
  cyan caption with a blue label, at sunrise a magenta rule and a pink
  caption (yellow, light magenta one in four).

**A theme for each light**: `set_look_lit(.Comic, by_light)` instead of
`set_look`. Each frame, before anything is drawn, the comic takes the theme
for `w.light`, the light the player sees (light.odin), so the boxes change
when the painting does: indoors with the clock, outdoors at a doorway or a
`relight`, never while she stands still. On the title screen it is the
theme for the light the title's picture is in (`Menu.lights`, and the dusk),
day's unless the game says. A game that calls `set_look` has one theme and
the light changes nothing.

Code draws only flat colours, the weave and lines. A frame that has to be
drawn — brass corners, a printed hem — would be a sprite, not a theme field.

The lettering is **Tiny5** (fonts/, SIL Open Font License; the licence is
`fonts/OFL.txt`), embedded in the engine with `#load`, so a game needs no
file at run time. It is drawn on its own 8-pixel em, hard-edged, at a whole
number of canvas pixels per font pixel (`letter_scale`: 3 at 1024 wide), in
capitals (`Comic.capitals`). The frames are drawn on the 320-wide reference
grid (`ui_scale`), the grid the paintings are painted on: a one-pixel line is
where a painted pixel would be. The layout is arithmetic with the measuring
handed in — `plan_balloon`, `plan_caption`, `wrap_measured`, `comic_ask` —
and look_test.odin tests it without a window.

A **Speaker** is a name, a portrait (usually a character's `face` part), and
a side:

```odin
ada := ne.Speaker{name = "Ada", portrait = face.sprite, fps = 7, side = .Left}
cat := ne.Speaker{name = "the cat", portrait = its_face.sprite, fps = 5, side = .Right}
```

### Conversations

A list of lines, each with somebody to say it. The player steps through with
Enter, Space or a click; Esc leaves. While one is running it holds the
screen — no typing, no walking.

```odin
ne.begin_conversation(w, &chat, []ne.Talk_Line{
    {who = &ada, text = "You were on the path at eleven."},
    {who = &crawford, text = "I was on the step. There's a difference."},
    {who = &ada, text = "Not to the man who's dead.", thinking = true},
})
```

Because two speakers usually sit on opposite sides, **the portrait swaps ends
as the turn passes**, which is all a reader needs to follow who is talking.
`talking(w)` is true while one is up. **A speaker with no portrait is named on
the box instead** — "Moore: …" — for somebody whose art is not drawn yet, and
for a voice through a wall, which is "A woman" and never has a face. A line
with `who = nil` is a stage direction.

**A close-up is a line with a `shot`.** While that line is up, the picture
fills the screen instead of the room — a painted two-shot of the faces, which
a room at walking scale cannot be, and which is not the room scaled up
(people never change size in a room). The speaker is named on the box rather
than pictured beside it, since their face is the picture. One sheet holds the
shot's frames, and each line picks one: who is talking, who is listening.

```odin
{who = &boss, text = "Don't break it.", shot = &two_shot, frame = 2},
```

**A card is a line with `card`.** The words alone, centred on a dark ground —
no room, no box, no face — fading in over `CARD_FADE` seconds and waiting for
Enter like any line: an epilogue, "four days later", a paragraph out of a
newspaper, inside the flow of a scene. (A picture alone is a Splash: Title
cards, below.) The harness prints it as `[card] ...`.

```odin
{text = "Mora, four days later.", card = true},
```

**Esc skips.** It ends the conversation and runs `on_end` as if it had been
read — unless the conversation was begun with an `on_skip`, which runs
instead. A scene told in several conversations, each starting the next from
its `on_end`, passes the same `on_skip` to all of them, so Esc skips the
whole scene and not one part of it.

### Talk files: what people say when asked

ASK MOORE ABOUT THE KEY and SHOW THE SHOE TO MOORE are content, and content
lives in files a writer can edit without touching Odin — `.talk` files:

```text
# nengine talk
ask margaret husband
margaret: Hugh. Estate work, then cattle.
ask margaret husband when=told_margaret_husband
margaret: He arranged things.

ask moore fence,gap when=saw_kink tick action=moore_the_gap
ada: There's nine feet where the two lines overlap.
moore: (very long pause) Aye.
(He does not put the rifle down.)
```

- `ask` (or `show`) <who> <about,about…>, then `when=`, `tick` (it yields, so
  the first telling costs time), `action=` (the game's `on_topic` does it).
- Lines are `name: text`, looked up in `World.speakers` so the portrait comes
  with them, or `(…)` for a stage direction.
- **The last topic that matches wins**, so a file reads as a person getting
  more forthcoming. A named topic beats `about = *`, the catch-all.
- Every telling sets `told_<who>_<about>`, and a second one
  `retold_<who>_<about>`: "again", and "a third time, quietly".
- `ne.answer(w, who, about)` says it, and is false if nobody has a line.

`ne.load_talk(w, path)` after the speakers are set.

**Showing a thing.** A `show` header is a thing held out, not a question, and
`ne.show_thing(w, who, thing)` keeps the rules: the thing must be carried
(`carrying_<thing>`) or be an object here marked `show=true` (a photograph on
a wall), else `Not_Carried`; somebody not in the room is `Not_Here`; a
speaker with `gone` set is `Gone`; the `*` topic is their `Shrug`, which never
costs a tick whatever the file says. `ne.answer` answers `ask` topics only: a
`show` topic is a thing held out, so asking about the shoe without it in her
hand never says the shoe's line (`topic_for(..., asks_only = true)`). `ne.shown(w, entry_id, who, text)` keeps the show under the
thing's notebook entry, once per person, and saves with it.

### A question the player answers

Some choices the parser has no other way to make: "I won't write the money
down", or everything goes in the book. `ne.expect_answer(w, "pickett_trade")`
— usually as a conversation's last line ends — and whatever the player types
next goes to `World.on_answer(w, question, cmd)` first. True if it was an
answer; either way the question is gone. A moment passes.

### A portrait that is a meter

A `Speaker` with `fps = 0` holds `frame` instead of animating. A drunk man's
face can be the only way the player is told how drunk he is.

### Overhearing

A conversation the protagonist is not in, through a wall: one position, one
window on the story clock, once, for a price in ticks.

```odin
switch ne.overhear(w, {name = "heard_retainer", from = 17*60+25, until = 17*60+40,
                       cost = 1, lines = RETAINER[:]}, &talk) {
case .Heard:     // award, note
case .Already, .Too_Early, .Too_Late: // a line of hers
}
```

`name` is a flag set when it is heard — `when=` reads it and it saves. Put it on
the spot it is heard from: an object with a `listen` interaction and a
`walk_to`, so the player walks to the wood stack first.

### Dialogue nodes: the script, read from the writers' files

A game's dialogue can live in Markdown files written like a script, and be
played by id. `ne.load_nodes(w, path)` reads every `### ID · title` node in a
file (an id has a dot in it); `ne.play_node(w, "A2.GT.SPEECH")` plays it.

```text
### A2.GT.SPEECH · Moore states the impossibility
> when: act2 16:00  needs: —  gives: F1  once  [a note for the builder]
MOORE: Before anyone unpacks. Two gates, one key.
(He shows it. He does not hand it over.)
ADA: (writing) Two gates, one key.
[sets: heard_the_fence]
```

`SPEAKER:` is looked up among `World.speakers` by name or last name; a line
in brackets is a stage direction; `[sets: a, b]` sets flags when the node
ends; other `[...]` notes are not shown; `*emphasis*` loses its asterisks;
prose and tables between nodes are skipped. The header's `when`, `needs`,
`gives`, `once` and `tick` are kept on the node for the game to read
(`World.on_node` is called as one starts, to award what it gives); a `tick`
node spends one the first time, and every node sets `said_<id>`. A `[sets: ...]` on a line of its own is set when the node ends; one inside
the header's `> when:` line is a note for the reader (it often carries a
condition, "if she takes it") and the game sets that flag itself.
`node_done(w, id)` does everything playing a node does except say it, for a
node whose lines a cutscene says.

A node can hold several tellings. `[open] ELENA: ...` and `— **Middle:** PERCY:
...` are lines tagged `open` and `middle`; `play_node(w, id, tag = "middle")`
plays the untagged lines and that tag's. `play_node(w, id, shot = &closeup)`
plays every line of it as that close-up (a sprite not drawn yet is no
picture, and the lines play over the room). A bold name with a condition after
it, `— **Lucy**, if she has been with Ada since one: LUCY: ...`, is tagged
with the whole label, however long the condition (`lucy, if she has been
...`; match it with `strings.has_prefix`). A bulleted list of barks
(`— PERCY: ...`, several speakers on one line split by ` · `) is read with
`node_lines_of(w, id, "percy")`. `>> Choice` starts a branch whose indented
lines `node_choose(w, id, n)` plays. Lines written after the branches and not
indented under any of them ("either way: ...") are the node's `after`, and
`node_choose` plays them after whichever branch was taken.

**Barks.** A node can be a room's ambient lines, each tagged by when
(`- day: OTTO: ...`, `- night, act3: LUCY: ...`). `ne.bark(w, id, fits)`
says the next one whose tag and line `fits` — the game decides what
"night, act3" means and whether that person is in the room — as a timed
message (`say_as`), not a conversation: nothing waits for Enter and nothing
costs a tick. It goes round the list a line at a time, so coming back into a
room gives the next thing somebody there is doing. `next_bark` is the same
without saying it. Where each list has got to is not saved.

### Peeps: through a net, a vent, a window

An aperture is a `peep` line, an object in every other way: the parser finds
it by name and the player walks to its `walk_to`.

```text
peep net5 pos=612,300 into=tent dress=5 kind=net blind=lamp_in_5 walk_to=612,330 frame=net_frame near=ada_at_net
```

`into` is the room on the far side (resolved by name at load, an unknown one
an error that says which), `dress` which dressing of it when one room is worn
several ways (the flag `tent_5`). `kind` is `window`, `net`, `vent`, `hatch`,
`grating` or `door`: a vent, a hatch and a grating never show faces. `blind`
is a condition (`always`, `never` allowed): while it holds the far side cannot
see out. `frame` and `near` name the art; without them it is
`peep_<kind>_frame` and `peep_<kind>_near`, and the blind frame is the frame's
`_blind` variant. Her side is lit like a room object: `near=ada_at_net` with
`ada_at_net.night.sprite` beside it is drawn by night in the light of the room
she stands in, and a light with no painting borrows. A window can give its own
near half (`Peep_Window.near`, a `Lit_Sprite`) for the one time her side
differs: a wet shirt across her face, her head turned.

What is said, and when, the game declares:

```odin
ne.Peep_Window{name = "t5_name", peep = "net5", from = 25*60+30, until = 26*60+20,
               lines = T5_NAME[:], turn = 5, turner = "Margaret", passer = "Moore", passer_at = 5,
               cost = 1, on_play = heard_the_name, on_caught = caught_at_five}
w.peep_windows = PEEP_WINDOWS[:]
```

LISTEN AT NET5, LOOK THROUGH NET5, SEARCH NET5 and PEEP NET5 walk there and
call `ne.peep`, which plays the window that holds now and returns `Played`,
`Nobody`, `Already` or `Too_Far`; `World.on_peep` words the rest (no tick for
those). A window plays **once, ever** (`heard_<name>`), spends `cost` ticks,
and is caught at its `turn` line if the aperture is not blind (`blind_at`
overrides it per window) or at its `passer_at` line regardless: the talk stops
there, `caught_<peep>_<who>` is set, and `on_caught` says what it costs.
`on_play(w, lines_heard)` runs when it ends however it ends. Escape while it
plays is leaving quietly: what was heard is kept, nobody catches her.

While it plays the screen is a split close-up: her side on the left, the far
room on the right in its own light and dressing, as it is now, through the
frame; or the window's painted `shot`, which always wears the plain frame (it
is the picture the window is meant to be seen as). Heard and not seen, the
room itself is shapes, the frame is the blind one, and the speakers are their
`Speaker.unseen` ("a man", "a woman"; "a voice" if unset) with no faces. A
missing picture is a band. A window's `near_who` is whoever speaks on her side
of the aperture (the player, to herself, at a dark window): that speaker keeps
her name and face when the far side is only voices. The harness prints `[peep net5: t5_name]`, the
lines, and `[caught by Moore at line 5]`; `!peeps` lists every window, its
hours and whether it was heard.

## Sound

| Field | What it does |
| --- | --- |
| `Scene.ambience` | Background loop, streamed. |
| `Object.loop` | Hum, hiss, purr, coming from the object, streamed. |
| `Object.tick` + `tick_frames` | Played when the object's animation reaches one of those frames. |
| `Actor.step` | Footstep, on walk frames 0 and 2. |
| `World.key_sound` | A click for each key typed at the prompt. |
| `World.note_sound` | A sound by name as a new notebook entry goes in: a pen. Not on a restore. |
| `play(sound)` | Anything else, from game code. |
| `ambience when=night camp_night` | A room's sound by the hour, like `desc when=`: the last line whose condition holds. It changes mid-room when a flag does — the generator stopping. |
| `footstep step_boards` | The floor's own footstep, instead of the player's. |
| `play_sound(w, name)` | One of the game's sounds by name, once (`World.assets` must be set). Silent if there is none. |
| `play_music(w, name, loop, volume, duck)` | Music over the room, streamed from its file: a cue once, or a bed until `stop_music`. `duck` is how loud it goes, of itself, while a conversation is up (an eavesdrop is one), eased over a third of a second: 1 never ducks, 0.4 is a bed that gets out of the way of the words. Started under a cue (`play_over`) it waits, held. A new game and a restore stop it, before `on_clock`, which says what plays at the hour restored to. |
| `music_from(w, places, elsewhere)` | The music playing now comes from somewhere (`Music_Place`: a room, a point in it, how loud `near` it and `far` at `reach` pixels and beyond, leaning to its side), instead of the same everywhere: a gramophone in a bar, heard through its door on the quay. In a room with no place it is `elsewhere` loud (0: not heard, and still going, so the record has moved on when she comes back). Walking through the door never starts it again. Goes with the music. |
| `play_over(w, name, loop, volume, duck)`, `stop_over(w, name)` | A cue over the music: a ride's theme, a sting, a death. The music is held where it is, paused, and goes on from there when the cue is over: by itself for one that plays once (by the play clock, or when raylib says it has finished), or at `stop_over` (with a name, only if that is the one up). A cue over a cue replaces it. `play_music` and `stop_music` under it change what comes back and leave the cue alone, so the hour can move the music on while a ride is under way. `music_heard` is the name heard now. A new game and a restore stop it. |
| `Death.music` | A cue by name over everything as the death box opens (`play_over`): the music under it is held, and a restore or a new game ends both. |
| `play_bed(w, name, volume)` | One sound under every room, wherever she walks, kept by the game from `on_clock`: an aeroplane coming in, a storm getting up. The same name again only changes how loud, so it can build a tick at a time; `stop_bed` (or `""`) ends it. Its own stream, so a room with the same sound as its ambience neither stops it nor sets its volume (the bed is quiet in that room, which plays it nearer), and music over it leaves it alone. A new game stops it; a restore leaves it to `on_clock`. |
| `Beat.sound` | Played as the beat starts: the shot, the triangle, the engine dying. |
| `Menu.music` | The title theme, streamed, while the menu is up. |
| `Loop.volume`, `loop_volume`, `loop_open` | How loud a stream was last set (raylib cannot be asked), set and kept together; whether it has a file open. |

**Long sounds stream; short ones are loaded whole.** raylib keeps an
`rl.Sound` in memory whole, as 32-bit float stereo at the device's rate
whatever the file was: a minute of music is 20 MB that way, a twelve-second
bed 4 MB. So everything long is a `Loop` — music (`play_music`,
`Menu.music`), the bed (`play_bed`), a room's ambience, an object's hum — an
`rl.Music` that streams from its file a buffer at a time, fed by
`rl.UpdateMusicStream` every frame (`update_audio` in play, `update_menu` at
the title, in the hidden harness as in a window). `assets_load_folder` only
notes each sound file by name (`Assets.audio`); a short `.wav` (an effect, six
seconds or less) is then loaded whole as a Sound, and anything else is opened
as a stream when a room, the music or the bed asks (`assets_loop`), or loaded
whole only if something plays it as a sound (`assets_sound`), which nothing
should.

**Baked files.** Sources are `.sound` and `.song` text; the game never
renders. `just bake` (nsound's `song bake` and `sound bake`; `bake_target`,
`bake_fresh` and `bake_write` in audio.odin) renders each that is stale to the
file beside it the game plays, and removes the name's other baked file:

| Source | Baked to |
| --- | --- |
| a `.song`; a `.sound` that loops or is longer than `LONG_SOUND_SECS` (6) | `.qoa`, streamed |
| any other `.sound`: a short effect | `.wav`, loaded whole |

**QOA** (qoa.odin, qoaformat.org) because raylib streams it natively, it is a
fifth the size of 16-bit PCM (3.2 bits a sample; the game's music went from
37.6 MB of `.wav` to 7.6 MB), and it is sample-exact at the loop point: a file
holds exactly the frames it was given, with no encoder padding or priming
delay to trust (an `.ogg` or `.mp3` has both). The encoder is nengine's own,
byte for byte the reference one (`qoa_encode`, and `export_audio` by the
path's extension) but for loops: it starts the predictor from the end of the
loop, so the step where a loop goes round is the source's give or take the
codec's ordinary error rather than a one-sample jump from silence. Its decoder
(`qoa_decode`, `qoa_stream_read`, which goes round as a looping `rl.Music`
does) is the one the tests hold raylib's to. An `.ogg` in the folder plays too.

Of a name's `.qoa`, `.ogg` and `.wav`, the newest plays, and of two the same
age the first in that order (`Audio_File`): a bake leaves one, so two means an
editor's export since, which is the one somebody wants to hear. `.wav` stays
the fallback for anything not baked this way.

A room's ambience plays at full, whatever an object elsewhere last did to the
shared stream; an object here whose `loop=` is the room's ambience is the
ambience, and is not placed. A hidden window (`NENGINE_HIDDEN`) is silent:
every sound loads and plays, at no volume (`master_volume`).

Real recordings load with `rl.LoadSound` and `load_loop` (or sit in the assets folder, as `.wav`, `.qoa` or `.ogg`). For placeholders, `sound_from_samples` and `loop_from_samples` take a list of numbers from -1 to 1, at `SAMPLE_RATE` (44100 a second) unless given a `rate`, mono unless given `channels` (stereo is interleaved, left then right), which is enough to stand a sound up from sine waves and noise before there is a real one. `export_wav` writes samples to a file you can listen to outside the game; `export_audio` writes a `.qoa` or a `.wav` by the path's extension (`nsound song render x.qoa` too).

Baked songs are 44.1 kHz stereo; baked sounds are 22.05 kHz mono unless they say `rate 44100`. A loaded `rl.Sound` costs the same memory at any rate, so for a short effect the rate and channels cost only disk; a `Loop` costs a few buffers, whatever its length.

## Using it

A whole game, less its content. Everything here is the engine's; what a game
writes is `start`, `on_command`, `on_clock` and its words.

```odin
import ne "../nengine"

main :: proc() {
    l := ne.launch_flags()               // --skip --menu --debug --shot --at --script --play --log --dev
    ne.init("My Game", 1024, 640)
    defer ne.shutdown()

    assets: ne.Assets
    ne.assets_load_folder(&assets, "assets", 3.2)

    w := ne.World{
        vocab = ne.vocab_join(WORDS[:]), on_command = on_command,
        clock_start = 19 * 60 + 30, clock_step = 4, on_clock = what_the_hour_does,
    }
    defer ne.destroy_world(&w)

    if problem, ok := ne.load_scenes(&w, "assets/scenes", {"hall", "study"}, &assets); !ok {
        fmt.eprintln(problem)            // a room that will not load, or an exit to nowhere
        return
    }
    ne.new_game(&w, start)               // wipe, then the game's own opening
    ne.run_script(&w, l.script)          // the harness, if asked for

    front := ne.front_new(assets.sprites["logo"], ne.Menu{title = "My Game", items = {"Start", "Quit"}}, l, start)
    defer ne.front_destroy(&front)
    ne.run_game(&w, &front, l)           // card, menu, play, restart, screenshot
}

start :: proc(w: ^ne.World) {
    if i, ok := ne.scene_index(w, "hall"); ok do ne.go_to(w, i, {160, 150})
    ne.checkpoint(w, "act1")
}
```

These helpers are for command handlers:

- `say`: show a message.
- `look_command`: LOOK — the room with no noun, an object or a piece of
  scenery with one. False only when nothing here has that name, so the game
  says *that* in its own voice. Scenery is the trap it closes: a game's LOOK
  that only checked its own switch said "you can't see that" for half of
  every room.
- `slot_command`: SAVE n and RESTORE n, done, and a `Slot_Outcome` back for
  the game to word. `slot_of` turns "3" into slot 3 and refuses the autosave.
- `find_object`, `describe`, `is_here`: look things up in the scene.
- `near`: is the player standing in the object's reach?
- `head_for_exit`: walk to an exit, and through it if it's open.
- `walk_to`, `go_to`: move the player. `scene_index` and `scene_named` find a
  room by name, which is how a game should say which room it means.
- `die`: kill the player.

A game supplies its own nouns; the engine's standard vocabulary brings the verbs.

## Drawing order

Whoever's feet are lower on screen is nearer the camera. Everything in a room
is sorted by where it stands and drawn back to front, so walking up the room
puts you behind the table and walking down puts you in front of it — and
because a person's position *is* their feet, that follows them as they move
without anything being told about it. An NPC walking behind the table is the
same rule doing the same thing.

Three things decide the order, in this order:

| | |
| --- | --- |
| `depth` | `back` is always behind everyone, `front` always in front. For the things that aren't really standing anywhere: a rug or a painted shadow nothing should hide behind, a bush at the front of the shot everything should pass behind. |
| feet | `pos.y`, shifted by `base` for art whose bottom edge isn't where it meets the floor — a hanging sign, a lamp on a chain. `base` moves the line it stands on without moving the picture. |
| order in the file | So two things standing on exactly the same line keep the order the file gave them, every frame. |

```text
obj table pos=512,470 sprite=table
obj rug   pos=512,590 sprite=rug   depth=back
obj bush  pos=300,200 sprite=bush  depth=front
obj sign  pos=200,300 sprite=sign  base=180
```

That last row matters more than it looks. The sort underneath is not stable,
so without a tiebreak two objects on the same line are free to trade places
between frames, which reads as a flicker in the corner of your eye that is
very hard to track down later.

**An object that spans depth** — a long counter running away from the camera,
a table set at an angle — is in front of you at one end and behind you at the
other, and one line cannot say both. **Split the art, not the thing:**

```text
obj bar       pos=300,400 sprite=bar_back     # the thing: name, description, verbs
text bar      Zinc, and a great deal of polishing.
on bar look   Somebody has been at it with a cloth.

obj bar_front pos=300,520 sprite=bar_front    # art only; no word anybody types
```

One object is the bar as far as the parser, the story and the save file are
concerned; the other is a picture with its own baseline. Stand between them
and you are behind the far half and in front of the near one. The player types
BAR and finds the bar, because `bar_front` is never in the vocabulary.

The cost is one cut in the pixel editor, per object that needs it, and nothing
in the engine.

**Checking it.** Nothing in a file says a table is painted into the floor, so
nothing but a picture shows her drawn over it. `nscene audit <scenes>` reads
every room with its paintings and lists the suspects — painted furniture with
floor behind it, feet lines that do not match their art, depth=back art that
stands up, people put inside blocks (tools/README.md) — and the harness's
`!crowd` draws her standing everywhere at once to settle them (probe.odin).

The other way — **taken since** (1 Nov 2026), once the rooms were painted from
a world model that knows every pixel's depth — is a Sierra priority map: the
next section. Splitting still works, and a room with no maps is drawn exactly
as this section says.

### Drifting layers: parallax in a room

A room can move as the title screen does: layers over its backdrop that drift
left and repeat sideways, for clouds, smoke, a river's water, the land going
past a window.

```text
bg river_bank
drift clouds speed=6 y=0
drift water  speed=24 y=300 fps=5
```

- **`drift <sprite> speed=<px/s> y=<y> [fps=<n>]`.** The sprite's top edge
  sits at `y`, it moves left `speed` canvas pixels a second (0 stays put), and
  copies of it are laid side by side across the screen, so its left and right
  edges should join up. A sprite of several frames with an `fps` plays them in
  a loop, with their holds: water moving as well as flowing.
- **Drawn over the backdrop and under everything in the room**, back to front
  in the order the file gives them. Nobody and nothing is ever behind one, so
  a layer is for what is farther away than anybody stands, or for what lies
  under their feet; something that stands in front of people is an object.
- **The same drawing as the title screen's** (`Layer`, `draw_layer`,
  `layer_offset`, `layer_frame` in menu.odin): what drifts on the title
  drifts the same way in a room. The clock is the World's `time`, which runs
  on through conversations and cutscenes.
- **In every light, as a backdrop is** (light.odin): `water.night` beside
  `water` is the night's painting, found by the name on the line. A light it
  was not painted for borrows another's painting and is shown through the
  room's tint. The `.sprite` is used first, so its frames come with it, and a
  baked `.png` of that name failing that.
- **Saved as read.** `scene_text` writes each `drift` line after the `bg`
  line, and the room editor keeps the file's own lines, so a room opened and
  saved keeps its layers.

## Depth and solid maps: Sierra's priority and control screens

SCI drew every room three times: the picture, a *priority* screen (how near the
camera each pixel stands) and a *control* screen (where the floor is blocked).
A room here can carry the same two, as text files beside its backdrop, found by
the backdrop's name (priority.odin):

```text
tent_row.sprite   tent_row.night.sprite ...   the paintings
tent_row.depth    per art pixel: the feet line of what is seen there
tent_row.solid    per art pixel: is the floor there taken
```

**Depth.** Each art pixel holds a canvas y: the line on the floor straight
below the surface seen there (a wall's every pixel holds the line along its
foot; a roof's, the line under it; the ground holds nothing). A person, and
every thing at `depth=normal`, is drawn behind every pixel whose line is lower
on the screen than their feet. A tie is theirs. That is all of it: she walks
behind a tent painted into the backdrop, behind the near end of a godown at
35° and in front of its far end, behind a fence post, with nothing in the
scene file. One map serves all four lights. `depth=back`, `depth=front`, the
passer outside a window and a thing marked `whole=true` (an overlay that
repaints the backdrop) are never hidden.

It is done on the GPU, in whichever shader the draw already goes through (plain,
the light's tint, or the `up` shader through a ride's camera): the vertex shader
hands on the canvas position, the fragment shader looks the line up in the map
at the art pixel the backdrop has there, and discards. A draw whose box no deep
enough pixel reaches skips it (8×8 tiles of the map's deepest line). About
0.15 ms a room, measured by `!depth time`. `depth_hides` is the same sum on the
CPU, and `!depth check` holds the GPU to it pixel by pixel.

**A thing with its own depth.** `lamp_post.depth` beside `lamp_post.sprite`:
the same rows for one frame, each pixel's line measured from the thing's `pos`
(so it moves with it). Such a thing is drawn whole at its farthest line and
stamped into the room's map while it is shown, so it hides people by its
pixels as the backdrop does; hidden, it is unstamped. Its `base` is not used.
This is how a long thing seen at an angle that is *not* painted into the
backdrop (a gate that swings, a cart) is in front at one end and behind at the
other; one painted into the backdrop needs nothing.

**Solid.** A taken pixel is floor nobody stands on. It adds to the walk
polygon and the blocks and replaces neither: `can_step`, `line_clear`,
`in_a_block` (so side arrivals and the world check, `landing_fault`) all read
it, and a room that has one is walked by a search over its pixels pulled tight
into straight legs (`scene_path_grid`), so a click goes round what is painted.
A click on it (a tent's canvas, the foot of a wall) walks her to the nearest
floor she can reach and be seen on (`stand_spot`: no more than `STAND_HIDDEN`
of her behind what is painted, or the nearest at all if nowhere is), nearest
to the foot of what was clicked (the depth map's line there), so she comes
round to its camera side and not to a strip behind it where only her head
shows. A click beyond a side's brink where the brink is painted solid is such
a click, not a crossing; and somebody of the room going off or coming on over
a side does it at the nearest brink along it that is not painted solid, as GO
NORTH does. Stepping out of it is
allowed, so somebody put down inside is never stuck. Every exit's patch and
every `walk_to` (8 px round) are cleared out of it when the room loads, so a
door is a door and every interaction point can be stood on.

```text
depth_map none            # this room: no depth map (or another's: depth_map tent_row)
solid_map none
obj gate_open ... whole=true
```

**The files** are one run-coded line per art row (`v*n` is n of v):

```text
depth tent_row              solid tent_row
size 320 200                size 320 200
.*320                       .*320
.*57 412*30 .*233           .*120 X*36 .*164
```

`.` is nothing (depth) or free floor (solid); `X` is taken (not `#`,
which starts a comment). A game's art tools write
them from their own model of the room, where the floor line of every pixel is known exactly. A hand can fix one in a
text editor; the F1 view shades the taken floor magenta.

A lane is carved through the solid map, when the room loads, from every
exit's patch and every `walk_to` to the main floor, so a door in a painted
wall or a spot at a counter is never cut off. A side gets one only where it
needs one: a brink on free floor is joined like a spot; a brink painted over
is left alone while any of the side is open (a lane from it would run along
the strip behind whatever stands on the edge, floor closed on purpose); a side
painted over end to end (a gate the model has shut) gets a lane from every
brink, as before. A lane runs over the walk polygon: once on it,
it stays on it (a lane off the floor is walked by nobody). A room's way-finding goes round the polygon's
corners first, as it always did, and over the solid map's pixels only when
that fails; a walk to a spot off the floor (over a side, onto an edge) is the
straight line it always was. `NENGINE_NO_MAPS=1` runs any game as if no room
had either map.

**People are solid too.** Every person in a room stands on an oval round their
feet (`person_foot`: about half their picture's width, wider sitting). Her
steps, lines and ways go round it; a click on somebody's feet stops at its
edge; TALK TO stops beside them as before. A person of the room (`npc`) walking
their routine goes round *her* (the way worked out again, up to `WAY_AGAIN`
times); one coming or going through a side waits `PERSON_WAIT` for her and then
goes on. People do not stop each other, a cutscene's people are not stopped,
and somebody standing in a doorway (an exit's patch) stops nobody.

**The harness.** `!depth off` / `!depth on` (draw as before the maps, for a
before-and-after), `!depth at x,y` (the line and the floor there), `!depth
check [x,y ...]` (her at each point, GPU against CPU), `!depth time [n]`,
`!depth solid off|on`, `!depth walk x,y`, `!depth sweep [n]` (walks every
which way, with and without the solid map: how many went over taken floor),
`!depth case walk x,y` (can she stand there, a click there, an arrow held at
it: PASS only if all three keep her off it) and `!depth case front|behind x,y
x0,y0,x1,y1 [out=f.png]` (her at the point, facing front: how much of her
inside the box the room hides, in the real draw; out= paints the hidden part
magenta). A game keeps its audit's cases and replays them with these as
regressions from a script of its own.

**The audit: a standing rule for every room.** `!depth audit` (depth_audit.odin),
or `just depth-audit [rooms...]` from the shell (`AT='!at 22:00'` for another
hour): Ada drawn all over the room's floor and walked about it, hidden, and
every fault a line: a painted room with no depth or solid map (NO-MAP,
NO-SOLID); floor where she vanishes behind something painted (VANISHES); a
thing drawn over her where the depth map says she is in front (OVER, naming
it); a walk onto taken floor or into somebody (THROUGH); somebody standing in
the only way to a door, a side or a thing's spot (BLOCKS). Behind: she is hidden
by each thing along its whole length; in front: she is drawn over it and never
vanishes; solid: she cannot stand in or walk through it, or through anybody.

## One room, five acts

A room changes as the story turns: somebody leaves, a shoe appears, the
description goes from *lamps and a great deal of talking* to *cold*. That is
one room file with conditions on its contents, not five copies of the room —
fourteen rooms times five acts is seventy files, and changing a doorway in
seventy files is how a doorway ends up different in three of them.

The game sets **flags**; everything in a scene can carry a `when=`:

```text
desc            Warm, and lit from under the water.
desc when=act3  Two of them. Nobody has touched anything.

obj  shoe   pos=210,180 when=act3
obj  bodies pos=160,190 when=act3 block=circle:20
exit gap    area=300,150,20,40 to=fuel_store when=act5
scenery moon when=act3 A thin moon, and no cloud at all.
```

```odin
ne.checkpoint(&w, "act3")                        // and the room follows
ne.set_only(&w, "act4", {"act2", "act3", "act4"}) // one of a set
```

A condition is `all of these, none of those`: `when=act3,!body_moved`. That is
the whole language on purpose — anything needing more is a decision, and
decisions belong in game code where they can be read.

Something that isn't here is not drawn, not found by the parser, and **does
not block the floor**. Conditions are worked out when the flags change rather
than when they are read, because drawing asks sixty times a second and the
answer changes at a checkpoint. `set_flag` does that for you; flags go into
saves by themselves.

**Arriving.** A `trigger` whose area covers the whole floor fires on the first
frame in the room, wherever the door put her: bodies on a deck, a man at a
post. Smaller triggers still wait to be stepped into.

## Objects carry their own verbs

An object that can only be looked at is a picture with a caption. One that
carries its verbs is a thing:

```text
obj door pos=300,150
text door Heavy, and shut.
on door look          You have never seen it shut before.
on door unlock with=key   The lock gives.
on door unlock            You have nothing to unlock it with.
on door open action=swing_door
on door open when=act4    The hatch has been forced.
```

The object gets first refusal on a command, then the scene's `on_command`,
then the world's — so the switch is left holding only what is genuinely
scene-wide. An interaction naming a second noun beats one that doesn't, so
UNLOCK DOOR WITH KEY and UNLOCK DOOR are different answers written in any
order. `action=` names a procedure the game binds with `scene_bind_action`,
the same way triggers work.

A verb of two words is written with an underscore — `on elena talk_to …` —
because half the standard verbs are two words and there is otherwise no
telling where the verb stops and the sentence starts.

## Walk over, then do it

OPEN DOOR from across the room does not open the door from across the room.

```text
obj door pos=600,420 sprite=door walk_to=600,450 reach=box:220,120
```

- **`walk_to=` is the interaction point** — the spot the player stands on to do
  anything to it. Any verb but a far one walks there first; the command waits,
  and runs on arrival through the usual object → scene → world order. Facing is
  turned towards the object on arrival.
- **`reach=` is the ring.** From outside it, the thing is too far and the game
  says so through `on_out_of_reach(w, o, .Too_Far)`. No ring means the whole
  room is in reach.
- **People** (objects that walk) are approached from the side the player is on,
  `BESIDE` pixels off, re-aimed every frame in case they wander.
- **Far verbs** are done from where the player stands. `{"look"}` unless the game
  sets `World.far_verbs` — a game with listening, counting or a power that works
  at a distance lists them.
- **Changing your mind**: a click, an arrow key or leaving the room calls it off.
  A new command that needs a walk replaces it; one that does not (LOOK, the
  notebook) leaves it going.
- **Blocked on the way** and not close to the spot: `on_out_of_reach(w, o, .Blocked)`.
- **No `walk_to`**: the command runs where the player stands, as before.
- **ASK ELENA ABOUT THE PHOTOGRAPH** never walks to the photograph: after
  "about", the second noun is a topic. GIVE PLATE TO CAT walks to the cat.
- **GO TO \<thing\>** is the same walk with nothing at the end; GO TO \<exit\>
  heads for the exit. Only when there is a thing or an exit here by that name,
  so a game's own "go" still gets the rest.

The F1 view draws the ring in yellow and the point as a red dot.

## Doing something: a part played once

A part a person *stands in* loops for as long as they stand in it. A part a
person *does* (picking up a cup, kneeling to look under a cot, a wave) plays
once, from its own first frame, and hands back whatever they were doing
before. On an object's verb, the player walks over, does it, and only then
does the verb happen:

```text
on cup take anim=pick_up action=take_cup You pick up the cup.
```

TAKE CUP walks to the cup, plays `pick_up`, and says the line and runs
`take_cup` at the end of the reach, not the start of it. While it plays the
player's hands are busy: clicks and the arrow keys wait. Typing does not, and
a new command finishes the gesture first, so what it was for happens before
the new command does. Leaving the room, going under on a ride, restarting and
loading all end it. **A part nobody has drawn yet plays for no time**, and the
verb happens at once, so a half-finished character never holds the game up.
The harness does not wait for gestures either: it prints `[played pick_up]`
and carries on.

From game code, on anybody:

```odin
ne.actor_play(&o.actor, "wave")               // once
ne.actor_play(&o.actor, "wave", times = 3)    // three times through
ne.actor_play(&o.actor, "cleaning", times = 0, secs = 4)  // round and round, four seconds
ne.actor_playing(&o.actor)                    // still at it?
ne.actor_stop_anim(&o.actor)

ne.player_play(w, "kneel", proc(w: ^ne.World) { ne.say(w, "Nothing under the cot.") })
```

A routine says `step elena play wave once` (or `3x`), and the step waits for
it to finish; `play cleaning 4` still holds the pose for four seconds, now
from its first frame. A cutscene says `2.50 elena play wave once`, `play wave
3x`, or `play chair 3` for three seconds. See `anim.odin`.

### Through a door, up a ladder

An exit can be gone through as something she does rather than walked
through:

```text
exit ladder area=400,280,40,40 to=loft arrive=300,420 anim=climb_up at=420,320 face=back arrive_anim=climb_off
```

Stepping into it, a click there, or GO TO LADDER walks her to `at`, turns her
to `face`, plays `climb_up`, and changes the room at the end of it. In the
loft she plays `climb_off` where she arrives. Every part of it is optional:
`at` alone lines her up, `anim` alone climbs from wherever she stepped in, and
`arrive_anim` alone is a stumble on the far side. While she climbs, the exit
does not fire again under her, and a click or a typed command calls off the
walk to the spot. A part nobody has drawn plays for no time, so an exit
whose art is still to come is an ordinary exit until it arrives. The harness
prints `[played climb_up]`, `[went to loft]` and `[played climb_off]`.

For a way out that is not an exit (ENTER TENT, a trapdoor the game opens):

```odin
ne.go_to_after(w, "duck_in", tent_scene, {300, 420}, arrive_part = "stand_up")
```

### Frames that hold

A part plays at its `fps`, one tick per frame. A frame can hold for more ticks
than one, which is how a gesture gets its weight without drawing the same
picture twice:

```text
part pick_up frames=4 fps=8
frame 0
frame 1 hold=2     # the reach, held
frame 2
frame 3 hold=4     # the cup, up, held for half a second
```

A room's `.sprite` takes `hold=` on its frames too, and an object with `fps=`
plays them with their holds: a bush that sways in a gust and then stands
still. Each object runs on its own phase (from where it stands), so two
bushes in one room do not move in step.

A frame with no `hold` shows for one tick, so every file written before holds
existed plays exactly as it did. Holds work on every part, the standing and
walking ones too. The character editor shows "frame N holds for" under the
speed, with how long the part takes once through; adding a frame copies its
neighbour's hold and deleting one takes its hold with it. From the command
line, frames counting from 1 as the editor shows them:

```text
nart character part hold ada.char pick_up 4 3
```

## People are objects that walk

There is one kind of thing in a room. A person has a name the parser knows, a
description, verbs and a condition exactly like a lamp does, because it *is*
an object — one carrying character art and a routine:

```text
obj elena pos=100,470 char=elena speed=100 facing=right when=!elena_gone
text elena She is wiping down the bar, again.
on elena look     She looks up, and keeps wiping.
on elena talk_to  Evening, miss. You'll want the far tent.
routine elena loop
step elena walk_to 500,470
step elena play cleaning 4
step elena face left
step elena walk_to 100,470
step elena wait 2
```

Steps run in order and, if the routine loops, start again at the end. Each
finishes in its own time — a walk when the walking is done, a pose when its
seconds are up — which is what makes it a routine rather than a cutscene. A
cutscene is cues on a clock and everybody obeys it; a routine is one person
getting on with something while the game happens around them.

`play` shows a named part of the character file, so a `cleaning` pose beside
the standard ten is all a cleaner needs. Somebody the act has taken away stops
walking and forgets where they had got to, so they don't come back half way
through wiping a table they haven't walked to.

`pose=sit` on the `obj` line is the part a person holds when nothing else is
asking for one — a guest in a chair, a man on a step. A routine's `play`
borrows the pose for its own step and hands `sit` back afterwards.

`pos` is still the field everything reads — drawing order, blocking, how near
the player is — and the actor keeps it up to date as they go.

## Score, and how long it took

A mystery is scored on what the player worked out, so the points go on the
clues. The game declares every award once — which is what lets "0 of 45" be
true from the first minute — and awards them by name as they happen:

```odin
AWARDS := [?]ne.Award {
    {"crate_manifest", "One name booked five months early", 10},
    {"elena_tent",     "Elena said which tent was hers",    15},
    {"field_book",     "Fairbank's field book",             20},
}
w.awards = AWARDS[:]

ne.award(&w, "field_book")   // once; true only the first time
ne.score_text(&w)            // "45 of 250"
ne.playtime_text(ne.playtime(&w))  // "1h 23m"
```

**Awarding is idempotent.** Finding the same clue twice is worth what finding
it once was. That is the whole reason awards have names rather than the game
adding numbers to a counter: a score a player can feed by looking at a thing
repeatedly is not a score.

**An award also sets a flag of its own name**, so a clue changes the world as
well as the score without the game saying it twice and getting them out of
step. That composes with everything else — a clue reads differently once you
have it, with no new feature involved:

```text
on crate look when=!crate_manifest action=found_manifest Twelve names, and one booked five months early. (+10)
on crate look Twelve people's paperwork. You have already read the names.
```

Put the award on the object rather than in a scene switch. The object answers
first, so a switch branch behind it is dead code.

For the ending, `awards_earned` gives what was found **in the order the player
found it**, and `awards_missed` gives what they walked past — which is the
half that makes an ending worth reading.

SCORE and TIME are in the standard vocabulary, so the player can ask at any
point; both are plain reads, so a status line can show them every frame.

`World.time` is the play clock: it runs while the game is played and not while
a menu is up, it goes into every save and comes back with one. Everything that
needs a clock reads the same one, so there is only ever one answer to "when".

**When each award could be had.** An `Award` carries `from` and `until` on the
story clock (0: from the start, for good): `{"the_shoe", "One shoe…", 25,
23*60+52, 26*60}`. `awards_missed` returns the missed in the order they were
available, so an ending can say what was lost and **the hour it went** — the
argument for playing again. `awards_earned` gives each one's `minute` on the
story clock as well as its playtime, and both go into saves.

**An award of one branch.** `Award.only` is a condition: until it has held
once in this game, the award is neither earned nor missed, so the other
branch's award is not a thing she lost. That it held is remembered for good
(the flag `award_open_<name>`, saved, and ignored by the turn clock).

## The notebook

What the player has written down. The engine keeps the filing; the game draws
the prop and decides which tab is showing, because a notebook is a prop and
every game will want its own.

```odin
TABS := [?]ne.Notebook_Tab{{"people", "People"}, {"things", "Things"}, {"times", "Times"}}
w.notebook_tabs = TABS[:]

ne.note(&w, {id = "glasses", tab = "things",
             text = "One full, lipstick. One empty, flies in it."})
ne.note(&w, {id = "tod", tab = "times", minute = 24 * 60 + 10, source = "Dr Sherwood",
             text = "Between eleven and one, both, within minutes."})

for e in ne.notebook_entries(&w, "times", .Time) { /* draw it */ }
```

Writing is idempotent, for the same reason awarding is: a player who looks at
the shoe four times has found one shoe, and a notebook with it in four times is
one nobody can read. `note` is true the first time only, so a game can say
something once and stay quiet after.

**`minute` is a time on the game's own clock, not a time of day.** A case that
runs from teatime to dawn crosses midnight, and if minutes wrapped at 1440 then
ten past midnight would sort before ten to twelve and the night would come apart
in the one tab that has to hold it together. Count from wherever suits and let
it run past 1440; the engine only ever compares two of them, and turning one
back into "00:10" for the page is the frontend's business. It is a `Maybe`
because most entries have no time at all, and an int's nothing is zero, which is
a perfectly good time.

`notebook_entries` returns a fresh list — sorted `.Found`, the order it was
lived in, or `.Time`, by the clock. Sorting a list the player already had is a
set piece all by itself: the same facts, read in a different order, and the hole
in the middle of the night becomes a hole you can see.

**Dog-ears.** The game declares which entries cannot both be right; the engine
notices when the player is holding both halves and marks each. It never says
which one is the lie, because it does not know and neither, yet, does the
player. A contradiction can carry a `needs` flag condition, so one can be held
back until the story is ready for it — which is worth having, because a player
taught that dog-ears are reliable will not think twice about the one the book
stays quiet about.

**The accusation.** The game declares the questions, since how many bodies
there are is the case; `accuse` records a name and an entry offered as proof,
and refuses evidence that is not in the notebook. Whether the name is the right
name is not the engine's business — being right and being able to show it are
different things, and only the second one is a rule.

The whole notebook, its order and the answers go into a save by themselves.

**The words.** `NOTEBOOK` (with *journal*, *diary*, *casebook*, *notes*),
`SORT` and `ACCUSE` are in the standard vocabulary, because a detective series
should not have to type them out again. As with SCORE, the engine ships the
words and the game decides what they do — opening the book is drawing, and
drawing is the game's.

`sort by` is a verb of its own rather than a verb and a preposition: "by" is
already a way of saying "near", so `sort by time` would otherwise come apart as
sort/near/time, a sentence about standing next to a clock.

The names of the tabs are a game's own and belong in its vocabulary. Two traps
worth knowing: **"time" is already a verb**, so a tab called `times` parses and
a tab called `time` asks how long you have been playing; and **a synonym cannot
contain a hyphen**, because the tokeniser splits on one and hands the parser a
word nobody knows.

> **The rule this exists to keep:** the notebook never knows more than the
> player does. There is no "important", no highlight, no hint and no solver.

**Two rules for a mystery's notebook.** A tab can be `no_proof`
(`{name = "questions", title = "Questions", no_proof = true}`): what she
wondered is not what she can show, and `ne.accuse_why` refuses its entries as
`Not_Proof` (`accuse` stays a bool). `ne.close_note(w, id)` strikes an entry
through and keeps it; `notebook_entries(..., open_only = true)` leaves closed
ones out, and the strike saves. The accusation has as many questions as the
game asks, answered in any order, the last answer to each kept; `!page` prints
them for a game that does not print its own.

## The story clock

`World.time` is playtime — seconds at the keyboard. The story clock is the
other one: the hour the fiction has reached, and in a mystery the two are
unrelated and should be. **Discovery costs time**: walking is free, looking is
free, finding is not.

```odin
w.clock_start = 16 * 60          // where the story opens
w.clock_step  = 15               // what a tick is worth, in minutes
w.clock_paces = {{from = 19 * 60 + 30, step = 4}} // and from dinner on
w.on_clock    = what_the_hour_does

ne.discover(&w, {id = "the_glasses", tab = "things", text = "..."})
    // a note in the book, stamped with the hour, and one tick — the first time only
```

`on_clock` is the game's and is called whenever the clock moves, once at the
start of a game and after every restore. It should set flags; the rooms read
the flags with `when=`, so nothing but one procedure knows what time it is. The
engine saves the count itself.

**Minutes on this clock run past 1440.** A case that goes from teatime to dawn
crosses midnight, so ten past midnight is 1450, not 10 — or the second half of
the night sorts before the first in the one notebook page where order is the
evidence. `clock_face` turns a minute into "00:10" for a debug bar or a page;
never compare two of those strings.

`tick` refuses a negative. The story does not run backwards; a restore is
`set_clock`.

**A tick need not be worth the same all day.** `clock_paces` changes the step
from a given minute: an afternoon of luggage in quarter hours, a night of
evidence in fours. A tick is worth the pace in force where it starts.

**A clock can be held.** `w.clock_held = "act1"` is a condition; while it
holds, a tick spends nothing. For a prologue that happens before the hours
matter — a boat, a train — where waiting and finding go on as usual and the
hour does not. It is flags, so it saves itself.

- `clock_between(w, from, until)` — is it in a window? For an eavesdrop, a host.
- `clock_at_least(w, minute)` — spend whatever it takes to get there. For a
  scene that takes the time it takes: a talk from twenty past to twenty-five to
  is over at twenty-five to, however early you walked in.

### Turns: a tick runs to the next change

With `clock_turns` (and `clock_step = 1`, so the clock counts minutes
underneath), a tick is a **turn**: the clock runs on minute by minute to the
next moment the world is different — a drawn thing or person appears, goes
or moves; a room reads, sounds or is lit otherwise; a flag changes; a beat or
an announcement falls due — and stops there, `clock_turn_max` minutes at most.
Every tick the player pays for changes somebody, and no window is stepped
over. `clock_at_least` still jumps by minutes: a story's cut is not so many
turns.

With `notes_tick`, every new notebook entry spends a tick, but no command
spends more than one that way (`World.ticked`, reset by `run_command`): three
lines about one find are one find. `discover` is `note` that always costs.

`!ticks HH:MM` in the harness steps the clock turn by turn to that hour and
prints what each turn changed — or `NOTHING CHANGED` and why it stopped (a
flag with nobody visibly different, or as far as a turn goes). It is the list
of what a game has still to fill.

## Beats: what happens at an hour

A dinner is not a cutscene. People sit in their chairs until the hour they go,
the player walks about, and at twenty past eight a man leans over a woman's
chair. A **beat** is that: a conversation that happens in a room, in a window
on the story clock, once — heard if the player is there, and not if not.

```odin
w.beats = BEATS[:]
BEATS := [?]ne.Beat{
    {name = "heard_appointment", room = "fire_pit", from = 20*60+20, until = 20*60+28,
     area = {330, 560, 200, 60}, cost = 1, lines = APPOINTMENT[:], on_play = heard_it},
    {name = "saw_appointment", room = "fire_pit", from = 20*60+20, until = 20*60+28,
     only = "!heard_appointment", lines = SAW_IT[:]},
    {name = "generator", from = 22*60+30, until = 23*60, lines = GENERATOR[:]}, // any room
}
```

Every frame the world is running (and after every harness command) the first
beat that is due plays: window open, player in its `room` ("" is anywhere),
inside its `area` if it has one, `only=` true. It sets the flag `name`, spends
`cost` ticks, calls `on_play` (awards, notes) and opens its lines. Several due
together play in order. A beat nobody was there for never plays, and its flag
says so. Hearing something from one place and only seeing it from another is
two beats and an `only=`, as above.

A beat's `on_end` runs when its lines are over: what comes next, when what
comes next is not talk — the discovery's opening line, and then the ride.

## Announcements: a discovery that stops the game

A body is not found in a line of a conversation. The game declares
announcements like beats — a room, a condition, a close-up, a title, the words
— and the first time the player is in that room while the condition holds,
everything stops: the room dimmed, the close-up framed at the top, and the
title and the full description in a big box under it, until Enter.

```odin
w.announcements = ANNOUNCEMENTS[:]
ANNOUNCEMENTS := [?]ne.Announcement{
    {name = "an_pool", room = "pool_deck", only = "bodies_found",
     shot = &pool_closeup, title = "The plunge pool", text = "Two of them..."},
}
```

It is checked every frame ahead of a conversation, so a cut that lands the
player in the room and opens the talk about it shows the body first; and a
conversation that ends by setting the flag and starting the next one gets the
announcement in between. Showing one sets the flag `name`: once, and it saves.
Not during a ride (a ride draws its own frame). The harness prints it as
`[announcement] Title — text` and presses on.

`on_play` runs once, as it opens (by the room or by `announce_now`): what the
discovery writes in the notebook or awards. The tick, if the find is one, is
whatever cut brought the player there; an announcement does not move the
clock by itself.

**Inside a ride.** An announcement marked `in_ride = true` can open over a
host's view when a glance's `on_look` calls `ne.announce_now(w, name)`: a body
found through a otter's eyes. Every other announcement waits until she is back
in her own body.

## Carrying things

```odin
w.items = ITEMS[:] // {"offal", "kitchen scraps", "Scraps in a newspaper, and they smell.", ""}
ne.carry(w, "offal"); ne.carrying(w, "offal"); ne.lose(w, "offal"); ne.carried(w)
```

Having something is a flag, `carrying_<name>`: it saves by itself and a room
can read it (`when=carrying_offal`). LOOK AT a carried thing says its
description (through `look_command`). **PUT OFFAL ON THE BINS is the bins'
business**: when the first noun is not an object here, the command goes to the
second noun's object, turned round, so `on bins put with=offal` matches — and
the walk goes to the bins as well. After ABOUT the second noun is a topic and
this does not happen.

**A thing has a picture** for the inventory screen: the sprite `item_<name>`
(`item_offal`), or the one its fourth field, `icon`, names when two things
share a picture (`ne.item_icon`). The game draws them as 28x28 sprites like
any other; one that is missing shows as a plain tag with the label on it.

## Light: day, sunset, night, sunrise

A room is not dimmed as the clock runs; it is **painted again for each light**
it is seen in, and the engine shows the right painting (light.odin):

```text
pool_deck.sprite           day
pool_deck.sunset.sprite    sun low, shadows one way
pool_deck.night.sprite     moon, or lamps
pool_deck.sunrise.sprite   the same as sunset, shadows the other way
```

The same naming works for any sprite an object wears. A missing painting
borrows — sunrise from sunset, either from day — and whatever is drawn from a
borrowed painting, and every person (never repainted), goes through the game's
`light_tint(w, scene, light)`: a `Palette_Map` for that room in that light.
Keep it gentle; it is for people.

**Lights are objects.** A `glow` object is drawn as painted, in every light,
and a light it has no painting for is not drawn at all — so a lamp painted only
as `lamp.sunset` and `lamp.night` is nothing by day, a little at dusk, a pool
of light at midnight. Put them `depth=back`, behind the people they light.

**The light outside is latched.** The game says what the light is
(`on_light_now`, from its clock or its story). Indoors — a scene with
`indoors` in its file — the player always sees that. Outdoors the light they
see (`World.light`) changes only through a door to or from an indoor room, or
when the game cuts with `relight(w)`; nobody stands on a lawn and watches it
go dark. Two lights behind, the next doorway between outdoor rooms catches up.
A new game, a restore and `set_clock` are cuts. Another room seen through a
host's eyes is drawn in the light it is in now.

`!light night` in the harness shows the room you are in in that light,
whatever the clock says.

**The light as flags.** Every time the light latches the engine sets one of
`light_day`, `light_sunset`, `light_night`, `light_sunrise`, so an outdoor
room's `desc when=light_night` matches the painting she is looking at, not the
clock, which is a door ahead of it. The turn clock ignores these flags: a
sunset is not somebody being different.

## Text the font can draw

The font is ASCII and a script is not. Every message, and everything through
`wrap`, goes through `plain_text` first: an em dash becomes `--`, curly quotes
straight ones, an ellipsis three full stops. Write the script with its proper
punctuation; the screen will cope.

## Timers: seconds of real time

For the few moments a game wants the player's hands and not their clock: a
drug landing in twenty-five seconds, a fuse, a door.

```odin
ne.after(w, "the_drug_lands", 25, the_drug_lands)  // fires once, unless…
ne.cancel_timer(w, "the_drug_lands")               // …she got away
left, running := ne.timer_left(w, "the_drug_lands")
```

Real time is `World.time`: it stops under an overlay and while dead. The
story clock is another thing and a timer never touches it. The harness has no
frames, so `!secs <n>` lets n seconds pass.

`ne.deadline(w, name, secs, fire)` is `after` for seconds the *player* is
racing (the drug landing, a door about to close on a question); `ne.racing(w)`
says one is running. It fires the same way. The difference is for whatever
reads the screen on the player's behalf: autoplay skims while one runs.

## Somebody going past: windows and the passer

A room's openings onto the outside are `window` lines: the glass of a window,
or the gap of an open door, in canvas pixels. The view through it is painted
in the backdrop, and its frame, bars and sill are an object of their own at
`depth=back`, drawn over whatever stands outside.

```text
window back glass=445,176,138,122 feet=390 frame=win_hut_back
obj win_hut_back pos=512,400 sprite=win_hut_back depth=back base=200
window shutter glass=854,262,32,218 feet=470 frame=win_hut_shutter_open when=shutter_cut
```

`feet` is the line a figure out there stands on; leave it off and it is the
foot of the glass and half a figure, so they show from the waist up. `frame`
names the object it is drawn just under; with none it goes after everything at
`depth=back`. `when=` is a condition, as everywhere.

The engine does one thing with them (`passer.odin`): **now and then somebody
walks past.**

```odin
ne.set_passer(&w, {character = "stranger", chance = 0.10, max_delay = 20, only = "light_night"})
```

Each time the player comes into a room that is `indoors`, has a window open,
and while `only` holds, the dice are thrown once: `chance` of somebody. On a
hit they come after a random 0..`max_delay` seconds of real time
(`World.time`, which stops under an overlay), across one of the room's open
windows picked at random, either way, at `speed` (110 canvas pixels a second
unless told), in the character's `walk_left` or `walk_right`, from wholly out
of sight past one edge of the glass to wholly out of sight past the other.
They are drawn through a scissor the size of the glass, just under the frame,
so the frame, the room and everybody in it are in front, and they wear the
room's tint as people do. The walk keeps its own clock, and a frame moves it
at most a fifteenth of a second: the first frame after loading carries the
seconds the load took, and would otherwise end the walk unseen. Leaving the
room ends it.

**It is seen and nothing else**: no tick of the story clock, no flag, nothing
in a save, no word the parser knows. A figure who means something is a person
in the room file. The dice are the passer's own: `seed` in the call, or
`ne.passer_seed`, for a test; the harness seeds them the same every run, and
walks a passer the room rolled out at once, printing `[somebody passes the
back window, left to right]`, as it does a walk. `!passer` forces one.

## Arriving in a room

`World.on_arrive` is called after the player walks through an exit or over a
side (and after the harness's `!room` and a developer's TELEPORT), for
whatever happens when somebody comes in: a talk already under way. Not from
`go_to`, which restores and cutscenes use and which must not set a scene off
twice.

A room may hold two objects of one name under different conditions — the fire
laid, the fire lit — and each one's `text` and `on` lines belong to the `obj`
line above them.

Exits and triggers honour their `when=`: an exit whose condition is false is
not there. A gate that shuts at dusk is one exit with `gate=` (see Gates,
under Sides), or, the old way, two exits — one `when=!dusk`, and a
`closed=true` one `when=dusk` with its `shut` line.

## Sides: walking straight into the next screen

A game whose screens all look the same way (say every outdoor screen
looks north: up the picture is north) joins them by their **sides**. Walk off a
screen's east side and you are on the next screen's west side, at the
matching place, still walking. A side is a line in the scene file
(side.odin):

```
side north to=inside_path span=384,640
side east  to=banda_front span=400,608 name=banda
side south to=track span=448,576 gate=g1
shut south Padlocked at dusk. One key, on his belt.
side west  to=donga span=400,608 arrive=880,560
```

- **`span=lo,hi`** is the stretch of the side the walk band crosses, measured
  along it, in canvas pixels: x for north and south, y for east and west. Only
  there can she cross; anywhere else the floor just ends.
- **The brink** at a point along a side is the outermost floor there: the first
  floor met coming in from that border. A building's face in the middle of the
  floor is never a side, so a span only has to say where; the floor says how
  far.
- **Arrival** is at the matching point of the neighbour's opposite side: the
  place along one span mapped proportionally onto the other (a third of the way
  along the gate is a third of the way along on the far side; partners with
  equal spans give the same x, or the same y), then `ARRIVE_IN` (24 px) in from
  the brink. If something is there — a block, a person, an open exit's patch,
  a deadly edge — she lands at the nearest free spot along the span or further
  in. She faces the way she was going, and `on_arrive` is called, as for an
  exit.
- **`arrive=x,y`** makes it a long walk: no matching point and no partner,
  just that spot in the room it names (a signposted walk to the airstrip).
  She arrives standing: the arrow keys' heading is dropped, so she never
  walks off the end of one long walk into the next.
- **`when=`** false and the side is not there. **`name=`** is a noun: GO BANDA
  walks to it, as an exit's name does.

Three ways over, as for a deadly edge (edge.odin), and **an edge always wins**
where both could apply: a drop is never a doorway.

- **The arrow keys**: the step that would leave the floor, inside a span and
  within `SIDE_REACH` of its brink, crosses; she keeps walking in the new
  screen, Sierra style. A block at the brink stops her; it is not the floor's
  end.
- **A click** beyond the brink, or on the floor within `SIDE_NEAR` (24 px) of
  it, inside the span, walks her to the brink and over (`click_walk`). A click
  anywhere else walks as it always did.
- **Typed**: `ne.go_compass(w, "north")` walks to the side that way (straight
  across if she can) and over; a room with no side that way falls back to the
  exit whose doorway lies furthest that way, which is what interiors use. `ne.head_for_room(w, "banda_front")` is GO TO a
  neighbour, by exit or side; `head_for_exit` finds a side by its `name=`.

`ne.cross_player(w, .East)` crosses her from wherever she stands, gates or no
gates: the game's, between two cutscenes.

### Gates

A gate is one condition that shuts every side and exit naming it, in every
room at once, so its two sides can never disagree:

```odin
GATES := [?]ne.Gate {
    {name = "g1", shut = "dusk,!main_gate_open", text = "Padlocked at dusk."},
}
w.gates = GATES[:]   // before load_scenes: a gate= nobody declared fails the load
```

`side ... gate=g1` and `exit ... gate=g1` are shut while `shut` holds. A shut
side stops her at the brink and says its own `shut <dir>` line, or the gate's
`text`; a gated exit is `closed`, and says its `shut` line or the gate's.
`ne.gate_shut(w, "g1")` asks. Conditions take `|` for *or*, here and
everywhere: `walk_out,!dusk|gate_open` is both of the first two, or the last.

### Keeping her out of a room for a while

A gate shuts one way between two rooms. A keep-out shuts a whole room, from
every side and every door into it, for a window on the story clock, with a
line: for the minutes the story has people somewhere that cannot be drawn
without giving the case away (`keep_out.odin`).

```odin
KEEP_OUTS := [?]ne.Keep_Out {
    {room = "fuel_store", from = 17*60+36, until = 17*60+48, out_by = "south",
     text = "Somebody's round the back of the store. I'll come back.",
     out  = "Somebody coming, round the store. I'll come back."},
    {room = "fuel_store", only = "dragging_now", out_by = "south", text = "...", out = "..."},
}
w.keep_outs = KEEP_OUTS[:]
```

- **The window** is `[from, until)` in minutes (both 0: any hour), and `only=`
  a condition. Minutes, not a flag of its own, on purpose: a flag turning is a
  change the clock stops at (`turn`), and a keep-out must add no turns.
- **Every way in refuses**: a side (`try_side`) or a door (`check_exits`)
  into the room stops her at the brink and says `text`, as a shut gate does;
  GO TO <room> from next door walks her to the brink and is told. A shut gate
  on the same side speaks first.
- **Already in it** as it starts to hold, once the screen is hers (no
  conversation, ride, cutscene, announcement or overlay): she says `out` (or
  `text`) once and walks out by `out_by`'s side, else the nearest open side,
  else an open door (`keep_out_step`, every frame; the harness does it at once
  and prints `[kept out of <room>: to <room> at x,y]`). Sent elsewhere on the
  way, she is turned round again, without the line again.
- **The developer is let through**: TELEPORT and the harness's `!room` into a
  kept room take her there and say so (`(kept out now: let through)`), and she
  is not put out until she leaves (`keep_out_let`).
- `ne.kept_out(w, room)` asks; `!sides` shows `KEPT OUT "<text>"` on a side
  into a kept room; a hint whose `place` is kept is not offered.

### People across sides

The engine never runs people in rooms she is not in. A person's room is the
game's flags; what a side adds is how they leave and arrive in front of her:

- **`obj moore ... when=moore_here enters=west leaves=north`**: when the flag
  turns while she is in the room, they walk on from beyond the west side (at
  the place matching where they stand) and their routine starts when they get
  there; or they walk to the north brink and on out of sight. Going, they are
  already gone to the parser and to the floor; they are only drawn. Without
  `enters=`/`leaves=`, or with no side that way, they come and go at once, as
  ever. Leaving the room, a restore, walking in and a cutscene starting
  settle anybody half way (`people_settle`), each back in their line's pose:
  a cut never casts somebody mid-walk, nor do they finish a walk after it.
- **Changing lines on one screen is a swap**, never a walk: a person whose
  line goes while another line of theirs is in sight (a chair, a pose), or
  comes while another was, is changed over at once (`person_stays`).
  `enters=` and `leaves=` are for leaving the screen.
- **`step cook leave east`** in a routine walks them off for good, until the
  room is next entered.
- **Going north they sink** behind the brink, drawn down to it and no further,
  as somebody goes into water: people never change size. South they walk off
  the bottom of the picture; east and west, off its side.
- **Cutscenes**: `4.0 margaret leave east` walks her off through that side,
  and the next cut's `cast margaret enter=west` brings her on from just
  beyond its west side at the matching place. The game chains the two, with
  `cross_player` for Ada:

```odin
ne.play_cutscene(w, "attempt_1", proc(w: ^ne.World) {
    ne.cross_player(w, .West)
    ne.play_cutscene(w, "attempt_2", ...)
})
```

### Checking a world of sides

- **`nscene world <scenes-dir> --start <room>`** reads every room and checks
  them as one world: each side has a partner facing back, east and west spans
  equal, north and south landing somewhere free all along and in one
  proportion, gates and conditions on both partners, every room with a side
  reachable, the sides making a grid whose loops close, no exit in a side's
  lane and no drop at its brink. It prints what each gate cuts off when shut,
  and the grid as a map (`--` a side, `==` a gated one). Exits 1 on anything
  scoring 50; `--strict` on anything but its info lines (score 10 or less:
  what a gate cuts off, and a gate's own words said where a side has no
  `shut` line, which only the game can judge).
- **The live world** (world_check.odin), for a game's own tests: the same
  questions asked of a loaded world as its flags stand now, so a gate is shut
  or open as the game's clock has it, and its words count. Nothing is changed.
  `ne.rooms_reached(w, from)` is every room she can walk to now, by sides
  there and not shut and exits there and open. `ne.side_faults(w)`: every side
  has a partner facing back with the same gate and `when=`, east and west
  spans equal, floor all along its span, and every 16 px of it landing clear
  (on the floor, in no block there now, in no open exit's patch); a long walk
  arrives clear; a gated side says something when shut. `ne.gate_faults(w)`:
  each gate named, declared once, named by some side or exit, and able to
  shut. `ne.exit_faults(w)`: every exit arrives clear. `ne.world_faults(w)` is
  all three, as `World_Fault`s (`ne.fault_text`); `ne.landing_fault(w, sc, p)`
  says why a spot is no place to put her; `ne.exit_back(w, from, &e)` is
  whether a door has a door back. A game asks them in its own tests, at
  every hour that matters.
- **The room editor** draws each side along its brink (cyan; gold when picked),
  with an arrow out and where it goes; drag a side to slide its span, its ends
  to size it (16 px steps: 5 art px). **side** on the toolbar adds one: drag
  along the edge of the floor where the band crosses. Its panel reads the room
  next door and says whether the partner's span agrees ("take its span").
  `nscene scene add-side`, `scene side`, `scene remove f side:east`, and
  `scene sides-from-exits` (a first draft of sides from exit rectangles on a
  border) do the same from the command line.
- **The harness**: `!sides`, `!cross <dir> [at=c] [by=go|arrow|click]`, and
  `!strip <a> <b>|around [light=] [people] [debug]` (see The harness).

## In sight: nobody talks to her from out of the picture

The parser's "here" is a person's line whose `when=` holds. The eye's is more:
a picture for the pose they are in, inside the room's frame. With frames
running the two can come apart, and she is seen talking to nobody. sight.odin
keeps them together:

- **Gone at once stays drawn.** A person whose line goes with no `leaves=` is
  gone to the parser at once, and stays in the picture as they stood until the
  screen is hers again (`person_pop`). An answer that spent the turn that took
  them away is said to her face.
- **Walking on arrives.** When a line goes up in her room, whoever is walking
  on through a side has arrived (`people_arrive`): nobody speaks from beyond
  the edge.
- **Called back.** TALK TO (ASK, TELL, SHOW, GIVE: `talk_verbs`) somebody
  walking off: they stop, turn to her and stay to be spoken to, and go on their
  way once she has done with them (`call_back`, `sight_release`).
- **Called into sight.** A line said to her face by somebody with no line in
  the room that holds (a beat written for a room they are not drawn in) brings
  them to stand beside her (`CALLED_APART` along the floor, clear of anybody in
  sight) for as long as the screen is held. `SIGHT_LINGER` after it is hers
  again, they walk off by the nearest side, or go at once in a room with none
(`call_into_sight`). Never for a
  close-up, an aperture, a ride, a cut, a thought, a card or her own line.
- **Voices off are the game's.** `w.sight.voice_off(w, line)` is true for a
  line not said to her face: through a net, from the dark, from the top of a
  ladder. A speaker's first such line makes their later ones off too, until
  the screen is hers again. Left nil, every line is to her face.

The harness settles all of it after every line (`sight_settle`: the called
gone, the called-back on their way, the pops out of the picture), so
`!people` and snaps read as they always did. The check is `!autoplay` (The
harness), which plays a script in real frames and lists every **ghost**: a
person spoken to, or saying a line to her face, who is not in sight
(`person_unseen`: no picture for the pose, or less than a third of it inside
the frame).

## Riding: somebody else's eyes

The protagonist goes under where she stands, and the screen becomes what a
**host** is looking at. She is a passenger: the host looks at what it wants,
in its own order, on a loop the player can learn and cannot steer.

```odin
STOAT_LOOKS := [?]ne.Glance{
    {look = "beam", room = "tent_row", at = {460, 330}, secs = 3, line = "Along the beam."},
    {look = "moth", room = "tent_row", at = {700, 230}, secs = 4, zoom = 2.4},
    {look = "shout", secs = 1, leaves = true}, // the host breaks off
}
w.hosts = HOSTS[:] // ne.Host{name = "stoat", from = 20*60, until = 28*60, camera = {...}, attention = STOAT_LOOKS[:]}
```

- **`ne.ride(w, "stoat")`** returns an outcome — `Started`, `Unknown`,
  `Not_Here` (no object by that name in the room), `Not_Now` (its `only=`
  condition, or outside `from`..`until` on the story clock), `Already` — and
  the game words each one. What riding costs is the game's: `ne.tick` after
  `Started`.
- **The handover is always seen.** Her own view greys and tilts, and the host's
  dissolves up through it in a 4x4 ordered pattern, one art pixel to a cell.
  Coming back is the same, backwards. The player always knows the body is where
  it was left — and if the host is looking into that room, the body is in the
  picture.
- **Each glance** centres the camera on a point in a room (a different room is
  a cut; the same room is a head turning), says its `line` the first time round
  in a ride, and lasts `secs`. `leaves` ends the ride when it is over.
- **The camera** is `zoom` (never below 1: a host cannot see past the edge of
  what was painted), `tilt` in degrees, and `sway`, which is how badly it keeps
  still.
- **Colours stay in the palette.** `colours` is a `Palette_Map` — for each bEGA
  colour, the bEGA colour it becomes — applied by a shader over the whole view.
  `palette_map_tones({1, 8, 7, 15}, 1.4)` is a near-monochrome eye that sees
  more than we do; `palette_map_tones({0, 8, 7, 15})` is plain grey.
- **A glance can have a condition and an action.** `only=` skips it while false
  — the stoat looks into tent three only while somebody is in it — and
  `on_look` runs each time it comes round, which is where seeing something
  becomes an award or a note.
- **A host may be declared more than once** — the same animal at different
  hours, or in a moment only a scene makes (`only = "surviving"`). RIDE takes
  the first declaration that is here and awake, and otherwise reports the
  nearest miss. `room` pins a declaration to one scene: the same stoat in the
  tent row's beams and in the fuel store's rafters, looking at different
  things.
- **While riding** the prompt still works. WAIT is the next glance; STAND, WAKE
  and EXIT come back; LOOK says the glance again. Anything else goes to
  `on_ride_command` — which is where a game says what its power cannot do.
  `on_ride_end(w, host, broke_off)` is her coming round.
- **Where the body was left** — `ride_body(w)` — is kept after the ride and
  saved. A third act that punishes leaving it in the wrong place reads it there.
- People keep to their routines in the room she is looking into and in the room
  she is sitting in. Nothing else moves: she does not walk, and neither does
  the clock unless the game ticks it.

`ne.first_time(w, "refused_a_name")` is for the refusals: true once, then false
for good, and it is a flag, so it saves.

## Overlays

Something holding the screen over the world: a notebook, a map, a case of
belongings. The game draws it and works it; the engine stops the world under
it — nobody walks, nothing reaches the prompt, the play clock waits so routines
do not jump when it closes — and draws it last.

```odin
ne.open_overlay(w, {update = book_update, draw = book_draw})
// update returns false to close
```

For drawing one: `draw_panel` is the frame the speech boxes use, `wrap` wraps
text the way they do, `draw_sprite_in` stretches a painted page into a
rectangle, and `ui_px`/`ui_font` scale measurements given at the 320-wide
reference size, so a game's own overlay lines up with the engine's at any
canvas size.

## The menu bar, and its screens

Sierra's SCI0 bar (Laura Bow, 1989): nothing at the top of the picture until
the pointer touches the top edge, then a strip drops in with a few words on it,
and goes back up when the pointer leaves. A game says what is on it:

```odin
ne.set_menu_bar(&w, []ne.Bar_Item{
    {label = "Menu",      key = .F10, pick = ne.open_menu_screen},
    {label = "Save",      key = .F5,  pick = ne.open_save_screen},
    {label = "Load",      key = .F7,  pick = ne.open_load_screen},
    {label = "Inventory", key = .TAB, pick = ne.open_inventory_screen},
    {label = "Notebook",  key = .F4,  pick = open_my_notebook},
})
```

- **It appears** while the pointer is within `BAR_REVEAL` grid pixels of the
  top of the canvas (or above it, over a letterboxed picture's black), stays
  while the pointer is on it, and slides in and out in `BAR_SECS`. The world
  does not stop for it. A pointer that has not moved yet, or a hidden window's,
  never calls it down: it sits at 0,0.
- **Using it**: the word under the pointer is picked out in yellow, and a
  click runs it. A click anywhere on the bar is the bar's and never walks her
  (`pointer_in_play`). An item's `key` runs it from anywhere in play, and the
  same key closes the screen it opened. Use function keys and Tab: letters
  belong to the prompt.
- **It is not there** during a death, a cutscene, an announcement, a
  conversation (a peep's too), a ride or an open overlay, which are the times
  the prompt takes no command either (`menu_bar_allowed`). A game that sets
  no items has no bar: v1 has none.

The screens are overlays, so the world stops under each. They are
lettered in the comic look over the room dithered dark. Esc, a click outside
or the bar's key closes one; Up, Down and Enter work as the mouse does. The
game's words for them go in `w.screen_words` (`Screen_Words`):

| Screen | |
| --- | --- |
| **Save** | the player's eight slots: each one's title (`save_title`, the hour in a game with a clock), room (`room_name`, or the scene's name spaced) and play time, or EMPTY. A click saves, and over a slot already used it asks for a second click |
| **Load** | all ten, the autosave and the one before it first, labelled. A click restores, and an empty slot is greyed and does nothing |
| **Inventory** | `always` (what she has whatever happens), then `carried`, as a grid of pictures, seven across and three down a page. Each is the sprite `item_icon` names: `Item.icon`, or `item_<name>` when that is empty. The pointer on one (or the arrow keys) picks it out and brings its label up in a small caption by it. A click (or Enter) shows its description in a caption at the foot, unless `item_pick` does something with it (a notebook opens). A thing with no sprite is a plain tag with its label lettered under it. The wheel, Up and Down past the edge, and the arrows at the grid's right go a row at a time |
| **Menu** | Resume, Hint (when the game has a hint table), the game's own `menu` lines (a setting with `stays`, words that change with `label_of`), Restart and Quit. Restart and Quit ask first, and a second click says yes |
| **Hint** | how she is getting on, then the hint, a grade at a time (below) |

**Saving and loading are the typed commands.** A slot picked on a screen goes
through `slot_act`, which is what `slot_command` does with SAVE 3 once it has
the number, and how it went is said by `slot_said`, the procedure the game's
typed SAVE and RESTORE use. Load can reach the autosaves, which a typed number
cannot. Each is a row of the play log, input `save 3`, route `screen`.

The harness: `!bar` holds it down for a shot, `!bar hover <item>` with an item
picked out, `!bar <item> [row]` runs an item (and puts the pointer on a row of
the screen it opens), and `!screen` prints the screen up, clicks a row
(`!screen 3`), puts the pointer on one (`!screen hover 3`) or presses Esc
(`!screen esc`). On the inventory, `!screen` gives each thing's sprite name
(`[item_lamp]`, or `[item_lamp: none, a tag]`) and the page shown, and with
the pointer on a thing it says whose name is up. The tests are
`menubar_test.odin`.

### Hints

A Sierra hint book, on the Menu screen (hint.odin): the first thing she can
still do to earn points, said three ways, each plainer than the last. The game
writes the table, in the order its story is best played in; the engine picks
from it.

```odin
HINTS := [?]ne.Hint {
    {award = "the_photograph", needs = "act2", place = "banda",
     nudge = "The banda has a wall I have not looked at.",
     clearer = "There is a photograph on it, and nobody has dusted it.",
     answer = "In the banda, the photograph on the wall.",
     does = "look at photograph"},
}
w.hints = HINTS[:]
```

- **The hint** (`first_hint`) is the first entry that can be done now for an
  award that can be lost (its `until` is set), then the first for one that
  will wait, then the first idle entry (no `award`: how the story goes on,
  only when nothing scores). An entry can be done now when its award is not
  earned, the award's `only` holds, `needs` holds (flags, as `when=` reads
  them), the clock is inside its window (the entry's `from`/`until`, or the
  award's; a held clock has no window), `can` (a proc, for what flags cannot
  say) agrees, and its `place` is not kept out (keep_out.odin).
- **Three grades**: `nudge` (where to go, who to see), `clearer` (what to do
  there), `answer` with the words to type (`does`, `;` between commands).
  "Another hint" gives the next. Over them, a few lines of how she is getting
  on: the score, what is still to find, the hour, the room, or the game's own
  (`Screen_Words.status`).
- **Asking costs nothing**: no tick, no flag, no score.
- **The harness**: `!hint [1|2|3]` the hint at that grade; `!hint list` every
  entry that could be done now; `!hint try` types the answer in a forked copy
  of the game (hint_linux.odin), so the game being walked never changes, and
  says what it earned; `!hint check` tries the hint and flags any award earned
  since the last check that no entry could have been done for (a `GAP`);
  `!hint check all` tries every entry possible now; `!hint coverage` checks
  the table itself (every scoring award hinted, every grade worded, every
  `place` a room, every answer fitting the screen); `!status` the lines over
  it. Run after every line of a playthrough, `!hint check` proves the table.

## One room, worn several ways

Six tents built from one plan are six near-identical rooms that drift apart the
first time a doorway moves. Build one and dress it:

```odin
ne.dress(w, "tent", "3")         // tent_3 on, every other tent_* off
ne.dressing(w, "tent")           // "3"
```

The room's own `when=tent_3` lines do the rest. Flags go into saves, so a game
keeps nothing of its own for this. A group is every flag that begins
`<group>_`, so its name has to be its own — an award called `fire_warden` would
be taken off by dressing the fire.

## Starting, starting over, and the loop

`run_game` is the loop: the studio card, the title screen, play, and the
screenshot the harness exits on. The menu's first item starts a game and its
last one quits; anything between goes to `Front.on_menu`. A game's Load Game is
`title_load` from there (Title screen, above).

**Start and Restart are one path.** Both call `new_game`, which runs
`reset_story` — flags, score, notebook, answers, both clocks, a death, an
overlay, a half-typed command, and every routine back to its first step — and
then the game's `start`. A game never has to remember what to clear, and the
menu's new game and the death box's Restart cannot come to disagree about what
a new game is. Accusation questions are wiped too, so `start` asks them.

**An intro is `Front.intro`.** If a game sets one, the menu's Start runs it
instead of `start` (after the same `reset_story`): the story before the story,
once per game begun. It sets its own stage and, read or skipped, calls
`begin_after_intro(w, start)`, which is a new game from a clean slate. The
death box's Restart and `--skip` go straight to `start`, so nobody sits
through it twice and the harness never sees it unless a bang asks for it.

## Autoplay: the game playing itself

`--play file [--speed N]` plays a script in the window, the way a person would:
from the menu's Start (so an intro plays), each command typed at the prompt,
the walking walked and the rides ridden in real frames, every line and every
announcement up long enough to read before it presses on. `--speed` runs the
world N times faster (4 by default). It is for watching a playthrough, not for
testing: the harness below is the test tool.

The script format is the harness's — one command a line, `#` comments, and
`until HH:MM <command>`, which repeats a real command (usually `wait`) until the
story clock reads that. Bangs are skipped: a playthrough does not teleport.
`--script @file` runs the same file through the harness, which is how a
playthrough is checked.

It reads what the game puts up as a person would. A conversation, a peep, an
epilogue card or an announcement is up for its reading time and then Enter; a
choice or a timed question is answered by the script's next line, typed. A
cutscene plays at its own pace and nothing is typed under it; a line half
typed when anything takes the screen waits and goes in afterwards. A ride the
script started is the player's: WAIT in it lets the glance run out rather than
cutting it short, which keeps the glances in step with the harness's count. A
ride the story starts is watched to its end. While a deadline runs
(`ne.deadline`) she skims. When the script runs out, what is still coming plays
out, and the last screen (the score) stays up. The tests are
`autoplay_test.odin`.

**`!autoplay <file> [snaps=<folder>]`** plays the same script the same way in
the harness, with nothing drawn: `autoplay_step` and `update` a sixtieth of a
second at a time, which is what `--play` does between two draws at any speed.
Every line is read for its time, every walk walked, and people walk their
routines and on and off. It is the check for what only real frames do: the
harness settles each command at once, which hides a walk-off or a person
spoken to before they are drawn. It runs from where the game is (`!intro`
first for a playthrough from the menu's Start), watches everybody she speaks
to and every line said to her face (In sight, above), and reports the world
seconds, how it ended, where she is and the hour, then the ghosts, each with
a picture of the frame when `snaps=` names a folder.

## The harness

**`NENGINE_HIDDEN=1`** in the environment opens every window hidden — the game's and the tools' — so a `--shot` or a script runs, renders and screenshots
without ever showing up or taking focus, and silent: the sounds load and play at
no volume. `just smoke` and `just shot` set it. Nobody can see a hidden
window, so nothing is left running in one (hidden.odin): it dies with the
process that started it, a run with no `--shot` stops where the shot would
have been taken, and nothing hidden lasts past `HIDDEN_MAX_SECS` (ten
minutes).

`--script "a; b; c"` types commands before the window opens and prints every
reply. It is the only way to check a room, a parser change or a line of
dialogue without sitting at the prompt, and it is what `just smoke` drives.

A line starting `!` is the harness talking to the game. The engine's:

| | |
| --- | --- |
| `!room <name>` | go there, standing in the middle of the floor |
| `!tick [n]` | spend n ticks of the story clock |
| `!clock` | what hour it is |
| `!at HH:MM` | spend ticks until then — the first tick at or after it, the next time the clock reads that |
| `!flag <name>` / `!flag !name` | a flag on, or off |
| `!dress <group> <which>` | put a room in one of its dressings |
| `!note <tab> <id> [@minute] <text>` | write an entry, stamped now or at a minute on the game's clock |
| `!book [tab]` | print the notebook, or one page, as text, with each entry's `shown to` sub-lines (ne.shown) under it |
| `!ride` | who is being ridden, what it is looking at, where the body is |
| `!ride <host>` | go under and stay in the handover, for a `--shot` |
| `!leave <n>` | the next conversation read out is left (Escape) on its nth line: a peep left part-way prints `[left after n line(s)]` |
| `!hold <words>` | for a `--shot` of a line: the next conversation read out stops on the first line with these words in its text or its speaker's name (or on the nth line, for a number) and stays up, `[held at line n]`; a cutscene met first is left to play in the frames after the script (`--at` picks the moment), and an announcement stays up. Nothing runs on past it, so it goes last |
| `!typing <words>` | leave words in the typing line, unsent: a `--shot` of the prompt with a command half typed |
| `!cuts` | every cutscene loaded: `<name>: <secs>s in <room>, <n> cast, <n> cue(s), <n> line(s)` |
| `!cut <name>` | play one here, as `play_cutscene` would; it prints `[cutscene <name>]`, its lines, `[end <name>]` |
| `!sound` | what she can hear: `ambience <name>; loops <the loops of what is here>; music <name>; bed <name> at <volume>; played <every sound played since the last !sound>` — a name with no baked file behind it is `(silent: no such sound)`, and one played several times running is `<name> x<n>`. The music is the cue over it if there is one, with how loud if not full (where it comes from, ducked) and what it holds: `music kite at 0.60 over night`. A cue that plays once (`play_over`) is played out at once, as its frames would, printing `[cue <name>]`, and is among the played |
| `!stand x,y [facing]` | put her there, no walking |
| `!people` | everybody drawn here: `name x,y [pose]`, and `(coming)` or `(going)` while they walk on or off through a side, at the place they are going to or from; `nobody` (probe.odin) |
| `!put <obj>[/n] x,y` | move an object or a person (`/n`: the nth line of that name) |
| `!show <obj>[/n]` / `!hide ...` | force one shown or hidden until the flags next change; `!show *` every non-person, `!hide people` every person |
| `!snap <name> [debug\|marked]` | the room as drawn now, to a file (or onto the open sheet) |
| `!cutsnap <cut> <secs>...` | when the harness next plays that cutscene out, the room as drawn, with her, at each of those seconds of its clock: `<cut>_<secs>.png` (a time past its end, at its last frame). In the harness's own sixtieth-of-a-second steps, so the same however fast the machine draws (probe.odin) |
| `!crowd <name> [debug\|marked] [grid] [around] [x,y[:as=char][:pose=p][:facing=f]]...` | her at every point at once, each copy drawn by the real draw and composited: who is in front of what, at a glance (probe.odin) |
| `!spots <name> [debug\|marked]` | every person the room file holds, at every spot its lines and routine give it |
| `!sheet <path> [cols=N] [scale=F]` / `!sheet end` | the pictures in between go on one labelled contact sheet |
| `!bar [hover <item> \| <item> [row] \| off]` | the menu bar held down for a shot, an item picked out, or an item run as a click would; with a row, the pointer on that row of the screen it opens |
| `!screen [<n> \| hover <n> \| esc]` | the bar's screen that is up, as text; row n clicked (from 1), or under the pointer; Esc |
| `!title [at=F] [about] [load [n]]` | the title screen instead of play, for a `--shot`: its dusk held F of the way to night (0 to 1), its About page up, its Load screen up and row n picked, which goes into that save and prints where she is (menu.odin, launch.odin); its report ends `; music, <seconds> s` when the title has music |
| `!click x,y` / `!arrow <dir> [secs]` | a click in the room, or an arrow key tapped, walked out: `walked to x,y`, `over the edge <name>`, `crossed <dir> to <room> at x,y`, or `went to <room>` (edge.odin) |
| `!sides` | the room's sides: where each goes, its span and brink, its gate (open or SHUT and what it says), hidden, a long walk, or its partner (`partner ok` / `NO PARTNER`) (side_harness.odin) |
| `!cross <dir> [at=c] [by=go\|arrow\|click]` | across that side, walked out: as GO NORTH (the default), the arrow key from a step in, or a click just beyond the brink; `at=` is where along it |
| `!strip <a> <b>\|around [light=L] [people] [debug] [out=f.png]` | neighbours drawn as one picture the way they meet — east and west side by side, north above south, `around` a room and every neighbour in a plus — for checking the paint agrees across a side; `debug` draws the floors, the brinks, and lines from where she leaves to where she lands; onto the open sheet, or `strip_a_b.png` (probe.odin) |
| `!autoplay <file> [snaps=dir]` | a script played in real frames, undrawn, as `--play` plays it; ends with the ghosts (autoplay.odin, sight.odin) |
| `!type <command>` / `!frames <secs> [xN]` | a command typed and nothing settled; then that many seconds of the real loop, sixty frames a second (each frame N times as long): where she ends up and what is on screen. For what the settled harness hides |
| `!node <id> [tag]` | play a dialogue node, as the game would |
| `!hint ...` / `!status` | the hint, tried, checked (see Hints) |
| `!passer [window] [left\|right] [at=F]` | somebody going past a window here (passer.odin): now, walking in the frames after the script (`--at` picks the moment), or held F of the way across for a `--shot` or a `!snap`; `!passer ?` what is coming, `chance=1` somebody in every room come into, `seed=N` the dice |

A death prints `[dead: <reason>]` — there are no frames to play it out in —
and `!restore` presses the death box's Restore: back to the death's restore
point if it named one that was made (`restored "the gap": the_gap at 00:30`),
otherwise the newest save (`restored slot -1: ...`). Run
it with `XDG_DATA_HOME` pointing somewhere empty for a fresh profile; `just
smoke` always does.

After every command, and every `!` line, the harness carries on as the frames
after it would — plays a beat that is due, finishes a ride's handover, reads
out the conversation at the end of it, plays a cutscene out (`[cutscene
<name>]`, its lines, `[end <name>]`; see Cutscenes) — until nothing more
happens by itself.
A beat that starts a ride that ends in a conversation prints all three: a ride
that starts by itself on the way (a beat's, or the one a conversation ends in:
a scripted ride) goes round once, glance by glance, and she comes back, as its
frames would take her; a ride the line's own command started waits for her
WAITs and her GET UP, as it would at the prompt. (Before this, a scripted ride
was left open, and every later line was answered by a passenger.)

A command that sends the player walking is walked out there and then — the real
steps, undrawn, at sixty a second — and the harness prints `[walked to x,y]`
before the reply. A ride's handover is finished at once too, and the harness
prints `[through the stoat: beam]` for each glance and `[back: room at x,y]`
when she comes round. That is the one scripted check on walking; the people in the
room stand still while it happens. A walk (or a climb) that ends in another room
gets that room's first frame too: a trigger over the whole floor fires, as it
does in play, and what it says is part of the reply. So does a room come into
any other way, once nothing else is holding the frame.

Anything else starting `!` goes to the game's `Bang` handler. A command that
says nothing prints `[nothing said]`, or `[an overlay is open]` — never the
previous reply, which it used to, and a harness that can show a stale answer is
lying. A typed command closes any open overlay first, as a player would.

## Developer commands: TELEPORT and TIMETRAVEL

Two cheats, typed at the prompt like any command, for whoever is building the
game (dev.odin). They are there only with the dev switch on; off, the words
are in no vocabulary and get the parser's answer to a word it does not know,
in the game's voice. With it on they work in `--script` too.

| | |
| --- | --- |
| `--dev` / `NENGINE_DEV=1` | the switch, on the command line or in the environment (`launch_flags`; `World.dev.on` for a test). |
| `TELEPORT <place>` | to that room, standing where somebody coming in would: a door's arrival spot, else a step in over a side (the south first), else the free spot nearest the middle of the floor. Then `on_arrive` and a trigger over the whole floor, as for walking in; beats due play after |
| `TELEPORT` / `TELEPORT LIST` | every room, a page at a time (Enter for the next) |
| `TIMETRAVEL <time>` | the clock on to then, as `!at` runs it (`clock_at_least`): 20:00, 2000, 20.00, 20h, 20h30, 8pm, 8:30pm, noon, midnight. `TIME TRAVEL` is the same. On its own: the time now, and how |

A place is a room's name (`fuel_store`), the name with spaces, or a word in
`World.dev.places` with every synonym the vocabulary gives it (`{"gap",
"fuel_store"}` brings "the gap", "overlap"). Case, spacing and a leading "the"
or "to" do not matter. The order: a room's own name; a word of the game's,
which if it names several rooms lists them; the start of exactly one room's
own name ("kitchen y"); the start of any name, if only one room has it. Not
found, it lists the nearest by spelling.

A time goes on the story's day, `World.dev.day` (from and until, on the game's
clock; the twenty-four hours from `clock_start` if unset), so after midnight is
the same night: in a day from 16:00, 02:30 is 1590, after 23:59. A time outside
the day is refused. **The clock only runs forward**: a time already gone is
refused and says so ("It is 02:30, and 20:00 has gone: the clock only runs
forward"), never quietly taken as tomorrow's, which is what `!at` does. A
held clock (a prologue) is let go by `World.dev.unhold`, the game's, if it
has one.

```odin
w := ne.World{
    // ...
    dev = {places = ROOM_NOUNS[:], day = {16 * 60, 30 * 60 + 40}, unhold = skip_the_boat},
}
```

## The play log

`--log <file>` (or `NENGINE_LOG=<file>` in the environment) writes down every
command typed and everything the game said back — in normal play, under
`--play` and in the harness alike — so a session can be read afterwards for
the places where the replies run out. It is TSV, one row a command, with a
header, and each row is written and flushed as soon as the command is over, so
a crash or a closed window keeps everything up to the last one.

```log
time   room            status                              input                    route               gap           response
16:20  main_gate       act2 day; ledger,daybook,manifest   take padlock             game                no-verb       It isn't mine, and out here that matters more than it does at home.
16:20  main_gate       act2 day; ledger,daybook,manifest   look at padlock          object:padlock.look               Open on the hasp, for now. He will close it himself at dusk.
16:20  main_gate>kite  act2 day riding:kite; ledger,...    wait                     ride                              (turning) Round, and the whole escarpment tilts like a plate somebody is carrying.
```

| Column | |
| --- | --- |
| `time` | the story clock (HH:MM) when it was typed; the play clock (`+M:SS`) in a game without one |
| `room` | the scene and where she stood, `tent_row (50,612)`; `room>host` while riding, `room@aperture` at a peep |
| `status` | `World.on_status(w)`, a short line of the game's (the act, what she carries); without one, the light and the names of what she carries (`default_status`) |
| `input` | exactly as typed |
| `route` | how it was handled: `parse:unknown <word>`, `parse:no-antecedent`, `answer` (a pending question took it), `ride`, `peep:<object>`, `object:<name>.<verb>` (an object's own verb), `object:<name>.look` (its description), `scene`, `game` (the world's `on_command`), `walk` (GO TO, or a way out), `out-of-reach` (when she set off and could not get there: where she stopped, and the spot and the thing she was walking to), `ignored:cutscene`, `unanswered` (nobody has an `on_command`). A command that walks her over to something is recorded as what was done when she got there |
| `gap` | empty when the game answered on purpose; otherwise why it did not. The engine's own: `unknown-word`, `no-antecedent`, `talk-shrug` (a topic file's `*` answered), `show-shrug`, `ride-refused`, `peep-nobody`, `unanswered`, and `silent` for a command that showed nothing at all. A game marks its own fallbacks with `ne.log_gap(w, reason)` — `no-verb`, `no-object`, whatever it likes, short and the same each time |
| `response` | every line shown because of it, until the next command, joined with ` / `: the message box, a conversation's lines (`Name: text`, `Name (thinks): text`), an announcement (`Title: text`), a cutscene's lines, a peep's, a card (`[card] text`), a death (`[death] reason`) and anything a game logs itself with `ne.log_line` (a score line) |

A row ends when nothing more is coming of the command — no conversation,
cutscene or announcement up or due, no walk, gesture or ride handover under
way, no beat about to start — or, in the harness, at the end of its line.
What is said with nobody typing (a beat at an hour, a timer, a ride's next
glance) gets a row of its own with input `(beat)`, `(timer)` or `(ride)` and
route `story`, so the log is the whole of the session. A harness `!` line gets
one too, route `harness`, holding whatever it set going.

`log_gap` never changes what is said: it goes beside the stock reply, at the
point the game falls back on it.

```odin
case:
    ne.log_gap(w, "no-verb")   // the play log's mark; the line is the same
    ne.say(w, "I'm a booking clerk, not a magician.")
```

`just gaps [file]` counts a log's gap rows by reason and by what was typed,
the most frequent first. The tests are `playlog_test.odin`.

## Saving

Ten slots: an autosave, the autosave before that, and eight the player owns.

```odin
w.save_name = "my-game"   // where saves live
w.on_save   = write_my_state
w.on_load   = read_my_state
w.user      = &state            // so the hooks can find it without a global

ne.save_game(&w, 3, "the second night")   // a slot the player chose
ne.load_game(&w, 3)
ne.autosave(&w, "the veranda")            // rolls, then writes
```

The engine saves what the engine owns — which scene, where the player stands,
which way they face, the clock, what "it" means — and the game's two hooks put
its own state in and take it back out:

```odin
write_my_state :: proc(w: ^ne.World, s: ^ne.Save) {
    state := cast(^State)w.user
    ne.save_put_bool(s, "has_key", state.has_key)
    ne.save_put_int(s, "lucidity", state.lucidity)
}
read_my_state :: proc(w: ^ne.World, s: ^ne.Save) {
    state := cast(^State)w.user
    state.has_key  = ne.save_bool(s, "has_key")
    state.lucidity = ne.save_int(s, "lucidity", 100)
}
```

**The autosave rolls.** `autosave` moves the old one down to
`AUTOSAVE_PREVIOUS` before writing the new one, so a game that autosaves on
entering a room always leaves a step further back to go to. Without it,
autosaving on the way *into* the trap overwrites the only save from before the
trap — which is the bug that makes autosaving worse than not having it.

Call it on events the game picks: a room entered, a chapter turned, a body
found. The engine never autosaves by itself.

The details:

- **A save is a text file**, `key value` a line, so a save that stops loading can be read and fixed rather than being an opaque brick. A title runs to the end of its line, so it can have spaces.
- **The scene is stored by name**, not by index, so a save survives the rooms being reordered — which happens every time a game grows a scene.
- **Saves are the player's, not the project's**, so they go under the user's data directory. A `save_name` with a slash in it is taken as the folder itself, for a portable build or a test.
- **`save_infos`** lists every slot without loading any of them — title, when, which room, how long — which is what a save window will draw. `any_save` and `newest_save` are what a Restore button needs.
- **Restore points** are saves kept in memory under a name, for a death to go back to: `restore_point(w, "the question")` saves the world as it is now; `restore_point(w, "the gap", "the_gap", {760, 470})` saves it now but standing somewhere else (the death on the path restores to the gate where the lamp was). A `Death` with `restore = "the gap"` makes the box's Restore load that point, whatever was autosaved since; a point never made falls back to the newest save. Writing a point again replaces it; a new game forgets them all, and they are not written to disk. `has_restore_point`, `load_restore_point`.
- **Restoring clears the moment it was restored in** as well as a death:
  running timers, a question waiting for an answer, a conversation half
  read, an open overlay. None of it is in a save and none of it survives one.
- **Restoring clears a death.** The death box's Restore reaches for the newest save there is, and greys itself out when there is none.
- **A save carries its world's version**, when the game keeps one: `w.save_version = 12` writes `version 12` into every save, and a save of any other version (or none) is refused — `load_world` changes nothing and returns false, `slot_act` says `.Not_Restored`, and `w.old_save` is true so the game's `slot_said` can say *why* ("That save is from an older version of the game"). The Load screen greys such a slot as "(an older game)", and `newest_save` and `any_save` pass over it, so the death box's Restore never reaches one. Bump it when rooms are renamed or the world is rebuilt. A game that sets no version (0) loads anything, as before.
- **`slot_act`** is SAVE or RESTORE once the slot is known: `slot_command` and the bar's Save and Load screens both call it. Saving is into 1 to 8 only; restoring may be from the autosaves as well.

## Title cards

One picture, alone on a coloured ground, fading in, holding, and fading out —
the studio logo before the menu, a chapter heading, "three weeks earlier".

```odin
logo := ne.splash_new(assets.sprites["bika_logo"])
// each frame, while it runs:
if !ne.splash_update(&logo, dt) do // on to the menu
ne.splash_draw(&logo)
```

The picture is drawn at a whole-number scale, as large as fits with a margin,
because a logo at 3.7x has soft edges and the point of pixel art is that it
doesn't. Any key or click skips it — into the fade-out rather than straight to
the end, so a skipped logo still leaves the way it would have; pressing again
cuts it short, because the second press means it.

This is deliberately **not** a cutscene. A cutscene is people moving about a
room on a clock and needs a World, a scene and a cast; a card needs a picture
and a stopwatch, and putting a logo through the cutscene machinery would mean
inventing a room for it to happen in.

## Cutscenes

A cutscene is a room, a cast and a list of cues on a clock — real actors on a
real scene, so the moment it ends the player is standing where it left them.

```text
cut arrival scene=veranda
cast ada  char=ada  at=240,470 facing=right
cast heir char=heir at=760,470 facing=left

0.00 ada  walk_to 480,470
2.20 heir face left
2.60 heir say You're the agency girl.
3.00 line A1.VR.HEIR 2-4
6.00 camera shake 0.40
8.00 end
```

Times are seconds from the start, and a cue fires when the clock passes it.
Nothing waits for anything else — a cutscene is timed, not programmed, which
is what makes it readable down the left-hand column and drawable as a
timeline. A cue may walk somebody, turn them, have them speak or think, say a
line of narration, say a dialogue node's lines, put up a painted shot, shake
the camera, name a sound, or end the thing; anything more belongs to a
trigger.

**`line` says a node's lines, so a cutscene never copies the script.** The
words stay in the writers' Markdown (Dialogue nodes, above) and the cut says
which of them, and when:

```text
12.50 line A2.GT.FENCE 3                 the node's third line
12.50 line A2.GT.FENCE 3-5               its third, fourth and fifth
12.50 line A4.3D.PERCY 1-2 tag=percy     the first two of that telling
```

- Lines count from 1, within the telling: every untagged line, plus those
  tagged `tag=` — what `play_node(w, id, tag = ...)` plays. With no `tag=`,
  the untagged lines only.
- Each is said by its own speaker, with the portrait (named on the box when
  there is no face), and a stage direction, `(He goes.)`, as narration.
- **The engine times a range**: the first line at the cue, and each after it
  when the one before has had its reading time, `line_secs(text)` — the same
  2 seconds plus one for every fifteen characters, between 3 and 12, that any
  box stays up.
  There is no duration to give; to time lines by hand, give each its own cue.
  A cutscene with no `end` waits for a range's last line; one with an `end`
  stops there, whatever is still to come.
- The node is only *said*, not played: its `[sets: ...]` are not set and it is
  not marked said. A cutscene changes nothing.
- A node or a line that does not exist says nothing; the harness prints
  `[no line A2.GT.FENCE 3]` (with `tag=...` if one was asked for) where it
  would have been, so the author sees it.
- The editor shows a `line` cue on the nobody row, labelled with the node and
  the lines and as long as they take to read, and chooses one from the
  game's dialogue with its lines in view; `nart cutscene info` lists it as
  written.

`load_cutscene` reads one, `cutscene_start` puts the cast on the floor, and
`cutscene_update` runs the clock and returns false when it's over:

```odin
cut, _ := ne.load_cutscene("assets/cutscenes/arrival.cut")
ne.cutscene_start(&player, &cut, &assets)
// each frame, while it runs:
if !ne.cutscene_update(&player, &w, dt) do // back to the game
ne.cutscene_draw(&player)
```

`cutscene_text` writes one back. `cast_text`, `cue_text` and `cue_body_text`
(a cue's line after its time) write a line at a time the same way, for an
editor that keeps a file's own lines and writes again only the one it
changed.

The cast are ordinary `Actor`s, with the same character art picking a pose
from the direction. **A walk is a straight line at `CUT_SPEED` (190), through
anything**: that is what the cutscene editor draws and times, so what you time
there is what plays, and somebody can walk in from off the edge of the floor.
Pick walks that look right in the room; the floor does not check them.

**Somebody's own speed: `speed=` on the `cast` line**, in canvas pixels a
second, for whoever does not go at a walk — a cart, a boat, an aeroplane
crossing the sky, which are characters like anybody else, a walk of turning
wheels or propellers:

```text
cast cart  char=cart  at=-80,500 speed=60
cast plane char=plane at=1100,90 speed=320
0.00 cart  walk_to 1100,500
2.00 plane walk_to -200,70
```

- Without it, `CUT_SPEED`; `cast_speed(m)` is the one in force. The player
  and the room's people walk at it while the cut plays and at their own
  again after, as they do at `CUT_SPEED`.
- A part drawn with `step=` keeps its feet (or its wheels) with the ground at
  any speed (`walk_rate`, actor.odin), so a slow cart's wheels turn slowly.
- The cutscene editor times a walk at the walker's own speed too.

### A painted shot

A cutscene can show its lines over a painted picture, as a conversation's
close-up does (`Talk_Line.shot`): the room is not drawn while it is up, and
the boxes go over it with the speakers named on them, not pictured, because
their faces are the picture.

```text
0.00 shot street_wide
2.00 line A1.ROAD 1-6 shot=road_two_shot frames=0,1,0,1,2
14.0 shot off
```

- **`<t> shot <sprite> [<frame>]` puts one up**, on that frame (0 without
  one), and **`<t> shot off` takes it down.** It stays up until then, or
  until another shot, or the end of the cut; `say`, `think`, `narrate` and
  `line` cues between are said over it.
- **A `line` cue can name its own: `shot=<sprite>`**, put up with its first
  line, **and `frames=<f>,<f>,...`**, the shot's frame for each of the lines
  it says in turn: the first frame with the first line, the second with the
  second, and the last given for every line after (`shot_frame_for`). Who is
  talking, who is listening: the two-shot's frames. `frames=` without
  `shot=` changes the frames of the shot already up. The shot stays up after
  the lines, until a `shot off`, as a `shot` cue's does.
- **The timing does not change.** Each line still gets `line_secs`, and
  Enter still jumps to the next: everything between is done as staging,
  shots and frames included, so the line Enter jumps to goes up in its own
  frame. Escape and the end take the shot down.
- **A shot that was never drawn is no shot**: the lines play over the room,
  so a cut can be timed before its picture is painted. The sprite is found
  by name in the assets (a `.sprite` of that name), and drawn centred at the
  top of the canvas, as a conversation's close-up is.
- `cutscene_shot(w)` says which is up and on which frame. **In the harness**
  a shot prints as `[shot <sprite>]` when it goes up and `[shot off]` when it
  comes down (not on each change of frame).

### In the middle of play

```odin
ne.play_cutscene(w, "the_cow")
ne.play_cutscene(w, "the_fence", then = proc(w: ^ne.World) {
    ne.play_node(w, "A2.GT.KEY")
})
```

`.cut` files load with everything else (`assets_load_folder`), by file name
wherever they sit: `cutscenes/the_cow.cut` is `"the_cow"`, and that is the
name it goes by from then on (the `cut` line's own name is the editor's).
`play_cutscene` plays one **in the room the player is in now** — `scene=` is
the room the editor shows, not a move. To play the second half of a scene in
another room, go there in `then` and play the next one.

- **Who is who.** A cast member named like a person standing in the room — a
  shown object with `char=`, by its name, or failing that by the `.char` it
  wears — *is* that person, and the cut moves them. One named like the
  protagonist is the player: `World.player_name` if the game set it, or a
  cast name or `char=` that is the `.char` she wears (`cast ada`). Anybody
  else is an **extra**, brought on for the cutscene and wearing its `char=`
  (or the `.char` of an object by that name not in the room just now).
- **Where they start.** `at=` and `facing=` place them. Written without
  `at=`, a person in the room or the player starts where she stands; without
  `facing=`, facing her own way — which is how a cutscene that plays wherever
  she happens to be is written. An extra without `at=` is brought on: it
  waits just off the side of the room nearer where it first walks to (or the
  middle of the floor, if it never walks), `CUT_OFFSTAGE` past the edge at
  that height, and walks in on its first `walk_to` (`offstage_start`). The
  cutscene editor draws it there, with a tag on the room's edge.
- **While it plays nobody is at the controls.** No typing, no walking, no
  clicks; a command run anyway (autoplay, game code) is ignored. The story
  clock does not move, no beat plays and no announcement opens. People not in
  the cast stand still, as they do for a conversation. Real time runs on (a
  timer still fires), and so do the boxes.
- **An announcement opened first holds it.** A cut that takes her to a body
  opens the body's announcement itself, `announce_now(w, name)`, just before
  `play_cutscene`: the cutscene's clock waits under the box until she presses
  on, so the body comes before anybody speaks about it (the harness prints
  the `[announcement]` first). None opens by itself while one plays.
- **Lines are boxes, as a conversation's are,** but on the cutscene's clock,
  not waiting for Enter: `say` and `think` by the World's speaker of that
  name (`speaker_named`, so `cook` finds "the cook" and the portrait comes
  with it), named on the box when there is no face ("the cook: Only me."), and
  by the cast name when there is no speaker at all. `narrate` is a plain box,
  and `line` a node's lines by their own speakers (above). `sound` plays the
  game's sound of that name; `camera shake` shakes.
- **Enter goes on to the next line** (so do Space and a click, as in a
  conversation), for a reader who reads faster than the cut's clock. The
  clock jumps to the next thing said — a `say`, `think` or `narrate`, a
  `line` cue that names a line that exists, or the next line of a `line`
  range — and everything between is done as Escape does it: walks walked as
  far as they would have got by then (and still walking, if they would be),
  turns turned, parts played, sounds and shakes left out. So the staging is
  exactly where it would be had she waited. On the last line before the end,
  Enter goes to the end. It is not read for `CUT_ADVANCE_GRACE` (0.15 s)
  after a line goes up, so a held key does not race through.
  `advance_cutscene(w)` is Enter.
- **Escape skips to the end.** The rest is played out at once and in silence —
  every walk walked, every turn turned, nothing more said — so a skipped
  cutscene ends exactly where a watched one does. Then `then`.
- **When it ends** the player stays where it put her, facing where it turned
  her, at her own speed again. **The room's people go back to what their own
  lines say** — where they stood and what they were doing before it — because
  the state of the world is its flags, not the last cutscene: a cutscene that
  should leave somebody somewhere else sets a flag in `then`, and the scene
  file's `when=` puts them there. The extras go.
- **`then` runs once**, after everything is put back, so it can start a
  conversation, a node, or the next cutscene.
- **A name with no cutscene behind it plays nothing and runs `then` at once**
  (and `play_cutscene` returns false), so a game never hangs on a cutscene
  nobody has made yet. Starting one while another plays finishes the first
  (skipped, with its `then`). A restore or a new game drops one half played,
  without its `then`.

`start_cutscene(w, &cut, then)` is the same for a `Cutscene` the game has in
hand; `cutting(w)` is true while one plays; `advance_cutscene(w)` is Enter
and `skip_cutscene(w)` is Escape.

**In the harness** a cutscene plays out at once, as the frames would end it,
and prints like a conversation:

```text
> open the gate
  [cutscene the_fence]
  Moore: Signed for. Six.
  The dog comes round the corner of the store.
  [no line A2.GT.FENCE 9]
  [end the_fence]
```

A `line` cue's lines print as `say` lines do, by their speakers' names, in the
order of their times.

`!cuts` lists every one loaded — length, room, cast, cues and lines — and
`!cut <name>` plays one where she is standing, as the game would.

## Asset files

Scenes, sprites and songs can be written in code, as above, or kept in plain
text files and loaded. Files are the better way round, and what a game
should do — draw nothing at startup, load an assets folder. The files are
the same thing three different tools can edit: the editors in
[../tools/](../tools/), the editors' command lines, and you, in any text
editor. They diff well, so
changing a lamp's position shows up in git as the one line that changed.

```text
# room.scene
scene parlour
desc A small parlour. There's a hole in the floor.
bg parlour
drift smoke speed=6 y=20
walk 24,122 318,122 318,186 4,186
ambience house_music
obj lamp pos=232,158 sprite=lamp fps=6 walk_to=214,162 loop=lamp_hum tick=crackle ticks=5,7 block=circle:10 reach=circle:48
text lamp A standing lamp. It flickers.
scenery window Night outside. A thin moon.
exit door area=256,122,30,4 to=hall arrive=160,142 closed=true
shut door The door is closed.
trigger road area=0,157,320,43 action=run_over
edge pond action=drown 0,190 320,190 320,200 0,200
window back glass=40,60,60,50 feet=150 frame=window_frame when=night
```

**An edge is where the floor stops and something can still be stepped into**
(edge.odin): water off a jetty, a drop. Its points are a polygon off the
floor, beside it. Pathfinding never crosses it; only the arrow keys walking
off the floor into it, a click on it (to the brink, and over), or the game's
`walk_off_edge(w, "pond")` do, and then its bound `on_step` runs: a warning,
a death. Unbound, or its `when=` false, it is the end of the floor. In the
harness, `!click x,y` and `!arrow <dir>` walk as the mouse and the keys do.

Every name on the right of an `=` — the sprite, the loop, the tick, the
background, the ambience — is a file in the asset folder, minus its
extension. `ticks=5,7` says which animation frames the tick sound lands on.

**An exit goes to a room by name.** `to=hall`, not `to=1`: a number makes the
order a game loads its rooms in load-bearing, and inserting a room quietly
re-points every exit after it. `load_scenes` joins names up once every room is
in and fails, saying which exit, on a name nobody loaded. (A number still
works. This loader used to *claim* to resolve names and did not, so `to=hall`
parsed as 0 and dropped the player in the first room without a word.)

**A room may have a folder of its own**: `scenes/hall/hall.scene`, with its
backdrop in every light and the sprites only it uses beside it. `load_scenes`
looks there first, then for a loose `scenes/hall.scene`. The asset loader reads
folders inside folders and knows every file by its own name, so where a
sprite sits is only for the reader.

**An object's name is one word**, and it is what the parser matches. Give
objects short names — `chest`, not `vet_chest` — and let the vocabulary carry
the phrases people type: `{.Noun, "chest", "vet chest, drugs, vials"}`.

```text
# lamp.sprite — a palette, then one block of characters per frame
sprite lamp
size 12 20
frames 1
mode bega
ramp brass 000000 AA5500 FFFF55
pal . 0,0,0,0
pal * 250,220,130,255
frame 0
..********..
.**********.
```

```text
# potato.char — one person: every pose, sharing one palette
character potato
size 16 28
mode bega
pal # 28,26,32,255
part front frames=1
frame 0
.....#######....
part walk_left frames=4 fps=8 step=13
frame 0
...
```

`step=` on a walk is how far one stride carries the body, in art pixels (a
walk's frames cover two strides a cycle). With it, an actor plays the walk as
fast as it is moving, `speed / (2 * step * scale) * frames` frames a second, so
a planted foot stays planted at any speed (`walk_rate`, actor.odin). Without it
the walk plays at its `fps`, or the actor's `walk_fps`, and the feet slide when
the speed and the stride disagree.

### Palette modes

`mode` says which colours the picture is allowed. It constrains **authoring**,
not rendering: the file still stores plain RGBA, the game still draws it
without knowing, and nothing about it costs a frame. What it does is stop a
picture quietly acquiring a colour the rest of the game cannot use.

| | |
| --- | --- |
| `bega` | the sixteen an EGA card came up in, and nothing else |
| `fega` | any of the sixty-four an EGA card can be made to produce |
| `vga` | six bits a channel, which is what a VGA DAC takes |

A file with no `mode` line is `vga`, so everything written before modes existed
keeps working. **Nothing is ever refused at load.** If a file says a pixel is
some off-grid brown then that is what the game draws — the file is the truth,
and a loader that threw the picture away instead would lose work over a rule
about authoring. The tools report and offer to snap; `nart mode <file>` says
what would change before anything does.

EGA's DAC is two bits a channel laid out `rgbRGB` — high bit `0xAA`, low bit
`0x55`, both `0xFF` — which is why brown is index 20 and not 6.

A picture may hold no more colours than there are characters to name palette
slots with, 83 of them. That is why `vga` stops well short of 256: a `.sprite`
is a readable block of text before it is anything else.

### Ramps

`ramp <name> <hex>...` names the tones a surface goes through, darkest first.
It is authoring data — the game never reads it, and what it loads is the pixels
the ramp helped somebody choose. It lives in the file anyway, because coming
back in six months and knowing which four colours were meant to be the same
canvas in different light is the difference between carrying on and starting
again.

A light level picks a place along a ramp; where it falls between two steps, the
two are dithered and the eye reads the tone in between. `ne.ramp_at` clamps
light at 1.0 — above that every tone lands on the top step and form does not
dim, it disappears.

Colours are hex because a ramp has to survive the palette being renumbered,
which happens every time a character is saved.

A character is drawn more ways than a lamp is, so its poses live together in
one file: `front`, `back`, `left` and `right` standing, a `walk_` for each of
them, `talk`, and `face` for close-ups. `Actor.character` picks the pose from
the direction walked — no mirroring, because a character drawn from the left
isn't the same as one flipped. A pose nobody has drawn yet falls back to
`Actor.idle`/`walk`, so a half-finished character still plays.

**Those ten are the ones the engine picks by itself. A character may have as
many more as it likes** — sitting, kneeling, at a tripod, dead, holding a
rifle. An extra pose is a `part` like any other and the only difference is
that nothing chooses it for you:

```text
part sit_chair frames=2 fps=1.5
part hurt_walk frames=4 fps=7.5
part face size=44,52 frames=4 fps=7    # a pose can be its own size, too
```

```text
step moore play chair 4        # a routine, nengine/routine.odin: four seconds of it
step moore play wave once      # once through, and the step waits for it
2.60 moore play chair 3        # a cutscene cue
```

```odin
actor.pose = "sit_chair"   // game code; "" hands it back to the direction walked
```

An extra pose is never mirrored either. One that is used facing more than one way can be drawn
once for each: `sack_right` beside `sack` is what an actor in the pose `sack` shows while facing
right, and `play kick` on somebody facing left plays `kick_left` when there is one. Without such a
part, the pose itself shows whichever way they face.

A walking pose held by somebody standing still (`pose=lamp_walk` on a person at a gap) stands on
its first passing frame, a quarter of the way round, legs together; it walks only while they move.
A part is a walk when it has a `step=`. Somebody who walks on through a side (`enters=`) turns, once there, to the
`facing=` of their line, the way they turn to its `pose=`.

The editor lists the ten first and the extras under them, and makes them with
A (new), D (a copy of the pose you are looking at, which is how most of them
are actually drawn), R (rename) and Delete. The ten cannot be renamed or
removed, because something is looking them up by name. `nart character part
add|copy|rename|remove` does the same from the command line, and `character
info` marks which are extras.

```text
# step.sound — one noise, as a few layers stacked on each other
sound step
length 0.09
norm 0.45
lowpass 0.3
layer sine from=90 to=54 decay=50 vol=0.7
layer noise decay=150 vol=0.3
```

A layer is a shape (`sine` `square` `saw` `noise` `bell`), a pitch that may
slide, wobble or bend, a volume that may fade in, decay, pulse or hump, and a
filter. That is enough for footsteps, hinges, taps, engines and cats. The
noise is deterministic, so the same file always renders the same sound.

The whole sound can also say:

| Line | What it does |
| --- | --- |
| `rate 44100` | Render at this rate. The default, 22050, is what every `.sound` so far was designed at; at 44100 a hiss gains an octave of air above 11 kHz it never had (and, peak-normalised, comes out up to 3 LU quieter), so it is a choice. `lp`, `hp` and `lowpass` mean the same cutoff at any rate. |
| `reverb 0.6 0.4 0.3` | A room: size, damping, mix, and optionally pre-delay (seconds) and width. Dry unless it says. A loop's room rings on round into its start. |
| `level -20` | Master to this loudness (LUFS) instead of to `norm`'s peak, under a -1 dBFS limiter. Not the default, because a sound's level against the others is part of its design: a footstep is not as loud as a rifle. |

```text
# house.song — notes on a time line, 24 ticks to a quarter note
song house
tempo 84
time 4/4
key 0                  # sharps (+) or flats (-): 2 is D major
bars 4
loop yes               # a game bed wraps round; a piece of music ends
track bass inst=saw vol=0.3
note 0 96 A2
note 96 96 F2
note 192 36 G2 vel=80  # a dotted quarter, struck softly
```

A song renders to **44.1 kHz stereo**, and the mix is finished the way a
record is (`nengine/master.odin`): every track is placed by its `pan`, sent
to a room, and the whole is brought to a loudness and kept under a ceiling.
Each line below is optional; a song that says none of them gets the defaults.

| Line | What it does |
| --- | --- |
| `level -16` | The loudness to master to, in LUFS (BS.1770: K-weighted, gated — what a loudness meter reads). Default -16. Two cues written at different volumes come out equally loud, and one loud downbeat no longer sets the level of a minute. `level none` leaves the loudness alone and only limits. |
| `ceiling -1` | Nothing louder than this, in dBFS (default -1). A look-ahead limiter turns down smoothly in front of a peak, including the peaks a converter draws *between* samples, so nothing clips. |
| `reverb 0.5 0.5 0.25` | The room: size and damping (0..1), mix (0.25 is a room you notice, 1 is as loud as the instruments), then optionally pre-delay in seconds and width (0 mono .. 1 wide). A small Freeverb. The default is this one, a modest room like the one the MT-32 always had on; `reverb none` takes it away. A loop's room rings round into its start, so the seam is not dry; a piece is given the room's whole tail and ends on silence. |
| `tempo 60 at=1536 glide=96` | From tick 1536 the song runs at 60; with `glide` it gets there over that many ticks, so an ending can broaden. The first `tempo` line (no `at=`) is the starting tempo. |
| `level -19 short` | Level by the loudest 3 s (EBU short-term loudness, at its highest) instead of the whole cue. For a sparse cue (a night bed half rest, a sting) whose integrated loudness is set unpredictably by its few events: the loudest moment lands where you said. Without `short`, integrated, as before. |
| `reverb2 plate` | A second room, heard only by tracks that send to it with `rev2=`: a plate on the strings and the celesta while the piano stays in the dry room, a gramophone's own small room inside the score's big one. `plate` (short, dense, bright, no pre-delay), `hall` (long, late, dark) or `room` (the first room's kind); then optionally size, damping, mix, pre-delay and width as for `reverb`. Off unless said. |

On a `track` line:

| Field | What it does |
| --- | --- |
| `pan=-0.3` | -1 left .. 1 right, constant power. An instrument's own `pan` is added. |
| `rev=0.4` | How much of the track goes to the room (default 1, all of it). The room's send is high-passed, so a bass in the room is not mud. |
| `legato=1` | One line, slurred: a note that starts before (or as) the last ends glides into it without starting again — no new attack, no gap. A chord, or the same pitch again, is still struck. A plucked string (`wave string`) always re-plucks; to slide or hammer on without a new pluck, give one note a `slide_from=` or `bend=` (below). |
| `glide=0.06` | On a legato track, the slide between slurred notes, in seconds (portamento). |
| `mono=1` | One voice, as an AdLib channel is: a new note stops the one before (in 4 ms, so not with a click), held or struck, and a loop's last note is stopped by its first coming round. Notes on one tick still sound together. So a count of voices is exact, and a line of bells cannot ring over itself. |
| `rev2=0.5` | How much goes to the second room (`reverb2`). Default 0. |
| `damp=0.3` | Every note's damper on this track, unless the note says its own (see the instrument's `damp`); `damp=off` lets them ring. One instrument, two tracks: pedal down and pedal up. |
| `lp=3500` `hp=300` | The whole track through a two-pole low-pass and high-pass, in Hz, after its notes. With an `eq` or two, a gramophone horn or a 78 is one track's settings, not a copy of every instrument. |

Under a track line, as `vol` lines are:

| Line | What it does |
| --- | --- |
| `eq 1500 6 1.2` | A peak on the whole track: Hz, gain in dB (negative is a notch), Q (default 1; higher is narrower). As many as you like: a guitar body, a horn's honk, the two formants of a wordless "aah". |
| `echo 3/16 0.35 0.3` | A tape echo: the time in milliseconds (`echo 375 ...`) or as a fraction of a whole note at the opening tempo (`3/16` is a dotted eighth), then feedback (each repeat this much of the last, default 0.3) and mix (the first repeat's level, default 0.3). Each repeat comes back a little darker and thinner, with a slow wow, as tape does. Before the track's `lp`, `hp` and `eq`, which shape the echoes too. A loop's echoes ring round into its start. |

Inside a track: `vol <tick> <level>` lines are volume points, times the
track's `vol`, with a straight line between them (a crescendo over four bars
is `vol 0 0.5` then `vol 384 1`). On a note, `vel_end=110` moves the
velocity there across the note: a swell inside one held note.

And on a note, all optional:

| Field | What it does |
| --- | --- |
| `slide_from=-2@6` | Starts 2 semitones off and slides to its pitch over 6 ticks: a guitar sliding into a note, a pennywhistle's scoop, a hyena's whoop. |
| `bend=1@4 bend_at=24` | From 24 ticks into the note, moves a semitone over 4 ticks, and stays: a hammer-on, a pull-off (negative), a fall-off, a slide whistle. A plucked string (`wave string`) keeps ringing while its pitch moves, which it does not do across two notes. With both, a note can scoop in and fall away. |
| `nudge=-8` | Plays 8 ms early (or late, positive): a groove that lays back, finer than a tick. |
| `damp=0.4` | This note's damper, in seconds (`damp=off`: none, it rings), over its track's and its instrument's. |

Notes a little apart get a little air only where it is needed: before the
same pitch again, so two quarter notes do not play as one half note. A line
into a different note keeps its full length.

**A loop is exactly its bars long.** A note whose tail runs past the end
rings on into the start, which is what makes a bed join up. A note that
*starts* after the end is wrapped round to the start too, and
`nsound song render` says so: it never quietly makes the song a bar longer
(a piece with `loop no` does still grow to hold its notes).

Every voice has a seed of its own, from its track and its place in it: where
in its cycle it starts (so a bass, a drum and a harp on one downbeat do not
all start in phase and add up to one spike), its noise and its pluck. Two
notes are never the same noise, and one file always renders the same samples.

**Time is in ticks from the start of the song, not in rows of a grid.** A bar
is a way of *looking* at the time line, so changing 4/4 to 3/4 re-flows the
bars without moving a single note, and a triplet or a dotted quarter is just a
length like any other. That one decision is what lets the same song be edited
two ways — a tracker grid and a sheet of music — and lets a MIDI file import
into it. Both editors are in [tools/](tools/README.md).

The older grid format (`bpm`, `steps`, and rows of `A2 - - - .` cells) is
still read, and turns into notes on the way in: a run of `-` after a note was
always that note being held, so it becomes the note's length. Songs are
written out in the form above.

The second word on a `track` line names an **instrument**, and instruments are
files:

```text
# nengine/instruments/strings.inst
instrument violin
name "Violin"
family strings
range G3 G7          # sounding, low to high — the editor shades the rest
wave saw             # pulse <duty> | triangle | saw | sine | noise | string
layer none           # a second oscillator: <wave> <mix 0..1> <semitones up>
envelope 0.03 0.1 0.85 0.08   # attack decay sustain release; sustain 0 = plucked
vibrato 5.8 0.14 0.18         # rate Hz, depth semitones, delay seconds
sweep 0 0            # starts this many semitones off and glides home
breath 0.02          # white noise mixed in
tone 0.55            # low-pass: 1 is open, lower is darker
gain 0.55
color 236 112 84     # its colour in the music editor
end
```

And, all optional, what the synth upgrade added:

| Line | What it does |
| --- | --- |
| `wave triangle` | A clean triangle now: a soft flute, a round bass. `nes_triangle` is the NES's 16-step staircase it used to be. |
| `wave white` | White noise whatever the pitch: cymbals, shakers. (`noise` is the NES shift register, clocked from the pitch, as before.) |
| `layer3 sine 0.1 24` | A third oscillator, like `layer`. |
| `layer_envelope 0.001 0.6 0 0.2` | The second oscillator's own envelope (attack decay sustain release), so a celesta's bright overtone dies before its fundamental. `layer3_envelope` likewise; without one a layer follows the main envelope. |
| `filter 1200 0.3` | A two-pole state-variable low-pass at 1200 Hz, resonance 0..1. Without it `tone` is the one-pole filter it always was. |
| `keytrack 0.5` | The cutoff follows the pitch (1 fully, from C4), so high notes are not duller than low ones. |
| `filter_env 0.05 0.4 1.5` | The cutoff opens by 1.5 octaves over 0.05 s and falls back over 0.4 s: a horn's blare, a swell opening. |
| `vel_tone 1` | Velocity moves the cutoff: one octave per 100 of velocity, so a harder note is brighter, not just louder. Velocity 100 is unchanged. |
| `highpass 3000` | Takes the bottom off (two-pole), for cymbals and shakers. |
| `click 0.3 0.02 0.5` | A burst of noise as the note starts — level, decay in seconds, tone — for a bow's scrape, a reed's chiff, a mallet's knock. |
| `string 0.5 0.6` | For `wave string`: damping (0.5 is the classic; higher dies faster in the highs) and brightness of the pluck. |

And from the second round:

| Line | What it does |
| --- | --- |
| `damp 0.3` | A struck note's damper: once its written length is over, it is gone (60 dB down) in 0.3 s — a piano's damper, a vibraphone's pedal coming up, a mallet laid on the bar. Without it (the default) a struck note rings its whole decay, whatever its length. Either way it now falls on until it is inaudible (-90 dB) instead of stopping dead 40 dB down when its decay is up, which was a click. A track's or a note's `damp=` wins over this. Sustained instruments have `release` instead. |
| `tremolo 5.5 4 0.3` | The level dips 4 dB and back 5.5 times a second (rate in Hz, depth in dB, then optionally a delay in seconds before it comes in, over a quarter of a second). On the song's clock, not the note's and not the tempo's: every note of the instrument shares one motor, which keeps its speed through an accelerando, and in a loop it is nudged to whole cycles so the seam does not jump. A vibraphone's motor, the OPL's AM, a valve amp's tremolo. |
| `wave fm 3.5 2` | A two-operator FM pair, as an AdLib's OPL2 has: a carrier at the note, phase-modulated by a modulator at 3.5 times it (any ratio; a non-whole one is a bell or a gong) with a peak index of 2 radians (0 is a sine; 0-12 is useful). Without `fm_envelope` the index follows the main envelope, so it is brighter as it is louder, as brass is. The index is held under what would alias (the spectrum reaching 18 kHz by Carson's rule), which is also what the OPL's key scaling did by ear. Layers, the filter, click, pan and the room apply as to any wave. |
| `fm_envelope 0.001 0.14 0 0.1` | The index's own envelope (attack decay sustain release), times the index: a bass's thwonk, a piano's tine, a bell that thins as it rings. |
| `fm_feedback 0.4` | The modulator feeding back into itself, 0..1 (the OPL's FB 0-7): 0.5 is saw-like, 1 nearly noise. Its strings and its snares. |
| `fm_wave half abs` | The OPL2's waves for the modulator and (optionally) the carrier: `sine`, `half` (the top half only), `abs` (both halves up), `quarter` (the rising quarters). The hollow organs and buzzy harpsichords. A carrier's offset is taken out. |
| `fm_keyscale 0.5` | The index falls with pitch above C4 (1 is an octave's worth per octave), so high notes are not shrill. |
| `vel_index 0.7` | Velocity scales the index (at 1, velocity 50 halves it and 127 adds a quarter), as `vel_tone` does the cutoff. |
| `drive 0.25` | A soft saturation before the filter, 0..1: a small valve amp starting to break up, harder for a harder note, a little lopsided as a valve is. As loud as it was for a quiet note; only the peaks round off. 0.1-0.3 is a 1962 electric guitar; 1 is fuzz. |

A violin and a trumpet can both be a sawtooth and still not sound alike,
because an instrument is everything *around* the oscillator. Forty of them
ship in `nengine/instruments/`, including the eleven voices that used to be
hardcoded — `sine` `square` `saw` `bell` `noise` `piano` `organ` `strings`
`flute` `pluck` `marimba` — so every song written before still plays.

`based_on` starts from another instrument, from any file, in any order. A
block whose key already exists changes **only the lines it gives**, so a game
drops one file in `assets/instruments/` and darkens the violin without
copying the rest of the orchestra:

```text
instrument violin
gain 0.4
end
```

A `.song` can carry the same blocks itself, so a tune that needs one
particular sound travels with it; saving flattens `based_on` into the full
definition, so the song keeps that sound even if the orchestra changes
underneath it. `F5` in the music editor re-reads every instrument file
without losing the song you are editing.

The oscillators are band-limited (PolyBLEP): a naive square or saw high up
folds its harmonics back down as a whistle that slides the wrong way when the
tune goes up. `string` is the odd one out — a real Karplus-Strong plucked
string rather than an oscillator, and it is worth it. Its loop is tuned to a
fraction of a sample by an all-pass filter (within 3 cents from C2 to C7; a
whole number of samples was 30 cents flat by A5), and it is plucked from the
shape a real string starts from (a triangle, with a little noise for the
nail), darker for a softer note, at a set energy, so a note does not open on a
spike louder than itself.

### MIDI

A `.mid` imports straight into a song — drop one on the music editor, or

```sh
just sound song import tune.mid assets/music/tune.song
```

Ticks are rescaled from the file's own resolution to ours and snapped to
whichever is nearer of the 32nd grid and the triplet grid, so both survive: a
triplet comes in as three notes of 8 ticks, not three of 6 and a limp. One
track per MIDI track and channel, its instrument picked from the General MIDI
program number; channel 10 becomes drum tracks. A note outside its
instrument's range is moved by octaves until it fits, and the import says how
many it had to move.

The import takes the file's first tempo; a piece that slows down needs its
`tempo ... at=` lines added by hand.

## Sources and what the game loads

Two kinds of file, and the difference matters:

| | Sources — your work | Derived — always rewritten |
| --- | --- | --- |
| Art | `.sprite`, `.char`, `.scene` | `.png` from a backdrop `.sprite` |
| Sound | `.sound`, `.song` | `.wav` from either |

**The game loads no source file for audio.** `ambience house_music` finds
`house_music.wav`; the `.song` beside it is what you edit. Rendering sound at
startup is a cost the player pays for nothing, and a `.wav` is also where a
real recording goes the day you have one.

Backdrops go the other way round: a `.scene` will take either, preferring the
`.png` and falling back to the `.sprite`, so a backdrop you have only just
painted shows up without baking first.

| Call | What it does |
| --- | --- |
| `assets_load_folder(&a, dir, scale)` | Every asset in a folder and the folders inside it, by name: `.sprite`, `.png`, `.wav`, `.char`, `.cut` |
| `load_scene(path, &assets)` | A `Scene`, with its sprites and sounds looked up by name |
| `save_scene(&scene, path)` | Writes one back out |
| `scene_bind_trigger(&scene, "run_over", proc)` | Joins a file's `action=` to real code |
| `scene_bind_edge(&scene, "drown", proc(w, e, dir))` | The same for an `edge`; `walk_off_edge`, `click_walk`, `draw_actor_above` go with it |
| `assets_sprite` / `assets_sound` / `assets_loop` | One of them, by name |
| `assets_char_part(&a, "potato", "walk_left")` | One pose of a character |
| `load_character` / `save_character` | A `.char`: every pose one person has |
| `sprite_data_from_image` | The other way: a drawn image becomes a `.sprite` |
| `load_song` / `render_song` | A `.song`, and the samples to play it |
| `load_sound` / `render_sound` | A `.sound`, and the samples to play it |
| `sprite_data_resize` | Change a grid's size, keeping what fits |

A scene file is data only. It says *that* a trigger is called `run_over`; the
procedure that runs you over stays in game code, and `scene_bind_trigger`
joins the two up. Strings in a loaded scene are owned by it — `clear_world`
frees them, which is what `Scene.from_file` marks.

Sprites are stored at the size they were drawn, and kept that size on the GPU
too: one texel per painted pixel, scaled up only as they are drawn, with hard
edges. The scale needn't be a whole number: art authored 320 wide loads at
3.2 onto a 1024 canvas, and each art pixel x lands on canvas columns
round(3.2x) up to round(3.2(x+1)) — three of them or four, tiling exactly with
its neighbours, and the same rows. That is the picture the engine used to blow
up on the CPU before uploading it, pixel for pixel, at a tenth of the memory
(over a thousand sprites at 3.2 were hundreds of megabytes of texture). So the
files stay small and hand-editable however big the canvas gets, and so does
the game.

A `Sprite`'s `frame_w` and `frame_h` are its size on the canvas, which is what
everything positions by; `w`, `h` and `scale` are the painting and how much it
is blown up. Draw one with `draw_sprite` (feet at a point), `draw_sprite_at`
(top-left corner) or `draw_sprite_pro` (into any rectangle, turned, flipped,
tinted), never with raylib straight from `.texture`, which is the small
painting. `sprite_data_to_image(&d, scale)` is the blow-up on the CPU, for
writing a `.png` at the size the game draws it.

**A room's still things are drawn on the backdrop's own grid**
(`draw_sprite_on_grid`). `draw_sprite` blows a sprite up from its own corner,
so at 3.2 a picture cut from a backdrop and laid back over it anywhere but
every fifth art pixel drew some columns a canvas pixel off its own paint: on a
fine pattern (mesh, ruled lines) a checker. Objects that do not walk are drawn
with their corner on the nearest art pixel and blown up on the backdrop's
grid, so an overlay lands exactly on the paint it was cut from. The corner
moves at most half an art pixel; the feet, and so the drawing order, do not.
Not for people: somebody walking moves a canvas pixel at a time.

## Files

| File | What's in it |
| --- | --- |
| `nengine.odin` | Window, the canvas and its upscale, the per-frame draw |
| `parser.odin` | Parsing: text in, `Command` out |
| `approach.odin` | Walking over to a thing before doing something to it: the ring, the point |
| `inventory.odin` | What can be carried, and what is: flags, so it saves |
| `timer.odin` | Something that happens in so many seconds of real time; a deadline is one the player is racing |
| `beat.odin` | What happens at an hour, in a room, once — heard if you are there |
| `talk.odin` | Topic files, ASK and SHOW, and a question the player answers |
| `overhear.odin` | A conversation through a wall: one place, one window, once |
| `ride.odin` | Seeing through a host's eyes: the loop, the camera, the palette map, the handover |
| `save.odin` | Saving and restoring: ten slots, and a rolling autosave |
| `flags.odin` | Story flags, and the conditions that read them |
| `score.odin` | Awards, the score, and how long it took |
| `routine.odin` | People who are doing something, and the steps they do it in |
| `vocab.odin` | The standard vocabulary, and joining a game's words to it |
| `prompt.odin` | The typing line, running commands, the message box |
| `world.odin` | World, walking input, exits, and which walks go through a door (`check_exits`) |
| `edge.odin` | Deadly edges: water off a jetty, a drop; going over by arrow, click or JUMP |
| `side.odin` | Sides: walking straight into the next screen, arrival at the matching point, gates, people and cutscenes across a side |
| `side_harness.odin` | `!sides` and `!cross` |
| `sight.odin` | In sight: the gone kept drawn until the screen is hers, walkers on arrived for a line, the called back, the called into sight, voices off; the ghost watch `!autoplay` keeps |
| `keep_out.odin` | Keep-outs: a room shut from every way in for a window on the clock, with a line; put out of it if she is there as it starts |
| `world_check.odin` | A world of sides checked as it stands now: `rooms_reached`, `side_faults`, `gate_faults`, `exit_faults`, `world_faults`, `landing_fault`, `exit_back` (for a game's own tests) |
| `scene.odin` | Scenes, objects, scenery, exits, draw order |
| `actor.odin` | Walking characters |
| `anim.odin` | Which frame a part shows, frame holds, and playing a part once |
| `peep.odin` | Apertures, their windows, being caught, the split close-up |
| `nodes.odin` | Dialogue nodes read from Markdown script files, played by id |
| `walk.odin` | Walk-area polygon maths |
| `sprite.odin` | Sprite sheets: kept as painted, blown up as drawn; still things on the backdrop's grid |
| `audio.odin` | Sound: loops, effects, volume by distance |
| `death.odin` | Deaths and the death box |
| `menu.odin` | The title screen: its parallax layers, its lettering, the dusk to night, the About page, the Load screen over it |
| `dissolve.odin` | The Sierra dissolve: one painting into another a pixel at a time, in a fixed ordered-then-shuffled order |
| `menubar.odin` | The SCI0 menu bar along the top: when it shows, its clicks and keys, `!bar` |
| `screens.odin` | The bar's screens: Save, Load, the inventory and the menu, `!screen` |
| `hint.odin` | The menu's HINT: a game's hint table, `first_hint`, the three grades, the status over them, `!hint` and `!status`; each answer tried in a forked copy (`hint_linux.odin`) |
| `textbox.odin` | Speech, thought and prompt boxes, styles and portraits |
| `look.odin` | The look: boxes or a comic; the comic's theme (Comic, Surface, Paper, COMIC_BEGA, COMIC_PARCHMENT, COMIC_PARCHMENT_LIT, set_look_lit), lettering, balloons, captions, typing panel and panels |
| `fonts/` | Tiny5, the comic's lettering, and its licence (OFL.txt) |
| `conversation.odin` | Stepping through a list of lines |
| `cutscene.odin` | `.cut` files, and playing one by itself or in the middle of play |
| `shape.odin` | Box and circle shapes on the floor: `block` and `reach` |
| `passer.odin` | Somebody going past a window: the dice, the wait, the walk, drawn through the glass |
| `debug.odin` | The F1 debug view |
| `clock.odin` | The story clock, and discovery costing time |
| `notebook.odin` | The notebook's filing: entries, order, dog-ears, the accusation |
| `launch.odin` | Command-line switches, the card and menu, the loop, starting over |
| `script.odin` | The `--script` harness and its `!` commands |
| `probe.odin` | The harness's pictures: `!crowd`, `!spots`, `!snap`, `!strip`, `!cutsnap`, contact sheets, for checking drawing order; `!people` |
| `playlog.odin` | `--log`: every command typed and every reply, as TSV, with how it was handled and where the replies ran out |
| `autoplay.odin` | `--play`: the game playing a script itself, in its window, for watching; `!autoplay`, the same in the harness, undrawn |
| `dev.odin` | `--dev`: TELEPORT and TIMETRAVEL |
| `commands.odin` | The mechanical half of LOOK, SAVE and RESTORE |
| `palette.odin` | Palette modes, the EGA gamut, ramps |
| `data.odin` | The shared text-file format: lines, words, `key=value` |
| `scene_file.odin` | `.scene` files |
| `asset_file.odin` | `.sprite` files and the asset table |
| `char_file.odin` | `.char` files: a character's poses |
| `song_file.odin` | `.song` files and the synth that renders them |
| `sound_file.odin` | `.sound` files: one noise, in layers |
| `*_test.odin` | Tests (`odin test nengine`). They run in parallel: state a test touches is per World or `thread_local`, and files go through `test_tmp()` (tmp_test.odin), in the run's own `$TMPDIR` |

## Not yet

- Dialogue trees.
- Music that changes with the mood.

## Licence

MIT. See [LICENSE](LICENSE). The Tiny5 font in `fonts/` is under the SIL Open Font License ([fonts/OFL.txt](fonts/OFL.txt)).
