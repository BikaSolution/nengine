package nengine

import "core:os"
import "core:strings"

// A file in this run's own temp folder ($TMPDIR, which `just test` makes
// fresh for every run), so two test runs at once never share a file.
test_tmp :: proc(name: string) -> string {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" do base = "/tmp"
	return strings.concatenate({base, "/", name}, context.temp_allocator)
}
