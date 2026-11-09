package nengine

import "core:math"

// The mix bus: what happens to a song or a sound after its voices are added
// up and before it is written out. Three things, in order:
//
//   * a ROOM (reverb): a small Freeverb — eight damped combs and four
//     all-passes a side — fed by each track's send;
//   * a LEVEL: the whole piece is turned up or down until its loudness, as
//     a meter measures it (BS.1770: K-weighted, gated, in LUFS), lands on
//     the target. So two cues written at different volumes play at the same
//     loudness, and one loud downbeat no longer sets the level of a minute;
//   * a LIMITER: a look-ahead brick wall at the ceiling, so nothing clips.
//     It sees the peaks coming and turns down smoothly in front of them.
//
// None of it runs at play time. The baker does this once, offline, which is
// why it can look ahead as far as it likes.

// A render: interleaved frames, `channels` samples to a frame (L R L R for
// stereo), `rate` frames a second. A song is stereo at SAMPLE_RATE; a sound
// is mono, because the game places it left or right itself, at its own rate.
Audio :: struct {
	samples:  []f32,
	channels: int,
	rate:     int,
}

audio_frames :: proc(a: Audio) -> int {
	return len(a.samples) / max(a.channels, 1)
}

audio_seconds :: proc(a: Audio) -> f32 {
	return f32(audio_frames(a)) / f32(a.rate if a.rate > 0 else SAMPLE_RATE)
}

audio_destroy :: proc(a: ^Audio) {
	delete(a.samples)
	a^ = {}
}

// The channels averaged into one, for drawing a waveform or measuring.
audio_mono :: proc(a: Audio, allocator := context.allocator) -> []f32 {
	ch := max(a.channels, 1)
	out := make([]f32, audio_frames(a), allocator)
	for &v, i in out {
		sum: f32
		for c in 0 ..< ch do sum += a.samples[i * ch + c]
		v = sum / f32(ch)
	}
	return out
}

// The loudest sample, either channel.
audio_peak :: proc(a: Audio) -> f32 {
	p: f32
	for v in a.samples do p = max(p, abs(v))
	return p
}

// What nothing louder than is allowed out: -1 dBFS, which leaves room for
// the peaks a sample never shows but the converter draws between samples.
DEFAULT_CEILING :: f32(-1)

// No level asked for: leave the loudness alone and only keep it under the ceiling.
LEVEL_NONE :: f32(math.F32_MAX)

// A room. Size and damping are 0..1; mix is how loud the room is against the
// dry sound (0.25, the default, is a room you notice; 1 is as loud as the
// instruments).
Reverb :: struct {
	size:     f32,
	damp:     f32,
	mix:      f32,
	predelay: f32, // seconds
	width:    f32, // 0 mono .. 1 wide
}

// What a song gets if it says nothing: a modest room, like the one the
// MT-32 always had switched on. `reverb none` takes it away.
DEFAULT_REVERB :: Reverb{size = 0.5, damp = 0.5, mix = 0.25, predelay = 0.012, width = 1}

// What kind of space a room is. The same eight combs and four all-passes,
// at different lengths and density: a ROOM is the song's own (as it always
// was); a PLATE is short delays, dense and bright, with no pre-delay, the
// 1962 studio's EMT on the strings and the celesta; a HALL is long ones,
// late and dark.
Room_Kind :: enum u8 {
	Room,
	Plate,
	Hall,
}

ROOM_KIND_NAMES := [Room_Kind]string{.Room = "room", .Plate = "plate", .Hall = "hall"}

// A kind's own sound, before the song says any numbers.
room_preset :: proc(kind: Room_Kind) -> Reverb {
	switch kind {
	case .Plate: return {size = 0.85, damp = 0.15, mix = 0.3, predelay = 0, width = 1}
	case .Hall:  return {size = 0.8, damp = 0.5, mix = 0.3, predelay = 0.03, width = 1}
	case .Room:
	}
	return DEFAULT_REVERB
}

// How a kind scales the delay lines, and how hard its all-passes diffuse.
@(private = "file")
room_shape :: proc(kind: Room_Kind) -> (scale, diffusion: f32) {
	switch kind {
	case .Plate: return 0.55, 0.7
	case .Hall:  return 1.6, 0.6
	case .Room:
	}
	return 1, 0.5
}

// --- Loudness (ITU-R BS.1770 / EBU R128 integrated) ---

@(private = "file")
Biquad :: struct {
	b0, b1, b2, a1, a2: f64,
	z1, z2:             f64,
}

@(private = "file")
biquad_run :: #force_inline proc(q: ^Biquad, x: f64) -> f64 {
	y := q.b0 * x + q.z1
	q.z1 = q.b1 * x - q.a1 * y + q.z2
	q.z2 = q.b2 * x - q.a2 * y
	return y
}

// The two K-weighting stages, worked out for any rate (the spec gives them
// at 48 kHz; these are the same filters, from their analogue prototypes).
@(private = "file")
k_weighting :: proc(rate: f64) -> (shelf, high: Biquad) {
	{
		f0 := 1681.974450955533
		g := 3.999843853973347
		q := 0.7071752369554196
		k := math.tan(math.PI * f0 / rate)
		vh := math.pow(10, g / 20)
		vb := math.pow(vh, 0.4996667741545416)
		a0 := 1 + k / q + k * k
		shelf.b0 = (vh + vb * k / q + k * k) / a0
		shelf.b1 = 2 * (k * k - vh) / a0
		shelf.b2 = (vh - vb * k / q + k * k) / a0
		shelf.a1 = 2 * (k * k - 1) / a0
		shelf.a2 = (1 - k / q + k * k) / a0
	}
	{
		f0 := 38.13547087602444
		q := 0.5003270373238773
		k := math.tan(math.PI * f0 / rate)
		a0 := 1 + k / q + k * k
		high.b0, high.b1, high.b2 = 1, -2, 1
		high.a1 = 2 * (k * k - 1) / a0
		high.a2 = (1 - k / q + k * k) / a0
	}
	return
}

// Mean square of the K-weighted signal, summed over channels, in hops of
// 100 ms (a short sound keeps its end).
@(private = "file")
k_hops :: proc(samples: []f32, channels: int, rate: int) -> [dynamic]f64 {
	ch := max(channels, 1)
	frames := len(samples) / ch
	hop := max(rate / 10, 1)
	hops := make([dynamic]f64)
	filters := make([][2]Biquad, ch, context.temp_allocator)
	for c in 0 ..< ch {
		filters[c][0], filters[c][1] = k_weighting(f64(rate))
	}
	acc: f64
	n := 0
	for i in 0 ..< frames {
		for c in 0 ..< ch {
			y := biquad_run(&filters[c][1], biquad_run(&filters[c][0], f64(samples[i * ch + c])))
			acc += y * y
		}
		n += 1
		if n == hop {
			append(&hops, acc / f64(hop))
			acc, n = 0, 0
		}
	}
	if n > 0 && len(hops) < 30 do append(&hops, acc / f64(n))
	return hops
}

// The loudest 3 s, in LUFS: EBU R128's short-term loudness, at its highest.
// A sparse cue (a night bed half rest, a sting) is levelled by its few
// events, which integrated loudness gates and averages unpredictably; this
// is what a listener hears as "how loud it gets". A loop's window wraps.
loudness_short_max :: proc(samples: []f32, channels: int, rate := SAMPLE_RATE, loop := false) -> f32 {
	if len(samples) / max(channels, 1) == 0 do return math.inf_f32(-1)
	hops := k_hops(samples, channels, rate)
	defer delete(hops)
	n := len(hops)
	win := 30
	best: f64 = -1
	if n <= win {
		total: f64
		for h in hops do total += h
		best = total / f64(max(n, 1))
	} else {
		sum: f64
		for k in 0 ..< win do sum += hops[k]
		best = sum / f64(win)
		last := n - 1 if loop else n - win
		for i in 1 ..= last {
			sum += hops[(i + win - 1) % n] - hops[i - 1]
			best = max(best, sum / f64(win))
		}
	}
	if best <= 1e-30 do return math.inf_f32(-1)
	return f32(-0.691 + 10 * math.log10(best))
}

// Integrated loudness in LUFS: 400 ms blocks a quarter apart, K-weighted,
// those under -70 dropped and then those 10 LU under the average of the
// rest. Anything shorter than one block is one block. -inf for silence.
loudness :: proc(samples: []f32, channels: int, rate := SAMPLE_RATE) -> f32 {
	ch := max(channels, 1)
	frames := len(samples) / ch
	if frames == 0 do return math.inf_f32(-1)

	// Mean square of the K-weighted signal, summed over channels, in hops
	// of 100 ms; a block is four hops.
	hop := max(rate / 10, 1)
	hops := make([dynamic]f64)
	defer delete(hops)
	filters := make([][2]Biquad, ch, context.temp_allocator)
	for c in 0 ..< ch {
		filters[c][0], filters[c][1] = k_weighting(f64(rate))
	}
	acc: f64
	n := 0
	for i in 0 ..< frames {
		for c in 0 ..< ch {
			y := biquad_run(&filters[c][1], biquad_run(&filters[c][0], f64(samples[i * ch + c])))
			acc += y * y
		}
		n += 1
		if n == hop {
			append(&hops, acc / f64(hop))
			acc, n = 0, 0
		}
	}
	if n > 0 && len(hops) < 4 do append(&hops, acc / f64(n)) // a short sound: keep its end

	blocks := make([dynamic]f64)
	defer delete(blocks)
	if len(hops) < 4 {
		total: f64
		for h in hops do total += h
		append(&blocks, total / f64(max(len(hops), 1)))
	} else {
		for i in 0 ..= len(hops) - 4 {
			append(&blocks, (hops[i] + hops[i + 1] + hops[i + 2] + hops[i + 3]) / 4)
		}
	}
	lufs :: proc(ms: f64) -> f64 { return -0.691 + 10 * math.log10(max(ms, 1e-30)) }

	sum: f64
	count := 0
	for b in blocks do if lufs(b) > -70 { sum += b; count += 1 }
	if count == 0 do return math.inf_f32(-1)
	relative := lufs(sum / f64(count)) - 10
	sum, count = 0, 0
	for b in blocks do if lufs(b) > -70 && lufs(b) > relative { sum += b; count += 1 }
	if count == 0 do return math.inf_f32(-1)
	return f32(lufs(sum / f64(count)))
}

// --- The limiter ---

// Holds every sample (and the peak a converter would draw between two
// samples) under `ceiling_db`. Offline, so it looks ahead: the gain it needs
// is spread over a few milliseconds either side of each peak, and recovers
// over a tenth of a second. A loop is treated as a circle, so its seam sees
// the same gain from both sides.
limit :: proc(samples: []f32, channels: int, ceiling_db: f32, loop: bool, rate := SAMPLE_RATE) {
	ch := max(channels, 1)
	frames := len(samples) / ch
	if frames == 0 do return
	ceiling := math.pow(10, ceiling_db / 20)

	at :: #force_inline proc(s: []f32, ch, frames, i, c: int, loop: bool) -> f32 {
		j := i
		if loop do j = ((i % frames) + frames) % frames
		else if j < 0 || j >= frames do return 0
		return s[j * ch + c]
	}

	// What each frame needs, from its own peak and the ones either side of it.
	need := make([]f32, frames)
	defer delete(need)
	worst: f32
	for i in 0 ..< frames {
		peak: f32
		for c in 0 ..< ch {
			x0 := at(samples, ch, frames, i - 1, c, loop)
			x1 := samples[i * ch + c]
			x2 := at(samples, ch, frames, i + 1, c, loop)
			x3 := at(samples, ch, frames, i + 2, c, loop)
			// Halfway to the next sample, as a smooth curve through four.
			mid := (-x0 + 9 * x1 + 9 * x2 - x3) / 16
			peak = max(peak, abs(x1), abs(mid))
		}
		need[i] = 1 if peak <= ceiling else ceiling / peak
		worst = max(worst, peak)
	}
	if worst <= ceiling do return

	// The least gain in a window round each frame, then the average of that
	// over the same window: every value averaged is at most what this frame
	// needs, so the average is too, and it moves smoothly.
	w := max(rate * 3 / 1000, 1)
	least := sliding_min(need, w, loop)
	defer delete(least)
	gain := make([]f32, frames)
	defer delete(gain)
	{
		sum: f64
		count := 0
		for k in -w ..= w {
			j := k
			if loop do j = ((k % frames) + frames) % frames
			if j >= 0 && j < frames { sum += f64(least[j]); count += 1 }
		}
		for i in 0 ..< frames {
			gain[i] = f32(sum / f64(max(count, 1)))
			// Slide the window on by one.
			out_j, in_j := i - w, i + w + 1
			if loop {
				out_j = ((out_j % frames) + frames) % frames
				in_j = in_j % frames
				sum += f64(least[in_j]) - f64(least[out_j])
			} else {
				if out_j >= 0 { sum -= f64(least[out_j]); count -= 1 }
				if in_j < frames { sum += f64(least[in_j]); count += 1 }
			}
		}
	}

	// Recover slowly; never above what the frame needs. A loop goes round
	// twice so the start knows how the end left it.
	release := 1 - math.exp(-1 / (0.1 * f32(rate)))
	g: f32 = 1
	passes := 2 if loop else 1
	for p in 0 ..< passes {
		for i in 0 ..< frames {
			g = min(gain[i], g + (1 - g) * release)
			if p == passes - 1 do for c in 0 ..< ch do samples[i * ch + c] *= g
		}
	}
	// Belt and braces: the sums above are in float, so a last hair over the
	// line is clamped rather than trusted.
	for &v in samples do v = clamp(v, -ceiling, ceiling)
}

// The least value within w either side of each index (a monotonic queue).
@(private = "file")
sliding_min :: proc(x: []f32, w: int, loop: bool) -> []f32 {
	n := len(x)
	out := make([]f32, n)
	if n == 0 do return out
	if loop && 2 * w + 1 >= n {
		least := x[0]
		for v in x do least = min(least, v)
		for &v in out do v = least
		return out
	}
	value :: #force_inline proc(x: []f32, i: int, loop: bool) -> f32 {
		n := len(x)
		if loop do return x[((i % n) + n) % n]
		if i < 0 || i >= n do return 1
		return x[i]
	}
	q := make([]int, n + 2 * w + 2)
	defer delete(q)
	head, tail := 0, 0
	// Index k covers out[k - w]; walk k from -w to n - 1 + w.
	for k in -w ..< n + w {
		v := value(x, k, loop)
		for tail > head && value(x, q[tail - 1], loop) >= v do tail -= 1
		q[tail] = k
		tail += 1
		i := k - w
		if i < 0 do continue
		for q[head] < i - w do head += 1
		out[i] = value(x, q[head], loop)
	}
	return out
}

// Turn the whole thing up or down to `target` LUFS, then limit. The limiter
// takes a little loudness off when it works, so it measures again and goes
// round until it lands. With LEVEL_NONE it only limits. `short` measures
// the loudest 3 s instead of the whole (`level -16 short`).
master :: proc(samples: []f32, channels: int, target: f32, ceiling_db: f32, loop: bool, rate := SAMPLE_RATE, short := false) {
	if len(samples) == 0 do return
	if target == LEVEL_NONE {
		limit(samples, channels, ceiling_db, loop, rate)
		return
	}
	meter :: proc(x: []f32, channels: int, rate: int, loop, short: bool) -> f32 {
		return loudness_short_max(x, channels, rate, loop) if short else loudness(x, channels, rate)
	}
	now := meter(samples, channels, rate, loop, short)
	if math.is_inf(now) || math.is_nan(now) do return // silence stays silence
	gain := math.pow(10, (target - now) / 20)
	trial := make([]f32, len(samples))
	defer delete(trial)
	for _ in 0 ..< 10 {
		for v, i in samples do trial[i] = v * gain
		limit(trial, channels, ceiling_db, loop, rate)
		got := meter(trial, channels, rate, loop, short)
		if abs(got - target) < 0.1 || math.is_inf(got) do break
		gain *= math.pow(10, (target - got) / 20)
	}
	copy(samples, trial)
}

// --- The room ---

// Freeverb's tunings, in samples at 44.1 kHz; the right side is 23 longer,
// which is what makes it stereo.
@(private = "file")
COMBS := [8]int{1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617}
@(private = "file")
ALLPASSES := [4]int{556, 441, 341, 225}
@(private = "file")
SPREAD :: 23

// How long a room takes to die away by 60 dB, in seconds: the longest comb
// is what lasts. (Its delays scale with the rate, so this does not.)
reverb_tail :: proc(r: Reverb, kind := Room_Kind.Room) -> f32 {
	fb := reverb_feedback(r)
	scale, _ := room_shape(kind)
	longest := f32(COMBS[7] + SPREAD) * scale / 44100
	return 3 * longest / -math.log10(max(fb, 1e-4))
}

@(private = "file")
reverb_feedback :: proc(r: Reverb) -> f32 {
	return clamp(r.size, 0, 1) * 0.28 + 0.7
}

// The room's answer to `send` (mono), as interleaved stereo the same length.
// A loop's room runs round it more than once, so the tail of the last bar
// rings on into the first, as it would if the loop really had been playing.
// The send is high-passed first: a room full of bass is mud.
reverb_render :: proc(send: []f32, r: Reverb, loop: bool, rate := SAMPLE_RATE, allocator := context.allocator, kind := Room_Kind.Room) -> []f32 {
	n := len(send)
	out := make([]f32, 2 * n, allocator)
	if n == 0 || r.mix <= 0 do return out

	shape, diffusion := room_shape(kind)
	scale := f32(rate) / 44100 * shape
	fb := reverb_feedback(r)
	damp := clamp(r.damp, 0, 1) * 0.4
	width := clamp(r.width, 0, 1)
	// Calibrated so `mix 1` gives a room about as loud as what feeds it
	// (measured on noise, size 0.5: the room's RMS over the send's).
	wet := clamp(r.mix, 0, 4) * 3.1
	wet1 := wet * (width / 2 + 0.5)
	wet2 := wet * ((1 - width) / 2)
	gain_in :: f32(0.015)

	Comb :: struct { buf: []f32, i: int, store: f32 }
	All :: struct { buf: []f32, i: int }
	combs: [2][8]Comb
	alls: [2][4]All
	for side in 0 ..< 2 {
		for d, k in COMBS do combs[side][k].buf = make([]f32, max(int(f32(d + side * SPREAD) * scale), 1), context.temp_allocator)
		for d, k in ALLPASSES do alls[side][k].buf = make([]f32, max(int(f32(d + side * SPREAD) * scale), 1), context.temp_allocator)
	}
	pre := make([]f32, max(int(r.predelay * f32(rate)), 1), context.temp_allocator)
	pre_i := 0
	hp_state: f32
	hp := 1 - math.exp(-2 * math.PI * 120 / f32(rate))

	passes := 1
	if loop do passes = 1 + int(math.ceil(reverb_tail(r, kind) / max(f32(n) / f32(rate), 1e-3)))
	passes = min(passes, 6)

	for p in 0 ..< passes {
		last := p == passes - 1
		for j in 0 ..< n {
			x := send[j]
			hp_state += hp * (x - hp_state)
			x -= hp_state
			delayed := pre[pre_i]
			pre[pre_i] = x
			pre_i = (pre_i + 1) % len(pre)
			input := delayed * gain_in
			sides: [2]f32
			for side in 0 ..< 2 {
				acc: f32
				for &c in combs[side] {
					y := c.buf[c.i]
					c.store = y * (1 - damp) + c.store * damp
					c.buf[c.i] = input + c.store * fb
					c.i = (c.i + 1) % len(c.buf)
					acc += y
				}
				for &a in alls[side] {
					b := a.buf[a.i]
					a.buf[a.i] = acc + b * diffusion
					a.i = (a.i + 1) % len(a.buf)
					acc = b - acc
				}
				sides[side] = acc
			}
			if last {
				out[2 * j] = sides[0] * wet1 + sides[1] * wet2
				out[2 * j + 1] = sides[1] * wet1 + sides[0] * wet2
			}
		}
	}
	return out
}

// A short fade at the very end of a piece, so it stops on silence whatever
// the room was still doing.
fade_out :: proc(samples: []f32, channels: int, seconds: f32, rate := SAMPLE_RATE) {
	ch := max(channels, 1)
	frames := len(samples) / ch
	n := min(int(seconds * f32(rate)), frames)
	for k in 0 ..< n {
		i := frames - n + k
		g := f32(n - 1 - k) / f32(max(n, 1))
		for c in 0 ..< ch do samples[i * ch + c] *= g
	}
}

// --- A track's own effects: filters, peaks, a tape echo ---

// RBJ's cookbook biquads, at SAMPLE_RATE.
@(private = "file")
Biquad_Kind :: enum {
	Low,
	High,
	Peak,
}

@(private = "file")
biquad_design :: proc(kind: Biquad_Kind, hz, q, gain_db: f32, rate := SAMPLE_RATE) -> Biquad {
	w0 := 2 * math.PI * f64(clamp(hz, 10, 0.45 * f32(rate))) / f64(rate)
	cw, sw := math.cos(w0), math.sin(w0)
	alpha := sw / (2 * f64(max(q, 0.05)))
	b0, b1, b2, a0, a1, a2: f64
	switch kind {
	case .Low:
		b0, b1, b2 = (1 - cw) / 2, 1 - cw, (1 - cw) / 2
		a0, a1, a2 = 1 + alpha, -2 * cw, 1 - alpha
	case .High:
		b0, b1, b2 = (1 + cw) / 2, -(1 + cw), (1 + cw) / 2
		a0, a1, a2 = 1 + alpha, -2 * cw, 1 - alpha
	case .Peak:
		A := math.pow(10, f64(gain_db) / 40)
		b0, b1, b2 = 1 + alpha * A, -2 * cw, 1 - alpha * A
		a0, a1, a2 = 1 + alpha / A, -2 * cw, 1 - alpha / A
	}
	return {b0 = b0 / a0, b1 = b1 / a0, b2 = b2 / a0, a1 = a1 / a0, a2 = a2 / a0}
}

// A track's low-pass, high-pass and peaks, then (first, in fact) its echo,
// on its mono buffer. A loop's filters start warm from its own end, and its
// echoes ring round into its start, so the seam stays joined.
track_effects :: proc(buf: []f32, t: ^Track, echo_secs: f32, loop: bool, rate := SAMPLE_RATE) {
	n := len(buf)
	if n == 0 do return
	if echo_secs > 0 && t.echo.mix > 0 do tape_echo(buf, echo_secs, t.echo.feedback, t.echo.mix, loop, rate)

	chain := make([dynamic]Biquad, context.temp_allocator)
	if t.hp > 0 do append(&chain, biquad_design(.High, t.hp, 0.7071, 0, rate))
	if t.lp > 0 do append(&chain, biquad_design(.Low, t.lp, 0.7071, 0, rate))
	for q in t.eqs do if q.gain != 0 do append(&chain, biquad_design(.Peak, q.hz, q.q, q.gain, rate))
	if len(chain) == 0 do return
	if loop {
		warm := min(n, rate)
		for k in n - warm ..< n {
			x := f64(buf[k])
			for &f in chain do x = biquad_run(&f, x)
		}
	}
	for &v in buf {
		x := f64(v)
		for &f in chain do x = biquad_run(&f, x)
		v = f32(x)
	}
}

// How long a track's echoes last, to 60 dB down.
echo_tail :: proc(secs, feedback: f32) -> f32 {
	if secs <= 0 do return 0
	fb := clamp(feedback, 0.01, 0.95)
	return min(secs * (1 + 3 / -math.log10(fb)), 20)
}

// A tape echo: a delay line whose repeats come back through the tape's own
// narrowing (a little less top and bottom every time round) and a slow wow.
@(private = "file")
tape_echo :: proc(buf: []f32, secs, feedback, mix: f32, loop: bool, rate: int) {
	n := len(buf)
	d := secs * f32(rate)
	wow := 0.0004 * f32(rate) // 0.4 ms of wobble
	size := int(d + wow) + 4
	line := make([]f32, size)
	defer delete(line)
	w := 0
	lp_c := 1 - math.exp(-2 * math.PI * 3200 / f32(rate))
	hp_c := 1 - math.exp(-2 * math.PI * 150 / f32(rate))
	lp, hp: f32
	passes := 1
	if loop do passes = 1 + min(int(math.ceil(echo_tail(secs, feedback) / max(f32(n) / f32(rate), 1e-3))), 6)
	for p in 0 ..< passes {
		last := p == passes - 1
		for i in 0 ..< n {
			// The wow runs on the song's clock, whole cycles to a loop.
			ph := f32(i) / f32(n) * max(math.round(f32(n) / f32(rate) * 0.5), 1) if loop else f32(i) / f32(rate) * 0.5
			at := f32(w) - (d + wow * 0.5 * (1 + math.sin(2 * math.PI * ph)))
			for at < 0 do at += f32(size)
			k0 := int(at)
			fr := at - f32(k0)
			y := line[k0 % size] * (1 - fr) + line[(k0 + 1) % size] * fr
			x := buf[i]
			into := x + y * feedback
			lp += lp_c * (into - lp)
			hp += hp_c * (lp - hp)
			line[w] = lp - hp
			w = (w + 1) % size
			if last do buf[i] = x + y * mix
		}
	}
}
