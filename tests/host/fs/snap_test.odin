// Upstream's vxfs_snap_test.c: lib/fs snapshots and branches against a model.
// Random rounds of changes to several branches, commits, labels on
// snapshots, forks, labels removed, branches deleted and rolled back. After
// every commit the checker must find the volume clean (every block reachable,
// nothing leaked, deadlists fitting their snapshots), and every label must
// hold what the model says it did when it was made; now and then the volume
// is mounted again and all of it checked once more. Then the cases by hand: a
// middle snapshot deleted, a fork outliving its base's label, the base
// reclaimed when the fork goes, and refusals. And what each run leaves on its
// device is what upstream's leaves.
package fs_test

import "core:fmt"
import "core:log"
import "core:testing"
import vx "abi:vx"
import "vx:fs"

SNAP_NKEYS :: 300

Snap_Model :: struct {
	nv: [SNAP_NKEYS]u8, // 0: none
	v:  [SNAP_NKEYS][40]u8,
}

snap_key_of :: proc(i: int, k: []u8) -> []u8 {
	if i % 2 != 0 {
		return fs.key_dat(k, 3, u64(i) * B)
	}
	return fs.key_ent(k, 1, fmt.bprintf(k[9:], "f%d", i))
}

snap_change :: proc(t: ^testing.T, v: ^fs.Vol, br: ^fs.Branch, m: ^Snap_Model, r: ^Rng, count: u32) {
	keys: [48][32]u8
	vals: [48][40]u8
	msg: [48]fs.Msg
	n := 0
	seen: [SNAP_NKEYS]bool
	for c := u32(0); c < count && n < 48; c += 1 {
		i := int(below(r, SNAP_NKEYS))
		if seen[i] {
			continue
		}
		seen[i] = true
		key := snap_key_of(i, keys[n][:])
		if m.nv[i] != 0 && below(r, 3) == 0 {
			msg[n] = {op = i % 2 != 0 ? .Clearb : .Delete, key = key}
			n += 1
			m.nv[i] = 0
			continue
		}
		nv: int
		if i % 2 != 0 && below(r, 2) != 0 { // a data block
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
		} else {
			nv = int(1 + below(r, 39))
			for j in 0 ..< nv {
				vals[n][j] = u8(rnd(r))
			}
			if i % 2 != 0 {
				vals[n][0] = u8(fs.Value_Kind.Inline)
			}
		}
		msg[n] = {op = .Insert, key = key, val = vals[n][:nv]}
		copy(m.v[i][:], vals[n][:nv])
		m.nv[i] = u8(nv)
		n += 1
	}
	testing.expect_value(t, fs.upsert(&v.fs, &br.t, msg[:n]), vx.Status.Ok)
	testing.expect(t, fs.end_op(&v.fs))
}

snap_agrees :: proc(v: ^fs.Vol, tr: ^fs.Tree, m: ^Snap_Model) -> bool {
	k: [32]u8
	buf: [fs.INLMAX]u8
	for i in 0 ..< SNAP_NKEYS {
		val, st := fs.lookup(&v.fs, tr, snap_key_of(i, k[:]), &buf)
		ok := m.nv[i] != 0 ? st == .Ok && bytes_eq(val, m.v[i][:m.nv[i]]) : st == .Err_Not_Found
		if !ok {
			return false
		}
	}
	return true
}

// --- The world: labels, each a snapshot or a branch, with what they hold ---

MAXLABELS :: 48

Label :: struct {
	name:      [16]u8,
	nname:     int,
	used:      bool,
	branch:    bool,
	now:       ^Snap_Model, // a snapshot's are one
	committed: ^Snap_Model,
	br:        ^fs.Branch, // a branch's, open
}

label_name :: proc(l: ^Label) -> string {
	return string(l.name[:l.nname])
}

Snap_World :: struct {
	d:       ^Memdev,
	v:       ^fs.Vol,
	l:       [MAXLABELS]Label,
	serial:  u32,
	commits: u32,
	rng:     Rng,
}

sw_clean :: proc(t: ^testing.T, w: ^Snap_World, loc := #caller_location) -> bool {
	return clean(t, w.v, loc)
}

labels_agree :: proc(w: ^Snap_World) -> bool {
	for &l in w.l {
		if !l.used {
			continue
		}
		tr, st := fs.snap_open(w.v, label_name(&l))
		if st != .Ok || !snap_agrees(w.v, &tr, l.committed) {
			log.errorf("label %s disagrees", label_name(&l))
			return false
		}
	}
	return true
}

new_label :: proc(w: ^Snap_World, branch: bool, prefix: string) -> ^Label {
	for &l in w.l {
		if !l.used {
			l = {used = true, branch = branch}
			l.nname = len(fmt.bprintf(l.name[:], "%s%d", prefix, w.serial))
			w.serial += 1
			l.committed = new(Snap_Model)
			l.now = branch ? new(Snap_Model) : l.committed
			return &l
		}
	}
	return nil
}

drop_label :: proc(l: ^Label) {
	if l.now != l.committed {
		free(l.now)
	}
	free(l.committed)
	l^ = {}
}

// A label at random: a branch (1), a snapshot (0), or either (-1).
pick :: proc(w: ^Snap_World, branch: int) -> ^Label {
	cand: [MAXLABELS]^Label
	n := 0
	for &l in w.l {
		if l.used && (branch < 0 || l.branch == (branch == 1)) {
			cand[n] = &l
			n += 1
		}
	}
	return n > 0 ? cand[below(&w.rng, u32(n))] : nil
}

count_labels :: proc(w: ^Snap_World, branch: bool) -> int {
	n := 0
	for &l in w.l {
		if l.used && l.branch == branch {
			n += 1
		}
	}
	return n
}

sw_commit :: proc(t: ^testing.T, w: ^Snap_World) {
	testing.expect_value(t, fs.commit(w.v), vx.Status.Ok)
	w.commits += 1
	for &l in w.l {
		if l.used && l.branch {
			l.committed^ = l.now^
		}
	}
}

sw_remount :: proc(t: ^testing.T, w: ^Snap_World) {
	fs.unmount(w.v)
	testing.expect_value(t, fs.mount(w.v, dev_of(w.d), mem(), 512), vx.Status.Ok)
	for &l in w.l {
		if !l.used || !l.branch {
			continue
		}
		st: vx.Status
		l.br, st = fs.branch_open(w.v, label_name(&l))
		testing.expect_value(t, st, vx.Status.Ok)
		l.now^ = l.committed^ // uncommitted changes are gone
	}
}

round_of :: proc(t: ^testing.T, w: ^Snap_World) {
	op := below(&w.rng, 100)
	switch {
	case op < 45: // changes
		if l := pick(w, 1); l != nil {
			snap_change(t, w.v, l.br, l.now, &w.rng, 1 + below(&w.rng, 30))
		}
	case op < 60:
		sw_commit(t, w)
		testing.expect(t, sw_clean(t, w))
		testing.expect(t, labels_agree(w))
	case op < 72: // a snapshot of a branch's last commit
		b := pick(w, 1)
		s := b != nil ? new_label(w, false, "s") : nil
		if s != nil {
			testing.expect_value(t, fs.label(w.v, label_name(b), label_name(s), {}), vx.Status.Ok)
			s.committed^ = b.committed^
		}
	case op < 80: // a fork of anything
		from := count_labels(w, true) < 6 ? pick(w, -1) : nil
		f := from != nil ? new_label(w, true, "b") : nil
		if f != nil {
			testing.expect_value(t, fs.label(w.v, label_name(from), label_name(f), {.Mutable}), vx.Status.Ok)
			f.committed^ = from.committed^
			f.now^ = from.committed^
			st: vx.Status
			f.br, st = fs.branch_open(w.v, label_name(f))
			testing.expect_value(t, st, vx.Status.Ok)
		}
	case op < 90: // a snapshot's label removed
		if l := pick(w, 0); l != nil {
			testing.expect_value(t, fs.unlabel(w.v, label_name(l)), vx.Status.Ok)
			drop_label(l)
		}
	case op < 95: // a branch deleted: committed, closed, removed
		if count_labels(w, true) > 1 {
			if l := pick(w, 1); l != nil {
				sw_commit(t, w)
				testing.expect_value(t, fs.branch_close(l.br), vx.Status.Ok)
				testing.expect_value(t, fs.unlabel(w.v, label_name(l)), vx.Status.Ok)
				drop_label(l)
			}
		}
	case: // a branch rolled back to a snapshot
		s := pick(w, 0)
		if s == nil {
			break
		}
		if l := pick(w, 1); l != nil {
			sw_commit(t, w)
			testing.expect_value(t, fs.branch_close(l.br), vx.Status.Ok)
			testing.expect_value(t, fs.rollback(w.v, label_name(l), label_name(s)), vx.Status.Ok)
			l.committed^ = s.committed^
			l.now^ = s.committed^
			st: vx.Status
			l.br, st = fs.branch_open(w.v, label_name(l))
			testing.expect_value(t, st, vx.Status.Ok)
		}
	}
}

sw_open :: proc(t: ^testing.T, w: ^Snap_World, blocks: u64) {
	rng := w.rng
	w^ = {rng = rng}
	w.d = memdev_new(blocks)
	w.v = new(fs.Vol)
	m := new_label(w, true, "main")
	testing.expect_value(t, fs.format(w.v, dev_of(w.d), mem(), 512, 4, {label_name(m)}), vx.Status.Ok)
	st: vx.Status
	m.br, st = fs.branch_open(w.v, label_name(m))
	testing.expect_value(t, st, vx.Status.Ok)
}

sw_close :: proc(w: ^Snap_World) {
	fs.unmount(w.v)
	free(w.v)
	for &l in w.l {
		if l.used {
			drop_label(&l)
		}
	}
	memdev_free(w.d)
}

@(test)
test_snap_random :: proc(t: ^testing.T) {
	digests := [4]u64{0xeb9a6ce00107f415, 0x17846b3c95a500b4, 0x1f464b2da3054cdc, 0x3781f0b047bd358c}
	for seed in u64(1) ..= 4 {
		w := new(Snap_World)
		defer free(w)
		w.rng = {seed * 0x9E3779B97F4A7C15}
		sw_open(t, w, 16384)
		ok := true
		for r in 0 ..< 1500 {
			if !ok {
				break
			}
			round_of(t, w)
			if r % 97 == 96 {
				sw_commit(t, w)
				sw_remount(t, w)
				ok = sw_clean(t, w) && labels_agree(w)
				testing.expect(t, ok)
			}
			if !ok {
				log.errorf("seed %d: wrong at round %d", seed, r)
			}
		}
		sw_commit(t, w)
		testing.expect(t, sw_clean(t, w))
		testing.expect(t, labels_agree(w))
		testing.expect(t, w.commits > 20)
		testing.expect(t, w.serial > 10)
		expect_digest(t, fmt.tprintf("snap random %d", seed), w.d.bytes, digests[seed - 1])
		sw_close(w)
	}
}

// By hand: a fork outlives its base's label; deleting the fork reclaims the
// base; a middle snapshot deleted keeps both neighbours whole.
@(test)
test_snap_cases :: proc(t: ^testing.T) {
	w := new(Snap_World)
	defer free(w)
	w.rng = {99}
	sw_open(t, w, 8192)
	defer sw_close(w)
	m := &w.l[0]
	snap_change(t, w.v, m.br, m.now, &w.rng, 40)
	sw_commit(t, w)
	s1 := new_label(w, false, "s")
	testing.expect_value(t, fs.label(w.v, label_name(m), label_name(s1), {}), vx.Status.Ok)
	s1.committed^ = m.committed^
	snap_change(t, w.v, m.br, m.now, &w.rng, 40)
	sw_commit(t, w)
	s2 := new_label(w, false, "s")
	testing.expect_value(t, fs.label(w.v, label_name(m), label_name(s2), {}), vx.Status.Ok)
	s2.committed^ = m.committed^
	snap_change(t, w.v, m.br, m.now, &w.rng, 40)
	sw_commit(t, w)
	testing.expect(t, sw_clean(t, w))
	testing.expect(t, labels_agree(w))
	c: fs.Check
	testing.expect_value(t, fs.check_volume(w.v, &c), vx.Status.Ok)
	testing.expect(t, c.dlists > 0)
	snaps_before := c.snapshots

	// The middle one deleted: its neighbours still hold what they did.
	testing.expect_value(t, fs.unlabel(w.v, label_name(s2)), vx.Status.Ok)
	drop_label(s2)
	sw_commit(t, w)
	testing.expect(t, sw_clean(t, w))
	testing.expect(t, labels_agree(w))

	// A fork of s1, then s1's label removed: the fork keeps the snapshot.
	f := new_label(w, true, "b")
	testing.expect_value(t, fs.label(w.v, label_name(s1), label_name(f), {.Mutable}), vx.Status.Ok)
	f.committed^ = s1.committed^
	f.now^ = s1.committed^
	st: vx.Status
	f.br, st = fs.branch_open(w.v, label_name(f))
	testing.expect_value(t, st, vx.Status.Ok)
	snap_change(t, w.v, f.br, f.now, &w.rng, 40)
	sw_commit(t, w)
	testing.expect_value(t, fs.unlabel(w.v, label_name(s1)), vx.Status.Ok)
	drop_label(s1)
	sw_commit(t, w)
	testing.expect(t, sw_clean(t, w))
	testing.expect(t, labels_agree(w))
	// The fork deleted: its base, now named by nothing, goes too.
	testing.expect_value(t, fs.branch_close(f.br), vx.Status.Ok)
	testing.expect_value(t, fs.unlabel(w.v, label_name(f)), vx.Status.Ok)
	drop_label(f)
	sw_commit(t, w)
	testing.expect_value(t, fs.check_volume(w.v, &c), vx.Status.Ok)
	testing.expect_value(t, c.snapshots, 1)
	testing.expect_value(t, snaps_before, 3)
	testing.expect(t, labels_agree(w))

	// Refusals.
	testing.expect_value(t, fs.label(w.v, label_name(m), label_name(m), {}), vx.Status.Err_Exists)
	testing.expect_value(t, fs.label(w.v, "nothing", "x", {}), vx.Status.Err_Not_Found)
	testing.expect_value(t, fs.unlabel(w.v, label_name(m)), vx.Status.Err_Bad_State) // open
	snap_change(t, w.v, m.br, m.now, &w.rng, 5)
	testing.expect_value(t, fs.branch_close(m.br), vx.Status.Err_Bad_State) // changed, not committed
	s3 := new_label(w, false, "s")
	testing.expect_value(t, fs.label(w.v, label_name(m), label_name(s3), {}), vx.Status.Ok)
	s3.committed^ = m.committed^
	testing.expect_value(t, fs.rollback(w.v, label_name(s3), label_name(m)), vx.Status.Err_Access) // a snapshot is not a branch
	_, st = fs.branch_open(w.v, label_name(s3))
	testing.expect_value(t, st, vx.Status.Err_Access)
	sw_commit(t, w)
	testing.expect(t, sw_clean(t, w))
	testing.expect(t, labels_agree(w))

	// An open branch rolled back in place: still open, now as s3 was; and
	// refused while it has uncommitted changes.
	snap_change(t, w.v, m.br, m.now, &w.rng, 30)
	testing.expect_value(t, fs.branch_rollback(w.v, m.br, label_name(s3)), vx.Status.Err_Bad_State)
	sw_commit(t, w)
	testing.expect_value(t, fs.branch_rollback(w.v, m.br, label_name(s3)), vx.Status.Ok)
	testing.expect(t, m.br.open)
	m.now^ = s3.committed^
	m.committed^ = s3.committed^
	testing.expect(t, snap_agrees(w.v, &m.br.t, m.now))
	snap_change(t, w.v, m.br, m.now, &w.rng, 10) // and goes on from there
	sw_commit(t, w)
	testing.expect(t, sw_clean(t, w))
	testing.expect(t, labels_agree(w))
	expect_digest(t, "snap cases", w.d.bytes, 0xa9287ba05caf0e3f)
}
