// The boot image's archive format, ustar (POSIX.1-1988), read by svcd and
// bootfs and written by build's mkbootfs (upstream 04 §3.4).
//
// Only what a boot image holds: regular files, directories, and hard links
// to a regular file earlier in the archive, read as that file's contents (one
// program under many names: sbase's box, upstream ADR-0016). The reader is
// strict, because a boot image may be built by anyone with access to the ESP:
// every header's checksum and octal fields are checked, every file lies inside
// the image, and every path is relative, has no empty, "." or ".." component,
// is a name as upstream ADR-0013 has it (UTF-8, no control characters), and
// fits its fields. The first bad header ends the archive with
// Err_Invalid; no entry after it is returned.
//
// The writer is deterministic: the same files in the same order give the same
// bytes (mtime, uid and gid are zero; names are as given), so images are
// reproducible (upstream 04 §3.3).
//
// Imports only the ABI, lib/str and lib/utf, and allocates nothing, so the kernel's
// bootfs and the host build tool share it.
package tar

import vx "abi:vx"
import "vx:str"
import "vx:utf"

BLOCK :: 512

// prefix (155), '/', name (100). (Upstream said 255 until M3, so a path that
// filled both fields wrote its NUL one byte past the entry; here the buffer
// holds the path alone, with no NUL.)
MAX_PATH :: 256

Header :: struct {
	name:     [100]u8,
	mode:     [8]u8,
	uid:      [8]u8,
	gid:      [8]u8,
	size:     [12]u8,
	mtime:    [12]u8,
	chksum:   [8]u8,
	typeflag: u8,
	linkname: [100]u8,
	magic:    [6]u8,
	version:  [2]u8,
	uname:    [32]u8,
	gname:    [32]u8,
	devmajor: [8]u8,
	devminor: [8]u8,
	prefix:   [155]u8,
	pad:      [12]u8,
}
#assert(size_of(Header) == BLOCK)

// An entry holds its path itself (entry_path gives it), so it may be copied
// and returned by value.
Entry :: struct {
	dir:      bool,
	mode:     u32, // permission bits
	data:     []u8, // into the image; nil for a directory
	path_buf: [MAX_PATH]u8,
	path_len: int,
}

// The entry's path: "boot/svc/bootfs.ndb", without a trailing '/'.
entry_path :: proc "contextless" (e: ^Entry) -> string {
	return string(e.path_buf[:e.path_len])
}

Reader :: struct {
	image:  []u8,
	pos:    int,
	done:   bool,
	failed: bool,
}

open :: proc "contextless" (image: []u8) -> Reader {
	return Reader{image = image}
}

// A hard link's target path, as its header has it.
@(private="file")
Link :: [dynamic; 100]u8

// The next entry, as its header has it; a link's target path in link (else
// empty), unresolved, with no data. Err_Not_Found at the end of the archive
// (a zero block, or the end of the image); Err_Invalid at a bad header, and
// for every call after it.
@(private="file")
read_entry :: proc "contextless" (t: ^Reader, e: ^Entry, link: ^Link) -> vx.Status {
	clear(link)
	e^ = {}
	if t.failed {
		return .Err_Invalid
	}
	if t.done || len(t.image) - t.pos < BLOCK || zero_block(t.image[t.pos:][:BLOCK]) {
		t.done = true
		return .Err_Not_Found
	}
	src := t.image[t.pos:]
	h := (^Header)(raw_data(src))^ // one copy (Header is all bytes, so any address will do), then checked
	t.failed = true // until the header passes

	sum, size, mode: u64
	ok: bool
	if sum, ok = octal(h.chksum[:]); !ok || sum != u64(checksum(&h)) {
		return .Err_Invalid
	}
	if string(h.magic[:5]) != "ustar" {
		return .Err_Invalid
	}
	if size, ok = octal(h.size[:]); !ok {
		return .Err_Invalid
	}
	if mode, ok = octal(h.mode[:]); !ok {
		return .Err_Invalid
	}
	is_link := h.typeflag == '1'
	if h.typeflag == '5' {
		e.dir = true
	} else if h.typeflag != '0' && h.typeflag != 0 && !is_link {
		return .Err_Invalid // no symbolic links, devices or extensions
	}
	if (is_link && size != 0) || (e.dir && size != 0) || mode > 0o7777 {
		return .Err_Invalid
	}
	e.mode = u32(mode)

	plen, pok := field_len(h.prefix[:])
	nlen, nok := field_len(h.name[:])
	if !pok || !nok {
		return .Err_Invalid
	}
	n := copy(e.path_buf[:], h.prefix[:plen])
	if plen > 0 {
		e.path_buf[n] = '/'
		n += 1
	}
	n += copy(e.path_buf[n:], h.name[:nlen])
	if e.dir && n > 0 && e.path_buf[n - 1] == '/' {
		n -= 1
	}
	e.path_len = n
	if !path_ok(entry_path(e)) {
		return .Err_Invalid
	}

	blocks := (size + BLOCK - 1) / BLOCK
	if size > u64(len(t.image)) || blocks > u64((len(t.image) - t.pos) / BLOCK - 1) {
		return .Err_Invalid
	}
	if is_link {
		tlen, tok := field_len(h.linkname[:])
		if !tok || !path_ok(string(h.linkname[:tlen])) {
			return .Err_Invalid
		}
		_ = append(link, ..h.linkname[:tlen])
	} else if !e.dir {
		e.data = src[BLOCK:][:size]
	}
	t.pos += int(1 + blocks) * BLOCK
	t.failed = false
	return .Ok
}

// The regular file at path among the archive's first bytes, before: what a
// link there names. Links are not followed, so none forms a cycle.
@(private="file")
link_target :: proc "contextless" (before: []u8, path: string, e: ^Entry) -> bool {
	scan := open(before)
	link: Link
	for read_entry(&scan, e, &link) == .Ok {
		if !e.dir && len(link) == 0 && entry_path(e) == path {
			return true
		}
	}
	return false
}

// The next entry; a link reads as the regular file it names, earlier in the
// archive. Err_Not_Found at the end of the archive (a zero block, or the end
// of the image); Err_Invalid at a bad header, and for every call after it.
@(require_results)
next :: proc "contextless" (t: ^Reader, e: ^Entry) -> vx.Status {
	link: Link
	at := t.pos
	read_entry(t, e, &link) or_return
	if len(link) == 0 {
		return .Ok
	}
	target: Entry
	if !link_target(t.image[:at], string(link[:]), &target) {
		t.failed = true
		return .Err_Invalid
	}
	e.data = target.data
	return .Ok
}

// Finds a file or directory by path. Err_Not_Found if the archive (up to any
// bad header) has none.
@(require_results)
find :: proc "contextless" (image: []u8, path: string, out: ^Entry) -> vx.Status {
	t := open(image)
	st: vx.Status
	for st = next(&t, out); st == .Ok; st = next(&t, out) {
		if entry_path(out) == path {
			return .Ok
		}
	}
	return st == .Err_Invalid ? st : .Err_Not_Found
}

// The entries in order, as an iterator:
//
//	r := tar.open(image)
//	for e in tar.entries(&r) { ... }
//	if r.failed { ... } // a bad header ended the archive
entries :: proc "contextless" (t: ^Reader) -> (e: Entry, ok: bool) {
	ok = next(t, &e) == .Ok
	return
}

// An octal field: digits, then NUL or space padding to its end. The field
// must hold at least one digit.
@(private="file")
octal :: proc "contextless" (f: []u8) -> (v: u64, ok: bool) {
	i := 0
	for i < len(f) && f[i] == ' ' { // some writers pad the front
		i += 1
	}
	digits := 0
	for ; i < len(f) && f[i] >= '0' && f[i] <= '7'; i += 1 {
		if v >> 61 != 0 {
			return 0, false // would overflow
		}
		v = v * 8 + u64(f[i] - '0')
		digits += 1
	}
	for ; i < len(f); i += 1 {
		if f[i] != 0 && f[i] != ' ' {
			return 0, false
		}
	}
	return v, digits > 0
}

// The length of a NUL-padded field, or len(f) if it fills it. ok is false if
// bytes follow the terminator.
@(private="file")
field_len :: proc "contextless" (f: []u8) -> (n: int, ok: bool) {
	n = len(str.from_nul_padded(f))
	for b in f[n:] {
		if b != 0 {
			return 0, false
		}
	}
	return n, true
}

// A relative path with no empty, "." or ".." component, whose components are
// names as ADR-0013 has them: UTF-8, no control characters. A directory's one
// trailing '/' is removed before this.
@(private="file")
path_ok :: proc "contextless" (p: string) -> bool {
	if p == "" || str.has_suffix(p, "/") { // an empty last component
		return false
	}
	rest := p
	for c in str.split_iterator(&rest, '/') {
		if c == "" || c == "." || c == ".." || !utf.is_name(c) {
			return false
		}
	}
	return true
}

@(private="file")
checksum :: proc "contextless" (h: ^Header) -> u32 {
	sum: u32
	for b, i in transmute([BLOCK]u8)h^ {
		sum += (i >= 148 && i < 156) ? ' ' : u32(b) // the checksum field counts as spaces
	}
	return sum
}

@(private="file")
zero_block :: proc "contextless" (b: []u8) -> bool {
	for c in b {
		if c != 0 {
			return false
		}
	}
	return true
}

// --- Writing ---

// An archive being written into a caller's buffer. A bad path, or running
// out of room, sets failed, and every later call is ignored.
Writer :: struct {
	using out: str.Buf,
}

// Adds a file holding data or, with dir set (and data empty), a directory,
// with its permission bits. The path is split into prefix and name where it
// must be.
add :: proc "contextless" (w: ^Writer, path: string, dir: bool, mode: u32, data: []u8) {
	if w.failed {
		return
	}
	size := u64(len(data))
	blocks := (size + BLOCK - 1) / BLOCK
	h: Header
	split := 0 // the length of the prefix; 0 if the name holds it all
	fits := len(path) <= len(h.name)
	for i := len(path) - 1; !fits && i >= 0; i -= 1 {
		if path[i] == '/' && i <= len(h.prefix) && len(path) - i - 1 <= len(h.name) && len(path) - i - 1 > 0 {
			split = i
			fits = true
		}
	}
	if !fits || !path_ok(path) || (dir && size != 0) || mode > 0o7777 ||
	   blocks + 1 > u64((len(w.buf) - w.len) / BLOCK) {
		w.failed = true
		return
	}
	copy(h.prefix[:], path[:split])
	copy(h.name[:], path[split > 0 ? split + 1 : 0:])
	put_octal(h.mode[:], u64(mode))
	put_octal(h.uid[:], 0)
	put_octal(h.gid[:], 0)
	put_octal(h.size[:], size)
	put_octal(h.mtime[:], 0)
	h.typeflag = dir ? '5' : '0'
	copy(h.magic[:], "ustar\x00")
	h.version = {'0', '0'}
	put_octal(h.chksum[:7], u64(checksum(&h))) // six digits, a NUL, and a space
	h.chksum[7] = ' '
	out := w.buf[w.len:][:int(1 + blocks) * BLOCK]
	header := transmute([BLOCK]u8)h
	copy(out, header[:])
	n := copy(out[BLOCK:], data)
	for &b in out[BLOCK + n:] {
		b = 0
	}
	w.len += len(out)
}

// Adds a hard link at path to target, a regular file added before it.
add_link :: proc "contextless" (w: ^Writer, path, target: string, mode: u32) {
	if w.failed {
		return
	}
	before := w.len
	add(w, path, false, mode, nil)
	if w.failed {
		return
	}
	h := (^Header)(raw_data(w.buf[before:]))
	if len(target) > len(h.linkname) || !path_ok(target) {
		w.failed = true
		return
	}
	copy(h.linkname[:], target)
	h.typeflag = '1'
	put_octal(h.chksum[:7], u64(checksum(h)))
	h.chksum[7] = ' '
}

// Ends the archive with its two zero blocks. Returns its length, or 0.
@(require_results)
end :: proc "contextless" (w: ^Writer) -> int {
	if w.failed || len(w.buf) - w.len < 2 * BLOCK {
		return 0
	}
	for &b in w.buf[w.len:][:2 * BLOCK] {
		b = 0
	}
	w.len += 2 * BLOCK
	return w.len
}

// An octal field of len(f) - 1 digits, zero-filled, and a NUL.
@(private="file")
put_octal :: proc "contextless" (f: []u8, v: u64) {
	f[len(f) - 1] = 0
	x := v
	for i := len(f) - 2; i >= 0; i -= 1 {
		f[i] = u8('0' + (x & 7))
		x >>= 3
	}
}
