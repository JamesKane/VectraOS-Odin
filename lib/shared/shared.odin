// vx:shared, upstream's <vx/shared.h> (01 §6.6, M6 step 6e1b3): a structure
// shared in a VMO and read in place, its links offsets from the VMO's start,
// every one checked against the VMO's bounds before it is followed, once per
// link. libvx's in upstream's tree, in lib/ until libvx exists (6e2).
//
// A reader that trusts its writer (a host's input to a plugin) may follow
// links unchecked; one that does not (a plugin's result) has the writer
// seal the VMO (rt.vmo_seal) before it is sent, so the bytes cannot change
// after these checks, and checks each link with at or follow, as §4.3 asks
// of any shared memory.
//
// Links between VMOs are (slot, offset) pairs: the slot indexes a table at
// the head of the VMO, whose entries name the handles sent with the message
// by their position (Twizzler's foreign object table, positions in place of
// global ids): the reader maps each of those handles once, in order, and
// follow checks the slot against the table as it checks the offset against
// the VMO it names.
//
// A VMO as the reader mapped it is a []u8 over the mapping: a view.
package shared

import "base:intrinsics"

// The len bytes at off in view, if they lie wholly inside it and off is a
// multiple of align (a power of two, or 0 for none); else ok is false. No
// sum can wrap.
@(require_results)
at :: proc "contextless" (view: []u8, off, length, align: u64) -> (bytes: []u8, ok: bool) {
	size := u64(len(view))
	if raw_data(view) == nil || off > size || length > size - off || (align != 0 && off & (align - 1) != 0) {
		return nil, false
	}
	return view[off:][:length], true
}

// A T at off in view, checked as at checks it; nil if it is not there.
@(require_results)
at_as :: proc "contextless" (view: []u8, off: u64, $T: typeid) -> ^T {
	b, ok := at(view, off, size_of(T), align_of(T))
	return ok ? cast(^T)raw_data(b) : nil
}

// The n items of each bytes of an array at off, checked whole.
@(require_results)
array :: proc "contextless" (view: []u8, off, n, each, align: u64) -> (bytes: []u8, ok: bool) {
	total, overflow := intrinsics.overflow_mul(n, each)
	if overflow {
		return nil, false
	}
	return at(view, off, total, align)
}

// A link into another VMO of the message: its slot in the table at the head
// of the VMO holding the link, and the offset in the VMO the slot names.
Link :: struct {
	slot:     u32,
	reserved: u32, // 0
	offset:   u64,
}

#assert(size_of(Link) == 16)

// The table at the head of a VMO with links: count positions follow it,
// each the position of a handle in the message, a u32.
Table :: struct {
	count: u32,
}

#assert(size_of(Table) == 4)

// The len bytes link names, from the VMO from holds it in: the slot checked
// against from's table, the position against the views the reader mapped
// (the message's handles, in order), and the offset against that view. The
// table's words are read once each: an unsealed writer may change them.
@(require_results)
follow :: proc "contextless" (from: []u8, views: [][]u8, link: Link, length, align: u64) -> (bytes: []u8, ok: bool) {
	t := at_as(from, 0, Table)
	if t == nil || link.reserved != 0 {
		return nil, false
	}
	count := intrinsics.volatile_load(&t.count)
	if link.slot >= count {
		return nil, false
	}
	positions := array(from, size_of(Table), u64(count), size_of(u32), align_of(u32)) or_return
	position := intrinsics.volatile_load(cast(^u32)raw_data(positions[int(link.slot) * size_of(u32):]))
	if u64(position) >= u64(len(views)) {
		return nil, false
	}
	return at(views[position], link.offset, length, align)
}
