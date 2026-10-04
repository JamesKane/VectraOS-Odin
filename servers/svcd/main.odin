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
import "vx:tar"

MAX_SERVICES :: 16
MAX_RESTARTS :: 5 // in RESTART_WINDOW, then svcd gives up
RESTART_WINDOW :: vx.Duration(10_000_000_000) // 10 s
MAX_DEVICES :: 4 // device objects per driver

BOOT_IMAGE_RIGHTS :: vx.Rights{.Read, .Map, .Duplicate, .Transfer, .Inspect}
CONNECTOR_RIGHTS :: vx.Rights{.Read, .Write, .Wait, .Duplicate, .Transfer, .Inspect}

when ODIN_ARCH == .amd64 {
	ARCH :: "x86_64"
} else {
	ARCH :: "aarch64"
}

Service :: struct {
	manifest:     string, // the whole file, in the boot image
	at:           int, // where its service= record starts
	name:         string, // in names
	restart:      bool,
	broken:       bool, // its device objects could not be made: never started
	devices:      int,
	device:       [MAX_DEVICES]vx.Handle, // svcd's own handles; each instance gets duplicates
	device_name:  [MAX_DEVICES]string,
	task:         vx.Handle,
	restarts:     u32,
	window_start: vx.Instant,
}

Post :: struct {
	name:   string, // into buf
	client: vx.Handle, // /srv/NAME,
	server: vx.Handle, // and svcd's handle to the service's end
	buf:    [32]u8,
}

services: [MAX_SERVICES]Service
service_count: int
posts: [MAX_SERVICES]Post
post_count: int
image: []u8
image_vmo, port, resource: vx.Handle
console_attached: bool
names: [MAX_SERVICES][32]u8

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
	for &p in posts[:post_count] {
		if p.name == name {
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
mint :: proc "contextless" (s: ^Service, rec: ^ndb.Record) -> vx.Status {
	if s.devices == MAX_DEVICES {
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
		s.device[s.devices] = h
		s.device_name[s.devices] = name
		s.devices += 1
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
				say(current.name, ": cannot make its device, status -")
				rt.print_u64(u64(-i64(st)))
				rt.print("\n")
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
			case service_count == MAX_SERVICES || name == "" || len(name) >= len(names[0]) || program == "":
				say("skipping a service in ", path, ": no name or program, or too many services\n")
			case:
				copy(names[service_count][:], name) // the record's values do not outlive the reader
				_, restart := ndb.get(&rec, "restart")
				services[service_count] = {manifest = text, at = before, name = string(names[service_count][:len(name)]), restart = restart}
				current = &services[service_count]
				if srv != "" && find_post(srv) == nil {
					if post_count == MAX_SERVICES || len(srv) >= len(posts[0].buf) {
						fail("too many posts, or a long name")
					}
					p := &posts[post_count]
					a, b, st := rt.channel_create()
					if st != .Ok {
						fail("channel_create")
					}
					p^ = {client = a, server = b}
					copy(p.buf[:], srv)
					p.name = string(p.buf[:len(srv)])
					post_count += 1
				}
				service_count += 1
			}
		}
		before = r.pos
	}
	if res == .Error {
		say(path, ": ", r.error, "\n")
	}
}

@(private="file")
records_buf: [16 * 1024]u8
@(private="file")
ns_names: [vx.CHANNEL_MAX_HANDLES][8]u8
@(private="file")
src_buf: [vx.CHANNEL_MAX_HANDLES][40]u8

// Builds the spawn message's records and handles for a service, and starts it.
start :: proc "contextless" (s: ^Service) -> vx.Status {
	w := ndb.Writer{buf = records_buf[:]}
	handles: [vx.CHANNEL_MAX_HANDLES - 1]vx.Handle // NONE until given, so a failure closes only real ones
	handle_names: [vx.CHANNEL_MAX_HANDLES - 1]string
	count := 0
	st := vx.Status.Ok

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
		handles[count], st = rt.handle_dup(image_vmo, BOOT_IMAGE_RIGHTS)
		handle_names[count] = "bootimage"
		count += 1
		ndb.flag(&w, "bootimage")
		ndb.put_u64(&w, "size", u64(len(image)))
		_ = ndb.end(&w)
	}
	srv, _ := ndb.get(&rec, "post")
	posts_console := srv == "cons" // decided now: rec moves on to the records below
	if st == .Ok && srv != "" {
		p := find_post(srv)
		if p != nil {
			handles[count], st = rt.handle_dup(p.server, CONNECTOR_RIGHTS)
		} else {
			st = .Err_Not_Found
		}
		handle_names[count] = "listen"
		count += 1
	}
	cons := find_post("cons")
	if st == .Ok && ndb.has(&rec, "console") && cons != nil {
		handles[count], st = rt.handle_dup(cons.client, CONNECTOR_RIGHTS)
		handle_names[count] = "console"
		count += 1
	}
	if st == .Ok && ndb.has(&rec, "tasks") { // svcd's own task: the whole tree, for procfs
		handles[count], st = rt.handle_dup(rt.self, {.Inspect, .Manage, .Transfer})
		handle_names[count] = "tasks"
		count += 1
	}
	for i in 0 ..< s.devices {
		if st != .Ok {
			break
		}
		handles[count], st = rt.handle_dup(s.device[i], vx.RIGHTS_SAME)
		handle_names[count] = s.device_name[i]
		count += 1
	}

	for st == .Ok {
		if ndb.next(&r, &rec) != .Record || ndb.has(&rec, "service") {
			break
		}
		switch {
		case ndb.has(&rec, "arg"):
			v, _ := ndb.get(&rec, "arg")
			ndb.put(&w, "arg", v)
		case ndb.has(&rec, "mount"):
			srv_name, _ := ndb.get(&rec, "srv")
			p := find_post(srv_name)
			if p == nil || count == vx.CHANNEL_MAX_HANDLES - 1 {
				say(s.name, ": cannot mount /srv/", srv_name, "\n")
				st = .Err_Not_Found
				break
			}
			hn := &ns_names[count]
			hn^ = {'n', 's', '.', u8('0' + count / 10), u8('0' + count % 10), 0, 0, 0}
			handles[count], st = rt.handle_dup(p.client, CONNECTOR_RIGHTS)
			handle_names[count] = string(hn[:5])
			count += 1
			src := &src_buf[count]
			copy(src[:], "/srv/")
			n := min(len(p.name), len(src) - 5)
			copy(src[5:], p.name[:n])
			v, _ := ndb.get(&rec, "mount")
			ndb.put(&w, "mount", v)
			ndb.put(&w, "handle", string(hn[:5]))
			if a, ok := ndb.get(&rec, "aname"); ok {
				ndb.put(&w, "aname", a)
			}
			if f, ok := ndb.get(&rec, "flags"); ok {
				ndb.put(&w, "flags", f)
			}
			ndb.put(&w, "src", string(src[:5 + n]))
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
		if st == .Ok {
			_ = ndb.end(&w)
		}
	}
	if st == .Ok && w.failed {
		st = .Err_Range
	}
	if st != .Ok {
		for h in handles[:count] {
			if h != 0 {
				_ = rt.handle_close(h)
			}
		}
		return st
	}

	a := rt.Spawn_Args {
		name         = s.name,
		image        = elf.data,
		handles      = handles[:count],
		handle_names = handle_names[:count],
		records      = ndb.written(&w),
	}
	s.task, st = rt.spawn_elf(&a)
	if st == .Ok {
		st = rt.port_bind(port, s.task, .Exit, u64(service_index(s)))
	}
	if st != .Ok {
		return st
	}
	info, _ := rt.task_info(s.task)
	if posts_console && !console_attached && cons != nil {
		c, dst := rt.handle_dup(cons.client, CONNECTOR_RIGHTS)
		console_attached = dst == .Ok && rt.console_attach(c) == .Ok
	}
	say("started ", s.name, " (task ")
	rt.print_u64(info.id)
	rt.print(")\n")
	return .Ok
}

service_index :: proc "contextless" (s: ^Service) -> int {
	return int((uintptr(s) - uintptr(&services[0])) / size_of(Service))
}

cannot :: proc "contextless" (what: string, s: ^Service, st: vx.Status) {
	say(what, s.name, ": ", p9.error_text(st), "\n")
}

// A service has exited: restart it if its manifest says so, then say so. In
// that order, because the service may be the console svcd writes to.
exited :: proc "contextless" (s: ^Service, exit_status: i64) {
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
			if st := start(s); st != .Ok {
				cannot("cannot restart ", s, st)
			}
		}
	}
	say(s.name, " exited with status ")
	rt.print_i64(exit_status)
	rt.print("\n")
	if gave_up {
		say(s.name, " keeps exiting; it is not restarted again\n")
	}
}

// Whether the kernel command line's vx.skip=NAME,NAME,... names the service.
skipped :: proc "contextless" (name: string) -> bool {
	c := rt.spawn.cmdline
	KEY :: "vx.skip="
	for i := 0; i + len(KEY) <= len(c); i += 1 {
		if (i > 0 && c[i - 1] != ' ') || c[i:i + len(KEY)] != KEY {
			continue
		}
		at := i + len(KEY)
		for at < len(c) && c[at] != ' ' {
			start_at := at
			for at < len(c) && c[at] != ' ' && c[at] != ',' {
				at += 1
			}
			if c[start_at:at] == name {
				return true
			}
			if at < len(c) && c[at] == ',' {
				at += 1
			}
		}
	}
	return false
}

@(export, link_name="vx_main")
main :: proc() -> int {
	info, _ := rt.task_info(rt.self)
	rt.print("svcd: hello from user space (task ")
	rt.print_u64(info.id)
	rt.print(")\n")
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
		if e.dir || len(path) < len(DIR) + 5 || path[:len(DIR)] != DIR || path[len(path) - 4:] != ".ndb" {
			continue
		}
		read_manifest(path, string(e.data))
	}
	if st == .Err_Invalid {
		fail("the boot image is malformed")
	}

	for drivers := 1; drivers >= 0; drivers -= 1 { // drivers first, so the console is there for the rest
		for &s in services[:service_count] {
			if (s.devices > 0) == (drivers == 1) && !s.broken && !skipped(s.name) {
				if started := start(&s); started != .Ok {
					cannot("cannot start ", &s, started)
				}
			}
		}
	}

	for {
		pk: [8]vx.Packet
		n, _ := rt.port_wait(port, vx.INFINITE, 0, pk[:])
		for p in pk[:n] {
			if p.trigger == .Exit && p.key < u64(service_count) {
				exited(&services[p.key], i64(p.value)) // the exit status, signed
			}
		}
	}
}
