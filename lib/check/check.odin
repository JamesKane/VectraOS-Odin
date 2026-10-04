// An exhaustive interleaving model checker (upstream 04 §7), host only.
//
// A model is a few threads, each a state machine whose step procedure
// performs exactly one memory operation per call. The checker runs every
// possible order of those steps, and of the moments each thread's buffered
// stores reach memory, and checks the model's final condition in every state
// where nothing can move any more. A violation prints the interleaving that
// led to it.
//
// The memory model is a store-buffer model (TSO): a thread's stores wait in
// its own FIFO buffer, where its own loads see them, until a flush makes them
// visible to everyone; a fence (seq_cst) waits until its buffer is empty. That
// is the reordering behind lost wake-ups (the store-buffer litmus test), the
// one the ring protocol's fences exist to stop. It is not the whole C11
// model: the weaker reorderings ARM allows on top (load-load, load-store) are
// kept out of these protocols by their acquire and release orderings, which
// the models do not try to break. Kernel operations (kernel_*) act like
// syscalls: they drain the caller's buffer first, then act on memory
// atomically.
//
// States are remembered by 128-bit fingerprints, so a collision could hide a
// state; at these model sizes the odds are negligible.
//
// Host only, so it uses core: and the context's allocator.
package check

import "core:fmt"

MAX_THREADS :: 4
MAX_VARS :: 16
MAX_LOCALS :: 8
BUFFER :: 8 // stores a thread can have waiting
DEPTH :: 256 // steps before the checker gives up on a path

Thread :: struct {
	pc:           u32,
	done:         bool,
	buffered:     u8,
	buffer_var:   [BUFFER]u8,
	buffer_value: [BUFFER]i64,
	local:        [MAX_LOCALS]i64,
}

// Fingerprinted byte for byte, padding included: every State starts zeroed
// and is only ever copied whole, so equal states have equal bytes.
State :: struct {
	mem: [MAX_VARS]i64,
	t:   [MAX_THREADS]Thread,
}

// What a step procedure gets: the state to change and its thread. An
// operation whose precondition fails (a fence with stores waiting, a full
// buffer, a wait for a condition that does not hold) sets `blocked`: that step
// is not possible now, and the checker throws its effects away.
Ctx :: struct {
	s:       ^State,
	tid:     u32,
	blocked: bool,
}

Model :: struct {
	name:     string,
	threads:  u32,
	init:     proc(s: ^State),
	step:     proc(c: ^Ctx), // one operation of thread c.tid; sets its done at its end
	final_ok: proc(s: ^State) -> (why: string, ok: bool),
}

// --- Operations for step procedures ---

me :: proc(c: ^Ctx) -> ^Thread {
	return &c.s.t[c.tid]
}

load :: proc(c: ^Ctx, var: u32) -> i64 {
	t := me(c)
	for i := int(t.buffered) - 1; i >= 0; i -= 1 {
		if u32(t.buffer_var[i]) == var {
			return t.buffer_value[i] // its own newest store
		}
	}
	return c.s.mem[var]
}

store :: proc(c: ^Ctx, var: u32, value: i64) {
	t := me(c)
	if t.buffered == BUFFER {
		c.blocked = true
		return
	}
	t.buffer_var[t.buffered] = u8(var)
	t.buffer_value[t.buffered] = value
	t.buffered += 1
}

fence :: proc(c: ^Ctx) {
	if me(c).buffered != 0 {
		c.blocked = true
	}
}

kernel_load :: proc(c: ^Ctx, var: u32) -> i64 {
	fence(c)
	return c.s.mem[var]
}

kernel_add :: proc(c: ^Ctx, var: u32, delta: i64) {
	fence(c)
	c.s.mem[var] += delta
}

// Sleeps until mem[var] > seen (a port_wait on a .Counter_Ge binding).
kernel_wait_above :: proc(c: ^Ctx, var: u32, seen: i64) {
	fence(c)
	if c.s.mem[var] <= seen {
		c.blocked = true
	}
}

// --- The checker ---

@(private="file")
Action_Kind :: enum u8 {
	Step, // the thread steps
	Flush, // the thread's oldest store reaches memory
}

@(private="file")
Action :: struct {
	kind: Action_Kind,
	tid:  u8,
}

@(private="file")
Search :: struct {
	m:          ^Model,
	seen:       []u64, // fingerprints, two words each, 0 0 meaning empty
	seen_cap:   u64,
	seen_count: u64,
	states:     u64,
	finals:     u64,
	truncated:  u64,
	path:       [DEPTH]Action,
	failed:     bool,
}

@(private="file")
fingerprint :: proc(s: ^State) -> (fp: [2]u64) {
	p := ([^]u8)(s)[:size_of(State)]
	a, b := u64(0xcbf29ce484222325), u64(0x84222325cbf29ce4)
	for byte in p {
		a = (a ~ u64(byte)) * 0x100000001b3
		b = (b ~ u64(byte)) * 0x9e3779b97f4a7c15
		b ~= b >> 29
	}
	return {a | 1, b} // never 0: 0 0 marks an empty slot
}

// True if the state was new (and is now remembered).
@(private="file")
remember :: proc(r: ^Search, s: ^State) -> bool {
	if r.seen_count * 2 >= r.seen_cap { // grow at half full
		old_cap, old := r.seen_cap, r.seen
		r.seen_cap = old_cap * 2 if old_cap != 0 else 1 << 16
		r.seen = make([]u64, r.seen_cap * 2)
		for i in 0 ..< old_cap {
			if old[2 * i] == 0 {
				continue
			}
			j := old[2 * i] & (r.seen_cap - 1)
			for r.seen[2 * j] != 0 {
				j = (j + 1) & (r.seen_cap - 1)
			}
			r.seen[2 * j] = old[2 * i]
			r.seen[2 * j + 1] = old[2 * i + 1]
		}
		delete(old)
	}
	fp := fingerprint(s)
	j := fp[0] & (r.seen_cap - 1)
	for r.seen[2 * j] != 0 {
		if r.seen[2 * j] == fp[0] && r.seen[2 * j + 1] == fp[1] {
			return false
		}
		j = (j + 1) & (r.seen_cap - 1)
	}
	r.seen[2 * j] = fp[0]
	r.seen[2 * j + 1] = fp[1]
	r.seen_count += 1
	return true
}

// Tries action a on a copy of s. Returns false if it is not possible now.
@(private="file")
apply :: proc(r: ^Search, s: ^State, a: Action, out: ^State) -> bool {
	out^ = s^
	t := &out.t[a.tid]
	if a.kind == .Flush {
		if t.buffered == 0 {
			return false
		}
		out.mem[t.buffer_var[0]] = t.buffer_value[0]
		t.buffered -= 1
		n := int(t.buffered)
		copy(t.buffer_var[:n], t.buffer_var[1:n + 1])
		copy(t.buffer_value[:n], t.buffer_value[1:n + 1])
		t.buffer_var[n] = 0 // keep fingerprints canonical
		t.buffer_value[n] = 0
		return true
	}
	if t.done {
		return false
	}
	c := Ctx{s = out, tid = u32(a.tid)}
	r.m.step(&c)
	return !c.blocked
}

@(private="file")
report :: proc(r: ^Search, depth: u32, why: string) {
	fmt.eprintf("vx-check: %s: violation: %s\n  interleaving:", r.m.name, why)
	for a in r.path[:depth] {
		fmt.eprintf(" %s%d", "flush" if a.kind == .Flush else "T", a.tid)
	}
	fmt.eprintf("\n")
}

// Depth-first over every interleaving, iteratively (no recursion, as in the
// rest of the tree), with one frame per step on the current path.
@(private="file")
explore :: proc(r: ^Search, start: ^State) {
	Frame :: struct {
		s:    State,
		next: u32, // the next action to try: tid * 2 + kind
		any:  bool, // some action was possible here
	}
	stack := make([]Frame, DEPTH + 1)
	defer delete(stack)
	depth := u32(0)
	stack[0].s = start^
	remember(r, start)
	r.states += 1
	for {
		f := &stack[depth]
		moved := false
		for f.next < r.m.threads * 2 {
			a := Action{kind = Action_Kind(f.next % 2), tid = u8(f.next / 2)}
			f.next += 1
			n: State
			if !apply(r, &f.s, a, &n) {
				continue
			}
			f.any = true
			if !remember(r, &n) {
				continue // reached before, by another order
			}
			r.states += 1
			if depth + 1 == DEPTH {
				r.truncated += 1
				continue
			}
			r.path[depth] = a
			depth += 1
			stack[depth] = {s = n}
			moved = true
			break
		}
		if moved {
			continue
		}
		if !f.any { // nothing could move here: a final state
			r.finals += 1
			why, ok := r.m.final_ok(&f.s)
			if !ok && !r.failed {
				r.failed = true
				report(r, depth, why)
			}
		}
		if depth == 0 {
			break
		}
		depth -= 1
	}
}

// Explores every interleaving of the model. Returns true if no final state
// broke its condition and no path was cut short, and prints what it covered.
run :: proc(m: ^Model) -> bool {
	r := Search{m = m}
	s: State
	m.init(&s)
	explore(&r, &s)
	fmt.eprintf("vx-check: %s: %d states, %d final, %d cut at the depth bound: %s\n", m.name, r.states, r.finals, r.truncated, "VIOLATION" if r.failed else "ok")
	delete(r.seen)
	return !r.failed && r.truncated == 0
}
