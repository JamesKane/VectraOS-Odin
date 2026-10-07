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
// A futex is keyed on the VMO that holds its word and the word's offset in
// it (ADR-0015, upstream's ADR-0037), so the same word mapped into two tasks
// is one futex, and a pager's page evicted and supplied again elsewhere keeps
// its key. Waiters hash into buckets, each with its own lock. futex_wait
// checks the word under the bucket's lock, so a futex_wake that changes the
// word first is never missed.
//
// Robust futexes (Linux's layout): a thread registers a list of the locks it
// holds, and as it ends the kernel marks each one it still owns OWNER_DIED
// and wakes a waiter.

@(private="file")
FUTEX_BUCKETS :: 64

@(private="file")
Futex_Key :: struct {
	vmo:    ^Vmo, // the VMO the word is in: compared, never followed
	offset: u64, // the word's offset in it
}

@(private="file")
Futex_Waiter :: struct {
	next:   ^Futex_Waiter,
	thread: ^Thread,
	key:    Futex_Key,
}

@(private="file")
Futex_Bucket :: struct {
	lock: Spinlock,
	head: ^Futex_Waiter,
}

@(private="file")
futex_buckets: [FUTEX_BUCKETS]Futex_Bucket

@(private="file")
futex_bucket :: proc "contextless" (k: Futex_Key) -> u32 {
	return u32((((u64(uintptr(k.vmo)) >> 4) ~ (k.offset >> 2)) * 0x9e3779b97f4a7c15) >> 58)
}

// The key of the word at user address word in task t, and whether its page
// is present. ok is false if no mapping holds it, or it is device memory.
@(private="file")
futex_key_of :: proc "contextless" (t: ^Task, word: Uva) -> (k: Futex_Key, present, ok: bool) {
	spin_guard(&t.lock)
	if t.maps == nil {
		return
	}
	for &m in t.maps {
		if m.size == 0 || word < m.va || u64(word - m.va) >= m.size || m.vmo.physical {
			continue
		}
		k = {
			vmo    = vmo_root(m.vmo), // a lease's: its parent's, so both are one futex
			offset = m.offset + u64(word - m.va),
		}
		ok = true
		break
	}
	present = ok && t.root != 0 && user_page_pa(t.root, word) != 0
	return
}

// Blocks while *word (a user address, in the current task) holds `expected`,
// until futex_wake or the deadline. .Err_Bad_State if the word already
// differs, or its page is absent (a pager's, evicted): the caller loads it,
// which brings the page back, and asks again.
@(require_results)
futex_wait :: proc "contextless" (word: Uva, expected: u32, deadline: Instant) -> vx.Status {
	if word & 3 != 0 || word >= USER_TOP {
		return .Err_Invalid
	}
	t := this_cpu().current
	key, present, found := futex_key_of(t.task, word)
	if !found {
		return .Err_Invalid
	}
	if !present {
		return .Err_Bad_State
	}
	b := &futex_buckets[futex_bucket(key)]
	w := Futex_Waiter{thread = t, key = key}
	spin_lock(&b.lock)
	// Read through the task's own mapping, not the page: if another thread has
	// unmapped the word since, the load fails rather than read a freed page.
	now, mapped := user_load32(word)
	if !mapped {
		spin_unlock(&b.lock)
		return .Err_Bad_State
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
	if word & 3 != 0 || word >= USER_TOP {
		return 0, .Err_Invalid
	}
	key, _, found := futex_key_of(this_cpu().current.task, word)
	if !found {
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

// --- Robust futexes ---

@(private="file")
ROBUST_LIST_LIMIT :: 2048 // entries walked at most: the list is the thread's memory

// A robust list's head, Linux's.
@(private="file")
Robust_Head :: struct {
	next:    u64, // the first entry; bit 0, Linux's mark for a PI lock, of which there are none
	offset:  i64, // from an entry to its lock word
	pending: u64, // the entry being added or taken off, or 0
}

// One lock word of a thread that has ended: OWNER_DIED, waiters kept, and
// one of them woken, if the word is still the thread's.
@(private="file")
futex_owner_died :: proc "contextless" (word: Uva, owner: u32) {
	if word & 3 != 0 || word >= USER_TOP {
		return
	}
	seen, mapped := user_load32(word)
	if !mapped {
		return
	}
	for _ in 0 ..< 64 { // another thread changing it each time: hostile, let go
		if seen & vx.FUTEX_OWNER_MASK != owner {
			return
		}
		now, ok := user_cas32(word, seen, (seen & vx.FUTEX_WAITERS) | vx.FUTEX_OWNER_DIED)
		if !ok {
			return
		}
		if now == seen {
			if seen & vx.FUTEX_WAITERS != 0 {
				_, _ = futex_wake(word, 1)
			}
			return
		}
		seen = now
	}
}

// Walks thread th's robust list, which is in the current address space, and
// unregisters it. A bad pointer ends the walk.
futex_robust_walk :: proc "contextless" (th: ^Thread) {
	head, owner := th.robust_head, th.robust_owner
	th.robust_head = 0
	if head == 0 {
		return
	}
	h: Robust_Head
	if copy_in(&h, head) != .Ok {
		return
	}
	pending := Uva(h.pending &~ 1)
	entry := Uva(h.next &~ 1)
	for n := 0; entry != head && n < ROBUST_LIST_LIMIT; n += 1 {
		next: u64
		if copy_in(&next, entry) != .Ok {
			break
		}
		if entry != pending {
			futex_owner_died(entry + Uva(h.offset), owner)
		}
		entry = Uva(next &~ 1)
	}
	if h.pending != 0 {
		futex_owner_died(pending + Uva(h.offset), owner)
	}
}

// thread_set_robust(head, size, owner): the calling thread's robust list.
@(require_results)
sys_thread_set_robust :: proc "contextless" (head: Uva, size, owner: u64) -> vx.Status {
	if head != 0 && (size != size_of(Robust_Head) || head & 7 != 0 || head >= USER_TOP || owner == 0 || owner > u64(vx.FUTEX_OWNER_MASK)) {
		return .Err_Invalid
	}
	th := this_cpu().current
	th.robust_head, th.robust_owner = head, u32(owner)
	return .Ok
}
