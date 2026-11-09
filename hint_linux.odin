#+build linux
package nengine

import "core:strings"
import "core:sys/linux"

// The hint's answer, tried in a copy of this process: fork, and the child
// goes there and types it, writes what came of it down a pipe, and is gone.
// The game the harness is walking never knows. Quiet, the child's own lines
// go nowhere and only the verdict comes back. Harness only (`!hint try`,
// `!hint check`): nothing a player does forks anything.
//
// A copy can hang where the original never would: fork copies only the
// thread that forked, so a lock the sound thread held at that moment is
// held for ever in the copy, and the copy's next sound waits on it. Rare, and
// nothing to do with the hint; such a copy is stopped after ten seconds and
// the try made again, up to three times.
@(private)
hint_fork :: proc(w: ^World, h: Hint, quiet: bool, on_bang: Bang) -> (verdict: string, ok: bool) {
	for attempt in 1 ..= 3 {
		hung: bool
		verdict, ok, hung = hint_fork_once(w, h, quiet, on_bang)
		if !hung do return
		if attempt == 3 do return "FAIL: the copy hung three times, and was stopped", false
	}
	return
}

@(private = "file")
hint_fork_once :: proc(w: ^World, h: Hint, quiet: bool, on_bang: Bang) -> (verdict: string, ok, hung: bool) {
	fds: [2]linux.Fd
	if linux.pipe2(&fds, {.CLOEXEC}) != .NONE do return "skipped: no pipe", false, false
	pid, err := linux.fork()
	if err != .NONE {
		linux.close(fds[0])
		linux.close(fds[1])
		return "skipped: no fork", false, false
	}
	if pid == 0 {
		linux.close(fds[0])
		if quiet {
			if null, e := linux.open("/dev/null", {.RDWR}); e == .NONE {
				linux.dup2(null, 1)
				linux.dup2(null, 2)
			}
		}
		v := hint_try_here(w, h, on_bang)
		linux.write(fds[1], transmute([]u8)v)
		// Straight out: nothing of the parent's (the window, the sound, the
		// files) is this copy's to close.
		linux.exit_group(0)
	}
	linux.close(fds[1])
	// Read until the child is done with the pipe, for at most ten seconds:
	// a copy that hangs is killed.
	b := strings.builder_make(context.temp_allocator)
	buf: [512]u8
	deadline := 10_000
	waited := 0
	for {
		pfd := []linux.Poll_Fd{{fd = fds[0], events = {.IN}}}
		n, perr := linux.poll(pfd, 100)
		if perr == .EINTR do continue
		if n > 0 {
			got, rerr := linux.read(fds[0], buf[:])
			if rerr == .EINTR do continue
			if got <= 0 do break
			strings.write_bytes(&b, buf[:got])
			continue
		}
		waited += 100
		if waited >= deadline {
			linux.kill(pid, .SIGKILL)
			linux.close(fds[0])
			status: u32
			linux.wait4(pid, &status, {}, nil)
			return "", false, true
		}
	}
	linux.close(fds[0])
	status: u32
	linux.wait4(pid, &status, {}, nil)
	verdict = strings.to_string(b)
	if verdict == "" do return "FAIL: the copy said nothing (it crashed)", false, false
	return verdict, true, false
}
