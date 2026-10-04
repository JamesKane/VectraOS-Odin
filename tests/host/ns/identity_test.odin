// Upstream's M4 cases in tests/host/ns_test.c: mount points found by
// identity (ADR-0009), and namespace(6) files as newns reads them.
package ns_test

import "abi:vx"
import "core:testing"
import "vx:ns"
import "vx:p9"

// Mount points are found by identity (ADR-0009, 9front's findmount): a mount
// shows through every name that reaches the directory it was made on, and
// through no name that does not.
@(test)
test_identity :: proc(t: ^testing.T) {
	space := new(ns.Namespace)
	defer free(space)
	fx := fixture(t)
	defer free(fx)
	ok := vx.Status.Ok
	testing.expect_value(t, ns.mount(space, &fx.boot_c, vx.HANDLE_NONE, "/srv/bootfs", "", "/", {}), ok)
	testing.expect_value(t, ns.bind(space, "/boot", "/dev", {}), ok) // /dev is /boot now
	testing.expect_value(t, ns.mount(space, &fx.dev_c, vx.HANDLE_NONE, "/srv/cons", "", "/boot/bin", {}), ok)
	expect_exists(t, space, "/boot/bin/cons") // the same directory, by either name
	expect_exists(t, space, "/dev/bin/cons")
	testing.expect_value(t, list(space, "/dev/bin"), "cons null")

	// A bind onto the other name joins the same mount point.
	testing.expect_value(t, ns.bind(space, "/bin", "/dev/bin", {.After}), ok)
	testing.expect_value(t, list(space, "/boot/bin"), "cons null") // /bin is empty: the union is the same

	// /boot replaced by bootfs's empty /bin: the mount's directory is not under it.
	testing.expect_value(t, ns.bind(space, "/bin", "/boot", {}), ok)
	expect_exists(t, space, "/boot/bin", false)
	expect_exists(t, space, "/dev/bin/cons")

	// A new name in a directory is found by that directory, by any name for it.
	testing.expect_value(t, ns.mount(space, &fx.dev_c, vx.HANDLE_NONE, "/srv/cons", "", "/boot/new", {}), ok)
	expect_exists(t, space, "/bin/new/cons") // /bin is the directory /boot shows

	// Union create: the first member bound with -c, or none. readme, a file,
	// takes it here, and its server refuses: not the union's refusal.
	f: ns.File
	testing.expect_value(t, ns.create(space, "/dev/bin/x", 0o644, p9.OWRITE, &f), vx.Status.Err_Access) // no -c member
	testing.expect_value(t, ns.bind(space, "/readme", "/dev/bin", {.After, .Create}), ok)
	testing.expect_value(t, ns.create(space, "/dev/bin/x", 0o644, p9.OWRITE, &f), vx.Status.Err_Invalid)

	// A union bound elsewhere is copied whole, in order.
	testing.expect_value(t, ns.bind(space, "/dev/bin", "/bin", {}), ok)
	expect_exists(t, space, "/bin/cons")
}

a_var :: proc "contextless" (ctx: rawptr, name: string) -> string {
	return name == "user" ? "glenda" : ""
}

// namespace(6) files, as newns reads them: operations, flags, quotes, $vars,
// comments, and lines that are none.
@(test)
test_script :: proc(t: ^testing.T) {
	text :=
		"# a comment, with an apostrophe's quote\n" +
		"mount -c /srv/tmpfs /tmp\n" +
		"\n" +
		"  bind -a $user/bin '/a b'\n" +
		"mount /srv/fs /n/x 'it''s'\n" +
		"unmount /n/x\n" +
		"bind -ab /x /y\n"
	s := new(ns.Script)
	defer free(s)
	s^ = {
		text = text,
		var  = a_var,
	}
	op: ns.Op
	testing.expect_value(t, ns.script_next(s, &op), vx.Status.Ok)
	testing.expect_value(t, op.kind, ns.Op_Kind.Mount)
	testing.expect_value(t, op.flags, ns.Flags{.Create})
	testing.expect_value(t, len(op.args), 2)
	testing.expect_value(t, op.args[0], "/srv/tmpfs")
	testing.expect_value(t, op.args[1], "/tmp")
	testing.expect_value(t, op.line, 2)
	testing.expect_value(t, ns.script_next(s, &op), vx.Status.Ok)
	testing.expect_value(t, op.kind, ns.Op_Kind.Bind)
	testing.expect_value(t, op.flags, ns.Flags{.After})
	testing.expect_value(t, op.args[0], "glenda/bin")
	testing.expect_value(t, op.args[1], "/a b")
	testing.expect_value(t, ns.script_next(s, &op), vx.Status.Ok)
	testing.expect_value(t, len(op.args), 3)
	testing.expect_value(t, op.args[2], "it's")
	testing.expect_value(t, ns.script_next(s, &op), vx.Status.Ok)
	testing.expect_value(t, op.kind, ns.Op_Kind.Unmount)
	testing.expect_value(t, len(op.args), 1)
	testing.expect_value(t, ns.script_next(s, &op), vx.Status.Err_Invalid) // -a and -b together
	testing.expect_value(t, op.line, 7)
	testing.expect_value(t, ns.script_next(s, &op), vx.Status.Err_Not_Found) // the end
	s^ = {
		text = "bind /only\n",
	}
	testing.expect_value(t, ns.script_next(s, &op), vx.Status.Err_Invalid) // one word short
	s^ = {
		text = "mount '/srv/x /y\n",
	}
	testing.expect_value(t, ns.script_next(s, &op), vx.Status.Err_Invalid) // a quote not closed
}

// Not upstream's: ns output quotes a word as namespace(6) must, so a path
// with a space replays (through newns) as itself.
@(test)
test_print_quotes :: proc(t: ^testing.T) {
	space := new(ns.Namespace)
	defer free(space)
	fx := fixture(t)
	defer free(fx)
	testing.expect_value(t, ns.mount(space, &fx.boot_c, vx.HANDLE_NONE, "/srv/it's", "", "/", {}), vx.Status.Ok)
	testing.expect_value(t, ns.mount(space, &fx.dev_c, vx.HANDLE_NONE, "/srv/cons", "", "/a b", {}), vx.Status.Ok)
	out: [256]u8
	n := ns.print(space, out[:])
	testing.expect_value(t, string(out[:n]), "mount '/srv/it''s' /\nmount /srv/cons '/a b'\n")
	s := new(ns.Script)
	defer free(s)
	s.text = string(out[:n])
	op: ns.Op
	testing.expect_value(t, ns.script_next(s, &op), vx.Status.Ok)
	testing.expect_value(t, op.args[0], "/srv/it's")
	testing.expect_value(t, ns.script_next(s, &op), vx.Status.Ok)
	testing.expect_value(t, op.args[1], "/a b")
}
