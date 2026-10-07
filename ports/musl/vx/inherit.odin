package backend

import vx "abi:vx"
import "linux"
import "vx:ndb"
import "vx:ns"
import "vx:p9"
import "vx:rt"

// Descriptors for a child.
//
// A child (posix_spawn, execve) is given a table of descriptors as fd=
// records in its spawn message, one per open descriptor without FD_CLOEXEC
// (the working directory goes as vx:procns's cwd=, ADR-0017):
//   fd=N console
//   fd=N pipe=read|write end=NAME flags=F       the same channel end, shared
//   fd=N file=PATH flags=F offset=O [dir] [token=T]   joined, or opened again
//   fd=N same=M                                 the same description as M
// A file with a token is the same open file, its offset shared; one without
// (a server without posix) is opened again, its offset the child's own. A
// socket is its /net data file, with what the back end keeps of it.

// A file or directory at path, opened again with the description's flags
// (never creating or truncating) at offset.
@(private="file")
file_reopen :: proc "contextless" (path: string, flags: linux.Open_Flags, offset: u64) -> ^Ofd {
	f: ns.File
	if ns.open(namespace(), path, open_mode(flags), &f) != .Ok {
		return nil
	}
	s: p9.Stat
	dir := p9.client_stat(f.c, f.fid, &s) == .Ok && s.mode & p9.DMDIR != 0
	o := ofd_new(.File, flags & KEPT_FLAGS)
	if o == nil {
		ns.close(&f)
		return nil
	}
	o.f = f
	o.dir = dir
	if !dir {
		o.f.offset = offset
	}
	_ = append(&o.path, path)
	if file_shared(o) {
		_, _ = p9.client_seek(o.f.c, o.f.fid, i64(offset), .Set)
		if .Append in flags {
			_ = p9.client_append(o.f.c, o.f.fid, true)
		}
	}
	tty_check(o)
	return o
}

// The open file a token names, joined on the server path is on (the
// parent's); or, if it cannot be, the file opened again at offset.
@(private="file")
file_join :: proc "contextless" (path: string, flags: linux.Open_Flags, token: [p9.TOKEN_SIZE]u8, offset: u64) -> ^Ofd {
	// Any fid on the server picks the connection the token is good on: the
	// file's own, or its directory's, if it was removed or renamed since.
	dir := len(path)
	for dir > 1 && path[dir - 1] != '/' {
		dir -= 1
	}
	c, fid, st := ns.walk(namespace(), path)
	if st != .Ok {
		c, fid, st = ns.walk(namespace(), path[:dir])
	}
	if st == .Ok {
		_ = p9.client_clunk(c, fid)
		if joined, jst := p9.client_join(c, token); jst == .Ok {
			o := ofd_new(.File, flags & KEPT_FLAGS)
			if o == nil {
				_ = p9.client_clunk(c, joined)
				return nil
			}
			o.f = {
				ns  = namespace(),
				c   = c,
				fid = joined,
			}
			_ = append(&o.path, path)
			tty_check(o)
			return o
		}
	}
	return file_reopen(path, flags, offset)
}

// The names of the pipe ends a child is given: "fd.NN".
@(private="file")
handle_names: [FD_MAX][5]u8

@(private="file")
flags_word :: proc "contextless" (f: linux.Open_Flags) -> u64 {
	return u64(transmute(u32)f)
}

// The child's file-creation mask and descriptors as records, its pipes' ends
// duplicated into handles[count^:cap] (names beside them). Its working
// directory is procns.spawn_records' cwd=.
fd_records :: proc "contextless" (table: ^[FD_MAX]Slot, w: ^ndb.Writer, handles: []vx.Handle, names: []string, count: ^int, cap: int) {
	ndb.put_u64(w, "umask", u64(umask)) // musl's own, as signals= is
	_ = ndb.end(w)
	for &slot, fd in table {
		o := slot.o
		if o == nil || slot.cloexec || o.lost {
			continue
		}
		same := -1
		for j in 0 ..< fd {
			if table[j].o == o && !table[j].cloexec {
				same = j
				break
			}
		}
		ndb.put_u64(w, "fd", u64(fd))
		switch {
		case same >= 0:
			ndb.put_u64(w, "same", u64(same))
		case o.kind == .Console:
			ndb.flag(w, "console")
		case o.kind == .Pipe_In || o.kind == .Pipe_Out:
			nm := &handle_names[fd]
			nm^ = {'f', 'd', '.', '0' + u8(fd / 10), '0' + u8(fd % 10)}
			h, st := vx.HANDLE_NONE, vx.Status.Err_Range
			if count^ < cap && o.pipe != vx.HANDLE_NONE {
				h, st = rt.handle_dup(o.pipe, vx.RIGHTS_SAME)
			}
			if st == .Ok {
				handles[count^], names[count^] = h, string(nm[:])
				count^ += 1
				ndb.put(w, "pipe", o.kind == .Pipe_In ? "read" : "write")
				ndb.put(w, "end", string(nm[:])) // not handle=, which declares a handle
				ndb.put_u64(w, "flags", flags_word(o.flags))
			} else {
				w.failed = true
			}
		case o.kind == .File:
			ndb.put(w, "file", string(o.path[:]))
			ndb.put_u64(w, "flags", flags_word(o.flags))
			at, ok := file_offset(o)
			ndb.put_u64(w, "offset", ok && i64(at) >= 0 ? at : 0)
			if file_shared(o) {
				if token, tst := p9.client_share(o.f.c, o.f.fid, 1); tst == .Ok { // the child joins it
					ndb.put(w, "token", string(token[:]))
				}
			}
			if o.dir {
				ndb.flag(w, "dir")
			}
			if o.sock.type != 0 { // a socket: its /net data file, and what the back end keeps of it
				ndb.put_u64(w, "sock", u64(o.sock.type))
				ndb.put_u64(w, "port", u64(o.sock.port))
				if o.sock.bound {
					ndb.flag(w, "bound")
				}
				if o.sock.listening {
					ndb.flag(w, "listening")
				}
			}
		}
		_ = ndb.end(w)
	}
}

@(private="file")
records_scratch: [vx.CHANNEL_MAX_BYTES]u8

// The descriptors a POSIX parent's records give (the working directory is vx:rt's cwd=).
from_records :: proc "contextless" () {
	r := ndb.Reader {
		src     = rt.spawn.text,
		scratch = records_scratch[:],
	}
	rec: ndb.Record
	for ndb.next(&r, &rec) == .Record {
		if ndb.has(&rec, "cwd") {
			continue // vx:rt's, read at start-up
		}
		fd, ok := ndb.get_u64(&rec, "fd")
		if !ok || fd >= FD_MAX {
			continue
		}
		flags_n, _ := ndb.get_u64(&rec, "flags")
		offset, _ := ndb.get_u64(&rec, "offset")
		flags := transmute(linux.Open_Flags)u32(flags_n)
		switch {
		case ndb.has(&rec, "same"):
			if n, sok := ndb.get_u64(&rec, "same"); sok && n < FD_MAX && fd_table[n].o != nil {
				fd_table[n].o.refs += 1
				fd_place(int(fd), fd_table[n].o)
			}
		case ndb.has(&rec, "console"):
			fd_place(int(fd), rt.console_connector() != vx.HANDLE_NONE ? ofd_new(.Console, linux.O_RDWR) : nil)
		case ndb.has(&rec, "pipe"):
			name, _ := ndb.get(&rec, "end")
			if len(name) >= 8 {
				continue
			}
			end := rt.spawn_take(name)
			kind, _ := ndb.get(&rec, "pipe")
			if end != vx.HANDLE_NONE {
				fd_place(int(fd), pipe_ofd(end, len(kind) == 4, flags & {.Nonblock})) // "read"
			}
		case ndb.has(&rec, "file"):
			path, _ := ndb.get(&rec, "file")
			token, _ := ndb.get(&rec, "token")
			if len(path) >= ns.MAX_PATH {
				continue
			}
			o: ^Ofd
			if len(token) == p9.TOKEN_SIZE {
				t: [p9.TOKEN_SIZE]u8
				copy(t[:], token)
				o = file_join(path, flags, t, offset)
			} else {
				o = file_reopen(path, flags, offset)
			}
			if sock, sok := ndb.get_u64(&rec, "sock"); o != nil && sok {
				port, _ := ndb.get_u64(&rec, "port")
				o.sock.type = u8(sock)
				o.sock.port = u16(port)
				o.sock.bound = ndb.has(&rec, "bound")
				o.sock.listening = ndb.has(&rec, "listening")
			}
			fd_place(int(fd), o)
		}
	}
}

// --- After a fork ---
//
// The child has a copy of this memory, so the table is as it was, but not
// of rings: the namespace's connections and the console's are gone, and so
// are the fids its files were open on. Each is opened again by its path, at
// its offset. A directory starts again from its first entry. Pipe ends are
// shared, as POSIX has them; the port a blocked read waits on is the child's
// own.

// Before a fork: a token for each open file the child should join.
fd_before_fork :: proc "contextless" () {
	for &o in ofds {
		o.has_token = false
		if file_shared(&o) {
			token, st := p9.client_share(o.f.c, o.f.fid, 1)
			o.token, o.has_token = token, st == .Ok
		}
		if o.has_token {
			if at, ok := file_offset(&o); ok && i64(at) >= 0 {
				o.f.offset = at // for the child, if it cannot join
			}
		}
	}
}

fd_after_fork_parent :: proc "contextless" () {
	for &o in ofds {
		o.has_token = false
	}
}

fd_after_fork :: proc "contextless" () {
	rt.console_forget()
	rt.close_all(fd_port)
	fd_port, _ = rt.port_create()
	namespace_after_fork()
	for &o in ofds {
		o.closed_bound, o.read_bound = false, false
		if o.ra != nil { // their connections' rings were not copied
			ra_forget(o.ra)
			o.ra = nil
		}
		if o.wb != nil {
			ra_forget(o.wb)
		}
		o.wb = nil
		o.sock.connecting = false // the parent's to finish
		if o.kind != .File {
			continue
		}
		offset := o.f.offset
		o.f = {} // the fid was on the old connection
		path := string(o.path[:])
		n := o.has_token ? file_join(path, o.flags, o.token, offset) : file_reopen(path, o.flags, offset)
		o.has_token = false
		if n == nil { // gone: every call on it now fails with EBADF
			o.lost = true
			continue
		}
		o.f = n.f
		o.dirs_len, o.dirs_at, o.dir_next = 0, 0, 0
		n^ = {} // its fid is o's now
	}
	ra_pools_forget()
}
