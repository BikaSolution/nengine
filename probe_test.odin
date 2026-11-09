package nengine

import "core:testing"

// Probes (probe.odin): the parts that are not pictures.

@(test)
a_probe_point_carries_who_and_which_way :: proc(t: ^testing.T) {
	p, ok := parse_probe_point("640,560:as=porter:pose=sit:facing=left")
	testing.expect(t, ok)
	testing.expect_value(t, p.pos, [2]f32{640, 560})
	testing.expect_value(t, p.as, "porter")
	testing.expect_value(t, p.pose, "sit")
	testing.expect_value(t, p.facing, Facing.Left)

	plain, good := parse_probe_point("12,34")
	testing.expect(t, good)
	testing.expect_value(t, plain.as, "")

	_, bad := parse_probe_point("12,34:colour=red")
	testing.expect(t, !bad)
	_, worse := parse_probe_point("twelve")
	testing.expect(t, !worse)
}

@(test)
people_here_lists_who_is_drawn :: proc(t: ^testing.T) {
	sc: Scene
	defer delete(sc.objects)
	append(&sc.objects, Object{name = "moore", walks = true, actor = {pos = {512, 600}, pose = "unlock"}})
	append(&sc.objects, Object{name = "lamp", actor = {pos = {1, 1}}})
	append(&sc.objects, Object{name = "lucy", walks = true, hidden = true, actor = {pos = {9, 9}}})
	append(&sc.objects, Object{name = "otto", walks = true, hidden = true, going = true, going_from = {192, 550}})
	testing.expect_value(t, people_here_text(&sc), "moore 512,600 unlock; otto 192,550 (going)")
	empty: Scene
	testing.expect_value(t, people_here_text(&empty), "nobody")
}

@(test)
a_crowd_never_puts_two_people_on_top_of_each_other :: proc(t: ^testing.T) {
	// Two on one spot, one far away: the far one shares the first picture.
	points := [?]Probe_Point{{pos = {100, 500}}, {pos = {110, 510}}, {pos = {600, 500}}, {pos = {100, 300}}}
	layers := probe_layers(points[:])
	testing.expect_value(t, len(layers), 2)
	testing.expect_value(t, len(layers[0]), 3) // 100,500  600,500  100,300 (150 apart is apart)
	testing.expect_value(t, len(layers[1]), 1)
	for layer in layers do for p, i in layer do for q in layer[i + 1:] {
		d := p.pos - q.pos
		testing.expect(t, abs(d.x) >= PROBE_APART.x || abs(d.y) >= PROBE_APART.y)
	}
}


@(test)
cutsnap_reads_a_cut_and_its_seconds_in_order :: proc(t: ^testing.T) {
	name, times, ok := parse_cutsnap({"the_post", "40.5", "0.5", "81"})
	defer delete(times)
	testing.expect(t, ok)
	testing.expect_value(t, name, "the_post")
	testing.expect_value(t, len(times), 3)
	testing.expect_value(t, times[0], f32(0.5))
	testing.expect_value(t, times[2], f32(81))
	_, _, none := parse_cutsnap({"the_post"})
	testing.expect(t, !none)
	_, _, bad := parse_cutsnap({"the_post", "soon"})
	testing.expect(t, !bad)
}
