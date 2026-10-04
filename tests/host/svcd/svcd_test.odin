// servers/svcd's namespace templates on the host (ns=NAME in a manifest,
// upstream ADR-0009): the program itself, linked against lib/rt, with a fake
// kernel underneath that makes channels and duplicates. A boot image made
// here holds upstream's /lib/ns/posix; put_template turns it into a child's
// mount and bind records, each mount naming a connector to its post.
//
// Upstream has no host test of svcd; these cases follow its svcd.c.
package svcd_test

import vx "abi:vx"
import "core:testing"
import "vx:ndb"
import "vx:tar"
import svcd "../../../servers/svcd"

kernel_log: [1024]u8
kernel_log_len: int
next_handle := vx.Handle(0x100)

@(export, link_name="vx_syscall")
fake_syscall :: proc "c" (nr: vx.Syscall, a0, a1, a2, a3, a4, a5: u64) -> i64 {
	#partial switch nr {
	case .Debug_Write:
		s := ([^]u8)(uintptr(a0))[:a1]
		kernel_log_len += copy(kernel_log[kernel_log_len:], s)
		return 0
	case .Channel_Create:
		hs := ([^]vx.Handle)(uintptr(a1))
		hs[0], hs[1] = next_handle, next_handle + 1
		next_handle += 2
		return 0
	case .Handle_Dup:
		(^vx.Handle)(uintptr(a2))^ = next_handle
		next_handle += 1
		return 0
	case .Handle_Close:
		return 0
	}
	return i64(vx.Status.Err_Unsupported)
}

POSIX :: `# /lib/ns/posix: the namespace a POSIX program expects
mount /srv/bootfs /
bind -a /boot/bin /bin
bind -b /boot/bin/posix /bin
mount -c /srv/tmpfs /tmp
mount /srv/null /dev
mount -a /srv/ptyd /dev
mount /srv/proc /proc spec
`

image_buf: [16 * 1024]u8

@(test)
test_templates :: proc(t: ^testing.T) {
	w := tar.Writer{buf = image_buf[:]}
	tar.add(&w, "lib", true, 0o755, nil)
	tar.add(&w, "lib/ns", true, 0o755, nil)
	tar.add(&w, "lib/ns/posix", false, 0o644, transmute([]u8)string(POSIX))
	tar.add(&w, "lib/ns/dir", true, 0o755, nil)
	tar.add(&w, "lib/ns/bad", false, 0o644, transmute([]u8)string("mount /srv/bootfs /\nfrob x\n"))
	tar.add(&w, "lib/ns/nopost", false, 0o644, transmute([]u8)string("bind /a /b\nmount /srv/nope /n\n"))
	tar.add(&w, "lib/ns/unmount", false, 0o644, transmute([]u8)string("unmount /n\n"))
	n := tar.end(&w)
	testing.expect(t, n > 0)
	svcd.image = image_buf[:n]
	for post in ([]string{"bootfs", "tmpfs", "null", "ptyd", "proc"}) {
		testing.expect(t, svcd.ensure_post(post) != nil)
	}
	s: svcd.Service
	_ = append(&s.name, "posixtest")

	// Each mount of /srv/NAME a connector to that post, ns.NN by its index in
	// the spawn message; flags as letters.
	g: svcd.Grants
	records: [4096]u8
	rw := ndb.Writer{buf = records[:]}
	testing.expect_value(t, svcd.put_template(&s, &g, &rw, "posix"), vx.Status.Ok)
	testing.expect_value(t, ndb.written(&rw),
		"mount=/ handle=ns.00 src=/srv/bootfs\n" +
		"bind=/bin new=/boot/bin flags=a\n" +
		"bind=/bin new=/boot/bin/posix flags=b\n" +
		"mount=/tmp handle=ns.01 flags=c src=/srv/tmpfs\n" +
		"mount=/dev handle=ns.02 src=/srv/null\n" +
		"mount=/dev handle=ns.03 flags=a src=/srv/ptyd\n" +
		"mount=/proc handle=ns.04 aname=spec src=/srv/proc\n")
	testing.expect_value(t, len(g.handles), 5)
	testing.expect_value(t, len(g.names), 5)
	testing.expect_value(t, g.names[0], "ns.00")
	testing.expect_value(t, g.names[4], "ns.04")
	testing.expect_value(t, string(kernel_log[:kernel_log_len]), "")

	// What cannot be: no template, a line that is no operation, a post that is
	// not there, an operation a template does not do.
	Case :: struct {
		name: string,
		st:   vx.Status,
		said: string,
	}
	for c in ([]Case {
			{"none", .Err_Not_Found, "svcd: posixtest: no namespace template none\n"},
			{"", .Err_Not_Found, "svcd: posixtest: no namespace template \n"},
			{"dir", .Err_Not_Found, "svcd: posixtest: no namespace template dir\n"}, // a directory
			{"bad", .Err_Invalid, "svcd: posixtest: namespace template bad: no operation on line 2\n"},
			{"nopost", .Err_Not_Found, "svcd: posixtest: cannot mount /srv/nope\nsvcd: posixtest: namespace template nopost: cannot do line 2\n"},
			{"unmount", .Err_Unsupported, "svcd: posixtest: namespace template unmount: cannot do line 1\n"},
		}) {
		kernel_log_len = 0
		g = {}
		rw = {buf = records[:]}
		testing.expectf(t, svcd.put_template(&s, &g, &rw, c.name) == c.st, "template %q", c.name)
		testing.expect_value(t, string(kernel_log[:kernel_log_len]), c.said)
	}
}
