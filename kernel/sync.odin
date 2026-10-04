package kernel

import "base:intrinsics"

// Spinlocks. The kernel runs with interrupts off, so a lock never has to
// guard against an interrupt on its own CPU, only against the other CPUs.
//
// A ticket lock: a CPU takes the next ticket and waits for it to come up, so
// CPUs get the lock in the order they asked. All zeroes is an unlocked lock.

Spinlock :: struct {
	next:  u32, // the next ticket to hand out
	owner: u32, // the ticket that holds the lock
}

spin_lock :: proc "contextless" (l: ^Spinlock) {
	ticket := intrinsics.atomic_add_explicit(&l.next, 1, .Relaxed)
	for intrinsics.atomic_load_explicit(&l.owner, .Acquire) != ticket {
		arch_pause()
	}
}

spin_unlock :: proc "contextless" (l: ^Spinlock) {
	intrinsics.atomic_add_explicit(&l.owner, 1, .Release)
}
