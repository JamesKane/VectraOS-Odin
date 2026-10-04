// The boot image's archive format, ustar (POSIX.1-1988), read by svcd and
// bootfs and written by build's mkbootfs (upstream 04 §3.4).
//
// Only what a boot image holds: regular files and directories. The reader is
// strict, because a boot image may be built by anyone with access to the ESP:
// every header's checksum and octal fields are checked, every file lies inside
// the image, and every path is relative, has no empty, "." or ".." component,
// and fits its fields. The first bad header ends the archive with
// Err_Invalid; no entry after it is returned.
//
// The writer is deterministic: the same files in the same order give the same
// bytes (mtime, uid and gid are zero; names are as given), so images are
// reproducible (upstream 04 §3.3).
//
// Imports nothing and allocates nothing, so the kernel's bootfs and the host
// build tool share it.
package tar

import vx "abi:vx"

BLOCK :: 512

// prefix (155), '/', name (100). Upstream says 255 and keeps a NUL after the
// path in a 256-byte buffer, so a path that fills both fields writes one byte
// past it; here the buffer holds the path alone, and such a path reads.
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

// path points into buf, so it is valid only while this Entry is where next
// or find filled it in.
Entry :: struct {
	path: string, // "boot/svc/bootfs.ndb", without a trailing '/'
	dir:  bool,
	mode: u32, // permission bits
	data: []u8, // into the image; nil for a directory
	buf:  [MAX_PATH]u8,
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

// The next entry. Err_Not_Found at the end of the archive (a zero block, or
// the end of the image); Err_Invalid at a bad header, and for every call
// after it.
@(require_results)
next :: proc "contextless" (t: ^Reader, e: ^Entry) -> vx.Status {
	e^ = {}
	if t.failed {
		return .Err_Invalid
	}
	if t.done || len(t.image) - t.pos < BLOCK || zero_block(t.image[t.pos:][:BLOCK]) {
		t.done = true
		return .Err_Not_Found
	}
	src := t.image[t.pos:]
	h: Header
	copy(header_bytes(&h), src[:BLOCK]) // one copy, then checked
	t.failed = true // until the header passes

	sum, size, mode: u64
	ok: bool
	if sum, ok = octal(h.chksum[:]); !ok || sum != u64(checksum(&h)) {
		return .Err_Invalid
	}
	if h.magic[0] != 'u' || h.magic[1] != 's' || h.magic[2] != 't' || h.magic[3] != 'a' || h.magic[4] != 'r' {
		return .Err_Invalid
	}
	if size, ok = octal(h.size[:]); !ok {
		return .Err_Invalid
	}
	if mode, ok = octal(h.mode[:]); !ok {
		return .Err_Invalid
	}
	if h.typeflag == '5' {
		e.dir = true
	} else if h.typeflag != '0' && h.typeflag != 0 {
		return .Err_Invalid // no links, devices or extensions
	}
	if (e.dir && size != 0) || mode > 0o7777 {
		return .Err_Invalid
	}
	e.mode = u32(mode)

	plen, pok := field_len(h.prefix[:])
	nlen, nok := field_len(h.name[:])
	if !pok || !nok {
		return .Err_Invalid
	}
	n := copy(e.buf[:], h.prefix[:plen])
	if plen > 0 {
		e.buf[n] = '/'
		n += 1
	}
	n += copy(e.buf[n:], h.name[:nlen])
	if e.dir && n > 0 && e.buf[n - 1] == '/' {
		n -= 1
	}
	e.path = string(e.buf[:n])
	if !path_ok(e.path) {
		return .Err_Invalid
	}

	blocks := (size + BLOCK - 1) / BLOCK
	if size > u64(len(t.image)) || blocks > u64((len(t.image) - t.pos) / BLOCK - 1) {
		return .Err_Invalid
	}
	if !e.dir {
		e.data = src[BLOCK:][:size]
	}
	t.pos += int(1 + blocks) * BLOCK
	t.failed = false
	return .Ok
}

// Finds a file or directory by path. Err_Not_Found if the archive (up to any
// bad header) has none.
@(require_results)
find :: proc "contextless" (image: []u8, path: string, out: ^Entry) -> vx.Status {
	t := open(image)
	st: vx.Status
	for st = next(&t, out); st == .Ok; st = next(&t, out) {
		if out.path == path {
			return .Ok
		}
	}
	return st == .Err_Invalid ? st : .Err_Not_Found
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
	for n < len(f) && f[n] != 0 {
		n += 1
	}
	for i in n ..< len(f) {
		if f[i] != 0 {
			return 0, false
		}
	}
	return n, true
}

// A relative path with no empty, "." or ".." component, and nothing
// unprintable. A directory's one trailing '/' is removed before this.
@(private="file")
path_ok :: proc "contextless" (p: string) -> bool {
	if len(p) == 0 {
		return false
	}
	start := 0
	for i in 0 ..= len(p) {
		if i < len(p) && p[i] != '/' {
			if p[i] < 0x20 || p[i] == 0x7f {
				return false
			}
			continue
		}
		c := p[start:i]
		if len(c) == 0 || c == "." || c == ".." {
			return false
		}
		start = i + 1
	}
	return true
}

@(private="file")
header_bytes :: proc "contextless" (h: ^Header) -> []u8 {
	return ([^]u8)(h)[:BLOCK]
}

@(private="file")
checksum :: proc "contextless" (h: ^Header) -> u32 {
	sum: u32
	for b, i in header_bytes(h) {
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

// An archive being written into a caller's buffer.
Writer :: struct {
	buf:    []u8,
	len:    int,
	failed: bool, // a bad path, or out of room; every later call is ignored
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
	copy(out, header_bytes(&h))
	n := copy(out[BLOCK:], data)
	for &b in out[BLOCK + n:] {
		b = 0
	}
	w.len += len(out)
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
