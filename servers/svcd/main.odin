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
//   service=NAME program=/boot/bin/PROG [post=SRV] [bootimage] [console] [tasks] [restart] [arch=A]
//   arg=VALUE                                  an argument, in order
//   mount=OLD srv=SRV [aname=A] [flags=abc]    a mount in its namespace
//   bind=OLD new=NEW [flags=abc]               a bind in its namespace
//   ioport=BASE count=N                        a driver's I/O ports (x86_64)
//   mmio=ADDRESS size=N                        a driver's registers
//   irq=LINE                                   a driver's interrupt
//
// post=SRV: svcd makes a listen channel, gives the service its server end
// ("listen") and keeps the client end as /srv/SRV, for mounts. It keeps a
// second handle to the server end, so connections made while the service is
// restarting wait for it, and none is lost. bootimage: the service gets the
// boot image, read-only. console: it writes to /srv/cons (lib/rt). tasks:
// it gets svcd's own task, and through it every task (procfs). arch: it runs
// only on that architecture. vx.skip=NAME,... on the kernel command line
// leaves services out. A service gets nothing that is not named here: no
// ambient authority.
//
// Drivers, the services with ioport, mmio or irq records, start first. svcd
// mints their device objects from the root Resource once, keeps them, and
// gives each instance its own handles to them, so a restarted driver gets
// the same device. Once a service has posted /srv/cons, svcd writes there too.
package svcd

import vx "abi:vx"
import "vx:memory"
import "vx:ndb"
import "vx:p9"
import "vx:rt"
import "vx:str"
import "vx:tar"

MAX_SERVICES :: 16
MAX_RESTARTS :: 5 // in RESTART_WINDOW, then svcd gives up
RESTART_WINDOW :: vx.Duration(10_000_000_000) // 10 s
MAX_DEVICES :: 4 // device objects per driver
MAX_NAME :: 31 // bytes in a service's or a post's name

BOOT_IMAGE_RIGHTS :: vx.Rights{.Read, .Map, .Duplicate, .Transfer, .Inspect}
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
	name:   [dynamic; MAX_NAME]u8,
	client: vx.Handle, // /srv/NAME,
	server: vx.Handle, // and svcd's handle to the service's end
}

services: [dynamic; MAX_SERVICES]Service // a service's index is its .Exit key
posts: [dynamic; MAX_SERVICES]Post
image: []u8
image_vmo, port, resource: vx.Handle
console_attached: bool

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
// malformed manifest is reported and skipped.
read_manifest :: proc "contextless" (path, text: string) {
	r := manifest_reader(text, 0)
	before := r.pos
	current: ^Service // the service the records belong to; none for one svcd skipped
	res: ndb.Result
	for {
		rec: ndb.Record
		res = ndb.next(&r, &rec)
		if res != .Record {
			break
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
				_ = append(&services, s)
				current = &services[len(services) - 1]
				if srv != "" && find_post(srv) == nil {
					if len(posts) == MAX_SERVICES || len(srv) > MAX_NAME {
						fail("too many posts, or a long name")
					}
					a, b, st := rt.channel_create()
					if st != .Ok {
						fail("channel_create")
					}
					p := Post{client = a, server = b}
					_ = append(&p.name, srv)
					_ = append(&posts, p)
				}
			}
		}
		before = r.pos
	}
	if res == .Error {
		say(path, ": ", r.error, "\n")
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
ns_name_buf: [vx.CHANNEL_MAX_HANDLES][8]u8

// "ns." and a mount's handle index in two digits, as upstream names them:
// ns.03.
@(private="file")
ns_name :: proc "contextless" (index: int) -> string {
	b := str.Buf{buf = ns_name_buf[index][:]}
	str.write_string(&b, index < 10 ? "ns.0" : "ns.")
	str.write_u64(&b, u64(index))
	return str.to_string(&b)
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
	srv, _ := ndb.get(&rec, "post")
	posts_console := srv == "cons" // decided now: rec moves on to the records below
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
	if ndb.has(&rec, "tasks") { // svcd's own task: the whole tree, for procfs
		grant(&g, "tasks", rt.handle_dup(rt.self, {.Inspect, .Manage, .Transfer})) or_return
	}
	for d in s.devices {
		grant(&g, d.name, rt.handle_dup(d.handle, vx.RIGHTS_SAME)) or_return
	}

	for ndb.next(&r, &rec) == .Record && !ndb.has(&rec, "service") {
		switch {
		case ndb.has(&rec, "arg"):
			v, _ := ndb.get(&rec, "arg")
			ndb.put(&w, "arg", v)
		case ndb.has(&rec, "mount"):
			srv_name, _ := ndb.get(&rec, "srv")
			p := find_post(srv_name)
			if p == nil || len(g.handles) == cap(g.handles) {
				say(name_of(s), ": cannot mount /srv/", srv_name, "\n")
				return .Err_Not_Found
			}
			handle := ns_name(len(g.handles))
			grant(&g, handle, rt.handle_dup(p.client, CONNECTOR_RIGHTS)) or_return
			src_buf: [len("/srv/") + MAX_NAME]u8
			src, _ := str.join(src_buf[:], "/srv/", string(p.name[:]))
			v, _ := ndb.get(&rec, "mount")
			ndb.put(&w, "mount", v)
			ndb.put(&w, "handle", handle)
			if a, ok := ndb.get(&rec, "aname"); ok {
				ndb.put(&w, "aname", a)
			}
			if f, ok := ndb.get(&rec, "flags"); ok {
				ndb.put(&w, "flags", f)
			}
			ndb.put(&w, "src", src)
		case is_device_record(&rec): // passed on as they are, for the driver to read
			for t in rec.tuples {
				if t.flag {
					ndb.flag(&w, t.key)
				} else {
					ndb.put(&w, t.key, t.value)
				}
			}
		case ndb.has(&rec, "bind"):
			b, _ := ndb.get(&rec, "bind")
			nw, _ := ndb.get(&rec, "new")
			ndb.put(&w, "bind", b)
			ndb.put(&w, "new", nw)
			if f, ok := ndb.get(&rec, "flags"); ok {
				ndb.put(&w, "flags", f)
			}
		case:
			continue
		}
		_ = ndb.end(&w)
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
	}
	given = true
	s.task = rt.spawn_elf(&a) or_return
	rt.port_bind(port, s.task, .Exit, u64(index)) or_return
	info, _ := rt.task_info(s.task)
	if posts_console && !console_attached && cons != nil {
		c, dst := rt.handle_dup(cons.client, CONNECTOR_RIGHTS)
		console_attached = dst == .Ok && rt.console_attach(c) == .Ok
	}
	say("started ", name_of(s), " (task ", info.id, ")\n")
	return .Ok
}

cannot :: proc "contextless" (what: string, s: ^Service, st: vx.Status) {
	say(what, name_of(s), ": ", p9.error_text(st), "\n")
}

// A service has exited: restart it if its manifest says so, then say so. In
// that order, because the service may be the console svcd writes to.
exited :: proc "contextless" (index: int, exit_status: i64) {
	s := &services[index]
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
	say(name_of(s), " exited with status ", exit_status, "\n")
	if gave_up {
		say(name_of(s), " keeps exiting; it is not restarted again\n")
	}
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

	resource = rt.spawn_take("resource")
	image_vmo = rt.spawn_take("bootimage")
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
			if (len(s.devices) > 0) == drivers && !s.broken && !skipped(name_of(&s)) {
				if started := start(i); started != .Ok {
					cannot("cannot start ", &s, started)
				}
			}
		}
	}

	for {
		pk: [8]vx.Packet
		n, _ := rt.port_wait(port, vx.INFINITE, 0, pk[:])
		for p in pk[:n] {
			if p.trigger == .Exit && p.key < u64(len(services)) {
				exited(int(p.key), i64(p.value)) // the exit status, signed
			}
		}
	}
}
