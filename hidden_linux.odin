#+build linux
package nengine

import "core:sys/linux"

// The kernel kills this process when its parent dies (PR_SET_PDEATHSIG).
// False if the parent is already gone, so nobody is waiting for this run.
@(private)
die_with_parent :: proc() -> bool {
	PR_SET_PDEATHSIG :: 1
	linux.syscall(linux.SYS_prctl, PR_SET_PDEATHSIG, int(linux.Signal.SIGKILL))
	return linux.getppid() != 1
}
