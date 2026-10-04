// Not upstream's: lib/ns against upstream's vx-ns, operation by operation.
// ops.txt is a run of mounts, binds and unmounts over ns_test's two trees
// (crossing mount points by identity, new names, unions copied whole, failed
// changes, unmounts by source and whole); after each, its status, the
// namespace's text, which of a set of paths exist, three directory listings,
// and the fids the servers hold against the members' must be what upstream's
// vx-ns gives for the same run (ops_upstream.txt, from a harness built with
// clang against M4's ns.c: the P4 cross-check).
package ns_test

import "abi:vx"
import "core:fmt"
import "core:strings"
import "core:testing"
import "vx:ns"
import "vx:p9"

OPS :: #load("ops.txt", string)
OPS_UPSTREAM :: #load("ops_upstream.txt", string)

@(rodata)
PATHS := [?]string {
	"/",
	"/bin",
	"/bin/ls",
	"/bin/cons",
	"/boot",
	"/boot/bin",
	"/boot/bin/ls",
	"/boot/bin/cons",
	"/dev",
	"/dev/cons",
	"/dev/bin",
	"/dev/bin/ls",
	"/n",
	"/n/x",
	"/n/x/ls",
	"/n/x/ls/cons",
	"/new",
	"/new/cons",
	"/readme",
	"/readme/cons",
	"/n/n",
	"/n/boot",
	"/cons",
	"/null",
	"/boot/bin/cat",
}

// The names in a directory, as the harness lists them: every name read, or
// "(bad stat)" if an entry is malformed (a union with a file in it).
list_names :: proc(space: ^ns.Namespace, path: string) -> string {
	f: ns.File
	if ns.open(space, path, p9.OREAD, &f) != .Ok {
		return "(cannot open)"
	}
	defer ns.close(&f)
	b := strings.builder_make(context.temp_allocator)
	buf: [2048]u8
	for {
		got, e := ns.read(&f, buf[:])
		if e != .Ok {
			return "(read failed)"
		}
		if got == 0 {
			break
		}
		it := p9.Dir_Entries{buf = buf[:got]}
		for st in p9.next_entry(&it) {
			if strings.builder_len(b) > 0 {
				strings.write_byte(&b, ' ')
			}
			strings.write_string(&b, st.name)
		}
		if it.off != got {
			return "(bad stat)"
		}
	}
	return strings.to_string(b)
}

op_flags :: proc(f: string) -> (flags: ns.Flags) {
	if strings.contains_rune(f, 'a') {
		flags += {.After}
	}
	if strings.contains_rune(f, 'b') {
		flags += {.Before}
	}
	if strings.contains_rune(f, 'c') {
		flags += {.Create}
	}
	return
}

@(test)
test_ops_against_upstream :: proc(t: ^testing.T) {
	space := new(ns.Namespace)
	defer free(space)
	fx := fixture(t)
	defer free(fx)
	b := strings.builder_make(context.temp_allocator)
	ops := OPS
	lineno := 0
	for line in strings.split_lines_iterator(&ops) {
		lineno += 1
		w := strings.fields(line, context.temp_allocator)
		status: int
		switch w[0] {
		case "m":
			boot := w[1] == "boot"
			status = int(ns.mount(space, boot ? &fx.boot_c : &fx.dev_c, vx.HANDLE_NONE, boot ? "/srv/bootfs" : "/srv/cons", "", w[2], op_flags(w[3])))
		case "b":
			status = int(ns.bind(space, w[1], w[2], op_flags(w[3])))
		case:
			status = int(ns.unmount(space, w[1] == "-" ? "" : w[1], w[2]))
		}
		fmt.sbprintf(&b, "op %d -> %d\n", lineno, status)
		out: [2048]u8
		n := ns.print(space, out[:])
		strings.write_string(&b, string(out[:n]))
		strings.write_string(&b, "exists ")
		for p in PATHS {
			strings.write_byte(&b, exists(space, p) ? '1' : '0')
		}
		fmt.sbprintf(&b, "\nlist / [%s]\n", list_names(space, "/"))
		fmt.sbprintf(&b, "list /bin [%s]\n", list_names(space, "/bin"))
		fmt.sbprintf(&b, "list /dev [%s]\n", list_names(space, "/dev"))
		members := 0
		for &e in space.entries {
			if len(e.path) > 0 {
				members += len(e.members)
			}
		}
		fmt.sbprintf(&b, "fids %d members %d\n", used_fids(&fx.boot_srv) + used_fids(&fx.dev_srv), members)
	}
	got, want := strings.to_string(b), OPS_UPSTREAM
	line := 0
	for {
		gl, gok := strings.split_lines_iterator(&got)
		wl, wok := strings.split_lines_iterator(&want)
		line += 1
		if !gok && !wok {
			break
		}
		if !testing.expectf(t, gl == wl, "line %d: got %q, upstream has %q", line, gl, wl) {
			break
		}
	}
}
