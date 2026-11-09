package nengine

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

// The typing line at the bottom of the screen, and the message box at the top.
//   Enter    run the command (on an empty line: dismiss the message)
//   Esc      clear the line and the message
//   F3       retype the last command, as Sierra games always did

// Show a message. It stays up longer the longer it is.
say :: proc(w: ^World, text: string) {
	post(w, text, .Narration, nil)
}

// Somebody says it out loud, with their portrait beside the box.
say_as :: proc(w: ^World, who: ^Speaker, text: string) {
	post(w, text, .Speech, who)
}

// Somebody thinks it. Same box, different style, and nobody else hears.
think :: proc(w: ^World, who: ^Speaker, text: string) {
	post(w, text, .Thought, who)
}

// How long a box stays up for these words: a breath, and a reading speed.
// A cutscene's `line` cue gives each of a node's lines this long, too.
line_secs :: proc(text: string) -> f32 {
	return clamp(2 + f32(len(text)) / 15, 3, 12)
}

@(private)
post :: proc(w: ^World, text: string, mode: Message_Mode, who: ^Speaker) {
	// The play log has the whole of it, with who said it (playlog.odin).
	if who != nil && who.name != "" && !strings.has_prefix(text, fmt.tprintf("%v:", who.name)) {
		log_line(w, fmt.tprintf("%v%v: %v", who.name, " (thinks)" if mode == .Thought else "", text))
	} else {
		log_line(w, text)
	}
	w.message_len = copy(w.message_buf[:], plain_text(text))
	// A beat in it is a moment longer (textbox.odin's beats_as_breaks).
	w.message_until = w.time + line_secs(string(w.message_buf[:w.message_len])) + BEAT_SECS * f32(beats_in(text))
	w.message_mode = mode
	w.message_who = who
	w.message_speaker = who
}

Message_Mode :: enum {
	Narration, // the game talking to the player
	Speech,    // a character, out loud
	Thought,   // a character, to themselves
}

// Which style a box gets: the game's, or the built-in one.
@(private)
style_for :: proc(w: ^World, mode: Message_Mode) -> Box_Style {
	chosen: Maybe(Box_Style)
	switch mode {
	case .Narration: chosen = w.narration_style
	case .Speech:    chosen = w.speech_style
	case .Thought:   chosen = w.thought_style
	}
	if s, set := chosen.?; set do return s
	switch mode {
	case .Narration: return BOX_PLAIN
	case .Speech:    return BOX_SPEECH
	case .Thought:   return BOX_THOUGHT
	}
	return BOX_PLAIN
}

// The message currently showing, or "".
message :: proc(w: ^World) -> string {
	if w.time >= w.message_until do return ""
	return string(w.message_buf[:w.message_len])
}

// Parse a line and hand it to the game: the current scene's on_command gets
// first go, then the world's. Each one is a row of the play log, if one is
// being kept (playlog.odin).
run_command :: proc(w: ^World, line: string) {
	log_begin(w, line)
	command(w, line)
	// Set walking by it: the row is not over until she stops.
	if w.log.open && w.player.moving do w.log.walked = true
}

@(private = "file")
command :: proc(w: ^World, line: string) {
	// Nobody is at the controls while a cutscene plays. See cutscene.odin.
	if cutting(w) {
		log_route(w, "ignored:cutscene")
		return
	}
	w.ticked = false // a new command has spent no time yet
	// Typed over a gesture: the gesture finishes now, and what it was for
	// happens before the new command does, so nothing is lost or reordered.
	// Any other gesture (arriving up a ladder) simply ends; and a walk to an
	// exit's spot is called off like any walk the player changes her mind about.
	if w.after_anim.active {
		actor_stop_anim(&w.player)
		run_after_anim(w)
	}
	actor_stop_anim(&w.player)
	w.exit_walk = {}
	// TELEPORT and TIMETRAVEL, with --dev on (dev.odin). Off, they are words
	// the parser does not know, like any other.
	if dev_command(w, line) do return
	cmd, err, bad := parse(line, w.vocab, w.last_noun)
	switch err {
	case .Empty:
		w.message_until = 0
		log_discard(w)
		return
	case .Unknown_Word, .No_Antecedent:
		if err == .Unknown_Word {
			log_route(w, fmt.tprintf("parse:unknown %v", bad))
			log_gap(w, "unknown-word")
		} else {
			log_route(w, "parse:no-antecedent")
			log_gap(w, "no-antecedent")
		}
		// The game gets first refusal, because the reply to a sentence that
		// did not parse is a line of the protagonist's and not of the
		// engine's. What is below is what you get for not answering: correct,
		// clear, and in nobody's voice.
		if w.on_parse_error != nil && w.on_parse_error(w, err, bad) do return
		if err == .Unknown_Word {
			say(w, fmt.tprintf("I don't know the word \"%v\".", bad))
		} else {
			say(w, fmt.tprintf("\"%v\" what? Name the thing.", bad))
		}
		return
	case .None:
	}

	// So the next sentence can say "it".
	if cmd.noun != "" do w.last_noun = cmd.noun

	// Somebody has just asked the player something, and this is the answer —
	// whatever it is. The question is gone either way: a moment passes.
	if w.pending != "" {
		q := w.pending
		w.pending = ""
		if w.on_answer != nil && w.on_answer(w, q, cmd) {
			log_route(w, "answer")
			return
		}
	}

	// Riding, the only things to do are wait and leave. See ride.odin.
	if riding(w) {
		log_route(w, "ride")
		ride_command(w, cmd)
		return
	}

	// Doing something to a thing across the room means walking over to it
	// first; the command waits until the player gets there. See approach.odin.
	scene := current_scene(w)
	// Spoken to while walking off: they stop and turn to her (sight.odin).
	call_back(w, scene, cmd)
	if approach_command(w, scene, cmd) do return
	dispatch_command(w, scene, cmd)
}

// The object gets first refusal, then the scene, then the world. An object
// that carries its own verbs keeps them out of a switch, and the switch is
// left holding only what is genuinely scene-wide.
@(private)
dispatch_command :: proc(w: ^World, scene: ^Scene, cmd: Command) {
	if sight_watch.on do sight_check_command(w, scene, cmd) // a frames run's watch (sight.odin)
	if do_object_command(w, scene, cmd) do return
	if scene.on_command != nil && scene.on_command(w, cmd) {
		log_route(w, "scene")
		return
	}
	if w.on_command != nil {
		log_route(w, "game")
		w.on_command(w, cmd)
		return
	}
	log_route(w, "unanswered")
	log_gap(w, "unanswered")
}

// An object's own answer to a command, if it has one.
@(private = "file")
do_object_command :: proc(w: ^World, scene: ^Scene, cmd: Command) -> bool {
	if cmd.verb == "" || cmd.noun == "" do return false
	o := object_here(scene, cmd.noun)
	if o == nil {
		// PUT OFFAL ON BINS, with the offal in a pocket: the bins' business.
		// The command is turned round for them, so their `with=offal` matches.
		if cmd.noun2 == "" || cmd.prep == "about" do return false
		o = object_here(scene, cmd.noun2)
		if o == nil do return false
		turned := cmd
		turned.noun, turned.noun2 = cmd.noun2, cmd.noun
		turned.adj, turned.adj2 = cmd.adj2, cmd.adj
		return do_object_command(w, scene, turned)
	}

	// LISTEN AT, LOOK THROUGH or PEEP at an aperture. See peep.odin.
	if p := peep_command_here(w, scene, cmd); p != nil {
		log_route(w, fmt.tprintf("peep:%v", p.name))
		do_peep(w, p)
		return true
	}

	it := object_interaction(w, o, cmd)
	if it == nil {
		// Nothing written for this verb. LOOK still works, because an object
		// with a description has already said what it looks like.
		if cmd.verb == "look" && cmd.noun2 == "" {
			// Several things of one name (three bushes) share one `text` line,
			// which belongs to whichever it was written under: any of them says it.
			if text := description_of_name(scene, o); text != "" {
				log_route(w, fmt.tprintf("object:%v.look", o.name))
				say(w, text)
				return true
			}
		}
		return false
	}
	// A placeholder, with neither words nor a procedure, falls through rather
	// than swallowing the command in silence.
	if it.text == "" && it.on_do == nil do return false
	log_route(w, fmt.tprintf("object:%v.%v", o.name, cmd.verb))
	// TAKE CUP with `anim=pick_up`: the reach first, the cup at the end of it.
	// A part that is not drawn yet plays for no time, and the verb happens now.
	if it.anim != "" && actor_part_secs(&w.player, it.anim) > 0 {
		actor_play(&w.player, it.anim)
		w.after_anim = {active = true, cmd = cmd, object = o.name}
		return true
	}
	run_interaction(w, o, it, cmd)
	return true
}

// Says an interaction's words and runs its procedure. The procedure can read
// the command that brought it there in World.cmd: ASK ELENA ABOUT THE TELEPHONE
// lands on Elena's `talk_to`-style action with "telephone" in cmd.noun2.
@(private)
run_interaction :: proc(w: ^World, o: ^Object, it: ^Interaction, cmd: Command = {}) {
	if it.text != "" do say(w, it.text)
	if it.on_do != nil {
		w.cmd = cmd
		it.on_do(w, o)
	}
}

@(private)
update_prompt :: proc(w: ^World) {
	walking_keys := numpad_down()
	for c := rl.GetCharPressed(); c != 0; c = rl.GetCharPressed() {
		if walking_keys && c >= '0' && c <= '9' do continue // numpad with Num Lock on
		if c >= ' ' && c <= '~' && w.input_len < len(w.input) {
			w.input[w.input_len] = u8(c)
			w.input_len += 1
			play(w.key_sound, 0.5)
		}
	}
	if (rl.IsKeyPressed(.BACKSPACE) || rl.IsKeyPressedRepeat(.BACKSPACE)) && w.input_len > 0 {
		w.input_len -= 1
		play(w.key_sound, 0.3)
	}
	if rl.IsKeyPressed(.ESCAPE) {
		w.input_len = 0
		w.message_until = 0
	}
	if rl.IsKeyPressed(.F3) {
		w.input_len = copy(w.input[:], w.last_input[:w.last_len])
	}
	if rl.IsKeyPressed(.ENTER) {
		if w.input_len == 0 {
			w.message_until = 0
			return
		}
		w.last_len = copy(w.last_input[:], w.input[:w.input_len])
		w.input_len = 0
		run_command(w, string(w.last_input[:w.last_len]))
	}
}

@(private)
draw_ui :: proc(w: ^World) {
	if the_look == .Comic {
		if text := message(w); text != "" do draw_comic_message(w, text)
		draw_comic_prompt(w)
		return
	}
	if text := message(w); text != "" {
		draw_box(style_for(w, w.message_mode), text, w.message_who, w.time)
	}

	// The typing line. It borrows the prompt style's colours if there is one.
	bar := BOX_PLAIN
	if s, set := w.prompt_style.?; set do bar = s
	bar_h := ui(12)
	rl.DrawRectangle(0, HEIGHT - bar_h, WIDTH, bar_h, bar.fill)
	rl.DrawRectangle(0, HEIGHT - bar_h - ui(1), WIDTH, ui(1), bar.edge)
	if bar.flourish == .Side_Bar do rl.DrawRectangle(0, HEIGHT - bar_h, ui(2), bar_h, bar.accent)
	cursor := "_" if i32(w.time * 2) % 2 == 0 else ""
	line := fmt.ctprintf(">%v%v", string(w.input[:w.input_len]), cursor)
	rl.DrawText(line, ui(3), HEIGHT - bar_h + ui(1), ufont(bar.font), bar.ink)
}


// The words for LOOK at an object: its own, or, when it has none, those of
// another of the same name in the room that is there now.
@(private)
description_of_name :: proc(scene: ^Scene, o: ^Object) -> string {
	if o.description != "" do return o.description
	for &other in scene.objects {
		if other.name == o.name && !other.hidden && other.description != "" do return other.description
	}
	return ""
}
