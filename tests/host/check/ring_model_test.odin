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

Variant :: struct {
	name:             string,
	entries:          i64, // how many the producer publishes
	producer_fence:   bool,
	consumer_fence:   bool,
	bell_before_flag: bool,
	recheck:          bool,
}

// The variant under check. The step procedures take no user data, so it is
// a global, and the variants run one after another in one test.
current: Variant

init :: proc(s: ^check.State) {}

producer_step :: proc(c: ^check.Ctx) {
	t := check.me(c)
	switch t.pc {
	case 0: // write the entry, publish the tail
		if t.local[PRODUCED] == current.entries {
			t.done = true
			return
		}
		t.local[PRODUCED] += 1
		check.store(c, TAIL, t.local[PRODUCED])
		t.pc = 1 if current.producer_fence else 2
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
			if t.local[HEAD] == current.entries {
				t.done = true
			}
			return
		}
		t.pc = 1 if current.bell_before_flag else 2
	case 1:
		t.local[SEEN_BELL] = check.kernel_load(c, DOORBELL)
		t.pc = 2 if current.bell_before_flag else 3
	case 2: // NEED_WAKEUP
		check.store(c, FLAG, 1)
		t.pc = 3 if current.bell_before_flag else 1
	case 3: // the fence (or straight on without one)
		if current.consumer_fence {
			check.fence(c)
		}
		t.pc = 4 if current.recheck else 5
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

check_variant :: proc(variant: Variant) -> bool {
	current = variant
	m := check.Model {
		name     = current.name,
		threads  = 2,
		init     = init,
		step     = step,
		final_ok = final_ok,
	}
	return check.run(&m)
}

@(test)
test_ring_model :: proc(t: ^testing.T) {
	holds := []Variant {
		{name = "ring wake protocol, 1 entry", entries = 1, producer_fence = true, consumer_fence = true, bell_before_flag = true, recheck = true},
		{name = "ring wake protocol, 3 entries", entries = 3, producer_fence = true, consumer_fence = true, bell_before_flag = true, recheck = true},
		{name = "doorbell read after the flag", entries = 3, producer_fence = true, consumer_fence = true, bell_before_flag = false, recheck = true},
	}
	broken := []Variant {
		{name = "no producer fence", entries = 2, producer_fence = false, consumer_fence = true, bell_before_flag = true, recheck = true},
		{name = "no consumer fence", entries = 2, producer_fence = true, consumer_fence = false, bell_before_flag = true, recheck = true},
		{name = "no fences", entries = 2, producer_fence = false, consumer_fence = false, bell_before_flag = true, recheck = true},
		{name = "no recheck", entries = 2, producer_fence = true, consumer_fence = true, bell_before_flag = true, recheck = false},
	}
	for variant in holds {
		testing.expectf(t, check_variant(variant), "%s: the checker found a violation", variant.name)
	}
	fmt.eprintf("vx-check: the next four are broken on purpose and must fail:\n")
	for variant in broken {
		testing.expectf(t, !check_variant(variant), "%s: the checker missed the violation", variant.name)
	}
}
