package procns

// Relays and posts (upstream's lib/vx-ns/relay.c, its M6 step 6d4d2c), as
// 9front shares a mounted channel: a 9P server over TCP is mounted through
// a relay (servers/relay, relay(4)), so every process the namespace reaches
// shares its one session rather than dialing its own, and a post in srvfs's
// /srv is opened for the connector it holds. For programs that mount by
// name: rc's mount, srv(1). A program that does not use these dials for
// itself still (vx:ns's dial).
//
// The relay is spawned with a copy of the namespace, not as a member of its
// group: its /net is the spawner's, and a mount of the relay itself, which
// the group's text soon has, is never replayed into it.
//
// Here rather than in vx:ns, which makes no system calls (the host builds
// it): spawning a relay and connecting through a connector are vx:rt's.

import vx "abi:vx"
import "vx:ndb"
import "vx:ns"
import "vx:p9"
import "vx:rt"

@(private="file")
RELAY_IMAGE_MAX :: u64(8) << 20

// The program at path read into a mapping of its own: unmapped by the
// caller (RELAY_IMAGE_MAX bytes at va).
@(private="file", require_results)
read_image :: proc "contextless" (space: ^ns.Namespace, path: string) -> (va: u64, size: int, st: vx.Status) {
	f: ns.File
	ns.open(space, path, p9.OREAD, &f) or_return
	defer ns.close(&f)
	vmo := rt.vmo_create(RELAY_IMAGE_MAX) or_return
	va, st = rt.as_map(rt.self, vmo, 0, RELAY_IMAGE_MAX, {.Write})
	rt.close_all(vmo) // the mapping keeps it
	st or_return
	image := ([^]u8)(uintptr(va))[:RELAY_IMAGE_MAX]
	for size < len(image) {
		n: int
		n, st = ns.read(&f, image[size:][:min(len(image) - size, 65536)])
		if st != .Ok || n <= 0 {
			break
		}
		size += n
	}
	if st == .Ok && (size == 0 || size == len(image)) {
		st = .Err_Invalid
	}
	if st != .Ok {
		_ = rt.as_unmap(rt.self, va, RELAY_IMAGE_MAX)
		return 0, 0, st
	}
	return va, size, .Ok
}

@(private="file")
relay_records: [8 * 1024]u8

// A relay for addr (as vx:ns's dial spells it, tcp!HOST!PORT), connected
// through once to see that it dialed: the connection, and the connector it
// came through (the namespace's once it is mounted). It runs as long as
// anything holds a connector, in a session and note group of its own, so
// the spawner's interrupts leave it be; its own messages go to the console.
@(require_results)
relay :: proc "contextless" (space: ^ns.Namespace, addr: string) -> (c: ^p9.Client, connector: vx.Handle, st: vx.Status) {
	va, size := read_image(space, "/boot/bin/relay") or_return
	w := ndb.Writer {
		buf = relay_records[:],
	}
	ndb.put(&w, "arg", addr)
	_ = ndb.end(&w)
	handles: [vx.CHANNEL_MAX_HANDLES - 1]vx.Handle
	names: [vx.CHANNEL_MAX_HANDLES - 1]string
	a, b: vx.Handle
	a, b, st = rt.channel_create()
	count: int
	if st == .Ok {
		count, st = copy_records(space, &w, handles[:vx.CHANNEL_MAX_HANDLES - 4], names[:], 0)
	}
	if st == .Ok {
		handles[count], names[count] = b, "listen"
		count += 1
		b = vx.HANDLE_NONE // the child's, whatever happens
		if cc := rt.console_connector(); cc != vx.HANDLE_NONE {
			if h, dst := rt.handle_dup(cc, vx.RIGHTS_SAME); dst == .Ok {
				handles[count], names[count] = h, "console"
				count += 1
			}
		}
		args := rt.Spawn_Args {
			name         = "relay",
			image        = ([^]u8)(uintptr(va))[:size],
			handles      = handles[:count],
			handle_names = names[:count],
			records      = ndb.written(&w),
			proc_conn    = ns.connector(space, "/proc"),
			proc_flags   = {.No_Wait, .Set_Sid},
		}
		task: vx.Handle
		task, st = rt.spawn_elf(&args)
		if st == .Ok {
			rt.close_all(task)
		}
	}
	_ = rt.as_unmap(rt.self, va, RELAY_IMAGE_MAX)
	rt.close_all(b)
	if st == .Ok {
		c, st = connect_handle(a) // fails if it could not dial: it has gone
	}
	if c != nil {
		return c, a, .Ok
	}
	rt.close_all(a)
	return nil, vx.HANDLE_NONE, st == .Ok ? .Err_Peer_Closed : st
}

// The connector of a post in srvfs's /srv, by its path there (/srv/NAME).
@(require_results)
open_post :: proc "contextless" (space: ^ns.Namespace, path: string) -> (connector: vx.Handle, st: vx.Status) {
	c, fid := ns.walk(space, path) or_return
	connector, st = p9.client_open_handle(c, fid, p9.ORDWR)
	_ = p9.client_clunk(c, fid)
	if st == .Ok && connector == vx.HANDLE_NONE {
		st = .Err_Invalid // a file with no connector: not a post
	}
	return
}

// Mounts, at old, through a connector: its connection made, and the
// connector the namespace's if the mount is made.
@(private="file", require_results)
mount_connector :: proc "contextless" (space: ^ns.Namespace, connector: vx.Handle, src, aname, old: string, flags: ns.Flags) -> vx.Status {
	c, st := connect_handle(connector)
	if c == nil {
		rt.close_all(connector)
		return st
	}
	return ns.mount(space, c, connector, src, aname, old, flags)
}

// Mounts the post /srv/NAME at old: through a connection this namespace has
// from it already, or the connector srvfs gives for it (made at run time, by
// srv(1), say).
@(require_results)
mount_post :: proc "contextless" (space: ^ns.Namespace, src, aname, old: string, flags: ns.Flags) -> vx.Status {
	st := ns.mount_srv(space, src, aname, old, flags)
	if st != .Err_Not_Found {
		return st
	}
	connector := open_post(space, src) or_return
	return mount_connector(space, connector, src, aname, old, flags)
}

// Mounts the 9P server at addr (tcp!HOST!PORT, 9p://HOST:PORT) at old,
// through a relay: the one this namespace, or its group, has for it already,
// or a new one.
@(require_results)
mount_addr :: proc "contextless" (space: ^ns.Namespace, addr, aname, old: string, flags: ns.Flags) -> vx.Status {
	want_buf: [ns.MAX_SRC]u8
	src, ok := ns.dial_address(addr, want_buf[:])
	if !ok {
		return .Err_Invalid
	}
	st := ns.mount_srv(space, src, aname, old, flags)
	if st != .Err_Not_Found {
		return st
	}
	if group.chan != vx.HANDLE_NONE { // a member's relay, given to nsd with its mount
		connector: [1]vx.Handle
		if _, nst := nsd(group.chan, .Connector, {}, src, "", nil, connector[:]); nst == .Ok {
			return mount_connector(space, connector[0], src, aname, old, flags)
		}
	}
	c, connector := relay(space, src) or_return
	return ns.mount(space, c, connector, src, aname, old, flags)
}
