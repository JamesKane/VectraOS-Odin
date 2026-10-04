// lib/check on the ring's wake protocol (lib/ring, upstream 01 §4.3). A
// producer publishes entries and rings the doorbell when the consumer said it
// sleeps; the consumer drains the queue, announces it will sleep, rechecks,
// and sleeps until the doorbell rings. Ported from upstream's
// tests/host/ring_model_test.c.
//
// The protocol as written must hold in every interleaving, and so must one
// change to it: reading the doorbell count after announcing the sleep instead
// of before. (A ring in between follows a published tail, which the recheck
// sees, so the consumer never sleeps on it.) Four broken variants must each be
// caught: without the producer's fence, without the consumer's, without both,
// and without the recheck. A checker that cannot find those would prove
// nothing about the real one.
package check_test

import "core:fmt"
import "core:testing"
import "vx:check"

// Shared: the SQ tail, the consumer's NEED_WAKEUP, the doorbell counter.
TAIL :: 0
FLAG :: 1
DOORBELL :: 2

PRODUCER :: 0
CONSUMER :: 1

PRODUCED :: 0 // producer locals
SAW_FLAG :: 1
HEAD :: 0 // consumer locals
SEEN_BELL :: 1

// The variant under check. The step procedures take no user data, so these
// are globals, and the variants run one after another in one test.
entries: i64 // how many the producer publishes
producer_fence, consumer_fence, bell_before_flag, recheck: bool

init :: proc(s: ^check.State) {}

producer_step :: proc(c: ^check.Ctx) {
	t := check.me(c)
	switch t.pc {
	case 0: // write the entry, publish the tail
		if t.local[PRODUCED] == entries {
			t.done = true
			return
		}
		t.local[PRODUCED] += 1
		check.store(c, TAIL, t.local[PRODUCED])
		t.pc = 1 if producer_fence else 2
	case 1:
		check.fence(c)
		t.pc = 2
	case 2:
		t.local[SAW_FLAG] = check.load(c, FLAG)
		t.pc = 3
	case 3: // ring the doorbell if the consumer sleeps
		if t.local[SAW_FLAG] != 0 {
			check.kernel_add(c, DOORBELL, 1)
		}
		t.pc = 0
	}
}

consumer_step :: proc(c: ^check.Ctx) {
	t := check.me(c)
	switch t.pc {
	case 0: // drain
		if check.load(c, TAIL) != t.local[HEAD] {
			t.local[HEAD] += 1
			if t.local[HEAD] == entries {
				t.done = true
			}
			return
		}
		t.pc = 1 if bell_before_flag else 2
	case 1:
		t.local[SEEN_BELL] = check.kernel_load(c, DOORBELL)
		t.pc = 2 if bell_before_flag else 3
	case 2: // NEED_WAKEUP
		check.store(c, FLAG, 1)
		t.pc = 3 if bell_before_flag else 1
	case 3: // the fence (or straight on without one)
		if consumer_fence {
			check.fence(c)
		}
		t.pc = 4 if recheck else 5
	case 4: // recheck
		t.pc = 6 if check.load(c, TAIL) != t.local[HEAD] else 5
	case 5:
		check.kernel_wait_above(c, DOORBELL, t.local[SEEN_BELL])
		t.pc = 6
	case 6: // awake
		check.store(c, FLAG, 0)
		t.pc = 0
	}
}

step :: proc(c: ^check.Ctx) {
	if c.tid == PRODUCER {
		producer_step(c)
	} else {
		consumer_step(c)
	}
}

final_ok :: proc(s: ^check.State) -> (why: string, ok: bool) {
	if s.t[CONSUMER].done {
		return "", true
	}
	return "the consumer sleeps with entries waiting (a lost wake-up)", false
}

check_variant :: proc(name: string, n: i64, pfence, cfence, bell_first, check_again: bool) -> bool {
	entries = n
	producer_fence = pfence
	consumer_fence = cfence
	bell_before_flag = bell_first
	recheck = check_again
	m := check.Model {
		name     = name,
		threads  = 2,
		init     = init,
		step     = step,
		final_ok = final_ok,
	}
	return check.run(&m)
}

@(test)
test_ring_model :: proc(t: ^testing.T) {
	testing.expect(t, check_variant("ring wake protocol, 1 entry", 1, true, true, true, true))
	testing.expect(t, check_variant("ring wake protocol, 3 entries", 3, true, true, true, true))
	testing.expect(t, check_variant("doorbell read after the flag", 3, true, true, false, true))
	fmt.eprintf("vx-check: the next four are broken on purpose and must fail:\n")
	testing.expect(t, !check_variant("no producer fence", 2, false, true, true, true))
	testing.expect(t, !check_variant("no consumer fence", 2, true, false, true, true))
	testing.expect(t, !check_variant("no fences", 2, false, false, true, true))
	testing.expect(t, !check_variant("no recheck", 2, true, true, true, false))
}
