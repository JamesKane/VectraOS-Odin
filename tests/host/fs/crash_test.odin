// Upstream's vxfs_crash_test.c: power cuts (upstream docs/11 §14). A workload
// runs on a device that records every write and barrier: changes to
// branches, commits, labels, forks, labels removed, rollbacks, and logs long
// enough to be compressed. Then the record is replayed, and power is cut at
// every barrier and at random points between them. A write the last barrier
// covers has landed; one after it may have landed or not, in any order, and
// may be torn, some of its sectors new and the rest old. Every cut must
// mount, the checker must find it clean, and its labels must hold what they
// did at the last commit whose superblock landed: the one before the cut, or
// the one under way if its superblock got out.
//
// Upstream's C, built with clang, records the same writes for each seed and
// makes the same cuts: the record's digest and the counts of cuts, tears,
// newer mounts and second cuts here are its.
package fs_test

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:testing"
import vx "abi:vx"
import "vx:fs"

CRASH_BLOCKS :: 2048
SECTOR :: 512
BARRIER :: ~fs.Addr(0)

// --- The record ---

Event :: struct {
	addr:   fs.Addr, // BARRIER: a barrier
	data:   []u8,
	commit: u64, // the last commit whose superblock barrier had passed before this
}

Recorder :: struct {
	live:   []u8,
	ev:     [dynamic]Event,
	on:     bool,
	commit: u64, // set by the workload as commits return
	ctx:    runtime.Context, // the test's: the device's callbacks are contextless
}

record :: proc(r: ^Recorder, addr: fs.Addr, data: []u8) {
	if !r.on {
		return
	}
	e := Event{addr = addr, commit = r.commit}
	if data != nil {
		e.data = make([]u8, B)
		copy(e.data, data)
	}
	append(&r.ev, e)
}

rec_read :: proc "contextless" (ctx: rawptr, addr: fs.Addr, buf: ^[B]u8) -> vx.Status {
	copy(buf[:], (^Recorder)(ctx).live[addr:][:B])
	return .Ok
}

rec_write :: proc "contextless" (ctx: rawptr, addr: fs.Addr, buf: ^[B]u8) -> vx.Status {
	r := (^Recorder)(ctx)
	copy(r.live[addr:][:B], buf[:])
	context = r.ctx
	record(r, addr, buf[:])
	return .Ok
}

rec_barrier :: proc "contextless" (ctx: rawptr) -> vx.Status {
	r := (^Recorder)(ctx)
	context = r.ctx
	record(r, BARRIER, nil)
	return .Ok
}

rec_dev :: proc(r: ^Recorder) -> fs.Dev {
	return {ctx = r, read = rec_read, write = rec_write, barrier = rec_barrier, size = CRASH_BLOCKS * B}
}

recorder_free :: proc(r: ^Recorder) {
	for e in r.ev {
		delete(e.data)
	}
	delete(r.ev)
	delete(r.live)
}

// --- The workload's expectations: each commit's labels and contents ---

CRASH_NKEYS :: 200
CRASH_MAXLABELS :: 12

Crash_Model :: struct {
	nv: [CRASH_NKEYS]u8,
	v:  [CRASH_NKEYS][32]u8,
}

// What a commit left: its labels and what each holds.
State :: struct {
	n:    int,
	name: [CRASH_MAXLABELS]string,
	m:    [CRASH_MAXLABELS]Crash_Model,
}

crash_key_of :: proc(i: int, k: []u8) -> []u8 {
	if i % 2 != 0 {
		return fs.key_dat(k, 2, u64(i) * B)
	}
	return fs.key_ent(k, 1, fmt.bprintf(k[9:], "e%d", i))
}

Crash_Label :: struct {
	name:      [12]u8,
	nname:     int,
	used:      bool,
	branch:    bool,
	now:       Crash_Model,
	committed: Crash_Model,
	br:        ^fs.Branch,
}

crash_label_name :: proc(l: ^Crash_Label) -> string {
	return string(l.name[:l.nname])
}

// What upstream keeps in file statics: the rng, the states by commit, the
// labels, and the counts across seeds.
Crash :: struct {
	rng:         Rng,
	states:      [dynamic]State, // by commit number
	labels:      [CRASH_MAXLABELS]Crash_Label,
	serial:      u32,
	cuts:        u32,
	torn:        u32,
	at_newer:    u32,
	second_cuts: u32,
}

crash_change :: proc(t: ^testing.T, cr: ^Crash, v: ^fs.Vol, l: ^Crash_Label) {
	r := &cr.rng
	keys: [32][32]u8
	vals: [32][32]u8
	msg: [32]fs.Msg
	n := 0
	seen: [CRASH_NKEYS]bool
	for _ in 0 ..< 32 {
		i := int(below(r, CRASH_NKEYS))
		if seen[i] {
			continue
		}
		seen[i] = true
		key := crash_key_of(i, keys[n][:])
		if l.now.nv[i] != 0 && below(r, 3) == 0 {
			msg[n] = {op = i % 2 != 0 ? .Clearb : .Delete, key = key}
			l.now.nv[i] = 0
			n += 1
			continue
		}
		nv: int
		if i % 2 != 0 && below(r, 2) != 0 {
			b := fs.new_data(&v.fs, &l.br.t)
			if b == nil {
				panic("no data block")
			}
			c := u8(rnd(r))
			for &x in fs.data(b) {
				x = c
			}
			testing.expect(t, fs.write_block(&v.fs, b))
			vals[n][0] = u8(fs.Value_Kind.Ref)
			fs.pack_bptr(vals[n][1:], b.bp)
			fs.drop(&v.fs, b)
			nv = 1 + fs.PTRSZ
		} else {
			nv = int(1 + below(r, 31))
			for j in 0 ..< nv {
				vals[n][j] = u8(rnd(r))
			}
			if i % 2 != 0 {
				vals[n][0] = u8(fs.Value_Kind.Inline)
			}
		}
		msg[n] = {op = .Insert, key = key, val = vals[n][:nv]}
		copy(l.now.v[i][:], vals[n][:nv])
		l.now.nv[i] = u8(nv)
		n += 1
	}
	testing.expect(t, fs.upsert(&v.fs, &l.br.t, msg[:n]) == .Ok && fs.end_op(&v.fs))
}

note_state :: proc(cr: ^Crash, commit: u64) {
	if commit >= u64(len(cr.states)) {
		resize(&cr.states, int(commit) + 64)
	}
	s := &cr.states[commit]
	s.n = 0
	for &l in cr.labels {
		if l.used {
			delete(s.name[s.n])
			s.name[s.n] = fmt.aprint(crash_label_name(&l))
			s.m[s.n] = l.committed
			s.n += 1
		}
	}
}

crash_commit :: proc(t: ^testing.T, cr: ^Crash, v: ^fs.Vol, r: ^Recorder) {
	testing.expect_value(t, fs.commit(v), vx.Status.Ok)
	for &l in cr.labels {
		if l.used && l.branch {
			l.committed = l.now
		}
	}
	r.commit = v.sb.commit
	note_state(cr, r.commit)
}

crash_new_label :: proc(cr: ^Crash, branch: bool) -> ^Crash_Label {
	for &l in cr.labels {
		if !l.used {
			l = {used = true, branch = branch}
			l.nname = len(fmt.bprintf(l.name[:], "%c%d", branch ? 'b' : 's', cr.serial))
			cr.serial += 1
			return &l
		}
	}
	return nil
}

crash_pick :: proc(cr: ^Crash, branch: int) -> ^Crash_Label {
	c: [CRASH_MAXLABELS]^Crash_Label
	n := 0
	for &l in cr.labels {
		if l.used && (branch < 0 || l.branch == (branch == 1)) {
			c[n] = &l
			n += 1
		}
	}
	return n > 0 ? c[below(&cr.rng, u32(n))] : nil
}

crash_branches :: proc(cr: ^Crash) -> int {
	n := 0
	for &l in cr.labels {
		if l.used && l.branch {
			n += 1
		}
	}
	return n
}

workload :: proc(t: ^testing.T, cr: ^Crash, v: ^fs.Vol, r: ^Recorder, rounds: int) {
	for _ in 0 ..< rounds {
		op := below(&cr.rng, 100)
		switch {
		case op < 52:
			if l := crash_pick(cr, 1); l != nil {
				crash_change(t, cr, v, l)
			}
		case op < 55: // a log compressed: its old chain is freed by the next commit
			a := &v.fs.arenas[below(&cr.rng, u32(len(v.fs.arenas)))]
			if len(a.retired) == 0 {
				testing.expect(t, fs.log_compress(&v.fs, a))
			}
		case op < 75:
			crash_commit(t, cr, v, r)
		case op < 83:
			l := crash_pick(cr, 1)
			if l == nil {
				break
			}
			if s := crash_new_label(cr, false); s != nil {
				testing.expect_value(t, fs.label(v, crash_label_name(l), crash_label_name(s), {}), vx.Status.Ok)
				s.committed = l.committed
			}
		case op < 88:
			if crash_branches(cr) >= 4 {
				break
			}
			l := crash_pick(cr, -1)
			if l == nil {
				break
			}
			if s := crash_new_label(cr, true); s != nil {
				testing.expect_value(t, fs.label(v, crash_label_name(l), crash_label_name(s), {.Mutable}), vx.Status.Ok)
				s.committed = l.committed
				s.now = l.committed
				st: vx.Status
				s.br, st = fs.branch_open(v, crash_label_name(s))
				testing.expect_value(t, st, vx.Status.Ok)
			}
		case op < 95:
			if l := crash_pick(cr, 0); l != nil {
				testing.expect_value(t, fs.unlabel(v, crash_label_name(l)), vx.Status.Ok)
				l.used = false
			}
		case: // a rollback: committed first, so the branch can close
			s := crash_pick(cr, 0)
			if s == nil {
				break
			}
			l := crash_pick(cr, 1)
			if l == nil {
				break
			}
			crash_commit(t, cr, v, r)
			testing.expect_value(t, fs.branch_close(l.br), vx.Status.Ok)
			testing.expect_value(t, fs.rollback(v, crash_label_name(l), crash_label_name(s)), vx.Status.Ok)
			l.committed = s.committed
			l.now = s.committed
			st: vx.Status
			l.br, st = fs.branch_open(v, crash_label_name(l))
			testing.expect_value(t, st, vx.Status.Ok)
		}
	}
	crash_commit(t, cr, v, r)
}

// --- Replaying the record, with cuts ---

// A device as a cut left it: everything up to the last barrier, and over it
// blocks as the cut left them, and as mounting writes them.
Cutdev :: struct {
	durable: []u8,
	addr:    [dynamic]fs.Addr,
	data:    [dynamic][]u8,
	ctx:     runtime.Context,
}

cut_find :: proc(c: ^Cutdev, addr: fs.Addr) -> []u8 {
	for a, i in c.addr {
		if a == addr {
			return c.data[i]
		}
	}
	return nil
}

// The overlay's copy, made if need be.
cut_block :: proc(c: ^Cutdev, addr: fs.Addr) -> []u8 {
	if b := cut_find(c, addr); b != nil {
		return b
	}
	b := make([]u8, B)
	copy(b, c.durable[addr:][:B])
	append(&c.addr, addr)
	append(&c.data, b)
	return b
}

cut_read :: proc "contextless" (ctx: rawptr, addr: fs.Addr, buf: ^[B]u8) -> vx.Status {
	c := (^Cutdev)(ctx)
	context = c.ctx
	if b := cut_find(c, addr); b != nil {
		copy(buf[:], b)
	} else {
		copy(buf[:], c.durable[addr:][:B])
	}
	return .Ok
}

cut_write :: proc "contextless" (ctx: rawptr, addr: fs.Addr, buf: ^[B]u8) -> vx.Status {
	c := (^Cutdev)(ctx)
	context = c.ctx
	copy(cut_block(c, addr), buf[:])
	return .Ok
}

cut_barrier :: proc "contextless" (_: rawptr) -> vx.Status {
	return .Ok
}

cut_dev :: proc(c: ^Cutdev) -> fs.Dev {
	return {ctx = c, read = cut_read, write = cut_write, barrier = cut_barrier, size = CRASH_BLOCKS * B}
}

cut_free :: proc(c: ^Cutdev) {
	for b in c.data {
		delete(b)
	}
	delete(c.addr)
	delete(c.data)
	c.addr, c.data = nil, nil
}

// Whether v's labels hold what they did at commit `got`.
labels_match :: proc(cr: ^Crash, v: ^fs.Vol, chk: ^fs.Check, got, done: u64) -> bool {
	if got >= u64(len(cr.states)) {
		return true
	}
	s := &cr.states[got]
	ok := int(chk.labels) == s.n
	k: [32]u8
	buf: [fs.INLMAX]u8
	for i in 0 ..< s.n {
		if !ok {
			break
		}
		tr, st := fs.snap_open(v, s.name[i])
		ok = st == .Ok
		for j in 0 ..< CRASH_NKEYS {
			if !ok {
				break
			}
			val, ls := fs.lookup(&v.fs, &tr, crash_key_of(j, k[:]), &buf)
			ok = s.m[i].nv[j] != 0 ? ls == .Ok && bytes_eq(val, s.m[i].v[j][:s.m[i].nv[j]]) : ls == .Err_Not_Found
		}
		if !ok {
			log.errorf("cut after commit %d: label %s differs", done, s.name[i])
		}
	}
	return ok
}

// A second cut, in what came after a first: image is the disk the first left
// (and its mount repaired), r2 what two more commits on it wrote; power is cut
// at event `at`. It must mount, be clean, and be the first cut's commit (its
// labels as they were) or one of the two after it.
cut_again :: proc(cr: ^Crash, image: []u8, r2: ^Recorder, at: int, got: u64) -> bool {
	durable := make([]u8, len(image))
	defer delete(durable)
	copy(durable, image)
	pending := make([dynamic]^Event, context.temp_allocator)
	for i in 0 ..< min(at, len(r2.ev)) {
		e := &r2.ev[i]
		if e.addr != BARRIER {
			append(&pending, e)
			continue
		}
		for p in pending {
			copy(durable[p.addr:][:B], p.data)
		}
		clear(&pending)
	}
	c := Cutdev{durable = durable, ctx = context}
	defer cut_free(&c)
	for p in pending { // in flight: each lands or not, some torn
		if below(&cr.rng, 2) == 0 {
			continue
		}
		b := cut_block(&c, p.addr)
		if below(&cr.rng, 8) == 0 {
			for s := 0; s < B; s += SECTOR {
				if below(&cr.rng, 2) != 0 {
					copy(b[s:][:SECTOR], p.data[s:][:SECTOR])
				}
			}
		} else {
			copy(b, p.data)
		}
	}
	cr.second_cuts += 1
	v := new(fs.Vol)
	defer free(v)
	st := fs.mount(v, cut_dev(&c), mem(), 256)
	defer fs.unmount(v)
	ok := st == .Ok
	if !ok {
		log.errorf("second cut after commit %d: mount: %v", got, st)
	}
	chk: fs.Check
	if ok && fs.check_volume(v, &chk) != .Ok {
		log.errorf("second cut after commit %d: %s", got, report(&chk))
		ok = false
	}
	if ok && (v.sb.commit < got || v.sb.commit > got + 2) {
		log.errorf("second cut after commit %d: mounted %d", got, v.sb.commit)
		ok = false
	}
	if ok && v.sb.commit == got {
		ok = labels_match(cr, v, &chk, got, got)
	}
	return ok
}

// Mounts what a cut left (durable, and of the writes since the last barrier,
// those in `pending` chosen to land) and checks it. With tear_sb, every write
// lands, but the superblocks torn: their first sector new, the rest old.
try_cut :: proc(cr: ^Crash, durable: []u8, pending: []^Event, done: u64, tear_sb: bool) -> bool {
	r := &cr.rng
	c := Cutdev{durable = durable, ctx = context}
	defer cut_free(&c)
	// The writes in flight: each lands or not, in a shuffled order, some torn.
	order := make([]int, len(pending), context.temp_allocator)
	for &o, i in order {
		o = i
	}
	for i := len(pending); i > 1; i -= 1 {
		j := int(below(r, u32(i)))
		order[i - 1], order[j] = order[j], order[i - 1]
	}
	keep := tear_sb ? 1 : below(r, 4) // 0: none land, 1: all, else each by chance
	last := fs.Addr((CRASH_BLOCKS - 1) * B)
	for i in 0 ..< len(pending) {
		e := pending[tear_sb ? i : order[i]]
		if keep == 0 || (keep > 1 && below(r, 2) != 0) {
			continue
		}
		b := cut_block(&c, e.addr)
		if tear_sb && (e.addr == 0 || e.addr == last) {
			cr.torn += 1
			copy(b[:SECTOR], e.data[:SECTOR])
		} else if !tear_sb && below(r, 8) == 0 { // torn: sectors at random
			cr.torn += 1
			for s := 0; s < B; s += SECTOR {
				if below(r, 2) != 0 {
					copy(b[s:][:SECTOR], e.data[s:][:SECTOR])
				}
			}
		} else {
			copy(b, e.data)
		}
	}
	cr.cuts += 1
	v := new(fs.Vol)
	defer free(v)
	st := fs.mount(v, cut_dev(&c), mem(), 256)
	ok := st == .Ok
	if !ok {
		log.errorf("cut after commit %d: mount: %v", done, st)
	}
	chk: fs.Check
	if ok && fs.check_volume(v, &chk) != .Ok {
		log.errorf("cut after commit %d: %s", done, report(&chk))
		ok = false
	}
	got := v.sb.commit
	if ok && got != done && got != done + 1 {
		log.errorf("cut after commit %d: mounted commit %d", done, got)
		ok = false
	}
	if ok && got == done + 1 {
		cr.at_newer += 1
	}
	// Its labels, and what they hold.
	if ok {
		ok = labels_match(cr, v, &chk, got, done)
	}
	// And it goes on: two commits on what the cut left, recorded, the second
	// reusing what the first freed; then power is cut again in them.
	fs.unmount(v)
	more := ok && got < u64(len(cr.states)) && cr.states[got].n > 0 && cr.states[got].name[0][0] == 'b'
	if more {
		image := make([]u8, CRASH_BLOCKS * B)
		defer delete(image)
		for at := fs.Addr(0); at < CRASH_BLOCKS * B; at += B {
			_ = cut_read(&c, at, (^[B]u8)(raw_data(image[at:][:B])))
		}
		r2 := Recorder{live = make([]u8, CRASH_BLOCKS * B), on = true, ctx = context}
		defer recorder_free(&r2)
		copy(r2.live, image)
		br: ^fs.Branch
		st = fs.mount(v, rec_dev(&r2), mem(), 256)
		ok = st == .Ok
		if ok {
			br, st = fs.branch_open(v, cr.states[got].name[0])
			ok = st == .Ok
		}
		for round in 0 ..< 2 {
			if !ok {
				break
			}
			k: [32]u8
			val := [4]u8{1, 2, 3, u8(round)}
			ok = fs.upsert(&v.fs, &br.t, {{op = .Insert, key = crash_key_of(2 * round, k[:]), val = val[:]}}) == .Ok && fs.end_op(&v.fs) && fs.commit(v) == .Ok && fs.check_volume(v, &chk) == .Ok
		}
		if !ok {
			log.errorf("cut after commit %d: no commits after it", done)
		}
		fs.unmount(v)
		for _ in 0 ..< 3 {
			if !ok {
				break
			}
			ok = cut_again(cr, image, &r2, int(below(r, u32(len(r2.ev) + 1))), got)
		}
		for e, i in r2.ev { // and at every barrier of the first of them
			if !ok {
				break
			}
			if e.addr == BARRIER && below(r, 4) == 0 {
				ok = cut_again(cr, image, &r2, i, got)
			}
		}
	}
	return ok
}

Crash_Case :: struct {
	narenas: u32,
	events:  int,
	record:  u64, // the digest of everything the workload wrote
	cuts:    u32, // the counts so far, after this seed
	torn:    u32,
	newer:   u32,
	second:  u32,
}

test_cuts :: proc(t: ^testing.T, cr: ^Crash, seed: u64, rounds: int, c: Crash_Case) {
	cr.rng = {seed * 0x9E3779B97F4A7C15}
	cr.labels = {}
	cr.serial = 0
	r := Recorder{live = make([]u8, CRASH_BLOCKS * B), ctx = context}
	defer recorder_free(&r)
	m := crash_new_label(cr, true)
	v := new(fs.Vol)
	defer free(v)
	testing.expect_value(t, fs.format(v, rec_dev(&r), mem(), 256, c.narenas, {crash_label_name(m)}), vx.Status.Ok)
	v.fs.compress_at = 2 // long logs compressed by commits too
	st: vx.Status
	m.br, st = fs.branch_open(v, crash_label_name(m))
	testing.expect_value(t, st, vx.Status.Ok)
	r.commit = v.sb.commit
	note_state(cr, r.commit)
	durable := make([]u8, CRASH_BLOCKS * B)
	defer delete(durable)
	copy(durable, r.live) // the formatted volume, all landed
	r.on = true
	workload(t, cr, v, &r, rounds)
	r.on = false
	fs.unmount(v)

	// The replay: durable advances at each barrier; cuts at each barrier and between.
	pending: [dynamic]^Event
	defer delete(pending)
	bad := 0
	for i := 0; i < len(r.ev) && bad < 3; i += 1 {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		e := &r.ev[i]
		if e.addr != BARRIER {
			append(&pending, e)
			if below(&cr.rng, 6) == 0 && !try_cut(cr, durable, pending[:], e.commit, false) {
				bad += 1 // between barriers
			}
			continue
		}
		if !try_cut(cr, durable, pending[:], e.commit, false) {
			bad += 1 // just before the barrier
		}
		sbs := false
		for p in pending {
			sbs = sbs || p.addr == 0
		}
		if sbs && !try_cut(cr, durable, pending[:], e.commit, true) {
			bad += 1 // the superblocks torn
		}
		for p in pending {
			copy(durable[p.addr:][:B], p.data)
		}
		clear(&pending)
		if !try_cut(cr, durable, nil, e.commit, false) {
			bad += 1 // just after it
		}
	}
	testing.expect_value(t, bad, 0)
	testing.expect(t, len(r.ev) > 500)
	h: u64
	for &e in r.ev {
		h = fs.xxh64(([^]u8)(&e.addr)[:8], h)
		if e.data != nil {
			h = fs.xxh64(e.data, h)
		}
	}
	testing.expectf(t, len(r.ev) == c.events, "seed %d: %d events, upstream's %d", seed, len(r.ev), c.events)
	testing.expectf(t, h == c.record, "seed %d: the record's digest %016x, upstream's %016x", seed, h, c.record)
	testing.expectf(t, cr.cuts == c.cuts && cr.torn == c.torn && cr.at_newer == c.newer && cr.second_cuts == c.second, "seed %d: cuts %d torn %d newer %d second %d, upstream's %d %d %d %d", seed, cr.cuts, cr.torn, cr.at_newer, cr.second_cuts, c.cuts, c.torn, c.newer, c.second)
}

@(test)
test_crash :: proc(t: ^testing.T) {
	cr := new(Crash)
	defer free(cr)
	defer {
		for &s in cr.states {
			for n in s.name {
				delete(n)
			}
		}
		delete(cr.states)
	}
	// Two arenas; and 24, a superblock of more than one sector, which a cut can tear.
	cases := [3]Crash_Case {
		{2, 1709, 0x8573a77f1b83ad47, 800, 283, 307, 4028},
		{2, 1607, 0x4d6f96ec90c0c6c0, 1468, 563, 574, 7371},
		{24, 3820, 0x507fc1c98e6fcfba, 2505, 1388, 939, 12578},
	}
	for c, i in cases {
		test_cuts(t, cr, u64(i) + 1, 220, c)
	}
	testing.expect(t, cr.cuts > 1000) // the cuts reached what they are for
	testing.expect(t, cr.at_newer > 100)
	testing.expect(t, cr.torn > 500)
	testing.expect(t, cr.second_cuts > 2000)
}
