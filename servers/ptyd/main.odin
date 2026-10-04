// ptyd: pseudo-terminals (upstream docs/01 §9), posted as /srv/ptyd and
// mounted on /dev by the POSIX template (/lib/ns/posix).
//
//   ptmx        opening it makes a new terminal: the fid becomes its master
//   pts/N       terminal N's slave: what the program on it reads and writes
//   pts/N.ctl   its settings as an ndb record: reading gives them, writing
//               changes those it names (the musl back end's tcgetattr,
//               tcsetattr, TIOCGWINSZ, tcsetpgrp and the rest)
//
// The line discipline is here, as Linux's: input typed at the master is
// edited in canonical mode (erase, kill, ^D), echoed, and turned into signals
// (^C, ^Z, ^\) to the terminal's foreground process group: a note written to
// the group's notepg in /proc (upstream ADR-0011), "interrupt" for ^C as in
// Plan 9; the slave's output has NL made CR NL (ONLCR). A read with nothing
// to give is held until there is (Err_Should_Wait, which the ring server
// holds). A signal ptyd sends ends the slave reads it holds, as
// "interrupted", so ^C at a prompt is seen at once. The termios numbers are
// Linux's: the POSIX personality's.
package ptyd

import vx "abi:vx"
import "vx:ndb"
import "vx:note"
import "vx:ns"
import "vx:p9"
import "vx:p9ring"
import "vx:procns"
import "vx:rt"
import "vx:signal"
import "vx:str"
import "vx:utf"

PTYS :: 16
BUF :: 4096
NCCS :: 32
MAX_BREAKS :: 16

// Node numbers, which are the qids' paths. A terminal's master, slave and
// ctl are MASTER, SLAVE and CTL plus its number.
@(private="file")
ROOT :: p9.Node(1)
@(private="file")
PTMX :: p9.Node(2)
@(private="file")
PTS :: p9.Node(3)
@(private="file")
MASTER :: p9.Node(0x100)
@(private="file")
SLAVE :: p9.Node(0x200)
@(private="file")
CTL :: p9.Node(0x300)

// Linux's termios bits, as far as ptyd acts on them; any others a program
// sets are kept and read back as they were.
Iflag :: enum u32 {
	Icrnl = 8, // 0400
	Iutf8 = 14, // 040000
}
Oflag :: enum u32 {
	Opost = 0, // 01
	Onlcr = 2, // 04
}
Lflag :: enum u32 {
	Isig   = 0, // 01
	Icanon = 1, // 02
	Echo   = 3, // 010
	Echoe  = 4, // 020
	Echok  = 5, // 040
}
Iflags :: bit_set[Iflag;u32]
Oflags :: bit_set[Oflag;u32]
Lflags :: bit_set[Lflag;u32]

// Linux's control characters' places in cc.
V_INTR :: 0
V_QUIT :: 1
V_ERASE :: 2
V_KILL :: 3
V_EOF :: 4
V_MIN :: 6
V_SUSP :: 10

SIGQUIT :: signal.Signal(3)
SIGTSTP :: signal.Signal(20)

Byte_Ring :: struct {
	b:          [BUF]u8,
	head, used: u32,
}

Pty :: struct {
	used, master_gone: bool,
	masters, slaves:   u32, // opens of each side
	iflag:             Iflags,
	oflag:             Oflags,
	cflag:             u32,
	lflag:             Lflags,
	cc:                [NCCS]u8,
	rows, cols:        u16,
	pgrp:              i64, // the foreground process group, 0 for none
	input:             Byte_Ring, // ended lines (canonical) or bytes, for the slave to read
	// Where a read of `in` must stop though no newline came: after a line a
	// ^D sent as it was, or, where nothing came since, the end of the file (a
	// read of 0). Positions count the bytes ever put in `in`.
	in_put, in_taken:  u64,
	breaks:            [dynamic; MAX_BREAKS]u64,
	line:              [dynamic; BUF]u8, // the line being typed (canonical)
	out:               Byte_Ring, // for the master to read: the slave's output and echo
	reading:           bool, // a slave read is held, waiting for input
	interrupted:       bool, // a signal was sent while one was: it ends
}

// Not file-private: tests/host looks at the terminals.
ptys: [PTYS]Pty
@(private="file")
space: ns.Namespace // /proc, to signal process groups
@(private="file")
proc_mounted: bool // it is there

@(private="file")
ring_put :: proc "contextless" (r: ^Byte_Ring, c: u8) {
	if r.used == BUF {
		return // full: dropped, as a terminal does
	}
	r.b[(r.head + r.used) % BUF] = c
	r.used += 1
}

@(private="file")
ring_take :: proc "contextless" (r: ^Byte_Ring, out: []u8) -> u32 {
	n := min(u32(len(out)), r.used)
	for i in 0 ..< n {
		out[i] = r.b[(r.head + i) % BUF]
	}
	r.head = (r.head + n) % BUF
	r.used -= n
	return n
}

// Input, counted, for the breaks' positions.
@(private="file")
in_put :: proc "contextless" (p: ^Pty, c: u8) {
	if p.input.used == BUF {
		return // full: dropped, as a terminal does
	}
	ring_put(&p.input, c)
	p.in_put += 1
}

@(private="file")
drop_break :: proc "contextless" (p: ^Pty) {
	copy(p.breaks[:], p.breaks[1:])
	resize(&p.breaks, len(p.breaks) - 1)
}

@(private="file")
in_take :: proc "contextless" (p: ^Pty, out: []u8) -> u32 {
	n := ring_take(&p.input, out)
	p.in_taken += u64(n)
	for len(p.breaks) > 0 && p.breaks[0] < p.in_taken { // passed (a read not canonical): forgotten
		drop_break(p)
	}
	return n
}

@(private="file")
in_break :: proc "contextless" (p: ^Pty) {
	_ = append(&p.breaks, p.in_put) // so many unread: the rest run on
}

@(private="file")
in_flush :: proc "contextless" (p: ^Pty) {
	p.input = {}
	p.in_taken, p.in_put = 0, 0
	clear(&p.breaks)
	clear(&p.line)
}

@(private="file")
echo :: proc "contextless" (p: ^Pty, ch: u8) {
	if .Echo not_in p.lflag {
		return
	}
	c := ch
	if c == '\n' && p.oflag >= {.Opost, .Onlcr} {
		ring_put(&p.out, '\r')
	}
	if c < 0x20 && c != '\n' && c != '\t' { // ^C and the rest echo as Linux's do
		ring_put(&p.out, '^')
		c += '@'
	}
	ring_put(&p.out, c)
}

// Signals the foreground group: the signal's note, written to the notepg of
// the group's leader, whose pid names the group (vx:signal).
@(private="file")
signal_group :: proc "contextless" (p: ^Pty, sig: signal.Signal) {
	if p.reading {
		p.interrupted = true
	}
	if !proc_mounted || p.pgrp <= 0 {
		return
	}
	path_buf: [48]u8
	b := note.Buf{buf = path_buf[:]}
	note.put(&b, "/proc/")
	note.put_dec(&b, u64(p.pgrp))
	note.put(&b, "/notepg")
	f: ns.File
	if ns.open(&space, note.to_string(&b), p9.OWRITE, &f) != .Ok {
		return // the group has gone
	}
	text: [note.ERRMAX]u8
	_, _ = ns.write(&f, transmute([]u8)signal.signal_note(sig, 0, &text))
	ns.close(&f)
}

// Takes back the last character typed: with IUTF8, a whole rune (upstream
// ADR-0013), echoed as one character erased; without it, a byte.
@(private="file")
erase :: proc "contextless" (p: ^Pty) {
	n := len(p.line)
	resize(&p.line, .Iutf8 in p.iflag ? utf.back(string(p.line[:]), n) : n - 1)
	if .Echo in p.lflag {
		ring_put(&p.out, '\b')
		ring_put(&p.out, ' ')
		ring_put(&p.out, '\b')
	}
}

// The line is full: it ends, at the last whole rune that fits (with IUTF8;
// at the last byte without). A rune it would have split starts the next line.
@(private="file")
full :: proc "contextless" (p: ^Pty) {
	line := p.line[:]
	end := len(line)
	if .Iutf8 in p.iflag {
		start, back := end, 0
		for start > 0 && back < utf.UTF_MAX && line[start - 1] & 0xc0 == 0x80 {
			start -= 1
			back += 1
		}
		if start > 0 && line[start - 1] >= 0xc0 {
			start -= 1 // the lead byte of the last rune
		}
		if start < end && !utf.full_rune(string(line[start:end])) {
			end = start
		}
	}
	for c in line[:end] {
		in_put(p, c)
	}
	rest := copy(line, line[end:])
	resize(&p.line, rest)
}

// One byte typed at the master, through the line discipline.
@(private="file")
typed :: proc "contextless" (p: ^Pty, ch: u8) {
	c := ch
	if .Icrnl in p.iflag && c == '\r' {
		c = '\n'
	}
	if .Isig in p.lflag {
		sig: signal.Signal
		if c == p.cc[V_INTR] {
			sig = signal.SIGINT
		}
		if c == p.cc[V_QUIT] {
			sig = SIGQUIT
		}
		if c == p.cc[V_SUSP] {
			sig = SIGTSTP
		}
		if sig != 0 {
			echo(p, c)
			echo(p, '\n')
			clear(&p.line) // the line is thrown away
			signal_group(p, sig)
			return
		}
	}
	if .Icanon not_in p.lflag {
		in_put(p, c)
		echo(p, c)
		return
	}
	if c == p.cc[V_ERASE] || c == 0x08 {
		if len(p.line) > 0 {
			erase(p)
		}
		return
	}
	if c == p.cc[V_KILL] {
		for len(p.line) > 0 {
			erase(p)
		}
		return
	}
	if c == p.cc[V_EOF] { // the line as it is, or on an empty one the end of the file
		for b in p.line {
			in_put(p, b)
		}
		in_break(p)
		clear(&p.line)
		return
	}
	echo(p, c)
	if len(p.line) == BUF {
		full(p)
	}
	_ = append(&p.line, c)
	if c == '\n' {
		for b in p.line {
			in_put(p, b)
		}
		clear(&p.line)
	}
}

// --- The file system ---

@(private="file")
pty_of :: proc "contextless" (node: p9.Node) -> ^Pty {
	i := u64(node & 0xff)
	if node < MASTER || i >= PTYS || !ptys[i].used {
		return nil
	}
	return &ptys[i]
}

@(private="file")
fs_attach :: proc "contextless" (ctx: rawptr, aname: string) -> (root: p9.Node, st: vx.Status) {
	if aname != "" {
		return 0, .Err_Not_Found
	}
	return ROOT, .Ok
}

@(private="file")
fs_walk :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string) -> (child: p9.Node, st: vx.Status) {
	if dir == ROOT && name == "ptmx" {
		return PTMX, .Ok
	}
	if dir == ROOT && name == "pts" {
		return PTS, .Ok
	}
	if dir != PTS {
		return 0, .Err_Not_Found
	}
	for &p, i in ptys {
		if !p.used {
			continue
		}
		digits: [str.U64_DIGITS]u8
		n := str.format_u64(digits[:], u64(i))
		if name == n {
			return SLAVE + p9.Node(i), .Ok
		}
		if len(name) == len(n) + len(".ctl") && str.has_prefix(name, n) && str.has_suffix(name, ".ctl") {
			return CTL + p9.Node(i), .Ok
		}
	}
	return 0, .Err_Not_Found
}

@(private="file")
fs_parent :: proc "contextless" (ctx: rawptr, node: p9.Node) -> (parent: p9.Node, st: vx.Status) {
	top := node == ROOT || node == PTS || node == PTMX || (node >= MASTER && node < SLAVE)
	return top ? ROOT : PTS, .Ok
}

@(private="file")
stat_name: [24]u8

// A terminal's sides are devices (9P2000.u's DMDEVICE), which the back end
// takes for terminals; each is named by its number.
@(private="file")
fs_stat :: proc "contextless" (ctx: rawptr, node: p9.Node, out: ^p9.Stat) -> vx.Status {
	dir := node == ROOT || node == PTS
	name := "ptmx"
	if node == ROOT {
		name = "/"
	}
	if node == PTS {
		name = "pts"
	}
	mode := dir ? p9.DMDIR | 0o555 : 0o666
	if node >= MASTER {
		if pty_of(node) == nil {
			return .Err_Not_Found
		}
		b := str.Buf{buf = stat_name[:]}
		str.write_u64(&b, u64(node & 0xff))
		if node >= CTL {
			str.write_string(&b, ".ctl")
		}
		name = str.to_string(&b)
		if node < CTL {
			mode = p9.DMDEVICE | 0o620
		}
	}
	out^ = {
		qid  = {type = dir ? p9.QTDIR : p9.QTFILE, path = u64(node)},
		mode = mode,
		name = name,
		uid  = "sys",
		gid  = "sys",
		muid = "sys",
	}
	return .Ok
}

@(private="file")
fs_open :: proc "contextless" (ctx: rawptr, node: p9.Node, mode: p9.Open_Mode) -> vx.Status {
	if node == ROOT || node == PTS {
		return mode.access == .Read ? .Ok : .Err_Access
	}
	if node == PTMX {
		return .Ok
	}
	p := pty_of(node)
	if p == nil {
		return .Err_Not_Found
	}
	if node >= SLAVE && node < CTL {
		if p.master_gone {
			return .Err_Peer_Closed
		}
		p.slaves += 1
	}
	if node < SLAVE { // another fid for the master (Tjoin: a fork's, poll's): one more to close
		if p.master_gone {
			return .Err_Peer_Closed
		}
		p.masters += 1
	}
	return .Ok
}

// Opening ptmx makes a terminal, with Linux's defaults: cooked, echoing,
// signals on, 80 by 24.
@(private="file")
fs_clone :: proc "contextless" (ctx: rawptr, node: p9.Node, mode: p9.Open_Mode) -> (opened: p9.Node, st: vx.Status) {
	if node != PTMX {
		return 0, .Err_Not_Found
	}
	for &p, i in ptys {
		if p.used {
			continue
		}
		p = {
			used    = true,
			masters = 1,
			iflag   = {.Icrnl, .Iutf8}, // UTF-8 input, as Linux terminals have it (upstream ADR-0013)
			oflag   = {.Opost, .Onlcr},
			cflag   = 0o277, // CS8 | CREAD | B38400, as Linux reports them
			lflag   = {.Isig, .Icanon, .Echo, .Echoe, .Echok},
			rows    = 24,
			cols    = 80,
		}
		p.cc[V_INTR], p.cc[V_QUIT], p.cc[V_ERASE], p.cc[V_KILL] = 3, 0x1c, 0x7f, 0x15
		p.cc[V_EOF], p.cc[V_MIN], p.cc[V_SUSP] = 4, 1, 0x1a
		return MASTER + p9.Node(i), .Ok
	}
	return 0, .Err_No_Memory
}

@(private="file")
fs_clunk :: proc "contextless" (ctx: rawptr, node: p9.Node, opened: bool) {
	p := opened ? pty_of(node) : nil
	if p == nil {
		return
	}
	if node < SLAVE && p.masters > 0 {
		p.masters -= 1
		if p.masters == 0 {
			p.master_gone = true // a hang-up: the slave reads its end
		}
	}
	if node >= SLAVE && node < CTL && p.slaves > 0 {
		p.slaves -= 1
	}
	if p.master_gone && p.slaves == 0 {
		p^ = {}
	}
}

// The settings, as one record.
@(private="file")
settings :: proc "contextless" (p: ^Pty, buf: []u8) -> string {
	w := ndb.Writer{buf = buf}
	ndb.put_u64(&w, "iflag", u64(transmute(u32)p.iflag))
	ndb.put_u64(&w, "oflag", u64(transmute(u32)p.oflag))
	ndb.put_u64(&w, "cflag", u64(p.cflag))
	ndb.put_u64(&w, "lflag", u64(transmute(u32)p.lflag))
	ndb.put(&w, "cc", string(p.cc[:]))
	ndb.put_u64(&w, "rows", u64(p.rows))
	ndb.put_u64(&w, "cols", u64(p.cols))
	ndb.put_u64(&w, "pgrp", u64(p.pgrp))
	ndb.put_u64(&w, "avail", u64(p.input.used))
	return ndb.end(&w) ? ndb.written(&w) : ""
}

@(private="file")
settings_text: [512]u8

@(private="file")
fs_read :: proc "contextless" (ctx: rawptr, node: p9.Node, offset: u64, buf: []u8) -> (count: u32, st: vx.Status) {
	p := pty_of(node)
	if p == nil {
		return 0, .Err_Not_Found
	}
	if node >= CTL {
		text := settings(p, settings_text[:])
		if offset >= u64(len(text)) {
			return 0, .Ok
		}
		return u32(copy(buf, text[offset:])), .Ok
	}
	if node < SLAVE { // the master: what the slave wrote, and echo
		if p.out.used == 0 {
			return 0, .Err_Should_Wait
		}
		count = ring_take(&p.out, buf)
		server.again = true // room for a slave write held for it
		return count, .Ok
	}
	// A signal ptyd sent while a read waited ends it; but not one that finds
	// input here (the read it was for may have been given up since).
	if p.interrupted && p.input.used == 0 {
		p.interrupted, p.reading = false, false
		return 0, .Err_Interrupted
	}
	p.interrupted = false
	canonical := .Icanon in p.lflag
	if canonical && len(p.breaks) > 0 && p.breaks[0] == p.in_taken { // a ^D on an empty line: the end of the file
		drop_break(p)
		p.reading = false
		return 0, .Ok
	}
	if p.input.used == 0 {
		if p.master_gone {
			return 0, .Ok // the end of the file: hung up
		}
		p.reading = true
		return 0, .Err_Should_Wait
	}
	p.reading = false
	if !canonical {
		return in_take(p, buf), .Ok
	}
	// One line at most: to its newline, or to where a ^D sent it.
	n := 0
	for n < len(buf) && p.input.used > 0 {
		c := p.input.b[p.input.head]
		_ = in_take(p, buf[n:][:1])
		n += 1
		if c == '\n' {
			break // a break here too is the next read's: the end of the file
		}
		if len(p.breaks) > 0 && p.breaks[0] == p.in_taken {
			drop_break(p)
			break
		}
	}
	return u32(n), .Ok
}

@(private="file")
field :: proc "contextless" (r: ^ndb.Record, key: string, was: u64) -> u64 {
	v, ok := ndb.get_u64(r, key)
	return ok ? v : was
}

@(private="file")
ctl_scratch: [1024]u8

@(private="file")
fs_write :: proc "contextless" (ctx: rawptr, node: p9.Node, offset: u64, data: []u8) -> (count: u32, st: vx.Status) {
	p := pty_of(node)
	if p == nil {
		return 0, .Err_Not_Found
	}
	server.again = true // what is written at one end may let a read held at the other go on
	if node >= CTL { // set what the record names; `flush` throws away pending input
		r := ndb.Reader{src = string(data), scratch = ctl_scratch[:]}
		rec: ndb.Record
		if ndb.next(&r, &rec) != .Record {
			return 0, .Err_Invalid
		}
		p.iflag = transmute(Iflags)u32(field(&rec, "iflag", u64(transmute(u32)p.iflag)))
		p.oflag = transmute(Oflags)u32(field(&rec, "oflag", u64(transmute(u32)p.oflag)))
		p.cflag = u32(field(&rec, "cflag", u64(p.cflag)))
		p.lflag = transmute(Lflags)u32(field(&rec, "lflag", u64(transmute(u32)p.lflag)))
		if cc, ok := ndb.get(&rec, "cc"); ok && len(cc) == NCCS {
			copy(p.cc[:], cc)
		}
		rows, cols := p.rows, p.cols
		p.rows = u16(field(&rec, "rows", u64(p.rows)))
		p.cols = u16(field(&rec, "cols", u64(p.cols)))
		p.pgrp = i64(field(&rec, "pgrp", u64(p.pgrp)))
		if ndb.has(&rec, "flush") {
			in_flush(p)
		}
		if rows != p.rows || cols != p.cols {
			signal_group(p, signal.SIGWINCH)
			p.interrupted = false // a resize does not end reads
		}
		return u32(len(data)), .Ok
	}
	if node < SLAVE { // typed at the master
		for c in data {
			typed(p, c)
		}
		return u32(len(data)), .Ok
	}
	if p.master_gone {
		return 0, .Err_Peer_Closed
	}
	// The program's output, to the master: as much as there is room for (a
	// newline may take two), the rest written again; none, and the write
	// waits for the master to read (held, as a read is).
	taken := 0
	for c in data {
		crnl := c == '\n' && p.oflag >= {.Opost, .Onlcr}
		if BUF - p.out.used < (crnl ? 2 : 1) {
			break
		}
		if crnl {
			ring_put(&p.out, '\r')
		}
		ring_put(&p.out, c)
		taken += 1
	}
	if taken == 0 && len(data) > 0 {
		return 0, .Err_Should_Wait
	}
	return u32(taken), .Ok
}

@(private="file")
fs_readdir :: proc "contextless" (ctx: rawptr, dir: p9.Node, index: u32) -> (child: p9.Node, st: vx.Status) {
	if dir == ROOT {
		if index > 1 {
			return 0, .Err_Not_Found
		}
		return index != 0 ? PTS : PTMX, .Ok
	}
	if dir != PTS {
		return 0, .Err_Not_Found
	}
	left := index
	for &p, i in ptys {
		if !p.used || p.master_gone {
			continue
		}
		if left < 2 {
			return (left != 0 ? CTL : SLAVE) + p9.Node(i), .Ok
		}
		left -= 2
	}
	return 0, .Err_Not_Found
}

// Not file-private: tests/host drives its Fs on the host.
server := p9ring.Server {
	fs = {
		attach  = fs_attach,
		walk    = fs_walk,
		parent  = fs_parent,
		stat    = fs_stat,
		open    = fs_open,
		clone   = fs_clone,
		read    = fs_read,
		write   = fs_write,
		readdir = fs_readdir,
		clunk   = fs_clunk,
	},
	name = "ptyd",
	supported = {.Xattr, .Posix},
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	server.listen = rt.spawn_take("listen")
	if server.listen == vx.HANDLE_NONE {
		rt.print("ptyd: no listen channel\n")
		return -1 // upstream's exit string: "no listen channel"
	}
	// /proc, to signal process groups through.
	proc_mounted = procns.from_spawn(&space) == .Ok && ns.connector(&space, "/proc") != vx.HANDLE_NONE
	rt.print(proc_mounted ? "ptyd: serving /srv/ptyd\n" : "ptyd: serving /srv/ptyd, without /proc: no signals\n")
	return int(p9ring.serve(&server))
}
