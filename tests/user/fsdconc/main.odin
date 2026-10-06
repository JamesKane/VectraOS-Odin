// fsdconc: fsd's readers with the server let go (upstream's M6 step 6d5b),
// in the fsdconc scenario (tests/qemu/m6/fsdconc.ndb). Four reader threads,
// each on a connection of its own, walk, stat, list and read files whose
// every byte they check, one of them larger than fsd's block cache, while a
// writer makes, writes and removes files and commits: every byte read is
// right, fsd has more than one thread when they are done, and the volume's
// check is clean after, nothing given back early and nothing leaked. Each
// check prints a line only when it fails; the last line counts them. The
// checks are upstream's, some of several conditions, so the count is too.
package fsdconc

import vx "abi:vx"
import "vx:ns"
import "vx:p9"
import "vx:procns"
import "vx:rt"
import "vx:str"

checks, failures: u32
count_lock: rt.Mutex

check :: proc "contextless" (ok: bool, what := #caller_expression(ok), loc := #caller_location) {
	rt.mutex_lock(&count_lock)
	defer rt.mutex_unlock(&count_lock)
	checks += 1
	if !ok {
		failures += 1
		rt.print("fsdconc: FAILED line ", u64(loc.line), ": ", what, "\n")
	}
}

FILES :: 4
FILE_SIZE :: 1 << 20
BIG_SIZE :: 20 << 20
CHUNK :: 8192
READERS :: 4
ROUNDS :: 12
WRITES :: 40

space: ns.Namespace
fsd: vx.Handle

pattern :: proc "contextless" (k: u32, off: u64) -> u8 {
	return u8(off * 31 + u64(k) * 7 + (off >> 12))
}

fill :: proc "contextless" (buf: []u8, k: u32, off: u64) {
	for &b, i in buf {
		b = pattern(k, off + u64(i))
	}
}

connect :: proc "contextless" (c: ^rt.Conn, aname: string) -> (root: p9.Fid, ok: bool) {
	if rt.p9_connect(fsd, c) != .Ok {
		return 0, false
	}
	c.timeout = 60_000_000_000
	st: vx.Status
	root, st = p9.client_attach(&c.c, aname)
	return root, st == .Ok
}

// Each thread's own buffer for the names it makes: base and k's digits.
name_bufs: [READERS + 2][16]u8

file_name :: proc "contextless" (slot: int, base: string, k: u32) -> string {
	p := name_bufs[slot][:]
	n := copy(p, base)
	if k >= 10 {
		p[n] = u8('0' + k / 10)
		n += 1
	}
	p[n] = u8('0' + k % 10)
	return string(p[:n + 1])
}

// Writes the file of `size` bytes of pattern k at name in dir.
make_buf: [CHUNK]u8

make_file :: proc "contextless" (c: ^p9.Client, dir: p9.Fid, name: string, k: u32, size: u32) -> bool {
	fid, st := p9.client_walk(c, dir, "")
	if st != .Ok || p9.client_create(c, fid, name, 0o644, p9.OWRITE) != .Ok {
		return false
	}
	ok := true
	for off := u32(0); ok && off < size; off += CHUNK {
		fill(make_buf[:], k, u64(off))
		n, e := p9.client_write(c, fid, u64(off), make_buf[:])
		ok = e == .Ok && n == CHUNK
	}
	_ = p9.client_clunk(c, fid)
	return ok
}

// Reads the whole of name in dir, checking every byte against pattern k.
read_file :: proc "contextless" (c: ^p9.Client, dir: p9.Fid, name: string, k: u32, size: u64) -> bool {
	buf: [CHUNK]u8
	fid, st := p9.client_walk(c, dir, name)
	if st != .Ok {
		return false
	}
	ok := p9.client_open(c, fid, p9.OREAD) == .Ok
	off: u64
	for ok {
		n, e := p9.client_read(c, fid, off, buf[:])
		if e != .Ok || n <= 0 {
			break
		}
		for b, i in buf[:n] {
			if !ok {
				break
			}
			ok = b == pattern(k, off + u64(i))
		}
		off += u64(n)
	}
	_ = p9.client_clunk(c, fid)
	return ok && off == size
}

Reader :: struct {
	id:           int,
	conn:         rt.Conn,
	root, conc:   p9.Fid,
	good, listed: u32,
}

readers: [READERS]Reader

read_loop :: proc(arg: rawptr) {
	r := (^Reader)(arg)
	c := &r.conn.c
	for round in 0 ..< ROUNDS {
		k := u32(r.id + round) % FILES
		if read_file(c, r.conc, file_name(r.id, "f", k), k, FILE_SIZE) {
			r.good += 1
		}
		// A stat, and a listing that has the four.
		if fid, st := p9.client_walk(c, r.conc, file_name(r.id, "f", k)); st == .Ok {
			s: p9.Stat
			keep: p9.Stat_Text
			if p9.client_stat(c, fid, &s, &keep) == .Ok && s.length == FILE_SIZE {
				r.good += 1
			}
			_ = p9.client_clunk(c, fid)
		}
		if fid, st := p9.client_walk(c, r.conc, ""); st == .Ok {
			if p9.client_open(c, fid, p9.OREAD) == .Ok {
				dbuf: [4096]u8
				found: u32
				off: u64
				for {
					n, e := p9.client_read(c, fid, off, dbuf[:])
					if e != .Ok || n <= 0 {
						break
					}
					it := p9.Dir_Entries {
						buf = dbuf[:n],
					}
					for s in p9.next_entry(&it) {
						if len(s.name) == 2 && s.name[0] == 'f' {
							found += 1
						}
					}
					off += u64(n)
				}
				if found == FILES {
					r.listed += 1
				}
			}
			_ = p9.client_clunk(c, fid)
		}
		if round == 0 && r.id < 2 && read_file(c, r.conc, "big", 9, BIG_SIZE) {
			r.good += 1
		}
	}
}

writer_conn: rt.Conn
writer_root, writer_conc: p9.Fid
written: u32

write_loop :: proc(arg: rawptr) {
	c := &writer_conn.c
	for i in u32(0) ..< WRITES {
		if make_file(c, writer_conc, file_name(READERS, "t", i % 100), 20 + i, 64 * 1024) {
			written += 1
		}
		if i > 0 {
			if fid, st := p9.client_walk(c, writer_conc, file_name(READERS + 1, "t", (i - 1) % 100)); st == .Ok {
				_ = p9.client_remove(c, fid)
			}
		}
		if i % 5 == 4 { // a commit, readers or not
			if fid, st := p9.client_walk(c, writer_root, ""); st == .Ok {
				_ = p9.client_fsync(c, fid)
				_ = p9.client_clunk(c, fid)
			}
		}
	}
}

// fsd's threads, from its /proc status line.
fsd_threads :: proc "contextless" () -> u32 {
	for pid in u64(1) ..< 64 {
		path_buf: [32]u8
		number_buf: [4]u8
		path, _ := str.join(path_buf[:], "/proc/", str.format_u64(number_buf[:], pid), "/status")
		f: ns.File
		if ns.open(&space, path, p9.OREAD, &f) != .Ok {
			continue
		}
		buf: [255]u8
		n, st := ns.read_all(&f, buf[:])
		ns.close(&f)
		if st != .Ok {
			continue
		}
		status := string(buf[:n])
		if !str.contains(status, "name=fsd ") {
			continue
		}
		at := str.index(status, "threads=")
		if at < 0 {
			continue
		}
		t: u32
		for c in transmute([]u8)status[at + 8:] {
			if c < '0' || c > '9' {
				break
			}
			t = t * 10 + u32(c - '0')
		}
		return t
	}
	return 0
}

@(export, link_name = "vx_main")
vx_main :: proc() -> int {
	if procns.from_spawn(&space) != .Ok {
		rt.exits("no namespace")
	}
	fsd = ns.connector(&space, "/tmp")
	check(fsd != vx.HANDLE_NONE)
	ok: bool
	writer_root, ok = connect(&writer_conn, "home")
	check(ok)
	w := &writer_conn.c

	// The files: four of a mebibyte, and one larger than the cache (16 MiB).
	fid, st := p9.client_walk(w, writer_root, "")
	check(st == .Ok && p9.client_create(w, fid, "conc", p9.DMDIR | 0o755, p9.OREAD) == .Ok)
	_ = p9.client_clunk(w, fid)
	writer_conc, st = p9.client_walk(w, writer_root, "conc")
	check(st == .Ok)
	made := true
	for k in u32(0) ..< FILES {
		made = made && make_file(w, writer_conc, file_name(0, "f", k), k, FILE_SIZE)
	}
	made = made && make_file(w, writer_conc, "big", 9, BIG_SIZE)
	check(made)
	fid, st = p9.client_walk(w, writer_root, "")
	check(st == .Ok && p9.client_fsync(w, fid) == .Ok)
	_ = p9.client_clunk(w, fid)

	// The readers and the writer, all at once.
	t: [READERS + 1]rt.Thread
	for &r, i in readers {
		r.id = i
		r.root, ok = connect(&r.conn, "home")
		st = .Err_Not_Found
		if ok {
			r.conc, st = p9.client_walk(&r.conn.c, r.root, "conc")
		}
		check(ok && st == .Ok)
	}
	for &r, i in readers {
		t[i], st = rt.thread_spawn(read_loop, &r)
		check(st == .Ok)
	}
	t[READERS], st = rt.thread_spawn(write_loop, nil)
	check(st == .Ok)
	for &x in t {
		rt.thread_join(&x)
	}
	for &r, i in readers {
		check(r.good == 2 * ROUNDS + (i < 2 ? 1 : 0))
		check(r.listed == ROUNDS)
	}
	check(written == WRITES)
	check(fsd_threads() > 1) // readers let it go: it made threads to serve the rest

	// The volume's check, through adm: nothing given back early, nothing leaked.
	@(static) adm: rt.Conn
	aroot: p9.Fid
	aroot, ok = connect(&adm, "adm")
	check(ok)
	fid, st = p9.client_walk(&adm.c, aroot, "ctl")
	wrote := false
	if st == .Ok && p9.client_open(&adm.c, fid, p9.OWRITE) == .Ok {
		n, e := p9.client_write(&adm.c, fid, 0, transmute([]u8)string("check"))
		wrote = e == .Ok && n == 5
	}
	check(wrote)
	_ = p9.client_clunk(&adm.c, fid)
	status: [511]u8
	n := 0
	if fid, st = p9.client_walk(&adm.c, aroot, "status"); st == .Ok && p9.client_open(&adm.c, fid, p9.OREAD) == .Ok {
		n, _ = p9.client_read(&adm.c, fid, 0, status[:])
	}
	_ = p9.client_clunk(&adm.c, fid)
	clean := str.contains(string(status[:max(n, 0)]), "check=clean")
	check(clean)
	if !clean {
		rt.print(string(status[:max(n, 0)]))
	}

	rt.print("fsdconc: ", u64(checks), " checks, ", u64(failures), " failed\n")
	return 0
}
