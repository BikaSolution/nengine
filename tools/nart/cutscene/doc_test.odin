package cutscene

import ne "../../../"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// The cutscene editor's load and save, against every cutscene in the
// checkout, and its changes against the engine's own reading of what they
// wrote.

// The checkout: four folders up from this file (nengine/tools/nart/cutscene).
@(private = "file")
checkout :: proc() -> string {
	dir := #directory
	for _ in 0 ..< 4 do dir = dir[:strings.last_index_byte(strings.trim_right(dir, "/"), '/')]
	return dir
}

// The games beside the engine: every folder next to nengine/ with an assets/
// folder in it. The engine checked out on its own has none, and these tests
// then have nothing to read.
@(private = "file")
games :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	infos, err := os.read_directory_by_path(checkout(), -1, context.temp_allocator)
	if err != nil do return out[:]
	for f in infos {
		if f.type != .Directory || f.name == "nengine" do continue
		if os.is_dir(fmt.tprintf("%v/%v/assets", checkout(), f.name)) do append(&out, f.name)
	}
	return out[:]
}

@(private = "file")
cut_files :: proc(dir: string, out: ^[dynamic]string) {
	infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil do return
	for f in infos {
		path := fmt.tprintf("%v/%v", dir, f.name)
		if f.type == .Directory {
			cut_files(path, out)
		} else if strings.has_suffix(f.name, ".cut") {
			append(out, path)
		}
	}
}

// Every .cut in every game beside the engine, opened and saved by the editor with no change
// made, comes back byte for byte — the comments over each group, the groups
// written out of time order, the spacing — and the editor reads every line
// as the engine does: the same cast, and the same cues in the order they fire.
@(test)
every_cutscene_saves_back_exactly :: proc(t: ^testing.T) {
	files := make([dynamic]string, context.temp_allocator)
	for game in games() {
		cut_files(fmt.tprintf("%v/%v/assets", checkout(), game), &files)
	}
	if len(files) == 0 do return // no game beside the engine

	for path in files {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if !testing.expectf(t, err == nil, "could not read %v", path) do continue
		d: Cut_Doc
		testing.expectf(t, doc_load(&d, path), "%v did not load", path)
		back := doc_text(&d)
		testing.expectf(t, back == string(data), "%v: saved %v bytes for %v", path, len(back), len(data))

		c, ok := ne.parse_cutscene(string(data))
		testing.expectf(t, ok, "%v: the engine could not read it", path)
		testing.expectf(t, c.name == d.name && c.scene == d.scene, "%v: cut %v scene=%v, the engine has %v scene=%v", path, d.name, d.scene, c.name, c.scene)
		testing.expectf(t, len(c.people) == len(d.people), "%v: %v cast, the engine has %v", path, len(d.people), len(c.people))
		for m, i in c.people {
			if i >= len(d.people) do break
			e := d.people[i].m
			testing.expectf(t, m.name == e.name && m.character == e.character && m.at == e.at && m.keep_place == e.keep_place && m.keep_facing == e.keep_facing && m.facing == e.facing, "%v: cast %v differs", path, m.name)
		}
		testing.expectf(t, len(c.cues) == len(d.cues), "%v: %v cues, the engine has %v", path, len(d.cues), len(c.cues))
		for q, i in c.cues {
			if i >= len(d.order) do break
			e := d.cues[d.order[i]].q
			testing.expectf(t, ne.cue_text(q) == ne.cue_text(e), "%v: cue %v is %q, the engine has %q", path, i, ne.cue_text(e), ne.cue_text(q))
		}
		testing.expectf(t, ne.cutscene_length(&c) == doc_length(&d), "%v: %v seconds, the engine has %v", path, doc_length(&d), ne.cutscene_length(&c))
		testing.expectf(t, len(d.ignored) == 0, "%v: %v lines read as nothing", path, len(d.ignored))
		ne.cutscene_destroy(&c)
		doc_destroy(&d)
	}
}

@(private = "file")
CUT :: `# nengine cutscene
# The fence.
cut the_fence scene=main_gate

cast ada
cast moore  char=moore  at=470,500 facing=left

# The talk.
0.00 line A2.GT.FENCE 1-3
0.50 moore walk_to 300,480
4.00  moore say Signed for.
# Then the dog, a little before.
3.00 sound dog_bark
9.00 end
`

@(private = "file")
cut :: proc() -> (d: Cut_Doc) {
	doc_set_text_all(&d, CUT)
	return
}

@(private = "file")
engine_text :: proc(d: ^Cut_Doc) -> string {
	c, _ := ne.parse_cutscene(doc_text(d))
	defer ne.cutscene_destroy(&c)
	return strings.clone(ne.cutscene_text(&c), context.temp_allocator)
}

@(test)
lines_mean_what_the_engine_reads :: proc(t: ^testing.T) {
	d := cut()
	defer doc_destroy(&d)
	testing.expect_value(t, d.name, "the_fence")
	testing.expect_value(t, d.scene, "main_gate")
	testing.expect_value(t, len(d.people), 2)
	testing.expect(t, d.people[0].m.keep_place && d.people[0].m.keep_facing)
	testing.expect_value(t, d.people[1].m.character, "moore")
	testing.expect_value(t, len(d.cues), 5)
	// File order: the sound written after the say; firing order: before it.
	testing.expect_value(t, d.cues[3].q.action, ne.Cue_Action.Sound)
	testing.expect_value(t, d.order[2], 3)
	testing.expect_value(t, doc_length(&d), f32(9))
	notes := doc_notes_above(&d, d.cues[3].line)
	testing.expect_value(t, len(notes), 1)
}

@(test)
a_time_changes_only_the_time :: proc(t: ^testing.T) {
	d := cut()
	defer doc_destroy(&d)
	i := doc_set_cue_time(&d, 2, 4.5)
	testing.expect_value(t, d.lines[d.cues[i].line], "4.50  moore say Signed for.")
	// Everything else as it was.
	want, _ := strings.replace(CUT, "4.00  moore say", "4.50  moore say", 1, context.temp_allocator)
	testing.expect_value(t, doc_text(&d), want)
}

@(test)
a_cue_moved_in_time_keeps_to_its_group :: proc(t: ^testing.T) {
	d := cut()
	defer doc_destroy(&d)
	// The say dragged to before the walk: it moves above it, in its group,
	// and no further than the line at 0.00.
	i := doc_set_cue_time(&d, 2, 0.2)
	testing.expect_value(t, d.cues[i].line, 9)
	testing.expect(t, strings.has_prefix(d.lines[8], "0.00 line"))
	testing.expect(t, strings.has_prefix(d.lines[10], "0.50 moore walk_to"))
	doc_set_cue_time(&d, i, 4)
	// The say dragged past the end: it does not leave its group, which ends
	// at the comment.
	j := doc_set_cue_time(&d, doc_cue_at_line(&d, 10), 20)
	testing.expect_value(t, d.cues[j].line, 10)
	testing.expect(t, strings.contains(doc_text(&d), "# Then the dog, a little before.\n3.00 sound dog_bark"))
	// A cue dragged without being placed stays on its line.
	k := doc_set_cue_time(&d, doc_cue_at_line(&d, 13), 2, place = false)
	testing.expect_value(t, d.cues[k].line, 13)
}

@(test)
a_cast_field_changes_where_it_stands :: proc(t: ^testing.T) {
	d := cut()
	defer doc_destroy(&d)
	doc_set_cast_field(&d, 1, "at", "400,510")
	testing.expect_value(t, d.lines[d.people[1].line], "cast moore  char=moore  at=400,510 facing=left")
	doc_set_cast_field(&d, 1, "facing", "")
	testing.expect_value(t, d.lines[d.people[1].line], "cast moore  char=moore  at=400,510")
	testing.expect(t, d.people[1].m.keep_facing)
	doc_set_cast_field(&d, 0, "char", "ada")
	testing.expect_value(t, d.lines[d.people[0].line], "cast ada char=ada")
	doc_set_head(&d, "fence", "gate")
	testing.expect_value(t, d.lines[d.head], "cut fence scene=gate")
}

@(test)
renaming_somebody_renames_their_cues :: proc(t: ^testing.T) {
	d := cut()
	defer doc_destroy(&d)
	doc_rename_cast(&d, 1, "warden")
	testing.expect_value(t, d.people[1].m.name, "warden")
	testing.expect(t, strings.contains(doc_text(&d), "0.50 warden walk_to 300,480"))
	testing.expect(t, strings.contains(doc_text(&d), "4.00  warden say Signed for."))
	// Removing them takes their cues.
	gone := doc_remove_cast(&d, 1)
	testing.expect_value(t, gone, 2)
	testing.expect_value(t, len(d.cues), 3)
	testing.expect(t, strings.contains(doc_text(&d), "# Then the dog"))
}

@(test)
cues_and_cast_are_added_where_they_belong :: proc(t: ^testing.T) {
	d := cut()
	defer doc_destroy(&d)
	i := doc_add_cue(&d, ne.Cue{at = 1, who = "ada", action = .Face, facing = .Left})
	testing.expect_value(t, d.lines[d.cues[i].line], "1.00 ada face left")
	testing.expect_value(t, d.cues[i].line, 10) // after the walk at 0.50
	m := doc_add_cast(&d, "percy")
	testing.expect_value(t, d.lines[d.people[m].line], "cast percy")
	testing.expect_value(t, d.people[m].line, 6)
	// A cue made into another kind keeps its time as written.
	q := d.cues[doc_cue_at_line(&d, 12)].q
	testing.expect_value(t, q.action, ne.Cue_Action.Say)
	q.action = .Think
	doc_set_cue(&d, doc_cue_at_line(&d, 12), q)
	testing.expect_value(t, d.lines[12], "4.00  moore think Signed for.")
	// Two at one time fire in the order written; moved down, it fires second.
	j := doc_move_cue(&d, doc_cue_at_line(&d, 9), false)
	testing.expect_value(t, d.cues[j].line, 10)
	// And the engine reads the whole file as it reads its own writing.
	testing.expect(t, strings.contains(engine_text(&d), "cast percy"))
}

@(test)
a_new_cutscene_gets_its_lines_in_order :: proc(t: ^testing.T) {
	d: Cut_Doc
	defer doc_destroy(&d)
	doc_set_text_all(&d, "# nengine cutscene\ncut x\n\n4.00 end\n")
	doc_add_cast(&d, "ada")
	doc_add_cue(&d, ne.Cue{at = 0, who = "ada", action = .Walk_To, to = {100, 400}})
	testing.expect_value(t, doc_text(&d), "# nengine cutscene\ncut x\n\ncast ada\n\n0.00 ada walk_to 100,400\n4.00 end\n")
	doc_set_head(&d, "x", "veranda")
	testing.expect_value(t, d.lines[1], "cut x scene=veranda")
}

// A note after what the engine reads of a cue stays when the cue is changed,
// with its spacing as written; a tag is the cue's own, not the note's; and a
// note the new verb would read as its words goes above the line as a comment.
@(private = "file")
NOTED :: `cut noted
cast moore char=moore at=470,500
12.50 line A2.GT.FENCE 3     the node's third line
13.00 line A2.GT.FENCE 1-2 tag=percy   his telling
14.00 moore walk_to 300,480   to the gate
15.00 moore play wave 2x  waves, twice
16.00 moore face left	(turns)
17.00 sound gate  the latch
18.00 camera shake 0.40   a lorry
19.00 end  and out
`

@(test)
a_note_after_a_cue_is_kept :: proc(t: ^testing.T) {
	d: Cut_Doc
	defer doc_destroy(&d)
	doc_set_text_all(&d, NOTED)
	testing.expect_value(t, doc_text(&d), NOTED)
	// The engine reads the cue and not the note.
	testing.expect_value(t, len(d.cues), 8)
	testing.expect_value(t, d.cues[0].q.lines, [2]int{3, 3})
	testing.expect_value(t, cue_note(d.lines[2], d.cues[0].q), "     the node's third line")
	testing.expect_value(t, cue_note(d.lines[3], d.cues[1].q), "   his telling")
	testing.expect_value(t, cue_note(d.lines[5], d.cues[3].q), "  waves, twice")

	set :: proc(d: ^Cut_Doc, line: int, change: proc(q: ^ne.Cue)) {
		i := doc_cue_at_line(d, line)
		q := d.cues[i].q
		change(&q)
		doc_set_cue(d, i, q)
	}
	set(&d, 2, proc(q: ^ne.Cue) {q.lines = {3, 5}})
	testing.expect_value(t, d.lines[2], "12.50 line A2.GT.FENCE 3-5     the node's third line")
	set(&d, 3, proc(q: ^ne.Cue) {q.tag = "elena"})
	testing.expect_value(t, d.lines[3], "13.00 line A2.GT.FENCE 1-2 tag=elena   his telling")
	set(&d, 3, proc(q: ^ne.Cue) {q.tag = ""})
	testing.expect_value(t, d.lines[3], "13.00 line A2.GT.FENCE 1-2   his telling")
	set(&d, 4, proc(q: ^ne.Cue) {q.to = {320, 490}})
	testing.expect_value(t, d.lines[4], "14.00 moore walk_to 320,490   to the gate")
	set(&d, 5, proc(q: ^ne.Cue) {q.times = 1})
	testing.expect_value(t, d.lines[5], "15.00 moore play wave once  waves, twice")
	set(&d, 6, proc(q: ^ne.Cue) {q.facing = .Right})
	testing.expect_value(t, d.lines[6], "16.00 moore face right\t(turns)")
	set(&d, 7, proc(q: ^ne.Cue) {q.text = "gate_shut"})
	testing.expect_value(t, d.lines[7], "17.00 sound gate_shut  the latch")
	set(&d, 8, proc(q: ^ne.Cue) {q.amount = 1})
	testing.expect_value(t, d.lines[8], "18.00 camera shake 1.00   a lorry")
	// Made another kind that reads a few words, a walk into a face: the note
	// stays after them.
	set(&d, 4, proc(q: ^ne.Cue) {q.action = .Face; q.facing = .Back})
	testing.expect_value(t, d.lines[4], "14.00 moore face back   to the gate")
	// ...and the engine still reads every cue as it was meant.
	c, _ := ne.parse_cutscene(doc_text(&d))
	testing.expect_value(t, len(c.cues), 8)
	testing.expect_value(t, c.cues[2].facing, ne.Facing.Back)
	ne.cutscene_destroy(&c)

	// A say would say the note, and a line has no comment at its end: the
	// note goes over it.
	set(&d, 8, proc(q: ^ne.Cue) {q.action = .Narrate; q.who = ""; q.text = "A lorry goes by."})
	testing.expect_value(t, d.lines[8], "# a lorry")
	testing.expect_value(t, d.lines[9], "18.00 narrate A lorry goes by.")
	testing.expect_value(t, len(d.cues), 8)
	// A cue renamed with its person keeps its note too.
	doc_rename_cast(&d, 0, "warden")
	testing.expect_value(t, d.lines[4], "14.00 warden face back   to the gate")
	testing.expect_value(t, d.lines[5], "15.00 warden play wave once  waves, twice")
}
