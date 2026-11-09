#+build !linux
package nengine

// Trying a hint's answer in a copy of the game wants fork(), which is Linux's
// here (hint_linux.odin). Elsewhere the harness says so.
@(private)
hint_fork :: proc(w: ^World, h: Hint, quiet: bool, on_bang: Bang) -> (verdict: string, ok: bool) {
	return "skipped: trying a hint needs Linux", false
}
