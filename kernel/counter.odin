package kernel

import "base:intrinsics"
import vx "abi:vx"

// Counters, the kernel's monotonic timelines: counter_signal sets one to the
// larger of its value and the one given, and fires the COUNTER_GE bindings
// that value reaches. Ring doorbells are counters.

Counter :: struct {
	using obj: Object,
	lock:      Spinlock,
	value:     u64,
	obs:       Observers,
}

#assert(offset_of(Counter, obj) == 0) // objects are cast from ^Object

counter_pool: Pool(Counter)

@(require_results)
counter_create :: proc "contextless" (initial: u64) -> (^Counter, vx.Status) {
	c := pool_alloc(&counter_pool)
	if c == nil {
		return nil, .Err_No_Memory
	}
	object_init(&c.obj, .Counter)
	c.value = initial
	return c, .Ok
}

counter_signal :: proc "contextless" (c: ^Counter, v: u64) {
	spin_lock(&c.lock)
	defer spin_unlock(&c.lock)
	if v > c.value {
		c.value = v
		observers_fire(&c.obs, .Counter_Ge, v)
	}
}

// Adds to the counter (a doorbell rings by one), firing what the new value reaches.
counter_add :: proc "contextless" (c: ^Counter, delta: u64) {
	spin_lock(&c.lock)
	defer spin_unlock(&c.lock)
	c.value += delta
	observers_fire(&c.obs, .Counter_Ge, c.value)
}

counter_read :: proc "contextless" (c: ^Counter) -> u64 {
	spin_lock(&c.lock)
	defer spin_unlock(&c.lock)
	return c.value
}

@(require_results)
counter_bind :: proc "contextless" (c: ^Counter, b: ^Binding) -> vx.Status {
	if b.trigger != .Counter_Ge {
		return .Err_Invalid
	}
	spin_lock(&c.lock)
	defer spin_unlock(&c.lock)
	if c.value >= b.threshold {
		binding_fire(b, c.value)
	} else {
		observers_add(&c.obs, b)
	}
	return .Ok
}

counter_destroy :: proc "contextless" (c: ^Counter) {
	spin_lock(&c.lock)
	bindings := c.obs.head
	spin_unlock(&c.lock)
	observers_free(bindings)
	pool_free(&counter_pool, c)
}

// --- Futexes ---
//
// A futex is keyed on the physical address of its word, so the same word
// mapped into two tasks is one futex. Waiters hash into buckets, each with
// its own lock. futex_wait checks the word under the bucket's lock, so a
// futex_wake that changes the word first is never missed.

@(private="file")
FUTEX_BUCKETS :: 64

@(private="file")
Futex_Waiter :: struct {
	next:   ^Futex_Waiter,
	thread: ^Thread,
	key:    Paddr, // the word's
}

@(private="file")
Futex_Bucket :: struct {
	lock: Spinlock,
	head: ^Futex_Waiter,
}

@(private="file")
futex_buckets: [FUTEX_BUCKETS]Futex_Bucket

@(private="file")
futex_bucket :: proc "contextless" (key: Paddr) -> u32 {
	return u32(((u64(key) >> 2) * 0x9e3779b97f4a7c15) >> 58)
}

// Blocks while *word (a user address, in the current task) holds `expected`,
// until futex_wake or the deadline. .Err_Bad_State if the word already differs.
@(require_results)
futex_wait :: proc "contextless" (word: Uva, expected: u32, deadline: Instant) -> vx.Status {
	if word & 3 != 0 || word >= USER_TOP {
		return .Err_Invalid
	}
	t := this_cpu().current
	key := user_page_pa(t.task.root, word)
	if key == 0 || !in_direct_map(key, 4) { // device memory has no direct mapping
		return .Err_Invalid
	}
	b := &futex_buckets[futex_bucket(key)]
	w := Futex_Waiter{thread = t, key = key}
	spin_lock(&b.lock)
	// Read through the task's own mapping, not the page: if another thread has
	// unmapped the word since, the load fails rather than read a freed page.
	now, mapped := user_load32(word)
	if !mapped {
		spin_unlock(&b.lock)
		return .Err_Invalid
	}
	if now != expected {
		spin_unlock(&b.lock)
		return .Err_Bad_State
	}
	t.wait_token = &w
	w.next = b.head
	b.head = &w
	spin_unlock(&b.lock)

	woke := thread_block(deadline, 0)
	if woke != .Ok { // timed out or killed: leave the bucket if a waker has not taken us
		spin_lock(&b.lock)
		unlink(&b.head, &w, "next")
		spin_unlock(&b.lock)
	}
	return woke
}

// Wakes up to `count` threads waiting on *word. Returns how many it woke.
@(require_results)
futex_wake :: proc "contextless" (word: Uva, count: u32) -> (woken: u32, st: vx.Status) {
	if word & 3 != 0 {
		return 0, .Err_Invalid
	}
	key := user_page_pa(this_cpu().current.task.root, word)
	if key == 0 {
		return 0, .Err_Invalid
	}
	b := &futex_buckets[futex_bucket(key)]
	spin_lock(&b.lock)
	link := &b.head
	for link^ != nil && woken < count {
		w := link^
		if w.key != key {
			link = &w.next
			continue
		}
		link^ = w.next
		if thread_wake_token(w.thread, w, .Ok) {
			woken += 1
		}
	}
	spin_unlock(&b.lock)
	return woken, .Ok
}
