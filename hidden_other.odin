#+build !linux
package nengine

// Elsewhere there is no parent-death signal to ask for; the time limit
// (hidden_overdue) is the only guard.
@(private)
die_with_parent :: proc() -> bool {
	return true
}
