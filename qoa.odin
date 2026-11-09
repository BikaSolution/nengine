package nengine

import "core:encoding/endian"
import "core:math"

// QOA, the Quite OK Audio format (qoaformat.org): what `just bake` makes of
// music and long beds, and what the game streams them from (audio.odin).
// Lossy, a fifth the size of 16-bit PCM (3.2 bits a sample), decoded by
// raylib itself (LoadMusicStream, LoadSound, LoadWave), and sample-exact: a
// file holds exactly the frames it was given, with no padding and no encoder
// delay, so a loop rendered to an exact length plays that length.
//
// The encoder is here, not raylib's ExportWave, for the seam. Every QOA frame
// begins with its predictor's state (the last four samples, four weights),
// and a plain encoder begins the file from silence: the first samples of a
// loop are predicted from nothing and come out a little wrong, a one-sample
// step at every turn of the loop (on the title, 110 where the source steps
// by 1, in 16-bit units). Given `loop`, this one begins the predictor where
// the end of the loop leaves it, and the step at the turn is the source's
// give or take the codec's ordinary error (title: 14).
//
// The decoder is here for the tests and the tools: raylib's is not exported.
// Both follow the reference qoa.h exactly, 32-bit wrapping arithmetic
// included, and a test holds the decoder to raylib's own, sample for sample.

QOA_MAGIC :: 0x716f6166 // "qoaf"
QOA_SLICE_LEN :: 20
QOA_SLICES_PER_FRAME :: 256
QOA_FRAME_LEN :: QOA_SLICES_PER_FRAME * QOA_SLICE_LEN
QOA_LMS_LEN :: 4
QOA_MAX_CHANNELS :: 8

@(private = "file")
Qoa_Lms :: struct {
	history: [QOA_LMS_LEN]i32,
	weights: [QOA_LMS_LEN]i32,
}

@(private = "file")
QOA_QUANT := [17]i32{7, 7, 7, 5, 5, 3, 3, 1, 0, 0, 2, 2, 4, 4, 6, 6, 6}
@(private = "file")
QOA_SCALEFACTOR := [16]i32{1, 7, 21, 45, 84, 138, 211, 304, 421, 562, 731, 928, 1157, 1419, 1715, 2048}
@(private = "file")
qoa_reciprocal: [16]i32
@(private = "file")
qoa_dequant: [16][8]i32

// The two derived tables, as qoa.h defines them: the reciprocal rounds up,
// and the dequantized steps round to nearest with ties away from zero.
@(private = "file", init)
qoa_tables :: proc "contextless" () {
	steps := [8]f64{0.75, -0.75, 2.5, -2.5, 4.5, -4.5, 7, -7}
	for sf, s in QOA_SCALEFACTOR {
		qoa_reciprocal[s] = ((1 << 16) + sf - 1) / sf
		for q in 0 ..< 8 do qoa_dequant[s][q] = i32(math.round(f64(sf) * steps[q]))
	}
}

@(private = "file")
qoa_predict :: proc(l: ^Qoa_Lms) -> i32 {
	p: i32
	for i in 0 ..< QOA_LMS_LEN do p += l.weights[i] * l.history[i]
	return p >> 13
}

@(private = "file")
qoa_update :: proc(l: ^Qoa_Lms, sample, residual: i32) {
	delta := residual >> 4
	for i in 0 ..< QOA_LMS_LEN do l.weights[i] += -delta if l.history[i] < 0 else delta
	for i in 0 ..< QOA_LMS_LEN - 1 do l.history[i] = l.history[i + 1]
	l.history[QOA_LMS_LEN - 1] = sample
}

@(private = "file")
qoa_div :: proc(v, sf: i32) -> i32 {
	n := (v * qoa_reciprocal[sf] + (1 << 15)) >> 16
	return n + i32(v > 0) - i32(v < 0) - (i32(n > 0) - i32(n < 0)) // away from 0
}

@(private = "file")
qoa_clamp_s16 :: proc(v: i32) -> i32 {
	return clamp(v, -32768, 32767)
}

@(private = "file")
qoa_frame_size :: proc(channels, slices: int) -> int {
	return 8 + QOA_LMS_LEN * 4 * channels + 8 * slices * channels
}

// The file's size for this many frames (samples per channel).
qoa_size :: proc(frames, channels: int) -> int {
	n_frames := (frames + QOA_FRAME_LEN - 1) / QOA_FRAME_LEN
	n_slices := (frames + QOA_SLICE_LEN - 1) / QOA_SLICE_LEN
	return 8 + n_frames * (8 + QOA_LMS_LEN * 4 * channels) + n_slices * 8 * channels
}

// The reference encoder's starting state: weights {0, 0, -1, 2}, history 0.
@(private = "file")
qoa_lms_start :: proc(channels: int) -> (lms: [QOA_MAX_CHANNELS]Qoa_Lms) {
	for c in 0 ..< channels do lms[c].weights = {0, 0, -(1 << 13), 1 << 14}
	return
}

// Encodes `pcm` (interleaved, `frames` of `channels`) from state `lms`, which
// it leaves as the end of the file leaves it. With `out` nil it only runs
// the predictor, for priming.
@(private = "file")
qoa_encode_frames :: proc(pcm: []i16, channels, rate: int, lms: ^[QOA_MAX_CHANNELS]Qoa_Lms, out: []u8) -> int {
	frames := len(pcm) / channels
	p := 0
	put :: proc(out: []u8, p: ^int, v: u64) {
		if out != nil do endian.put_u64(out[p^:], .Big, v)
		p^ += 8
	}
	for start := 0; start < frames; start += QOA_FRAME_LEN {
		frame_len := min(QOA_FRAME_LEN, frames - start)
		slices := (frame_len + QOA_SLICE_LEN - 1) / QOA_SLICE_LEN
		put(out, &p, u64(channels) << 56 | u64(rate) << 32 | u64(frame_len) << 16 | u64(qoa_frame_size(channels, slices)))
		for c in 0 ..< channels {
			history, weights: u64
			for i in 0 ..< QOA_LMS_LEN {
				history = history << 16 | u64(u16(lms[c].history[i]))
				weights = weights << 16 | u64(u16(lms[c].weights[i]))
			}
			put(out, &p, history)
			put(out, &p, weights)
		}
		samples := pcm[start * channels:]
		prev_sf: [QOA_MAX_CHANNELS]i32
		for si := 0; si < frame_len; si += QOA_SLICE_LEN {
			for c in 0 ..< channels {
				slice_len := min(QOA_SLICE_LEN, frame_len - si)
				best_rank := max(u64)
				best_slice: u64
				best_lms: Qoa_Lms
				best_sf: i32
				// Every scalefactor tried, the last slice's first; the one
				// with the least squared error (and the least overgrown
				// weights) kept.
				for sfi in i32(0) ..< 16 {
					sf := (sfi + prev_sf[c]) % 16
					l := lms[c]
					slice := u64(sf)
					rank: u64
					for k in 0 ..< slice_len {
						sample := i32(samples[(si + k) * channels + c])
						predicted := qoa_predict(&l)
						residual := sample - predicted
						scaled := clamp(qoa_div(residual, sf), -8, 8)
						quantized := QOA_QUANT[scaled + 8]
						dequantized := qoa_dequant[sf][quantized]
						reconstructed := qoa_clamp_s16(predicted + dequantized)
						penalty := ((l.weights[0] * l.weights[0] + l.weights[1] * l.weights[1] +
							     l.weights[2] * l.weights[2] + l.weights[3] * l.weights[3]) >> 18) - 0x8ff
						if penalty < 0 do penalty = 0
						e := i64(sample - reconstructed)
						rank += u64(e * e) + u64(i64(penalty * penalty))
						if rank > best_rank do break
						qoa_update(&l, reconstructed, dequantized)
						slice = slice << 3 | u64(quantized)
					}
					if rank < best_rank {
						best_rank, best_slice, best_lms, best_sf = rank, slice, l, sf
					}
				}
				prev_sf[c] = best_sf
				lms[c] = best_lms
				// A short last slice is left-aligned: its empty bits on the right.
				best_slice <<= uint(QOA_SLICE_LEN - slice_len) * 3
				put(out, &p, best_slice)
			}
		}
	}
	return p
}

// Encodes 16-bit samples (interleaved when stereo) as a whole .qoa file.
// `loop`: the sound goes round, and its first samples are predicted from its
// last (see the head of this file). Returns nil for nothing to encode.
qoa_encode :: proc(samples: []i16, channels, rate: int, loop := false, allocator := context.allocator) -> []u8 {
	if channels < 1 || channels > QOA_MAX_CHANNELS || len(samples) < channels || rate <= 0 || rate > 0xffffff do return nil
	frames := len(samples) / channels
	pcm := samples[:frames * channels] // whole frames only
	lms := qoa_lms_start(channels)
	if loop {
		// The predictor warmed on the loop's last two frames' worth, so it
		// starts the file holding (very nearly) the samples that come
		// before it when it goes round. Not to the bit: the end of a whole
		// encode has wandered a little from the end of this short one, and
		// no number of passes makes the two meet (tried: they never do). Near
		// enough that the turn's error is the file's ordinary error.
		tail := min(frames, 2 * QOA_FRAME_LEN)
		qoa_encode_frames(pcm[(frames - tail) * channels:], channels, rate, &lms, nil)
	}
	out := make([]u8, qoa_size(frames, channels), allocator)
	endian.put_u64(out, .Big, u64(QOA_MAGIC) << 32 | u64(frames))
	qoa_encode_frames(pcm, channels, rate, &lms, out[8:])
	return out
}

// --- Decoding ---

// A .qoa read a frame at a time, as raylib streams one: `qoa_stream_read`
// fills whatever it is given, going round to the start at the end, which is
// exactly what a looping rl.Music does with the file.
Qoa_Stream :: struct {
	file:     []u8, // borrowed
	channels: int,
	rate:     int,
	frames:   int, // per channel, the whole file
	pos:      int, // the next frame's byte
	lms:      [QOA_MAX_CHANNELS]Qoa_Lms,
	buf:      []i16, // one frame, decoded
	buf_len:  int, // frames decoded into buf
	buf_pos:  int, // frames of buf already handed out
}

qoa_stream_open :: proc(file: []u8) -> (s: Qoa_Stream, ok: bool) {
	if len(file) < 16 do return {}, false
	head, _ := endian.get_u64(file, .Big)
	if head >> 32 != QOA_MAGIC do return {}, false
	frame_head, _ := endian.get_u64(file[8:], .Big)
	s.file = file
	s.frames = int(head & 0xffffffff)
	s.channels = int(frame_head >> 56)
	s.rate = int(frame_head >> 32 & 0xffffff)
	s.pos = 8
	if s.frames <= 0 || s.channels <= 0 || s.channels > QOA_MAX_CHANNELS do return {}, false
	s.buf = make([]i16, QOA_FRAME_LEN * s.channels)
	return s, true
}

qoa_stream_close :: proc(s: ^Qoa_Stream) {
	delete(s.buf)
	s^ = {}
}

// The predictor state a frame starts from, from its header.
@(private = "file")
qoa_frame_state :: proc(b: []u8, channels: int) -> (lms: [QOA_MAX_CHANNELS]Qoa_Lms) {
	p := 8
	for c in 0 ..< channels {
		history, _ := endian.get_u64(b[p:], .Big)
		weights, _ := endian.get_u64(b[p + 8:], .Big)
		p += 16
		for i in 0 ..< QOA_LMS_LEN {
			lms[c].history[i] = i32(i16(history >> 48))
			lms[c].weights[i] = i32(i16(weights >> 48))
			history <<= 16
			weights <<= 16
		}
	}
	return
}

// Decodes the frame at s.pos into s.buf. False at the end of the file.
@(private = "file")
qoa_decode_frame :: proc(s: ^Qoa_Stream) -> bool {
	b := s.file[s.pos:]
	ch := s.channels
	if len(b) < 8 + QOA_LMS_LEN * 4 * ch do return false
	head, _ := endian.get_u64(b, .Big)
	samples := int(head >> 16 & 0xffff)
	size := int(head & 0xffff)
	if int(head >> 56) != ch || size > len(b) || samples * ch > (size - 8 - QOA_LMS_LEN * 4 * ch) / 8 * QOA_SLICE_LEN do return false
	s.lms = qoa_frame_state(b, ch)
	p := 8 + QOA_LMS_LEN * 4 * ch
	for si := 0; si < samples; si += QOA_SLICE_LEN {
		for c in 0 ..< ch {
			slice, _ := endian.get_u64(b[p:], .Big)
			p += 8
			sf := i32(slice >> 60 & 0xf)
			slice <<= 4
			for k in si ..< min(si + QOA_SLICE_LEN, samples) {
				predicted := qoa_predict(&s.lms[c])
				dequantized := qoa_dequant[sf][slice >> 61 & 0x7]
				reconstructed := qoa_clamp_s16(predicted + dequantized)
				s.buf[k * ch + c] = i16(reconstructed)
				slice <<= 3
				qoa_update(&s.lms[c], reconstructed, dequantized)
			}
		}
	}
	s.pos += p
	s.buf_len, s.buf_pos = samples, 0
	return samples > 0
}

// Fills `out` (interleaved) with the next frames, going round at the end.
// Returns how many frames it wrote: all of them, unless the file is bad.
qoa_stream_read :: proc(s: ^Qoa_Stream, out: []i16) -> int {
	ch := max(s.channels, 1)
	want := len(out) / ch
	done := 0
	for done < want {
		if s.buf_pos == s.buf_len && !qoa_decode_frame(s) {
			s.pos = 8 // round to the first frame, which brings its own state
			if !qoa_decode_frame(s) do break
		}
		n := min(want - done, s.buf_len - s.buf_pos)
		copy(out[done * ch:(done + n) * ch], s.buf[s.buf_pos * ch:(s.buf_pos + n) * ch])
		s.buf_pos += n
		done += n
	}
	return done
}

// A whole .qoa file to 16-bit samples, interleaved.
qoa_decode :: proc(file: []u8, allocator := context.allocator) -> (pcm: []i16, channels, rate: int, ok: bool) {
	s := qoa_stream_open(file) or_return
	defer qoa_stream_close(&s)
	pcm = make([]i16, s.frames * s.channels, allocator)
	if qoa_stream_read(&s, pcm) != s.frames {
		delete(pcm, allocator)
		return nil, 0, 0, false
	}
	return pcm, s.channels, s.rate, true
}

