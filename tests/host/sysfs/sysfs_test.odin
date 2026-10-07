// servers/sysfs's file system on the host: the program itself, linked
// against lib/rt, with a fake kernel underneath, as tests/host/bootfs does.
// clock_read is a clock the test sets, and with an argument fills in the
// counter it is made from as the test says; port_create fails, so vx_main
// says what it serves and returns. Its p9.Fs is then driven through lib/p9's
// server framework and client.
//
// Upstream has no host test of sysfs; these cases follow its sysfs.c.
package sysfs_test

import vx "abi:vx"
import "core:testing"
import "vx:p9"
import "vx:rt"
import sysfs "../../../servers/sysfs"
import "../p9test"

LISTEN :: vx.Handle(0x202)

kernel_log: [1024]u8
kernel_log_len: int
now: i64
counter_hz: u64
clock_flags: u32
info_status: i64 // what clock_read(&info) answers
utc_offset: i64 // the wall clock's, as clock_read(&info) gives it

@(export, link_name="vx_syscall")
fake_syscall :: proc "c" (nr: vx.Syscall, a0, a1, a2, a3, a4, a5: u64) -> i64 {
	#partial switch nr {
	case .Debug_Write:
		s := ([^]u8)(uintptr(a0))[:a1]
		kernel_log_len += copy(kernel_log[kernel_log_len:], s)
		return 0
	case .Clock_Read:
		if a0 != 0 {
			if info_status < 0 {
				return info_status
			}
			info := ([^]u64)(uintptr(a0))
			info[0] = counter_hz
			info[1] = u64(clock_flags) // and reserved, 0
			info[2] = u64(utc_offset)
		}
		return now
	case .Handle_Close:
		return 0
	}
	return i64(vx.Status.Err_Unsupported) // port_create among them: vx_main returns
}

read_file :: proc(c: ^p9.Client, root: p9.Fid, path: string, buf: []u8, offset: u64 = 0) -> string {
	f, e := p9.client_walk(c, root, path)
	if e != .Ok {
		return "(walk failed)"
	}
	defer _ = p9.client_clunk(c, f)
	if p9.client_open(c, f, p9.OREAD) != .Ok {
		return "(open failed)"
	}
	n, re := p9.client_read(c, f, offset, buf)
	if re != .Ok {
		return "(read failed)"
	}
	return string(buf[:n])
}

@(test)
test_sysfs :: proc(t: ^testing.T) {
	names: p9.Stat_Text
	rt.spawn.handle_names[0], rt.spawn.handles[0] = "listen", LISTEN
	rt.spawn.handle_count = 1
	testing.expect_value(t, sysfs.vx_main(), int(vx.Status.Err_Unsupported))
	testing.expect_value(t, string(kernel_log[:kernel_log_len]), "sysfs: serving /srv/sys\n")

	srv := p9.Server{fs = sysfs.server.fs, max_msize = 8192, supported = sysfs.server.supported}
	tbuf, rbuf: [8192]u8
	c := p9.Client{rpc = p9test.loopback, ctx = &srv, tbuf = tbuf[:], rbuf = rbuf[:]}
	testing.expect_value(t, p9.client_version(&c, 8192, {.Posix, .Xattr}), vx.Status.Ok)
	testing.expect_value(t, c.extensions, p9.Extensions{.Xattr})
	root, e := p9.client_attach(&c, "")
	testing.expect_value(t, e, vx.Status.Ok)

	// The tree, and its stats.
	testing.expect_value(t, p9test.list(&c, root, ""), "clock name")
	testing.expect_value(t, p9test.list(&c, root, "clock"), "info now")
	Want :: struct {
		path, name: string,
		mode:       u32,
		qid:        p9.Qid,
	}
	for w in ([]Want {
			{"", "/", p9.DMDIR | 0o555, {type = p9.QTDIR, path = 1}},
			{"clock", "clock", p9.DMDIR | 0o555, {type = p9.QTDIR, path = 2}},
			{"clock/info", "info", 0o444, {type = p9.QTFILE, path = 3}},
			{"clock/now", "now", 0o444, {type = p9.QTFILE, path = 4}},
			{"clock/info/..", "clock", p9.DMDIR | 0o555, {type = p9.QTDIR, path = 2}},
			{"name", "name", 0o444, {type = p9.QTFILE, path = 5}},
		}) {
		st: p9.Stat
		testing.expectf(t, p9test.stat_of(&c, root, w.path, &st, &names) == .Ok, "stat %s", w.path)
		testing.expect_value(t, st.name, w.name)
		testing.expect_value(t, st.mode, w.mode)
		testing.expect_value(t, st.qid, w.qid)
		testing.expect_value(t, st.uid, "sys")
	}
	for path in ([]string{"info", "clock/nope", "clock/now/x"}) {
		_, e = p9.client_walk(&c, root, path)
		testing.expectf(t, e == .Err_Not_Found, "walk %s: %v", path, e)
	}
	f, _ := p9.client_walk(&c, root, "clock/now")
	testing.expect_value(t, p9.client_open(&c, f, p9.OWRITE), vx.Status.Err_Access)
	_ = p9.client_clunk(&c, f)

	// /sys/clock/info, as the kernel calibrated its counter.
	buf: [256]u8
	Info :: struct {
		hz:    u64,
		flags: u32,
		want:  string,
	}
	for w in ([]Info {
			{3187200000, 1 | 2 | 4, "tsc.hz=3187200000 tsc.invariant tsc.user source=tsc\n"},
			{24000000, 1 | 2 | 8, "cntfrq.hz=24000000 cntvct.invariant cntvct.user source=cntvct\n"},
			{1000000000, 4, "tsc.hz=1000000000 source=tsc\n"},
			{62500000, 2 | 8, "cntfrq.hz=62500000 cntvct.user source=cntvct\n"},
		}) {
		counter_hz, clock_flags = w.hz, w.flags
		testing.expect_value(t, read_file(&c, root, "clock/info", buf[:]), w.want)
	}
	counter_hz, clock_flags = 24000000, 1 | 2 | 8
	testing.expect_value(t, read_file(&c, root, "clock/info", buf[:], 10), "24000000 cntvct.invariant cntvct.user source=cntvct\n")
	testing.expect_value(t, read_file(&c, root, "clock/info", buf[:], 500), "")
	info_status = i64(vx.Status.Err_Unsupported)
	testing.expect_value(t, read_file(&c, root, "clock/info", buf[:]), "") // no counter to tell of
	info_status = 0

	// /sys/clock/now: realtime counts from boot, until there is a wall clock;
	// then it is UTC.
	now = 1234567890
	testing.expect_value(t, read_file(&c, root, "clock/now", buf[:]), "monotonic=1234567890 realtime=1234567890\n")
	testing.expect_value(t, read_file(&c, root, "clock/now", buf[:5], 3), "otoni")
	utc_offset = 1_767_225_600_000_000_000
	testing.expect_value(t, read_file(&c, root, "clock/now", buf[:]), "monotonic=1234567890 realtime=1767225601234567890\n")
	utc_offset = 0

	// /sys/name (upstream's 6e1c3): the command line's vx.host=, else vectra,
	// with no newline; a vx.host= with no value, or one inside another word,
	// is passed over.
	Name :: struct {
		cmdline, want: string,
	}
	for w in ([]Name {
			{"", "vectra"},
			{"vx.user=vectra vx.host=testhost", "testhost"},
			{"vx.host= vx.host=late", "late"},
			{"novx.host=no", "vectra"},
		}) {
		rt.spawn.cmdline = w.cmdline
		testing.expect_value(t, read_file(&c, root, "name", buf[:]), w.want)
	}
	rt.spawn.cmdline = "vx.host=testhost"
	testing.expect_value(t, read_file(&c, root, "name", buf[:4], 4), "host")
	rt.spawn.cmdline = ""
}
