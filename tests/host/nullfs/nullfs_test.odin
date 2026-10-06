// servers/nullfs's file system on the host: the program itself, linked
// against lib/rt, with a fake kernel underneath, as tests/host/bootfs does.
// port_create fails, so vx_main seeds (or not), says what it serves and
// returns; its p9.Fs is then driven through lib/p9's server framework and
// client. vx_main runs twice: without entropy, then with it.
//
// Upstream has no host test of nullfs; these cases follow its nullfs.c.
package nullfs_test

import vx "abi:vx"
import "core:fmt"
import "core:testing"
import "vx:drbg"
import "vx:p9"
import "vx:rt"
import nullfs "../../../servers/nullfs"
import "../p9test"

LISTEN :: vx.Handle(0x202)

kernel_log: [1024]u8
kernel_log_len: int

@(export, link_name="vx_syscall")
fake_syscall :: proc "c" (nr: vx.Syscall, a0, a1, a2, a3, a4, a5: u64) -> i64 {
	#partial switch nr {
	case .Debug_Write:
		s := ([^]u8)(uintptr(a0))[:a1]
		kernel_log_len += copy(kernel_log[kernel_log_len:], s)
		return 0
	case .Handle_Close:
		return 0
	}
	return i64(vx.Status.Err_Unsupported) // port_create among them: vx_main returns
}

run_main :: proc(t: ^testing.T, records: string, said: string, loc := #caller_location) {
	kernel_log_len = 0
	rt.spawn.handle_names[0], rt.spawn.handles[0] = "listen", LISTEN
	rt.spawn.handle_count = 1
	rt.spawn.text = records
	testing.expect_value(t, nullfs.vx_main(), int(vx.Status.Err_Unsupported), loc = loc)
	testing.expect_value(t, string(kernel_log[:kernel_log_len]), said, loc = loc)
}

open_file :: proc(c: ^p9.Client, root: p9.Fid, path: string, mode: p9.Open_Mode) -> (f: p9.Fid, e: vx.Status) {
	f = p9.client_walk(c, root, path) or_return
	if e = p9.client_open(c, f, mode); e != .Ok {
		_ = p9.client_clunk(c, f)
	}
	return
}

@(test)
test_nullfs :: proc(t: ^testing.T) {
	names: p9.Stat_Text
	run_main(t, "", "nullfs: serving /srv/null, without entropy: random cannot be read\n")

	srv := p9.Server{fs = nullfs.server.fs, max_msize = 8192, supported = nullfs.server.supported}
	tbuf, rbuf: [8192]u8
	c := p9.Client{rpc = p9test.loopback, ctx = &srv, tbuf = tbuf[:], rbuf = rbuf[:]}
	testing.expect_value(t, p9.client_version(&c, 8192, {.Posix, .Xattr}), vx.Status.Ok)
	testing.expect_value(t, c.extensions, p9.Extensions{.Xattr})
	root, e := p9.client_attach(&c, "")
	testing.expect_value(t, e, vx.Status.Ok)
	_, e = p9.client_attach(&c, "x")
	testing.expect_value(t, e, vx.Status.Err_Not_Found)

	testing.expect_value(t, p9test.list(&c, root, ""), "null zero random urandom")
	st: p9.Stat
	testing.expect_value(t, p9test.stat_of(&c, root, "", &st, &names), vx.Status.Ok)
	testing.expect_value(t, st.name, "/")
	testing.expect_value(t, st.mode, p9.DMDIR | 0o555)
	testing.expect_value(t, st.qid, p9.Qid{type = p9.QTDIR, path = 1})
	Want :: struct {
		name: string,
		path: u64,
	}
	for w in ([]Want{{"null", 2}, {"zero", 3}, {"random", 4}, {"urandom", 5}}) {
		testing.expect_value(t, p9test.stat_of(&c, root, w.name, &st, &names), vx.Status.Ok)
		testing.expect_value(t, st.name, w.name)
		testing.expect_value(t, st.mode, 0o666)
		testing.expect_value(t, st.qid, p9.Qid{type = p9.QTFILE, path = w.path})
		testing.expect_value(t, st.uid, "sys")
		testing.expect_value(t, st.length, 0)
	}
	_, e = p9.client_walk(&c, root, "nope")
	testing.expect_value(t, e, vx.Status.Err_Not_Found)
	_, e = open_file(&c, root, "", p9.OWRITE)
	testing.expect_value(t, e, vx.Status.Err_Access)

	// null reads as empty and zero as zeros; both take any write.
	buf: [64]u8
	n: int
	f: p9.Fid
	f, _ = open_file(&c, root, "null", p9.ORDWR)
	n, e = p9.client_read(&c, f, 0, buf[:])
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, n, 0)
	n, e = p9.client_write(&c, f, 0, transmute([]u8)string("anything"))
	testing.expect_value(t, n, 8)
	_ = p9.client_clunk(&c, f)
	f, _ = open_file(&c, root, "zero", p9.ORDWR)
	buf[3] = 9
	n, e = p9.client_read(&c, f, 1 << 40, buf[:])
	testing.expect_value(t, n, len(buf))
	testing.expect_value(t, buf, [64]u8{})
	n, e = p9.client_write(&c, f, 0, transmute([]u8)string("x"))
	testing.expect_value(t, n, 1)
	_ = p9.client_clunk(&c, f)

	// Unseeded, random and urandom refuse to be read, but take writes.
	for name in ([]string{"random", "urandom"}) {
		_, e = open_file(&c, root, name, p9.OREAD)
		testing.expect_value(t, e, vx.Status.Err_Bad_State)
		_, e = open_file(&c, root, name, p9.ORDWR)
		testing.expect_value(t, e, vx.Status.Err_Bad_State)
		f, e = open_file(&c, root, name, p9.OWRITE)
		testing.expect_value(t, e, vx.Status.Ok)
		_ = p9.client_clunk(&c, f)
	}

	// Seeded from the spawn message's entropy (16 bytes at least), they give
	// the generator's bytes; a write is mixed in, not taken as a seed.
	run_main(t, "entropy=short\n", "nullfs: serving /srv/null, without entropy: random cannot be read\n")
	seed := "0123456789abcdef0123456789abcdef"
	run_main(t, fmt.tprintf("entropy=%s\n", seed), "nullfs: serving /srv/null\n")
	want: drbg.Drbg // the same generator, from the same seed: nothing was written before
	drbg.mix(&want, transmute([]u8)seed, true)
	got, expect: [48]u8
	f, e = open_file(&c, root, "random", p9.OREAD)
	testing.expect_value(t, e, vx.Status.Ok)
	n, e = p9.client_read(&c, f, 0, got[:])
	testing.expect_value(t, n, len(got))
	drbg.read(&want, expect[:])
	testing.expect_value(t, got, expect)
	_ = p9.client_clunk(&c, f)
	f, _ = open_file(&c, root, "urandom", p9.ORDWR)
	n, e = p9.client_write(&c, f, 0, transmute([]u8)string("stir"))
	testing.expect_value(t, n, 4)
	drbg.mix(&want, transmute([]u8)string("stir"), false)
	got, expect = {}, {}
	n, e = p9.client_read(&c, f, 0, got[:16])
	testing.expect_value(t, n, 16)
	drbg.read(&want, expect[:16])
	testing.expect_value(t, got, expect)
	_ = p9.client_clunk(&c, f)
}
