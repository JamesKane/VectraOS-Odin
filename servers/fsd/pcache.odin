package fsd

// The page cache (upstream docs/11 §8, docs/proto/map.md). fsd is the
// system's pager when its manifest gives it `pager`: Tmap answers with a
// pager-backed VMO for the whole file, one per file however many map it,
// which the kernel asks fsd to fill a page at a time. Pages written through
// mappings are written back before each commit, and before a Tread of the
// file, so reads see them; a Twrite goes to the pages there as well as to
// the volume. An entry stays until nothing but fsd refers to its VMO, and
// keeps its file open until then, as a mapping keeps a removed file's data
// in POSIX.

import "base:intrinsics"
import vx "abi:vx"
import "vx:fs"
import "vx:memory"
import "vx:p9"
import "vx:p9ring"
import "vx:rt"

MAX_CACHED :: 64 // files mapped at once
SUPPLY_DEADLINE :: vx.Duration(10_000_000_000) // longer than any commit takes
PAGER_KEY :: p9ring.KEY_USER | 1

Cached :: struct {
	used, dead: bool, // dead: its snapshot has gone, and its pages are zeros from now on
	key:        u64, // file_key: the file, whoever maps it
	node:       Id, // a node of it, which the entry keeps open
	size:       u64, // the VMO's
	vmo:        vx.Handle,
}

pcache: [MAX_CACHED]Cached

@(private="file")
pager, scratch: vx.Handle // scratch: the anonymous page supplies are copied from
@(private="file")
page_buf: [memory.PAGE_SIZE]u8

// Makes fsd a pager, its page requests on port.
@(require_results)
pager_start :: proc "contextless" (port, authority: vx.Handle) -> (st: vx.Status) {
	pager = rt.pager_create(authority, port, PAGER_KEY, SUPPLY_DEADLINE) or_return
	scratch = rt.vmo_create(memory.PAGE_SIZE) or_return
	return .Ok
}

// A file's pages, at least one: its VMO's size.
@(private="file")
pages_of :: proc "contextless" (length: u64) -> u64 {
	size, _ := memory.page_round(length) // a file's length is at most fs.MAXFILE
	return size != 0 ? size : memory.PAGE_SIZE
}

pcache_find :: proc "contextless" (node: Id) -> ^Cached {
	if pager == vx.HANDLE_NONE {
		return nil
	}
	key := file_key(node)
	for &c in pcache {
		if c.used && !c.dead && c.key == key {
			return &c
		}
	}
	return nil
}

// Pages the mappings wrote, into the volume: each dirty range cleaned
// first, then read, so a write after the clean is dirty for next time. Only
// what lies within the file: past its end, a write is lost.
writeback :: proc "contextless" (c: ^Cached) {
	if c.dead || halted {
		return
	}
	f, st := file_of(c.node)
	if st != .Ok {
		return
	}
	// DIRTY answers PAGER_RANGES ranges at most: asked again until it has
	// none, each set cleaned before the next is asked for. Bounded, as a
	// writer could keep dirtying pages: what is left is the next writeback's.
	for _ in 0 ..< 4096 {
		ranges: [vx.PAGER_RANGES]vx.Pager_Range
		n, _ := rt.pager_dirty(pager, c.vmo, 0, c.size, &ranges)
		if n <= 0 {
			return
		}
		writeback_ranges(c, &f, ranges[:n])
	}
}

@(private="file")
writeback_ranges :: proc "contextless" (c: ^Cached, f: ^fs.File, ranges: []vx.Pager_Range) {
	for r in ranges {
		_ = rt.pager_op(pager, c.vmo, .Clean, r.offset, r.size)
		for at := r.offset; at < r.offset + r.size && at < f.d.length; at += memory.PAGE_SIZE {
			page := page_buf[:min(f.d.length - at, memory.PAGE_SIZE)]
			if rt.vmo_read(c.vmo, at, page) != .Ok {
				continue
			}
			if fs.write(&vol, tree_of(c.node), f, at, page, now_ns(), uid_of(c.node)) == .Ok {
				changed()
			}
		}
	}
}

// Whether a mapped file keeps a node on the slot (upstream's M6 step 6d5c:
// a snapshot's slot is closed for another only if not).
slot_mapped :: proc "contextless" (slot: u32) -> bool {
	for &c in pcache {
		if c.used && c.node.slot == slot {
			return true
		}
	}
	return false
}

@(private="file")
pcache_drop :: proc "contextless" (c: ^Cached) {
	_ = rt.handle_close(c.vmo)
	node := c.node
	c^ = {}
	clunk_node(node) // the open it kept
}

// Every entry written back, and those nothing else refers to now let go.
writeback_all :: proc "contextless" () {
	if pager == vx.HANDLE_NONE {
		return
	}
	for &c in pcache {
		if !c.used {
			continue
		}
		// Idle first: then nothing can write it between its writeback and its
		// going (only fsd could hand it out again, and fsd is here).
		idle, _ := rt.pager_idle(pager, c.vmo)
		writeback(&c)
		if idle {
			pcache_drop(&c)
		}
	}
}

// A slot's files changed under their mappings (a rollback), or went (dead):
// their clean pages out, to be asked for again.
pcache_forget :: proc "contextless" (slot: u32, dead: bool) {
	if pager == vx.HANDLE_NONE {
		return
	}
	for &c in pcache {
		if !c.used || c.node.slot != slot {
			continue
		}
		if dead {
			c.dead = true
		}
		_ = rt.pager_op(pager, c.vmo, .Clean, 0, c.size) // what was written since: dropped
		_ = rt.pager_op(pager, c.vmo, .Evict, 0, c.size)
	}
}

// The kernel asks for pages: each read from the file (zeros past its end,
// or if the file has gone), and supplied.
@(private="file")
supply :: proc "contextless" (pk: ^vx.Packet) {
	i := pk.source
	if i >= MAX_CACHED || !pcache[i].used {
		return
	}
	c := &pcache[i]
	f, st := file_of(c.node)
	there := !c.dead && st == .Ok
	first := vx.pager_offset(pk.value)
	for p in 0 ..< vx.pager_pages(pk.value) {
		at := first + p * memory.PAGE_SIZE
		got: u64
		if there && at < f.d.length {
			got, _ = fs.read(&vol, tree_of(c.node), &f, at, page_buf[:])
		}
		for &b in page_buf[got:] {
			b = 0
		}
		if rt.vmo_write(scratch, 0, page_buf[:]) == .Ok {
			_ = rt.pager_supply(pager, c.vmo, at, memory.PAGE_SIZE, scratch, 0)
		}
	}
}

on_event :: proc "contextless" (ctx: rawptr, pk: ^vx.Packet) {
	if pk.key == PAGER_KEY && pk.trigger == .Pager {
		supply(pk)
	}
}

// A Twrite's bytes, into the pages the cache has of them too.
pcache_wrote :: proc "contextless" (node: Id, offset: u64, data: []u8) {
	c := pcache_find(node)
	if c == nil {
		return
	}
	for done := u64(0); done < u64(len(data)) && offset + done < c.size; {
		at := offset + done
		n := min(memory.PAGE_SIZE - (at & (memory.PAGE_SIZE - 1)), u64(len(data)) - done, c.size - at)
		// Err_Should_Wait: not there, read from the volume later.
		_ = rt.vmo_write(c.vmo, at, data[done:][:n])
		done += n
	}
}

// A file's new size: its VMO's too (a page at least), pages past it gone and
// the last page's tail zeroed; or more pages, absent, if it grew.
pcache_truncated :: proc "contextless" (node: Id, size: u64) {
	c := pcache_find(node)
	if c == nil {
		return
	}
	keep := pages_of(size)
	if keep != c.size && rt.pager_resize(pager, c.vmo, keep) == .Ok {
		c.size = keep
	}
	page_buf = {}
	if size & (memory.PAGE_SIZE - 1) != 0 { // the last page's tail
		_ = rt.vmo_write(c.vmo, size, page_buf[:keep - size])
	}
	if size == 0 {
		_ = rt.vmo_write(c.vmo, 0, page_buf[:])
	}
}

// The VMO is the file's size, in pages: a mapping past that is the client's
// to leave unmapped (Rmap says how much there is), so no one can grow a
// file's cache with pages of zeros (upstream docs/proto/map.md).
fs_map :: proc "contextless" (ctx: rawptr, n: p9.Node, offset, length: u64, prot: p9.Prot) -> (m: p9.Mapped, st: vx.Status) {
	node := Id(n)
	if pager == vx.HANDLE_NONE {
		return {}, .Err_Unsupported
	}
	if is_made_up(node) {
		return {}, .Err_Access
	}
	if .Write in prot {
		mutable(node) or_return
	}
	f := file_of(node) or_return
	want := pages_of(f.d.length)
	if offset >= want {
		return {}, .Err_Range // nothing of the file there
	}
	c := pcache_find(node)
	if c == nil { // a new entry: room made by letting go of those no one maps
		if free_entry() == nil {
			writeback_all()
		}
		c = free_entry()
		if c == nil {
			return {}, .Err_No_Memory
		}
		o := open_slot(node, true)
		if o == nil {
			return {}, .Err_No_Memory
		}
		c.vmo = rt.vmo_create_pager(pager, u32(intrinsics.ptr_sub(c, &pcache[0])), want) or_return // its key: its index
		o.count += 1
		c.used, c.key, c.node, c.size = true, file_key(node), node, want
	} else if want != c.size { // the file grew (or shrank) by writes since
		rt.pager_resize(pager, c.vmo, want) or_return
		c.size = want
	}
	rights := vx.Rights{.Read, .Map, .Transfer, .Inspect}
	if .Write in prot {
		rights += {.Write}
	}
	if .Exec in prot {
		rights += {.Exec}
	}
	m.vmo = rt.handle_dup(c.vmo, rights) or_return
	m.vmo_offset, m.avail = offset, c.size - offset
	return m, .Ok
}

@(private="file")
free_entry :: proc "contextless" () -> ^Cached {
	for &c in pcache {
		if !c.used {
			return &c
		}
	}
	return nil
}
