// svcd: the first process. It starts the system's services from the
// manifests in boot/svc/*.ndb, in file order, and restarts them when they
// exit.
//
// The kernel gives svcd the boot image. svcd reads the manifests and the
// programs straight from it, because the file server that will serve it,
// bootfs, is one of the services svcd starts.
//
// A manifest is ndb records: a service= record, then the records that belong
// to it, up to the next service=.
//
//   service=NAME program=/boot/bin/PROG [post=SRV [srvmode=MODE]] [bootimage]
//           [console] [tasks] [resource] [pager] [acpi] [cmdline] [restart]
//           [arch=A] [when=WORD] [storeimage]
//   arg=VALUE                                  an argument, in order
//   env=NAME=VALUE                             an environment variable
//   mount=OLD srv=SRV [aname=A] [flags=abc]    a mount in its namespace
//   bind=OLD new=NEW [flags=abc]               a bind in its namespace
//   ioport=BASE count=N                        a driver's I/O ports (x86_64)
//   mmio=ADDRESS size=N                        a driver's registers
//   irq=LINE                                   a driver's interrupt
//   claim=SRV                                  the post's server end, as "claim:SRV"
//   connect=SRV                                a connector to the post, as "srv:SRV"
//   part=SRV type=GUID|name=NAME               passed on as it is, for partd (upstream's
//                                              docs/proto/block.md §6)
//   ns=NAME                                    the namespace template /lib/ns/NAME, a
//                                              namespace(6) file (upstream ADR-0009), here
//   user=NAME                                  who it runs as (upstream's docs/11 §9),
//                                              which its attaches name; else none;
//                                              user=$WORD: the command line's WORD=
//
// A namespace record (mount=, bind=, connect=, ns=) with when=WORD is used
// only when WORD is on the command line, as a service's own when= (upstream's
// 6d8).
//
// post=SRV: svcd makes a listen channel, gives the service its server end
// ("listen") and keeps the client end as /srv/SRV, for mounts. It keeps a
// second handle to the server end, so connections made while the service is
// restarting wait for it, and none is lost. bootimage: the service gets the
// boot image, read-only. console: it writes to /srv/cons (lib/rt). tasks:
// it gets svcd's own task, and through it every task (procfs). arch: it runs
// only on that architecture. vx.skip=NAME,... on the kernel command line
// leaves services out; when=WORD keeps a service out unless the command
// line has WORD (vx.live on an install medium, vx.system on an installed
// system: upstream's M5 step 9c). storeimage: the store image, read-only,
// when the kernel had a store.tar module (an install medium, upstream's 06
// §8). A service gets nothing that is not named here: no ambient authority.
// resource and acpi: the root Resource and the ACPI tables, which only
// devmgr needs. pager: a handle to the root Resource with .Pager alone (and
// .Transfer, .Inspect), "pager", which makes pagers and nothing else (fsd:
// upstream's docs/11 §8). entropy: a seed of its own for a random
// generator, from svcd's, which the kernel seeded from the bootloader's
// entropy (vx:drbg). cmdline: the kernel command line, as svcd's own spawn
// message has it (devmgr, which gives it to bus-acpi and to drivers for
// their options).
//
// Drivers, the services with ioport, mmio or irq records, start first. svcd
// mints their device objects from the root Resource once, keeps them, and
// gives each instance its own handles to them, so a restarted driver gets
// the same device. Once a service has posted /srv/cons, svcd writes there too.
//
// A post is a rendezvous: whichever manifest names it first makes it, and
// connections wait for a server. claim= is how devmgr gets the server end of
// a post such as /srv/ether0, to give the driver it starts; connect= gives a
// service a connector to one, such as netd's to /srv/ether0.
package svcd

import vx "abi:vx"
import "vx:drbg"
import "vx:memory"
import "vx:ndb"
import "vx:ns"
import "vx:p9"
import "vx:process"
import "vx:rt"
import "vx:str"
import "vx:tar"

MAX_SERVICES :: 32
MAX_RESTARTS :: 5 // in RESTART_WINDOW, then svcd gives up
RESTART_WINDOW :: vx.Duration(10_000_000_000) // 10 s
MAX_DEVICES :: 4 // device objects per driver
MAX_NAME :: 31 // bytes in a service's or a post's name

BOOT_IMAGE_RIGHTS :: vx.Rights{.Read, .Map, .Duplicate, .Transfer, .Inspect}
PAGER_RIGHTS :: vx.Rights{.Pager, .Transfer, .Inspect} // pagers and nothing else
USER_MAX :: 64 // bytes in a user= name
CONNECTOR_RIGHTS :: vx.Rights{.Read, .Write, .Wait, .Duplicate, .Transfer, .Inspect}

when ODIN_ARCH == .amd64 {
	ARCH :: "x86_64"
} else {
	ARCH :: "aarch64"
}

Device :: struct {
	handle: vx.Handle, // svcd's own; each instance gets a duplicate
	name:   string, // the handle's name in the spawn message: ioport, mmio or irq
}

// A service's name and its post's are held in the struct, not pointed to
// (the manifest's values do not outlive its reader), so either may be copied.
Service :: struct {
	manifest:     string, // the whole file, in the boot image
	at:           int, // where its service= record starts
	name:         [dynamic; MAX_NAME]u8,
	restart:      bool,
	broken:       bool, // its device objects could not be made: never started
	devices:      [dynamic; MAX_DEVICES]Device,
	task:         vx.Handle,
	restarts:     u32,
	window_start: vx.Instant,
}

Post :: struct {
	name:    [dynamic; MAX_NAME]u8,
	client:  vx.Handle, // /srv/NAME,
	server:  vx.Handle, // and svcd's handle to the service's end
	srvmode: u32, // srvmode=: listed in srvfs's /srv with these permissions, owned by sys
	listed:  bool,
}

services: [dynamic; MAX_SERVICES]Service // a service's index is its .Exit key
posts: [dynamic; MAX_SERVICES]Post
image: []u8
image_vmo, store_vmo, port, resource, acpi_vmo: vx.Handle
acpi_size, store_size: u64
console_attached: bool
procfs_started: bool // procfs serves /srv/proc: services are registered with it as they start
randomness: drbg.Drbg // seeded from the kernel's entropy; each service that asks gets a seed from it

name_of :: proc "contextless" (s: ^Service) -> string {
	return string(s.name[:])
}

say :: proc "contextless" (parts: ..rt.Print_Arg) {
	rt.print("svcd: ")
	rt.print(..parts)
}

fail :: proc "contextless" (what: string) -> ! {
	say("FAILED: ", what, "\n")
	for { // the root task never exits
		pk: [1]vx.Packet
		_, _ = rt.port_wait(port, vx.INFINITE, 0, pk[:])
	}
}

find_post :: proc "contextless" (name: string) -> ^Post {
	for &p in posts {
		if string(p.name[:]) == name {
			return &p
		}
	}
	return nil
}

// The post of that name, made if it is not there yet: whichever manifest
// names it first (post=, claim=, connect=) makes the rendezvous. nil if there
// is no room, or the name is too long.
ensure_post :: proc "contextless" (name: string) -> ^Post {
	if p := find_post(name); p != nil || name == "" {
		return p
	}
	if len(posts) == MAX_SERVICES || len(name) > MAX_NAME {
		return nil
	}
	a, b, st := rt.channel_create()
	if st != .Ok {
		return nil
	}
	p := Post{client = a, server = b}
	_ = append(&p.name, name) // it fits: checked above
	_ = append(&posts, p) // and so does it
	return &posts[len(posts) - 1]
}

// The manifest posts that say srvmode=, listed in srvfs's /srv (upstream's
// M6 step 6d4d2a), owned by sys: created there, then written with a
// connector of their own. Without srvfs (skipped), nothing; a srvfs that
// does not answer within a few seconds is given up on.
@(private="file")
list_conn: rt.Conn

list_posts :: proc "contextless" () {
	srv := find_post("srv")
	if srv == nil || skipped("srvfs") {
		return
	}
	connector, dst := rt.handle_dup(srv.client, vx.RIGHTS_SAME)
	if dst != .Ok {
		return
	}
	defer rt.close_all(connector)
	if rt.p9_connect(connector, &list_conn) != .Ok {
		return
	}
	defer rt.p9_disconnect(&list_conn)
	c := &list_conn.c
	list_conn.timeout = 5_000_000_000
	c.uname = "sys"
	root, ast := p9.client_attach(c, "")
	if ast != .Ok {
		return
	}
	for &p in posts {
		if !p.listed {
			continue
		}
		fid, st := p9.client_walk(c, root, "")
		if st == .Ok {
			st = p9.client_create(c, fid, string(p.name[:]), p.srvmode, p9.OWRITE)
		}
		dup: vx.Handle
		if st == .Ok {
			dup, st = rt.handle_dup(p.client, vx.RIGHTS_SAME)
		}
		if st == .Ok {
			st = rt.p9_write_handle(c, fid, dup)
		}
		if st != .Ok {
			say("cannot list /srv/", string(p.name[:]), " in srvfs\n")
		}
		if fid != 0 {
			_ = p9.client_clunk(c, fid)
		}
	}
	_ = p9.client_clunk(c, root)
}

// A reader over one manifest, from `at`; values decode into its own scratch.
@(private="file")
manifest_scratch: [16 * 1024]u8

manifest_reader :: proc "contextless" (text: string, at: int) -> ndb.Reader {
	return ndb.Reader{src = text, pos = at, scratch = manifest_scratch[:]}
}

// Makes the device object a driver's ioport=, mmio= or irq= record names.
@(require_results)
mint :: proc "contextless" (s: ^Service, rec: ^ndb.Record) -> vx.Status {
	if len(s.devices) == MAX_DEVICES {
		return .Err_No_Memory
	}
	h: vx.Handle
	st := vx.Status.Err_Invalid
	name := ""
	a, aok := ndb.get_u64(rec, "ioport")
	n, nok := ndb.get_u64(rec, "count")
	if aok && nok && a <= 0xffff && n <= 0x10000 {
		h, st = rt.iorange_create(resource, u16(a), u32(n))
		name = "ioport"
	} else if a, aok = ndb.get_u64(rec, "mmio"); aok {
		if n, nok = ndb.get_u64(rec, "size"); nok {
			h, st = rt.vmo_create_physical(resource, a, n)
			name = "mmio"
		}
	} else if a, aok = ndb.get_u64(rec, "irq"); aok && a <= u64(max(u32)) {
		h, st = rt.irq_create(resource, u32(a))
		name = "irq"
	}
	if st == .Ok {
		_ = append(&s.devices, Device{handle = h, name = name})
	}
	return st
}

is_device_record :: proc "contextless" (rec: ^ndb.Record) -> bool {
	return ndb.has(rec, "ioport") || ndb.has(rec, "mmio") || ndb.has(rec, "irq")
}

// Reads one manifest's service= records, and mints its drivers' devices. A
// malformed manifest, or one with a key svc(6) does not name (SVC_KEYS, from
// svc.def), is reported and skipped whole.
read_manifest :: proc "contextless" (path, text: string) {
	// Through it once for errors first: a manifest is used whole or not at all,
	// never a service with its records cut off at a typo.
	r := manifest_reader(text, 0)
	for {
		rec: ndb.Record
		res := ndb.next(&r, &rec)
		if res == .Error {
			say(path, ": ", r.error, ", so none of it is used\n")
			return
		} else if res != .Record {
			break
		}
		if key, unknown := ndb.unknown_key(&rec, SVC_KEYS[:]); unknown {
			say(path, ": unknown key ", key, ", so none of it is used\n")
			return
		}
	}
	r = manifest_reader(text, 0)
	before := r.pos
	current: ^Service // the service the records belong to; none for one svcd skipped
	for {
		rec: ndb.Record
		if ndb.next(&r, &rec) != .Record { // none fails: it was all read above
			break
		}
		if current != nil && (ndb.has(&rec, "claim") || ndb.has(&rec, "connect")) {
			name, _ := ndb.get(&rec, ndb.has(&rec, "claim") ? "claim" : "connect")
			if ensure_post(name) == nil {
				say(name_of(current), ": cannot make its post (too many, or a long name)\n")
				current.broken = true
			}
		}
		if current != nil && is_device_record(&rec) && !current.broken {
			if st := mint(current, &rec); st != .Ok {
				say(name_of(current), ": cannot make its device, status ", i64(st), "\n")
				current.broken = true
			}
		}
		if ndb.has(&rec, "service") {
			current = nil
			name, _ := ndb.get(&rec, "service")
			srv, _ := ndb.get(&rec, "post")
			arch, _ := ndb.get(&rec, "arch")
			program, _ := ndb.get(&rec, "program")
			switch {
			case arch != "" && arch != ARCH:
			// another architecture's
			case len(services) == MAX_SERVICES || name == "" || len(name) > MAX_NAME || program == "":
				say("skipping a service in ", path, ": no name or program, or too many services\n")
			case:
				_, restart := ndb.get(&rec, "restart")
				s := Service{manifest = text, at = before, restart = restart}
				_ = append(&s.name, name)
				made := ensure_post(srv)
				if mode, _ := ndb.get(&rec, "srvmode"); made != nil && mode != "" { // octal, as chmod has it
					m := u32(0)
					for c in transmute([]u8)mode {
						if c < '0' || c > '7' {
							break
						}
						m = m * 8 + u32(c - '0')
					}
					made.srvmode, made.listed = m & 0o777, true
				}
				if srv != "" && made == nil {
					say("skipping ", name, ": cannot post it (too many, or a long name)\n")
				} else {
					_ = append(&services, s)
					current = &services[len(services) - 1]
				}
			}
		}
		before = r.pos
	}
}

// The handles a service is given, in the spawn message's order, with their
// names there.
Grants :: struct {
	handles: [dynamic; vx.CHANNEL_MAX_HANDLES - 1]vx.Handle,
	names:   [dynamic; vx.CHANNEL_MAX_HANDLES - 1]string,
}

// Adds h, as `name`, if the handle_dup that made it (with status st)
// succeeded.
@(require_results)
grant :: proc "contextless" (g: ^Grants, name: string, h: vx.Handle, st: vx.Status) -> vx.Status {
	if st != .Ok {
		return st
	}
	if append(&g.handles, h) == 0 {
		_ = rt.handle_close(h)
		return .Err_Range
	}
	_ = append(&g.names, name)
	return .Ok
}

@(private="file")
records_buf: [16 * 1024]u8
@(private="file")
handle_name_buf: [vx.CHANNEL_MAX_HANDLES][len("claim:") + MAX_NAME]u8 // "ns.NN", "claim:NAME", "srv:NAME"

// "ns." and a mount's handle index in two digits, as upstream names them:
// ns.03.
@(private="file")
ns_name :: proc "contextless" (index: int) -> string {
	b := str.Buf{buf = handle_name_buf[index][:]}
	str.write_string(&b, index < 10 ? "ns.0" : "ns.")
	str.write_u64(&b, u64(index))
	return str.to_string(&b)
}

// A mount of the post /srv/SRV at old: a connector to it, and the record
// that names it (lib/procns replays it).
@(require_results)
put_mount :: proc "contextless" (s: ^Service, g: ^Grants, w: ^ndb.Writer, old, srv, aname, flags: string) -> vx.Status {
	p := find_post(srv)
	if p == nil || len(g.handles) == cap(g.handles) {
		say(name_of(s), ": cannot mount /srv/", srv, "\n")
		return .Err_Not_Found
	}
	handle := ns_name(len(g.handles))
	grant(g, handle, rt.handle_dup(p.client, CONNECTOR_RIGHTS)) or_return
	src_buf: [len("/srv/") + MAX_NAME]u8
	src, _ := str.join(src_buf[:], "/srv/", string(p.name[:]))
	ndb.put(w, "mount", old)
	ndb.put(w, "handle", handle)
	if aname != "" {
		ndb.put(w, "aname", aname)
	}
	if flags != "" {
		ndb.put(w, "flags", flags)
	}
	ndb.put(w, "src", src)
	_ = ndb.end(w)
	return .Ok
}

put_bind :: proc "contextless" (w: ^ndb.Writer, new, old, flags: string) {
	ndb.put(w, "bind", old)
	ndb.put(w, "new", new)
	if flags != "" {
		ndb.put(w, "flags", flags)
	}
	_ = ndb.end(w)
}

@(private="file")
script: ns.Script

// The namespace template /lib/ns/NAME in the boot image, a namespace(6) file
// (upstream ADR-0009), as the child's mount and bind records: a mount's
// service is a post, /srv/NAME.
@(require_results)
put_template :: proc "contextless" (s: ^Service, g: ^Grants, w: ^ndb.Writer, name: string) -> vx.Status {
	DIR :: "lib/ns/"
	path_buf: [64]u8
	t: tar.Entry
	path, fits := str.join(path_buf[:], DIR, name)
	if name == "" || !fits || tar.find(image, path, &t) != .Ok || t.dir {
		say(name_of(s), ": no namespace template ", name, "\n")
		return .Err_Not_Found
	}
	script = {text = string(t.data)}
	op: ns.Op
	st: vx.Status
	for st = ns.script_next(&script, &op); st == .Ok; st = ns.script_next(&script, &op) {
		letters: [dynamic; 3]u8
		if .After in op.flags {
			_ = append(&letters, 'a')
		}
		if .Before in op.flags {
			_ = append(&letters, 'b')
		}
		if .Create in op.flags {
			_ = append(&letters, 'c')
		}
		flags := string(letters[:])
		SRV :: "/srv/"
		if op.kind == .Mount && len(op.args[0]) > len(SRV) && str.has_prefix(op.args[0], SRV) {
			st = put_mount(s, g, w, op.args[1], op.args[0][len(SRV):], len(op.args) > 2 ? op.args[2] : "", flags)
		} else if op.kind == .Bind {
			put_bind(w, op.args[0], op.args[1], flags)
		} else {
			st = .Err_Unsupported // a template only mounts posts and binds, so far
		}
		if st != .Ok {
			say(name_of(s), ": namespace template ", name, ": cannot do line ", u64(op.line), "\n")
			return st
		}
	}
	if st == .Err_Not_Found {
		return .Ok // the end of the file
	}
	say(name_of(s), ": namespace template ", name, ": no operation on line ", u64(op.line), "\n")
	return st
}

// Builds the spawn message's records and handles for a service, and starts it.
@(require_results)
start :: proc "contextless" (index: int) -> vx.Status {
	s := &services[index]
	g: Grants
	given := false // to spawn_elf, which takes them whatever happens
	defer if !given {
		rt.close_all(..g.handles[:])
	}
	w := ndb.Writer{buf = records_buf[:]}

	r := manifest_reader(s.manifest, s.at)
	rec: ndb.Record
	if ndb.next(&r, &rec) != .Record {
		return .Err_Invalid
	}
	program, _ := ndb.get(&rec, "program")
	elf: tar.Entry
	if len(program) < 2 || program[0] != '/' || tar.find(image, program[1:], &elf) != .Ok || elf.dir {
		say("no program ", program, " in the boot image\n")
		return .Err_Not_Found
	}
	if ndb.has(&rec, "bootimage") {
		grant(&g, "bootimage", rt.handle_dup(image_vmo, BOOT_IMAGE_RIGHTS)) or_return
		ndb.flag(&w, "bootimage")
		ndb.put_u64(&w, "size", u64(len(image)))
		_ = ndb.end(&w)
	}
	if ndb.has(&rec, "storeimage") && store_vmo != vx.HANDLE_NONE { // an install medium's objects (upstream's 06 §8)
		grant(&g, "storeimage", rt.handle_dup(store_vmo, BOOT_IMAGE_RIGHTS)) or_return
		ndb.flag(&w, "storeimage")
		ndb.put_u64(&w, "size", store_size)
		_ = ndb.end(&w)
	}
	srv, _ := ndb.get(&rec, "post")
	posts_console := srv == "cons" // decided now: rec moves on to the records below
	posts_proc := srv == "proc"
	if srv != "" {
		p := find_post(srv)
		if p == nil {
			return .Err_Not_Found
		}
		grant(&g, "listen", rt.handle_dup(p.server, CONNECTOR_RIGHTS)) or_return
	}
	cons := find_post("cons")
	if ndb.has(&rec, "console") && cons != nil {
		grant(&g, "console", rt.handle_dup(cons.client, CONNECTOR_RIGHTS)) or_return
	}
	if ndb.has(&rec, "resource") && resource != vx.HANDLE_NONE { // root authority over devices: devmgr
		grant(&g, "resource", rt.handle_dup(resource, vx.RIGHTS_SAME)) or_return
	}
	if ndb.has(&rec, "pager") && resource != vx.HANDLE_NONE { // pagers and nothing else: fsd (upstream's docs/11 §8)
		grant(&g, "pager", rt.handle_dup(resource, PAGER_RIGHTS)) or_return
	}
	if ndb.has(&rec, "acpi") && acpi_vmo != vx.HANDLE_NONE {
		grant(&g, "acpi", rt.handle_dup(acpi_vmo, vx.RIGHTS_SAME)) or_return
		ndb.flag(&w, "acpi")
		ndb.put_u64(&w, "size", acpi_size)
		_ = ndb.end(&w)
	}
	if ndb.has(&rec, "cmdline") && rt.spawn.cmdline != "" { // the kernel's, for devmgr
		ndb.put(&w, "cmdline", rt.spawn.cmdline)
		_ = ndb.end(&w)
	}
	if ndb.has(&rec, "tasks") { // svcd's own task: the whole tree, for procfs
		grant(&g, "tasks", rt.handle_dup(rt.self, {.Inspect, .Manage, .Transfer})) or_return
	}
	if ndb.has(&rec, "entropy") && randomness.seeded {
		seed: [32]u8
		drbg.read(&randomness, seed[:])
		ndb.put(&w, "entropy", string(seed[:]))
		_ = ndb.end(&w)
	}
	for d in s.devices {
		grant(&g, d.name, rt.handle_dup(d.handle, vx.RIGHTS_SAME)) or_return
	}

	// The manifest's records, and a namespace template's lines where it
	// names one (ns=NAME: /lib/ns/NAME, a namespace(6) file).
	user: [dynamic; USER_MAX]u8 // user=NAME, copied: the reader's values last one record
	for ndb.next(&r, &rec) == .Record && !ndb.has(&rec, "service") {
		if word, has_when := ndb.get(&rec, "when"); has_when && !cmdline_has(word) {
			continue // not on this boot
		}
		switch {
		case ndb.has(&rec, "ns"):
			name, _ := ndb.get(&rec, "ns")
			put_template(s, &g, &w, name) or_return
		case ndb.has(&rec, "arg"):
			v, _ := ndb.get(&rec, "arg")
			ndb.put(&w, "arg", v)
			_ = ndb.end(&w)
		case ndb.has(&rec, "env"):
			v, _ := ndb.get(&rec, "env")
			ndb.put(&w, "env", v)
			_ = ndb.end(&w)
		case ndb.has(&rec, "mount"):
			old, _ := ndb.get(&rec, "mount")
			srv_name, _ := ndb.get(&rec, "srv")
			aname, _ := ndb.get(&rec, "aname")
			flags, _ := ndb.get(&rec, "flags")
			put_mount(s, &g, &w, old, srv_name, aname, flags) or_return
		case ndb.has(&rec, "claim") || ndb.has(&rec, "connect"):
			// claim=NAME: the post's server end, to hand on (devmgr gives it to
			// a driver); connect=NAME: a connector to it. As handles
			// "claim:NAME" and "srv:NAME".
			claim := ndb.has(&rec, "claim")
			name, _ := ndb.get(&rec, claim ? "claim" : "connect")
			p := find_post(name)
			if p == nil || len(g.handles) == cap(g.handles) {
				return .Err_Not_Found
			}
			handle, _ := str.join(handle_name_buf[len(g.handles)][:], claim ? "claim:" : "srv:", string(p.name[:]))
			grant(&g, handle, rt.handle_dup(claim ? p.server : p.client, CONNECTOR_RIGHTS)) or_return
		case is_device_record(&rec) || ndb.has(&rec, "part"): // passed on as they are: a driver's device, partd's partitions
			for t in rec.tuples {
				if t.flag {
					ndb.flag(&w, t.key)
				} else {
					ndb.put(&w, t.key, t.value)
				}
			}
			_ = ndb.end(&w)
		case ndb.has(&rec, "bind"):
			old, _ := ndb.get(&rec, "bind")
			nw, _ := ndb.get(&rec, "new")
			flags, _ := ndb.get(&rec, "flags")
			put_bind(&w, nw, old, flags)
		case ndb.has(&rec, "user"):
			u, _ := ndb.get(&rec, "user")
			// $WORD: the command line's WORD=VALUE (vx.user, which install puts in
			// an installed system's, as plan9.ini's user=), else none (6d8).
			if len(u) > 1 && u[0] == '$' {
				u = cmdline_value(u[1:], "none")
			}
			if u == "" || len(u) > USER_MAX {
				return .Err_Invalid
			}
			clear(&user)
			_ = append(&user, u) // it fits: checked above
		}
	}
	if w.failed {
		return .Err_Range
	}

	a := rt.Spawn_Args {
		name         = name_of(s),
		image        = elf.data,
		handles      = g.handles[:],
		handle_names = g.names[:],
		records      = ndb.written(&w),
		user         = string(user[:]),
		// Registered with procfs before it runs (ADR-0011): in a session and
		// note group of its own, as Plan 9's daemons run (RFNOTEG), so a note
		// to one group never reaches the rest of the system; svcd watches its
		// end itself, so it leaves no wait record. procfs itself, and what
		// started before it, are registered below, once procfs serves.
		proc_flags   = PROC_FLAGS,
	}
	if procfs_started && !posts_proc {
		a.proc_conn = find_post("proc").client
	}
	given = true
	s.task = rt.spawn_elf(&a) or_return
	rt.port_bind(port, s.task, .Exit, u64(index)) or_return
	if posts_proc { // procfs serves now: it learns of every service already running, itself among them
		procfs_started = true
		for &x in services {
			if x.task == vx.HANDLE_NONE {
				continue
			}
			if _, reg := rt.proc_register(find_post("proc").client, x.task, PROC_FLAGS); reg != .Ok && reg != .Err_Exists {
				cannot("cannot register ", &x, reg)
			}
		}
	}
	info, _ := rt.task_info(s.task)
	if posts_console && !console_attached && cons != nil {
		c, dst := rt.handle_dup(cons.client, CONNECTOR_RIGHTS)
		console_attached = dst == .Ok && rt.console_attach(c) == .Ok
	}
	say("started ", name_of(s), " (task ", info.id, ")\n")
	return .Ok
}

// How every service is registered with procfs.
PROC_FLAGS :: process.Flags{.No_Wait, .Set_Sid}

cannot :: proc "contextless" (what: string, s: ^Service, st: vx.Status) {
	say(what, name_of(s), ": ", p9.error_text(st), "\n")
}

// A service has exited: restart it if its manifest says so, then say so. In
// that order, because the service may be the console svcd writes to.
exited :: proc "contextless" (index: int) {
	s := &services[index]
	info, ist := rt.task_info(s.task)
	why := ist == .Ok ? vx.exit_string(&info) : "?"
	_ = rt.handle_close(s.task)
	s.task = vx.HANDLE_NONE
	gave_up := false
	if s.restart {
		now := rt.clock_read()
		if now - s.window_start > RESTART_WINDOW {
			s.window_start = now
			s.restarts = 0
		}
		s.restarts += 1
		gave_up = s.restarts > MAX_RESTARTS
		if !gave_up {
			if st := start(index); st != .Ok {
				cannot("cannot restart ", s, st)
			}
		}
	}
	say(name_of(s), " exited", len(why) != 0 ? ": " : "", why, "\n")
	if gave_up {
		say(name_of(s), " keeps exiting; it is not restarted again\n")
	}
}

// The value of WORD=VALUE on the kernel command line (the first, at its start
// or after a space), or dflt without one.
cmdline_value :: proc "contextless" (word, dflt: string) -> string {
	c := rt.spawn.cmdline
	for i := 0; i + len(word) + 1 <= len(c); i += 1 {
		if (i != 0 && c[i - 1] != ' ') || c[i:][:len(word)] != word || c[i + len(word)] != '=' {
			continue
		}
		from := i + len(word) + 1
		to := from
		for to < len(c) && c[to] != ' ' {
			to += 1
		}
		return c[from:to]
	}
	return dflt
}

// Whether the kernel command line has word, alone: at its start or after a
// space, and at its end or before one.
cmdline_has :: proc "contextless" (word: string) -> bool {
	c := rt.spawn.cmdline
	for i := 0; i + len(word) <= len(c); i += 1 {
		if (i == 0 || c[i - 1] == ' ') && (i + len(word) == len(c) || c[i + len(word)] == ' ') && c[i:][:len(word)] == word {
			return true
		}
	}
	return false
}

// Whether the service is wanted on this boot: its when=WORD, if it has one,
// is a word of the kernel command line (vx.live on an install medium,
// vx.system on an installed system: upstream's M5 step 9c).
wanted :: proc "contextless" (s: ^Service) -> bool {
	r := manifest_reader(s.manifest, s.at)
	rec: ndb.Record
	if ndb.next(&r, &rec) != .Record || !ndb.has(&rec, "when") {
		return true
	}
	word, _ := ndb.get(&rec, "when")
	return cmdline_has(word)
}

// Whether the kernel command line's vx.skip=NAME,NAME,... names the service.
skipped :: proc "contextless" (name: string) -> bool {
	KEY :: "vx.skip="
	line := rt.spawn.cmdline
	for word in str.split_iterator(&line, ' ') {
		if !str.has_prefix(word, KEY) {
			continue
		}
		list := word[len(KEY):]
		for skip in str.split_iterator(&list, ',') {
			if skip == name {
				return true
			}
		}
	}
	return false
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	info, _ := rt.task_info(rt.self)
	say("hello from user space (task ", info.id, ")\n")
	pst: vx.Status
	if port, pst = rt.port_create(); pst != .Ok {
		fail("port_create")
	}
	seed: ndb.Record
	bytes: string
	if rt.spawn_record("entropy", &seed) {
		bytes, _ = ndb.get(&seed, "entropy")
	}
	if len(bytes) >= 16 {
		drbg.mix(&randomness, transmute([]u8)bytes, true)
	} else {
		say("no entropy from the kernel: services get none\n")
	}

	resource = rt.spawn_take("resource")
	acpi_vmo = rt.spawn_take("acpi")
	if acpi_vmo != vx.HANDLE_NONE {
		rec: ndb.Record
		size_ok := false
		if rt.spawn_record("acpi", &rec) {
			acpi_size, size_ok = ndb.get_u64(&rec, "size")
		}
		if !size_ok {
			acpi_vmo = vx.HANDLE_NONE
		}
	}
	image_vmo = rt.spawn_take("bootimage")
	store_vmo = rt.spawn_take("storeimage")
	if store_vmo != vx.HANDLE_NONE {
		rec: ndb.Record
		size_ok := false
		if rt.spawn_record("storeimage", &rec) {
			store_size, size_ok = ndb.get_u64(&rec, "size")
		}
		if !size_ok {
			store_vmo = vx.HANDLE_NONE
		}
	}
	size, ok := rt.boot_image_size()
	if image_vmo == vx.HANDLE_NONE || !ok {
		fail("no boot image")
	}
	// The size is the kernel's, but round it up to pages without wrapping all the same.
	padded, pok := memory.page_round(size)
	if !pok {
		fail("cannot map the boot image")
	}
	base, mst := rt.as_map(rt.self, image_vmo, 0, padded, {})
	if mst != .Ok {
		fail("cannot map the boot image")
	}
	image = (cast([^]u8)uintptr(base))[:size]

	t := tar.open(image)
	e: tar.Entry
	st: vx.Status
	for st = tar.next(&t, &e); st == .Ok; st = tar.next(&t, &e) {
		DIR :: "boot/svc/"
		path := tar.entry_path(&e)
		if e.dir || len(path) <= len(DIR) + len(".ndb") || !str.has_prefix(path, DIR) || !str.has_suffix(path, ".ndb") {
			continue
		}
		read_manifest(path, string(e.data))
	}
	if st == .Err_Invalid {
		fail("the boot image is malformed")
	}

	for drivers in ([2]bool{true, false}) { // drivers first, so the console is there for the rest
		for &s, i in services {
			if (len(s.devices) > 0) == drivers && !s.broken && !skipped(name_of(&s)) && wanted(&s) {
				started := start(i)
				if started != .Ok {
					cannot("cannot start ", &s, started)
				}
				// srvfs up: the posts that say srvmode= are listed before the services after it look.
				if started == .Ok && name_of(&s) == "srvfs" {
					list_posts()
				}
			}
		}
	}

	for {
		pk: [8]vx.Packet
		n, _ := rt.port_wait(port, vx.INFINITE, 0, pk[:])
		for p in pk[:n] {
			if p.trigger == .Exit && p.key < u64(len(services)) {
				exited(int(p.key))
			}
		}
	}
}
