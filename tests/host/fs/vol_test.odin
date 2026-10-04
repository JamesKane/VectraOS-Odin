// Upstream's vxfs_vol_test.c: lib/fs volumes. Formatted with branches;
// changed, committed, and mounted again: what was committed is there and what
// was not is gone. A branch's old snapshots are deleted as it moves, and space
// adds up after every commit and mount: the checker finds the volume clean. A
// damaged superblock or arena header falls back to its copy; both damaged,
// the mount refuses. And what each run leaves on its device is what
// upstream's leaves.
package fs_test

import "core:fmt"
import "core:testing"
import vx "abi:vx"
import "vx:fs"

// --- The checker: clean, and how many snapshots ---

space_adds_up :: proc(t: ^testing.T, v: ^fs.Vol, nsnap: ^u32 = nil, loc := #caller_location) -> bool {
	c: fs.Check
	ok := fs.check_volume(v, &c) == .Ok
	testing.expectf(t, ok, "%s", report(&c), loc = loc)
	if nsnap != nil {
		nsnap^ = c.snapshots
	}
	return ok
}

// --- A model of one branch: keys k0..kN with values, or none ---

VOL_NKEYS :: 600

Vol_Model :: struct {
	nv:   [VOL_NKEYS]int,
	has:  [VOL_NKEYS]bool,
	data: [VOL_NKEYS]bool, // a Kdat whose value names a block
	v:    [VOL_NKEYS][64]u8,
}

vol_key_of :: proc(i: int, k: []u8) -> []u8 {
	if i % 3 == 0 { // a Kdat
		return fs.key_dat(k, 5, u64(i) * B)
	}
	return fs.key_ent(k, 1, fmt.bprintf(k[9:], "name-%d", i))
}

// A batch of random changes to branch br and the model.
vol_change :: proc(t: ^testing.T, v: ^fs.Vol, br: ^fs.Branch, m: ^Vol_Model, r: ^Rng, count: int) {
	keys: [64][32]u8
	vals: [64][64]u8
	msg: [64]fs.Msg
	n := 0
	for _ in 0 ..< count {
		i := int(rnd(r) % VOL_NKEYS)
		key := vol_key_of(i, keys[n][:])
		dup := false // one message a key, so the model's order cannot differ
		for x in msg[:n] {
			dup = dup || bytes_eq(x.key, key)
		}
		if dup {
			continue
		}
		if m.has[i] && rnd(r) % 3 == 0 {
			msg[n] = {op = i % 3 == 0 ? .Clearb : .Delete, key = key}
			n += 1
			m.has[i] = false
			continue
		}
		nv: int
		if i % 3 == 0 && rnd(r) % 2 != 0 { // a data block
			b := fs.new_data(&v.fs, &br.t)
			if !testing.expect(t, b != nil) {
				return
			}
			fs.data(b)[0] = u8(rnd(r))
			testing.expect(t, fs.write_block(&v.fs, b))
			vals[n][0] = u8(fs.Value_Kind.Ref)
			fs.pack_bptr(vals[n][1:], b.bp)
			fs.drop(&v.fs, b)
			nv = 1 + fs.PTRSZ
			m.data[i] = true
		} else {
			nv = int(1 + rnd(r) % 60)
			for j in 0 ..< nv {
				vals[n][j] = u8(rnd(r))
			}
			if i % 3 == 0 {
				vals[n][0] = u8(fs.Value_Kind.Inline)
			}
			m.data[i] = false
		}
		msg[n] = {op = .Insert, key = key, val = vals[n][:nv]}
		copy(m.v[i][:], vals[n][:nv])
		n += 1
		m.nv[i], m.has[i] = nv, true
	}
	testing.expect_value(t, fs.upsert(&v.fs, &br.t, msg[:n]), vx.Status.Ok)
	testing.expect(t, fs.end_op(&v.fs))
}

vol_agrees :: proc(t: ^testing.T, v: ^fs.Vol, tr: ^fs.Tree, m: ^Vol_Model) -> bool {
	k: [32]u8
	buf: [fs.INLMAX]u8
	for i in 0 ..< VOL_NKEYS {
		val, st := fs.lookup(&v.fs, tr, vol_key_of(i, k[:]), &buf)
		ok := m.has[i] ? st == .Ok && bytes_eq(val, m.v[i][:m.nv[i]]) : st == .Err_Not_Found
		if !ok {
			testing.expectf(t, false, "key %d: %v", i, st)
			return false
		}
	}
	return true
}

VOL_BRANCHES :: []string{"main", "cfg", "adm"}

test_format_mount :: proc(t: ^testing.T, r: ^Rng) {
	d := memdev_new(4096)
	defer memdev_free(d)
	v := new(fs.Vol)
	defer free(v)
	testing.expect_value(t, fs.format(v, dev_of(d), mem(), 256, 2, VOL_BRANCHES), vx.Status.Ok)
	snaps: u32
	testing.expect(t, space_adds_up(t, v, &snaps))
	testing.expect_value(t, snaps, 3)
	testing.expect_value(t, v.sb.commit, 1)
	testing.expect_value(t, len(v.fs.arenas), 2)
	fs.unmount(v)

	testing.expect_value(t, fs.mount(v, dev_of(d), mem(), 256), vx.Status.Ok)
	testing.expect_value(t, v.sb.commit, 1)
	testing.expect(t, space_adds_up(t, v, &snaps))
	testing.expect_value(t, snaps, 3)
	_, flags, st := fs.label_get(v, "cfg")
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, flags, fs.Label_Flags{.Mutable})
	_, _, st = fs.label_get(v, "nope")
	testing.expect_value(t, st, vx.Status.Err_Not_Found)
	br: ^fs.Branch
	br, st = fs.branch_open(v, "nope")
	testing.expect_value(t, st, vx.Status.Err_Not_Found)
	br, st = fs.branch_open(v, "main")
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect(t, br != nil && br.t.height == 1)
	fs.unmount(v)

	// Too small, and not a volume.
	tiny := memdev_new(9)
	defer memdev_free(tiny)
	testing.expect_value(t, fs.format(v, dev_of(tiny), mem(), 256, 0, []string{"main"}), vx.Status.Err_Invalid)
	fs.close(&v.fs)
	twice := []string{"home", "cfg", "home"} // a branch name given twice: refused (M5 step 10)
	testing.expect_value(t, fs.format(v, dev_of(d), mem(), 256, 2, twice), vx.Status.Err_Invalid)
	fs.unmount(v)
	blank := memdev_new(64)
	defer memdev_free(blank)
	testing.expect_value(t, fs.mount(v, dev_of(blank), mem(), 256), vx.Status.Err_Invalid)
	fs.unmount(v)
	expect_digest(t, "format_mount", d.bytes, 0xca44e03625928c83)
}

test_commits :: proc(t: ^testing.T, r: ^Rng) {
	d := memdev_new(8192)
	defer memdev_free(d)
	v := new(fs.Vol)
	defer free(v)
	testing.expect_value(t, fs.format(v, dev_of(d), mem(), 512, 3, VOL_BRANCHES), vx.Status.Ok)
	m, mc, scratch := new(Vol_Model), new(Vol_Model), new(Vol_Model) // as changed, as last committed; cfg's
	defer free(m)
	defer free(mc)
	defer free(scratch)
	br, st := fs.branch_open(v, "main")
	testing.expect_value(t, st, vx.Status.Ok)
	cfg: ^fs.Branch
	cfg, st = fs.branch_open(v, "cfg")
	testing.expect_value(t, st, vx.Status.Ok)
	used_after: [40]u64
	for c in 0 ..< 40 {
		for _ in 0 ..< 8 {
			vol_change(t, v, br, m, r, 40)
		}
		if c % 5 == 0 { // cfg too, now and then: two branches in one commit
			vol_change(t, v, cfg, scratch, r, 10)
		}
		testing.expect_value(t, fs.commit(v), vx.Status.Ok)
		mc^ = m^
		snaps: u32
		testing.expect(t, space_adds_up(t, v, &snaps))
		testing.expect_value(t, snaps, 3) // the old snapshots deleted as the branches move
		for &a in v.fs.arenas {
			used_after[c] += a.used
		}
		if c % 8 == 7 { // mounted again: as committed
			vol_change(t, v, br, m, r, 30) // not committed: lost
			fs.unmount(v)
			testing.expect_value(t, fs.mount(v, dev_of(d), mem(), 512), vx.Status.Ok)
			testing.expect(t, space_adds_up(t, v, &snaps))
			testing.expect_value(t, snaps, 3)
			br, st = fs.branch_open(v, "main")
			testing.expect_value(t, st, vx.Status.Ok)
			cfg, st = fs.branch_open(v, "cfg")
			testing.expect_value(t, st, vx.Status.Ok)
			testing.expect(t, vol_agrees(t, v, &br.t, mc))
			m^ = mc^
		}
	}
	// Space does not grow while the contents do not: the keys are bounded.
	testing.expect(t, used_after[39] < used_after[20] * 2)
	ro: fs.Tree
	ro, st = fs.snap_open(v, "main")
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect(t, vol_agrees(t, v, &ro, mc))
	fs.unmount(v)
	expect_digest(t, "commits", d.bytes, 0xc182042a608490ed)
}

test_damage :: proc(t: ^testing.T, r: ^Rng) {
	d := memdev_new(4096)
	defer memdev_free(d)
	v := new(fs.Vol)
	defer free(v)
	testing.expect_value(t, fs.format(v, dev_of(d), mem(), 256, 2, VOL_BRANCHES), vx.Status.Ok)
	m := new(Vol_Model)
	defer free(m)
	br, st := fs.branch_open(v, "main")
	testing.expect_value(t, st, vx.Status.Ok)
	vol_change(t, v, br, m, r, 50)
	testing.expect_value(t, fs.commit(v), vx.Status.Ok)
	base0 := u64(v.fs.arenas[0].base)
	foot0 := base0 + B + v.fs.arenas[0].size
	fs.unmount(v)
	last := u64(len(d.bytes)) - B
	blk :: proc(d: ^Memdev, at: u64) -> []u8 {
		return d.bytes[at:][:B]
	}

	// The primary superblock damaged: the backup, and the primary made whole again.
	d.bytes[100] ~= 1
	testing.expect_value(t, fs.mount(v, dev_of(d), mem(), 256), vx.Status.Ok)
	testing.expect_value(t, v.sb.commit, 2)
	br, st = fs.branch_open(v, "main")
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect(t, vol_agrees(t, v, &br.t, m))
	fs.unmount(v)
	testing.expect(t, bytes_eq(blk(d, 0), blk(d, last)))
	d.bytes[100] ~= 1
	d.bytes[last + 100] ~= 1 // both: nothing (and nothing written)
	testing.expect_value(t, fs.mount(v, dev_of(d), mem(), 256), vx.Status.Err_Invalid)
	fs.unmount(v)
	d.bytes[100] ~= 1
	d.bytes[last + 100] ~= 1

	// An arena's header damaged: its footer, and the header made whole again.
	d.bytes[base0 + 20] ~= 1
	testing.expect_value(t, fs.mount(v, dev_of(d), mem(), 256), vx.Status.Ok)
	br, st = fs.branch_open(v, "main")
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect(t, vol_agrees(t, v, &br.t, m))
	testing.expect(t, space_adds_up(t, v))
	fs.unmount(v)
	testing.expect(t, bytes_eq(blk(d, base0), blk(d, foot0)))
	d.bytes[base0 + 20] ~= 1
	d.bytes[foot0 + 20] ~= 1 // both
	testing.expect_value(t, fs.mount(v, dev_of(d), mem(), 256), vx.Status.Err_Invalid)
	fs.unmount(v)
	d.bytes[base0 + 20] ~= 1
	d.bytes[foot0 + 20] ~= 1

	// An older superblock with a newer one beside it: the newer wins, and the
	// older is made the newer.
	at2 := make([]u8, len(d.bytes))
	defer delete(at2)
	copy(at2, d.bytes) // the disk as commit 2 left it
	m2 := new(Vol_Model)
	defer free(m2)
	m2^ = m^
	testing.expect_value(t, fs.mount(v, dev_of(d), mem(), 256), vx.Status.Ok)
	br, st = fs.branch_open(v, "main")
	testing.expect_value(t, st, vx.Status.Ok)
	vol_change(t, v, br, m, r, 20)
	testing.expect_value(t, fs.commit(v), vx.Status.Ok)
	fs.unmount(v)
	copy(blk(d, last), at2[last:][:B])
	testing.expect_value(t, fs.mount(v, dev_of(d), mem(), 256), vx.Status.Ok)
	testing.expect_value(t, v.sb.commit, 3)
	br, st = fs.branch_open(v, "main")
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect(t, vol_agrees(t, v, &br.t, m))
	fs.unmount(v)
	testing.expect(t, bytes_eq(blk(d, 0), blk(d, last)))

	// A newer superblock whose arenas match neither copy: the older one, if its
	// arenas are what it says (commit 2's headers and footers, here).
	copy(blk(d, last), at2[last:][:B])
	{
		probe := new(fs.Vol)
		defer free(probe)
		testing.expect_value(t, fs.mount(probe, dev_of(d), mem(), 256), vx.Status.Ok) // to learn where the arenas are
		where_: [64][2]u64
		na := len(probe.fs.arenas)
		for &a, i in probe.fs.arenas[:min(na, 64)] {
			where_[i] = {u64(a.base), u64(a.base) + B + a.size}
		}
		fs.unmount(probe)
		copy(blk(d, last), at2[last:][:B]) // the probe's repair undone
		for i in 0 ..< min(na, 64) {
			for at in where_[i] {
				copy(blk(d, at), at2[at:][:B])
			}
		}
	}
	testing.expect_value(t, fs.mount(v, dev_of(d), mem(), 256), vx.Status.Ok)
	testing.expect_value(t, v.sb.commit, 2)
	br, st = fs.branch_open(v, "main")
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect(t, vol_agrees(t, v, &br.t, m2))
	testing.expect(t, space_adds_up(t, v))
	fs.unmount(v)
	testing.expect(t, bytes_eq(blk(d, 0), blk(d, last))) // commit 2's, both now

	// Superblocks that would have the volume hurt itself (a hostile image,
	// checksums and all): refused at mount. A snapshot tree of no height;
	// arenas that overlap; an arena over the primary superblock.
	keep: [2][B]u8
	bad := new([B]u8)
	defer free(bad)
	copy(keep[0][:], blk(d, 0))
	copy(keep[1][:], blk(d, last))
	for kind in 0 ..< 3 {
		testing.expect_value(t, fs.mount(v, dev_of(d), mem(), 256), vx.Status.Ok)
		testing.expect(t, len(v.fs.arenas) >= 2)
		switch kind {
		case 0:
			v.sb.snapht = 0
		case 1:
			v.fs.arenas[1].base = v.fs.arenas[0].base + B
		case 2:
			v.fs.arenas[0].base = 0
		}
		fs.pack_sb(v, bad[:])
		fs.unmount(v)
		copy(blk(d, 0), bad[:])
		copy(blk(d, last), bad[:])
		testing.expectf(t, fs.mount(v, dev_of(d), mem(), 256) == .Err_Invalid, "hostile superblock %d mounted", kind)
		fs.unmount(v)
		copy(blk(d, 0), keep[0][:])
		copy(blk(d, last), keep[1][:])
	}
	testing.expect_value(t, fs.mount(v, dev_of(d), mem(), 256), vx.Status.Ok)
	testing.expect_value(t, v.sb.commit, 2)
	// A tree of no height: refused by upsert, not recursed on.
	flat := fs.Tree{height = 0}
	k1 := [1]u8{u8(fs.Key_Kind.Ent)}
	testing.expect_value(t, fs.upsert(&v.fs, &flat, {{op = .Insert, key = k1[:]}}), vx.Status.Err_Invalid)
	fs.unmount(v)
	expect_digest(t, "damage", d.bytes, 0x3428b0c953f6da48)
}

// The checker finds what is wrong: a leaked block, a damaged one, a snapshot
// record that disagrees; and damage to free space is no damage.
test_checker :: proc(t: ^testing.T, r: ^Rng) {
	d := memdev_new(4096)
	defer memdev_free(d)
	v := new(fs.Vol)
	defer free(v)
	testing.expect_value(t, fs.format(v, dev_of(d), mem(), 256, 2, VOL_BRANCHES), vx.Status.Ok)
	m := new(Vol_Model)
	defer free(m)
	br, st := fs.branch_open(v, "main")
	testing.expect_value(t, st, vx.Status.Ok)
	for _ in 0 ..< 40 {
		vol_change(t, v, br, m, r, 50) // enough for pivots
	}
	testing.expect_value(t, fs.commit(v), vx.Status.Ok)
	c: fs.Check
	testing.expect_value(t, fs.check_volume(v, &c), vx.Status.Ok)
	testing.expect(t, c.trees > 4)
	testing.expect_value(t, c.snapshots, 3)
	testing.expect_value(t, c.labels, 3)

	// A block allocated and reached by nothing: leaked.
	testing.expect(t, fs.block_alloc(&v.fs, .Dat) != 0)
	testing.expect_value(t, fs.check_volume(v, &c), vx.Status.Err_Invalid)
	testing.expect_value(t, c.leaked, 1)
	fs.unmount(v)
	testing.expect_value(t, fs.mount(v, dev_of(d), mem(), 256), vx.Status.Ok) // never committed, so gone
	testing.expect_value(t, fs.check_volume(v, &c), vx.Status.Ok)

	// A free block written over: nothing is wrong.
	free_at := u64(v.fs.arenas[1].free.buf[0].off)
	for &x in d.bytes[free_at:][:B] {
		x = 0x5a
	}
	testing.expect_value(t, fs.check_volume(v, &c), vx.Status.Ok)
	// A leaf of main's damaged: found, and counted rather than stopping the walk.
	br, st = fs.branch_open(v, "main")
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect(t, br.t.height >= 2)
	root := fs.get(&v.fs, br.t.root, {.Pivot})
	leaf := fs.unpack_bptr(fs.tab_get(fs.pivot_kids(root), 0, false).val)
	fs.drop(&v.fs, root)
	fs.unmount(v)
	d.bytes[u64(leaf.addr) + 200] ~= 0x01
	testing.expect_value(t, fs.mount(v, dev_of(d), mem(), 256), vx.Status.Ok)
	testing.expect_value(t, fs.check_volume(v, &c), vx.Status.Err_Invalid)
	testing.expect_value(t, c.damaged, 1)
	testing.expect_value(t, c.snapshots, 3)
	fs.unmount(v)
	d.bytes[u64(leaf.addr) + 200] ~= 0x01

	// A snapshot whose label count is wrong.
	testing.expect_value(t, fs.mount(v, dev_of(d), mem(), 256), vx.Status.Ok)
	gen: fs.Gen
	gen, _, st = fs.label_get(v, "cfg")
	testing.expect_value(t, st, vx.Status.Ok)
	s: fs.Snap
	s, st = fs.snap_get(v, gen)
	testing.expect_value(t, st, vx.Status.Ok)
	s.nlbl = 2
	b := fs.batch_new(v)
	testing.expect(t, fs.snap_set(v, b, s) && fs.snap_flush(v, b))
	fs.batch_free(v, b)
	testing.expect_value(t, fs.check_volume(v, &c), vx.Status.Err_Invalid)
	testing.expect_value(t, c.bad_snaps, 1)
	fs.unmount(v)
	expect_digest(t, "checker", d.bytes, 0x35470a7027c4cd51)
}

// Upstream's main runs these in this order, one xorshift going on from each
// to the next.
@(test)
test_vol :: proc(t: ^testing.T) {
	r := Rng{7}
	test_checker(t, &r)
	test_format_mount(t, &r)
	test_commits(t, &r)
	test_damage(t, &r)
}
