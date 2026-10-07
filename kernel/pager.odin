package kernel

import "base:intrinsics"
import vx "abi:vx"

// Pagers: a trusted task's supply of pages for VMOs. fsd backs mmap of files
// with one.
//
// A pager-backed VMO starts with no pages. A user fault on one of them
// (pager_fault, from exception_raise) asks the pager for it: a packet on the
// pager's port, sent once however many threads fault on the page, and the
// faulting thread waits. pager_supply copies the pages in and wakes the
// waiters, which map them as their faults are taken again. A page that does
// not come by the pager's deadline is the thread's .Pager_Timeout instead,
// never a hang; the next fault on it asks again.
//
// Faults are resolved one page at a time, mapping only the faulting page: a
// mapping of a pager-backed VMO maps what is supplied when it is made, and
// the rest as it is touched. A page is mapped read-only, even in a writable
// mapping, until it is written: that write faults, marks it dirty and maps it
// writable, which is how the pager learns what to write back (pager_op
// .Dirty). Cleaning takes the pages out of every mapping, so the next write
// marks them again. The kernel's own copies to and from user memory take no
// page that is not there yet: they fail, as on a page that is not mapped,
// since some are made under locks.

Pager :: struct {
	using obj: Object,
	port:      ^Port, // where page requests go, held
	key:       u64,
	deadline:  Instant, // how long a fault waits for its page
}

#assert(offset_of(Pager, obj) == 0) // objects are cast from ^Object

// A thread waiting for a page of a VMO, on its waiters list, on its own stack.
Page_Waiter :: struct {
	next:   ^Page_Waiter,
	thread: ^Thread,
}

pager_pool: Pool(Pager)

@(require_results)
pager_create :: proc "contextless" (p: ^Port, key: u64, deadline: Instant) -> (^Pager, vx.Status) {
	if deadline == 0 {
		return nil, .Err_Invalid
	}
	g := pool_alloc(&pager_pool)
	if g == nil {
		return nil, .Err_No_Memory
	}
	object_init(&g.obj, .Pager)
	object_ref(&p.obj)
	g.port, g.key, g.deadline = p, key, deadline
	return g, .Ok
}

pager_destroy :: proc "contextless" (g: ^Pager) {
	object_drop(&g.port.obj)
	pool_free(&pager_pool, g)
}

// A VMO of `want` bytes whose pages g supplies, none yet.
@(require_results)
vmo_create_pager :: proc "contextless" (want: u64, g: ^Pager, key: u32) -> (v: ^Vmo, st: vx.Status) {
	if want == 0 || want > VMO_MAX_SIZE {
		return nil, .Err_Range
	}
	v = vmo_alloc(page_up(want) / PAGE_SIZE) or_return
	intrinsics.mem_zero(raw_data(v.pages), PAGE_SIZE << v.list_order) // the whole list: a resize may grow into it
	object_ref(&g.obj)
	v.pager, v.pager_key = g, key
	return v, .Ok
}

Pager_Result :: enum u8 {
	Not_Mine, // not a pager-backed page, or not an access its mapping allows: an ordinary fault
	Mapped, // the page is mapped: the access may be made again
	Timeout, // the pager did not supply it in time
	Killed, // the thread was killed (or interrupted) while it waited
}

// Wakes every thread waiting on v's pages, to look again. Under v's lock.
@(private="file")
wake_waiters :: proc "contextless" (v: ^Vmo) {
	for w := v.waiters; w != nil; {
		next := w.next // the waiter's frame may go once it runs
		_ = thread_wake_token(w.thread, w, .Ok)
		w = next
	}
	v.waiters = nil
}

// The mapping in t that holds address, or nil. Under t's lock.
@(private="file")
mapping_at :: proc "contextless" (t: ^Task, address: Uva) -> ^Mapping {
	if t.maps == nil {
		return nil
	}
	for &m in t.maps {
		if m.size != 0 && address >= m.va && address < m.va + Uva(m.size) {
			return &m
		}
	}
	return nil
}

// A user fault at address (access: read 0, write 1, execute 2) in the
// current task: resolved here if it is on a pager-backed mapping.
pager_fault :: proc "contextless" (address: u64, access: u32) -> Pager_Result {
	th := this_cpu().current
	t := th.task
	page_va := Uva(address) &~ (PAGE_SIZE - 1)
	deadline: Instant // set at the first wait, and kept: a supply of other pages does not extend it
	for {
		spin_lock(&t.lock)
		m := mapping_at(t, Uva(address))
		if m == nil || m.vmo.pager == nil || .No_Access in m.flags || (access == 1 && .Write not_in m.flags) || (access == 2 && .Exec not_in m.flags) {
			spin_unlock(&t.lock)
			return .Not_Mine
		}
		v := m.vmo
		index := (m.offset + u64(page_va - m.va)) / PAGE_SIZE
		spin_lock(&v.lock)
		if index >= v.size / PAGE_SIZE { // past its end, since it shrank: an ordinary fault
			spin_unlock(&v.lock)
			spin_unlock(&t.lock)
			return .Not_Mine
		}
		if pa := vmo_page(v, index); pa != 0 {
			// Supplied: mapped here now (another thread may have done it
			// first), dirty if written.
			if access == 1 {
				v.pages[index].dirty = true
			}
			e, _ := leaf_entry(t.root, u64(page_va))
			upgrade := e != nil && access == 1 && !arch_pte_user_ok(e^, true) // read-only until now
			if upgrade {
				unmap_page(t.root, u64(page_va))
			}
			ok := (e != nil && !upgrade) || map_range(t.root, u64(page_va), pa, PAGE_SIZE, page_map_flags(v, m.flags, v.pages[index]), m.key)
			root := t.root
			spin_unlock(&v.lock)
			spin_unlock(&t.lock)
			if upgrade {
				arch_tlb_shootdown(root, page_va, PAGE_SIZE) // no CPU keeps the read-only translation
			}
			return ok ? .Mapped : .Not_Mine // no memory for a table: the fault stands
		}
		// Not there: ask for it, if no one has, and wait.
		ask := !v.pages[index].asked
		if ask {
			v.pages[index].asked = true
		}
		w := Page_Waiter{next = v.waiters, thread = th}
		v.waiters = &w
		th.wait_token = &w
		object_ref(&v.obj)
		g := v.pager
		spin_unlock(&v.lock)
		spin_unlock(&t.lock)
		asked := vx.Status.Ok
		if ask {
			asked = port_post(g.port, {key = g.key, value = index * PAGE_SIZE, timestamp = vx.Instant(clock_now()), source = v.pager_key, trigger = .Pager})
		}
		if deadline == 0 {
			deadline = clock_now() + g.deadline
		}
		// A request the port had no room for is not lost: the page is left
		// unasked, and this thread asks again shortly, until its deadline.
		until := deadline
		if asked != .Ok {
			spin_lock(&v.lock)
			if v.pages[index].asked { // asked, never supplied: a supplied entry is the page alone
				v.pages[index] = {}
			}
			spin_unlock(&v.lock)
			if clock_now() + 1_000_000 < deadline {
				until = clock_now() + 1_000_000
			}
		}
		woke := thread_block(until, 0)
		if woke == .Err_Timed_Out && until != deadline {
			woke = .Ok // only the retry's wait
		}
		spin_lock(&v.lock)
		unlink(&v.waiters, &w, "next")
		supplied := vmo_page(v, index) != 0
		if !supplied && woke == .Err_Timed_Out && v.pages[index].asked {
			v.pages[index] = {} // the next fault asks again
		}
		spin_unlock(&v.lock)
		object_release(&v.obj)
		switch {
		case supplied:
			continue // mapped on the next pass
		case woke == .Err_Timed_Out:
			return .Timeout
		case woke != .Ok:
			return .Killed
		}
	}
}

// pager_supply: v's pages [offset, offset + size) from src's, where v has none.
@(require_results)
pager_supply :: proc "contextless" (g: ^Pager, v: ^Vmo, offset, size: u64, src: ^Vmo, src_offset: u64) -> vx.Status {
	if v.pager != g {
		return .Err_Invalid
	}
	if src.pager != nil || src.physical {
		return .Err_Unsupported // from anonymous memory only
	}
	end, overflow := intrinsics.overflow_add(offset, size)
	src_end, src_overflow := intrinsics.overflow_add(src_offset, size)
	if size == 0 || (offset | size | src_offset) & (PAGE_SIZE - 1) != 0 || overflow || end > v.size || src_overflow || src_end > src.size {
		return .Err_Range
	}
	// The new pages first, outside the lock: allocation may take a while.
	st := vx.Status.Ok
	for i in 0 ..< size / PAGE_SIZE {
		pa := phys_alloc(0)
		if pa == 0 {
			st = .Err_No_Memory
			break
		}
		page_copy(pa, vmo_page(src, src_offset / PAGE_SIZE + i))
		at := offset / PAGE_SIZE + i
		spin_lock(&v.lock)
		// Past the end now (a shrink since the check above): not kept.
		taken := at >= v.size / PAGE_SIZE || vmo_page(v, at) != 0
		if !taken {
			v.pages[at] = page_of(pa)
		}
		spin_unlock(&v.lock)
		if taken {
			phys_free(pa, 0) // supplied already: it stays as it was
		}
	}
	// Every waiter tries again: those whose pages came map them, the rest wait on.
	spin_lock(&v.lock)
	wake_waiters(v)
	spin_unlock(&v.lock)
	return st
}

// --- Taking pages out of mappings ---

// Pages [first, first + count) of v, out of every task's mappings of it, and
// out of every CPU's TLB: the next touch faults (pager_fault). A revoked
// lease's too (vmo_revoke, ADR-0021).
@(private)
vmo_unmap_everywhere :: proc "contextless" (v: ^Vmo, first, count: u64) {
	Span :: struct {
		va:   Uva,
		size: u64,
	}
	last_id: u64
	for {
		t: ^Task // the task with the next id
		held := false
		{
			spin_guard(&all_tasks_lock)
			for c := all_tasks; c != nil; c = c.all_next {
				if c.id > last_id && (t == nil || c.id < t.id) {
					t = c
				}
			}
			if t == nil {
				return
			}
			held = object_tryref(&t.obj) // one going away is skipped: its mappings go with it
			last_id = t.id
		}
		if !held {
			continue
		}
		spans: [dynamic; TASK_MAX_MAPPINGS / 8]Span
		spin_lock(&t.lock)
		if t.maps != nil {
			for &m in t.maps {
				if m.size == 0 || m.vmo != v {
					continue
				}
				m_first := m.offset / PAGE_SIZE
				m_end := m_first + m.size / PAGE_SIZE
				a, b := max(first, m_first), min(first + count, m_end)
				if a >= b {
					continue
				}
				va := m.va + Uva((a - m_first) * PAGE_SIZE)
				for p in 0 ..< b - a {
					unmap_page(t.root, u64(va) + p * PAGE_SIZE)
				}
				if append(&spans, Span{va, (b - a) * PAGE_SIZE}) == 0 {
					clear(&spans) // many: all of it
					_ = append(&spans, Span{0, u64(USER_TOP)})
				}
			}
		}
		root := t.root
		spin_unlock(&t.lock)
		if root != 0 {
			for s in spans {
				arch_tlb_shootdown(root, s.va, s.size)
			}
		}
		object_release(&t.obj)
	}
}

// Whether any task maps v, or a lease of it, writable (vmo_seal, ADR-0021):
// task by task in id order, as vmo_unmap_everywhere goes, each held while
// its mappings are looked at.
vmo_mapped_writable :: proc "contextless" (v: ^Vmo) -> bool {
	last_id: u64
	for {
		t: ^Task // the task with the next id
		held := false
		{
			spin_guard(&all_tasks_lock)
			for c := all_tasks; c != nil; c = c.all_next {
				if c.id > last_id && (t == nil || c.id < t.id) {
					t = c
				}
			}
			if t == nil {
				return false
			}
			held = object_tryref(&t.obj)
			last_id = t.id
		}
		if !held {
			continue
		}
		found := false
		spin_lock(&t.lock)
		if t.maps != nil {
			for m in t.maps {
				if m.size != 0 && .Write in m.flags && vmo_root(m.vmo) == v {
					found = true
					break
				}
			}
		}
		spin_unlock(&t.lock)
		object_release(&t.obj)
		if found {
			return true
		}
	}
}

// --- pager_op ---

// .Dirty: the dirty pages of [offset, offset + size) as ranges, into out
// (PAGER_RANGES of them at most).
pager_dirty :: proc "contextless" (v: ^Vmo, offset, size: u64, out: ^[dynamic; vx.PAGER_RANGES]vx.Pager_Range) {
	spin_guard(&v.lock)
	end := min((offset + size) / PAGE_SIZE, v.size / PAGE_SIZE)
	for i := offset / PAGE_SIZE; i < end && len(out) < vx.PAGER_RANGES; i += 1 {
		if vmo_page(v, i) == 0 || !v.pages[i].dirty {
			continue
		}
		if n := len(out); n > 0 && out[n - 1].offset + out[n - 1].size == i * PAGE_SIZE {
			out[n - 1].size += PAGE_SIZE
		} else {
			_ = append(out, vx.Pager_Range{offset = i * PAGE_SIZE, size = PAGE_SIZE}) // below PAGER_RANGES
		}
	}
}

// .Clean: [first, first + count) clean, and write-protected everywhere, so
// that a write from now on marks it dirty again. The pager cleans before it
// reads a range to write it back: a write that lands before the clean is in
// what it reads, one after it is dirty for the next time.
pager_clean :: proc "contextless" (v: ^Vmo, first, count: u64) {
	spin_lock(&v.lock)
	for i := first; i < first + count && i < v.size / PAGE_SIZE; i += 1 {
		if vmo_page(v, i) != 0 {
			v.pages[i].dirty = false
		}
	}
	spin_unlock(&v.lock)
	vmo_unmap_everywhere(v, first, count)
}

// Frees pages that have left every mapping: what evicting or shrinking took.
@(private="file")
free_pages :: proc "contextless" (pages: []Paddr) {
	for pa in pages {
		phys_free(pa, 0)
	}
}

// .Evict: the clean pages of [first, first + count) freed, absent again (a
// later touch asks the pager for them). A page is made absent before it
// leaves the mappings, and freed only after, so nothing maps a freed page.
pager_evict :: proc "contextless" (v: ^Vmo, first, count: u64) {
	for at := first; at < first + count; {
		freed: [dynamic; 64]Paddr
		from := at
		spin_lock(&v.lock)
		for ; at < first + count && at < v.size / PAGE_SIZE && len(freed) < 64; at += 1 {
			pa := vmo_page(v, at)
			if pa == 0 || v.pages[at].dirty {
				continue
			}
			_ = append(&freed, pa) // below 64
			v.pages[at] = {}
		}
		past := at >= v.size / PAGE_SIZE
		spin_unlock(&v.lock)
		vmo_unmap_everywhere(v, from, at - from)
		free_pages(freed[:])
		if past {
			break
		}
	}
}

// --- Resizing ---

// A pager-backed or resizable VMO's new size: pages past it out of the
// mappings and freed; pages added absent (a pager's) or zero (a resizable
// one's, ADR-0020). Its page list is made again if it outgrows it.
@(require_results)
vmo_resize :: proc "contextless" (v: ^Vmo, want: u64) -> vx.Status {
	if !vmo_locked(v) {
		return .Err_Unsupported // read without its lock: made {.Resizable} to resize
	}
	if want == 0 || want > VMO_MAX_SIZE {
		return .Err_Range
	}
	size := page_up(want)
	count := size / PAGE_SIZE
	order := order_for(count * size_of(Page))
	list: Paddr
	if order > v.list_order {
		list = phys_alloc_zeroed(order)
		if list == 0 {
			return .Err_No_Memory
		}
	}
	spin_lock(&v.lock)
	if v.resizing { // one at a time: a shrink drops the lock between its steps
		spin_unlock(&v.lock)
		if list != 0 {
			phys_free(list, order)
		}
		return .Err_Bad_State
	}
	v.resizing = true
	old := v.size / PAGE_SIZE
	if count < old {
		// Faults and new mappings past the end are refused from now on
		// (pager_fault, task_map). Then the pages past it, a batch at a time:
		// each made absent under the lock, out of every mapping, and only
		// then freed, so no mapping is ever left on a freed page (as .Evict
		// does).
		v.size = size
		for at := count; at < old; {
			freed: [dynamic; 64]Paddr
			from := at
			for ; at < old && len(freed) < 64; at += 1 {
				if pa := vmo_page(v, at); pa != 0 {
					_ = append(&freed, pa) // below 64
				}
				v.pages[at] = {}
			}
			spin_unlock(&v.lock)
			vmo_unmap_everywhere(v, from, at - from)
			free_pages(freed[:])
			spin_lock(&v.lock)
		}
	}
	old_list, old_order := Paddr(0), v.list_order
	pages := raw_data(v.pages)
	if list != 0 { // a bigger list: what there is, moved over (past the old end, every entry is empty)
		pages = cast([^]Page)phys_to_virt(list)
		copy(pages[:min(old, count)], v.pages[:min(old, count)])
		old_list = virt_to_phys(raw_data(v.pages))
		v.list_order = order
	}
	v.pages = pages[:count] // the block holds it: entries past the old end are empty, or filled below
	// A resizable VMO's new pages, zero; if memory runs out, it keeps the
	// size it reached.
	st := vx.Status.Ok
	if v.resizable {
		for i in old ..< count {
			pa := phys_alloc_zeroed(0)
			if pa == 0 {
				v.pages = pages[:i]
				size = i * PAGE_SIZE
				st = .Err_No_Memory
				break
			}
			v.pages[i] = page_of(pa)
		}
	}
	if size > v.size || !v.resizable {
		v.size = size
	}
	v.resizing = false
	wake_waiters(v) // they look again: one whose page is now past the end faults as usual
	spin_unlock(&v.lock)
	if old_list != 0 {
		phys_free(old_list, old_order)
	}
	return st
}
