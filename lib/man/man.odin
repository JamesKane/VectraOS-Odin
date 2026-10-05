// vx:man, the installed manual as man, lookman and sig read it (upstream
// docs/12-manual.md §5, §6.1; its lib/vx-man): pages at
// /lib/man/<sect>/<page>, and the index, /lib/man/index/, a directory of ndb
// files (base, one per package, home) whose union is the index. One record
// per name a page documents, and per node:
//
//   name=vx_create page=open sect=2 summary="open, create or close a file"
//   name=quoting page=rc sect=1 node=quoting title="Quoting"
//
// Pages are parsed by vx:guide; this only finds them. Nothing is allocated:
// the caller gives the buffers.
package man

import vx "abi:vx"
import "vx:ndb"
import "vx:ns"
import "vx:p9"
import "vx:str"

INDEX_DIR :: "/lib/man/index"

// The index's buffers: a directory read, one index file, and its records'
// decoded values. Large: a program keeps one as a global.
Index_Buffers :: struct {
	ents:    [4096]u8,
	text:    [256 * 1024]u8,
	scratch: [4096]u8,
}

// /lib/man/<sect>/<name>, in buf; false if it does not fit with a byte to
// spare (upstream's room for a NUL, so the same names fit), or sect is not 1-8.
page_path :: proc "contextless" (buf: []u8, sect: int, name: string) -> (path: string, ok: bool) {
	if sect < 1 || sect > 8 || len(buf) == 0 {
		return "", false
	}
	digit := [1]u8{u8('0' + sect)}
	return str.join(buf[:len(buf) - 1], "/lib/man/", string(digit[:]), "/", name)
}

// A whole file into buf: its length, or Err_Range if it holds more than buf
// (what fitted is in buf), or the open's or a read's error.
@(require_results)
read_file :: proc "contextless" (space: ^ns.Namespace, path: string, buf: []u8) -> (n: int, st: vx.Status) {
	f: ns.File
	ns.open(space, path, p9.OREAD, &f) or_return
	defer ns.close(&f)
	n = ns.read_all(&f, buf) or_return
	if n == len(buf) {
		more: [1]u8
		if got, _ := ns.read(&f, more[:]); got > 0 {
			return n, .Err_Range
		}
	}
	return n, .Ok
}

// Called for each record of the index until it returns false.
Each :: proc "contextless" (arg: rawptr, rec: ^ndb.Record) -> bool

// Calls each(arg, rec) for every record of every file in the index, until it
// returns false. A file that cannot be read, or holds more than b.text, is
// passed over, and a file's records stop at its first malformed one. False
// if the index cannot be read.
index :: proc "contextless" (space: ^ns.Namespace, b: ^Index_Buffers, each: Each, arg: rawptr) -> bool {
	dir: ns.File
	if ns.open(space, INDEX_DIR, p9.OREAD, &dir) != .Ok {
		return false
	}
	defer ns.close(&dir)
	go := true
	for go {
		n, st := ns.read(&dir, b.ents[:])
		if st != .Ok || n <= 0 {
			break
		}
		it := p9.Dir_Entries{buf = b.ents[:n]}
		for go {
			e := p9.next_entry(&it) or_break
			pbuf: [96]u8
			path, fits := str.join(pbuf[:len(pbuf) - 1], INDEX_DIR, "/", e.name)
			if !fits {
				continue
			}
			len_text, rst := read_file(space, path, b.text[:])
			if rst != .Ok {
				continue
			}
			r := ndb.Reader{src = string(b.text[:len_text]), scratch = b.scratch[:]}
			rec: ndb.Record
			for go && ndb.next(&r, &rec) == .Record {
				r.scratch_used = 0 // each record's values are used before the next is read
				go = each(arg, &rec)
			}
		}
	}
	return true
}

// A search for a page by title, in sects.
@(private="file")
Find :: struct {
	space:    ^ns.Namespace,
	title:    string,
	sects:    []int,
	buf:      []u8,
	path_buf: []u8,
	path:     string,
	n:        int, // the page's length; 0 while none is found
}

@(private="file")
wanted :: proc "contextless" (f: ^Find, sect: int) -> bool {
	for s in f.sects {
		if s == sect {
			return true
		}
	}
	return false
}

@(private="file")
by_name :: proc "contextless" (arg: rawptr, rec: ^ndb.Record) -> bool {
	f := (^Find)(arg)
	name, _ := ndb.get(rec, "name")
	sect, has_sect := ndb.get_u64(rec, "sect")
	if ndb.has(rec, "node") || name != f.title || !has_sect || sect > 8 || !wanted(f, int(sect)) {
		return true
	}
	page, _ := ndb.get(rec, "page")
	if path, ok := page_path(f.path_buf, int(sect), page); ok {
		if n, st := read_file(f.space, path, f.buf); st == .Ok {
			f.path, f.n = path, n
			return false
		}
	}
	f.n = 0
	return true
}

// The page title from the first of sects that has it, read into buf, its
// path made in path_buf: by its own file, else through the index (a name it
// documents). The page, or ok false.
read :: proc "contextless" (space: ^ns.Namespace, title: string, sects: []int, buf, path_buf: []u8, b: ^Index_Buffers) -> (page, path: string, ok: bool) {
	for s in sects {
		p := page_path(path_buf, s, title) or_continue
		if n, st := read_file(space, p, buf); st == .Ok {
			return string(buf[:n]), p, n > 0 // an empty page is none, as upstream's
		}
	}
	f := Find{space = space, title = title, sects = sects, buf = buf, path_buf = path_buf}
	_ = index(space, b, by_name, &f)
	if f.n == 0 {
		return "", "", false
	}
	return string(buf[:f.n]), f.path, true
}
