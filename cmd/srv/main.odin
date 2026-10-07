// srv: posts a 9P server over TCP in /srv, and mounts it, as 9front's
// srv(4) does (upstream's M6 step 6d4d2c): the dialing done by a relay
// (relay(4)), which the post keeps going for whoever opens it; the mount
// made in the namespace srv shares with whoever ran it, so the shell has it
// after srv exits.
package srv

import vx "abi:vx"
import usage "gen:usage/srv"
import "vx:ns"
import "vx:p9"
import "vx:procns"
import "vx:rt"
import "vx:str"

space: ns.Namespace

say :: proc "contextless" (a, b: string, st: vx.Status) {
	rt.eprint("srv: ", a, b)
	if st != .Ok {
		rt.eprint(": ", p9.error_text(st))
	}
	rt.eprint("\n")
}

// The part of s after its last c, or all of it.
after_last :: proc "contextless" (s: string, c: u8) -> string {
	return s[str.last_index_byte(s, c) + 1:]
}

// The part of s after its first c, or all of it.
after_first :: proc "contextless" (s: string, c: u8) -> string {
	i := str.index_byte(s, c)
	return i < 0 ? s : s[i + 1:]
}

// 9front's netmkaddr(dest, 0, "9fs"): host, net!host and net!host!service.
address :: proc "contextless" (d: string, buf: []u8) -> (string, bool) {
	bangs := 0
	for c in transmute([]u8)d {
		if c == '!' {
			bangs += 1
		}
	}
	return str.join(buf, bangs > 0 ? "" : "tcp!", d, bangs == 2 ? "" : "!9fs")
}

remove_post :: proc "contextless" (path: string) -> vx.Status {
	c, fid := ns.walk(&space, path) or_return
	return p9.client_remove(c, fid)
}

// Posts connector (a duplicate of it) as path, owned by whoever runs srv,
// 0600 as on 9front.
post :: proc "contextless" (path: string, connector: vx.Handle) -> (st: vx.Status) {
	f: ns.File
	ns.create(&space, path, 0o600, p9.OWRITE, &f) or_return
	dup: vx.Handle
	dup, st = rt.handle_dup(connector, vx.RIGHTS_SAME)
	if st == .Ok {
		st = rt.p9_write_handle(f.c, f.fid, dup)
	}
	ns.close(&f)
	if st != .Ok {
		_ = remove_post(path)
	}
	return
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	rt.exits(run())
}

run :: proc() -> string {
	args := rt.args()
	domount, reallymount, asnone := false, false, false
	flags: ns.Flags
	sleeptime: u64
	i := 0
	for ; i < len(args) && len(args[i]) > 1 && args[i][0] == '-'; i += 1 {
		a := args[i]
		for j := 1; j < len(a); j += 1 {
			switch a[j] {
			case 'a':
				flags += {.After}
				domount, reallymount = true, true
			case 'b':
				flags += {.Before}
				domount, reallymount = true, true
			case 'c':
				flags += {.Create}
				domount, reallymount = true, true
			case 'C', 'm': // -C: no mount cache here, a mount as any other
				domount, reallymount = true, true
			case 'N':
				asnone = true
			case 'n': // no authentication: there is none before keyd (upstream's M10)
			case 'q':
				domount, reallymount = true, false
			case 's':
				i += 1
				if i == len(args) {
					rt.eprint(usage.TEXT, "\n")
					return "usage"
				}
				for c in transmute([]u8)args[i] { // as atoi reads it: to the first byte not a digit
					if c < '0' || c > '9' {
						break
					}
					sleeptime = sleeptime * 10 + (u64(c) - '0')
				}
				j = len(a)
			case:
				rt.eprint(usage.TEXT, "\n")
				return "usage"
			}
		}
	}
	n := len(args) - i
	if .After in flags && .Before in flags {
		n = 0
	}
	if n < 1 || n > 3 {
		rt.eprint(usage.TEXT, "\n")
		return "usage"
	}
	dest := args[i]
	// 9front's names: /srv/ the address's last element; /n/ the address after its network.
	base := after_last(dest, '/')
	srv_buf: [96]u8
	mtpt_buf: [ns.MAX_PATH]u8
	addr_buf: [ns.MAX_SRC]u8
	srv, fits := str.join(srv_buf[:], "/srv/", n >= 2 ? args[i + 1] : base)
	mtpt: string
	mok: bool
	if n == 3 {
		mtpt, mok = str.join(mtpt_buf[:], args[i + 2])
		domount, reallymount = true, true
	} else {
		mtpt, mok = str.join(mtpt_buf[:], "/n/", after_first(base, '!'))
	}
	addr, aok := address(dest, addr_buf[:])
	if !fits || !mok || !aok || addr == "" {
		say(dest, ": name too long", .Ok)
		return "usage"
	}
	if procns.from_spawn(&space) != .Ok {
		return "no namespace"
	}

	for try := 1; ; try += 1 {
		c: ^p9.Client
		connector := vx.HANDLE_NONE
		if probe, fid, wst := ns.walk(&space, srv); wst == .Ok { // there already
			_ = p9.client_clunk(probe, fid)
			if !domount {
				say(srv, " already exists", .Ok)
				return ""
			}
			st: vx.Status
			connector, st = procns.open_post(&space, srv)
			if st == .Ok {
				c, st = procns.connect_handle(connector)
				if c == nil {
					rt.close_all(connector)
				}
			}
			if c == nil { // a post of nothing that answers: made again
				_ = remove_post(srv)
			}
		}
		if c == nil {
			st: vx.Status
			c, connector, st = procns.relay(&space, addr)
			if st != .Ok {
				say("dial ", addr, st)
				return "dial"
			}
			if sleeptime != 0 {
				if port, pst := rt.port_create(); pst == .Ok {
					pk: [1]vx.Packet
					_, _ = rt.port_wait(port, rt.clock_read() + vx.Instant(sleeptime * 1_000_000_000), 0, pk[:])
					rt.close_all(port)
				}
			}
			if st = post(srv, connector); st != .Ok {
				say(srv, "", st)
				return "post"
			}
		}
		if !domount || !reallymount {
			return ""
		}
		if asnone {
			c.uname = "none"
			try = 2 // no retry, as on 9front
		}
		st := ns.mount(&space, c, connector, srv, "", mtpt, flags)
		if st == .Ok {
			return ""
		}
		if (st == .Err_Peer_Closed || st == .Err_Timed_Out) && try == 1 { // hung up: made again, once
			_ = remove_post(srv)
			continue
		}
		rt.eprint("srv ", dest, ": mount failed: ", p9.error_text(st), "\n") // 9front's words
		return "mount"
	}
}
