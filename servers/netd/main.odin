// netd: the network service (upstream docs/00 §3, 02 §5, 04 §5 M3). It runs
// vx:net over the network driver's frames (/srv/ether0, the net class
// protocol in lib/driver/netproto.odin) and serves /net, posted as /srv/net,
// in Plan 9's layout:
//
//   /net/ipifc/0/status     dev=ether0 addr=10.0.2.15/24 gw=10.0.2.2 dhcp lease=86400s
//   /net/ipifc/0/ctl        write "add 10.0.2.15/24 [10.0.2.2]" (a static address) or "dhcp"
//   /net/icmp, /net/udp, /net/tcp    conversations:
//     clone                 opening it makes conversation N, and the fid becomes N/ctl
//     N/ctl                 read: N; write "connect ADDR[!PORT]", "announce PORT", "hangup";
//                           a TCP connect returns once the connection is made, or refused
//     N/data                a datagram a read (waiting for one), a datagram a write;
//                           ICMP: whole messages, the identifier and checksum filled in
//     N/local, N/remote     ADDR!PORT
//     N/status              Open, Announced or Closed; TCP's state, as Plan 9 names it
//     N/listen              TCP, announced: opening it waits for a call, and the fid
//                           becomes the new connection's ctl
//   TCP's data is a stream: a read returns what has arrived (0 at the end), a
//   write takes what fits, and waits only if nothing fits. A UDP conversation
//   whose ctl was sent "headers" reads and writes each datagram after a
//   52-byte header, as Plan 9's does: the remote, local and interface
//   addresses (16 bytes each, IPv4 mapped into IPv6), the remote port and
//   the local port; a write's header says where it goes.
//   /net/cs                 the connection server: write "tcp!HOST!SERVICE", then each read
//                           is a line "/net/tcp/clone ADDR!PORT", one for each address
//   /net/dns                write "NAME ip", then each read is a line "NAME ip ADDR"
//   Each open of cs or dns is a query of its own. A write is held while the
//   name is looked up (vx:net's DNS stub, the server DHCP named).
//
// A conversation lasts while any of its files is open. /net is served from
// the start, with or without a driver, since every namespace that mounts it
// connects when its program starts; netd dials the driver without waiting,
// and again if the driver goes. The address comes from DHCP.
//
// Everything below runs from p9ring's callbacks, which are contextless.
package netd

import "base:intrinsics"
import vx "abi:vx"
import "vx:driver"
import "vx:memory"
import "vx:net"
import "vx:p9"
import "vx:p9ring"
import "vx:ring"
import "vx:rt"
import "vx:str"

TEXT_MAX :: 256 // the most a file's text holds

// The most a query's answer holds: the longest is a DNS answer, DNS_ADDRS
// lines of "NAME ip A.B.C.D\n", a name of up to 253 bytes (upstream
// ab83fe6). An answer that does not fit fails the query rather than give
// part of a line (an address cut short can be another valid address).
ANSWER_MAX :: net.DNS_ADDRS * (253 + 4 + 15 + 1)

SECOND :: vx.Instant(1_000_000_000)

stack: net.Net
stack_up: bool // net.init done: the driver said its MAC address
server: p9ring.Server
// Each socket a POSIX program polls has a connection of its own (two, when
// it writes without waiting), besides its namespace's: more than the default.
NETD_CONNS :: 64
conns: [NETD_CONNS]p9ring.Server_Conn

// --- The driver ---

// What a packet on our own port bindings is about. Answer's key is fixed;
// the others carry the link's generation, so a packet about a session that
// has gone is never taken for one about the next.
Link_Event :: enum u64 {
	Answer,
	Bell,
	Gone,
}

link_key :: proc "contextless" (e: Link_Event, gen: u32) -> u64 {
	return p9ring.KEY_USER + u64(e) + u64(gen) << 8
}

// A request's user_data: what it is, and the slot it is about.
Tag_Kind :: enum u32 {
	None,
	Tx,
	Rx,
	Info,
}

Tag :: bit_field u64 {
	slot: u32      | 32,
	kind: Tag_Kind | 32,
}

tag :: proc "contextless" (kind: Tag_Kind, slot: u32) -> u64 {
	return transmute(u64)Tag{slot = slot, kind = kind}
}

Tx_Slots :: bit_set[0 ..< 64;u64]

Link :: struct {
	connector:           vx.Handle,
	asked, answer_armed: bool,
	retry_at:            vx.Instant, // when to ask again; vx.INFINITE while an ask is out or the link is up
	up, bell_armed:      bool,
	gen:                 u32,
	ring:                ring.Ring,
	end:                 vx.Handle,
	tx_free:             Tx_Slots, // the first 64 slots of our arena that are not in flight
}

link: Link

submit :: proc "contextless" (e: vx.Sqe) {
	e := e
	slot, ok := ring.produce_slot(&link.ring)
	if !ok {
		return // cannot happen: offers and sends together never outnumber the queue
	}
	copy(slot, memory.ptr_to_bytes(&e))
	if ring.produce(&link.ring) {
		_ = rt.ring_notify(link.end)
	}
}

// vx:net's way out: a frame into a free slot of our arena, and a Tx for it.
send_frame :: proc "contextless" (ctx: rawptr, frame: []u8) {
	if !link.up || len(link.ring.memory) == 0 || link.tx_free == {} || len(frame) > driver.NET_MAX_FRAME {
		stack.stats.dropped += 1 // no driver, or every slot is in flight: as a full NIC would
		return
	}
	slot := u32(intrinsics.count_trailing_zeros(transmute(u64)link.tx_free))
	link.tx_free -= {int(slot)}
	copy(ring.arena(&link.ring)[slot * driver.NET_SLOT:], frame)
	submit({opcode = u16(driver.Net_Op.Tx), flags = {.Dref}, user_data = tag(.Tx, slot), arena_off = slot * driver.NET_SLOT, len = u32(len(frame))})
}

ask_driver :: proc "contextless" () {
	link.asked = rt.session_ask(link.connector, driver.NET_CONNECT) == .Ok
	link.retry_at = link.asked ? vx.INFINITE : rt.clock_read() + SECOND
}

link_down :: proc "contextless" () {
	if link.up {
		rt.print("netd: the driver is gone; asking again\n")
	}
	_ = rt.handle_close(link.end)
	rt.session_unmap(&link.ring)
	link.up, link.bell_armed = false, false
	link.gen += 1
	link.retry_at = rt.clock_read() + SECOND
}

link_answer :: proc "contextless" () {
	end, st := rt.session_answer(link.connector, driver.NET_PARAMS, &link.ring)
	if st == .Err_Should_Wait {
		return
	}
	link.asked = false
	if st != .Ok { // refused, or a reply that made no sense: ask again in a second
		link.retry_at = rt.clock_read() + SECOND
		return
	}
	link.end = end
	link.up = true
	link.gen += 1
	link.tx_free = ~Tx_Slots{}
	_ = rt.port_bind(server.port, link.end, .Peer_Closed, link_key(.Gone, link.gen))
	submit({opcode = u16(driver.Net_Op.Info), user_data = tag(.Info, 0)})
	for s in u32(0) ..< driver.NET_SLOTS {
		submit({opcode = u16(driver.Net_Op.Rx), user_data = tag(.Rx, s), target = u64(s)})
	}
}

// Everything the driver has completed: frames into the stack, slots back.
// Whether there was anything.
link_drain :: proc "contextless" () -> (any: bool) {
	for link.up {
		c: vx.Cqe
		if ring.consume(&link.ring, memory.ptr_to_bytes(&c)) != .Ok {
			break
		}
		any = true
		t := transmute(Tag)c.user_data
		switch {
		case t.kind == .Tx && t.slot < 64:
			link.tx_free += {int(t.slot)}
		case t.kind == .Rx && t.slot < driver.NET_SLOTS:
			if c.result > 0 && stack_up {
				if frame, ok := ring.peer_bytes(&link.ring, c.aux2, u64(c.result)); ok {
					net.input(&stack, frame, rt.clock_read())
				}
			}
			submit({opcode = u16(driver.Net_Op.Rx), user_data = tag(.Rx, t.slot), target = u64(t.slot)}) // offered again
		case t.kind == .Info && c.result == 0 && !stack_up:
			mac: net.Mac
			for &b, i in mac {
				b = u8(c.aux2 >> (8 * uint(i)))
			}
			net.init(&stack, mac, c.aux, u32(rt.clock_read()) ~ u32(c.aux2), send_frame, nil)
			stack_up = true
			net.dhcp_start(&stack, rt.clock_read())
		}
	}
	if link.up && !link.ring.intact {
		link_down() // it broke the protocol
	}
	return
}

event :: proc "contextless" (ctx: rawptr, pk: ^vx.Packet) {
	switch {
	case pk.key == link_key(.Answer, 0):
		link.answer_armed = false
		if link.asked {
			link_answer()
		}
	case pk.key == link_key(.Gone, link.gen):
		if link.up {
			link_down()
		}
	case pk.key == link_key(.Bell, link.gen):
		link.bell_armed = false
	}
	// Frames are taken here, before the 9P connections are served again, so a
	// read waiting for a datagram sees what just came.
	if link.up {
		ring.end_sleep(&link.ring)
		_ = link_drain()
	}
}

last_addr: net.Ip4

tick :: proc "contextless" (ctx: rawptr) -> vx.Instant {
	now, next := rt.clock_read(), vx.INFINITE
	if !link.up && !link.asked && now >= link.retry_at {
		ask_driver()
	}
	if link.asked && !link.answer_armed {
		link.answer_armed = rt.port_bind(server.port, link.connector, .Readable, link_key(.Answer, 0)) == .Ok
	}
	if !link.up && !link.asked {
		next = link.retry_at
	}
	if link.up { // sleep only once the driver's queue is empty, and its doorbell armed
		// What is taken here came after the event pass: round again at once, so
		// a read held for a datagram is served again before we sleep.
		took := link_drain()
		seen, _ := rt.counter_read(link.end)
		if took || (link.up && !ring.prepare_sleep(&link.ring)) {
			next = now
		} else if link.up && !link.bell_armed {
			link.bell_armed = rt.port_bind(server.port, link.end, .Counter_Ge, link_key(.Bell, link.gen), seen + 1) == .Ok
		}
	}
	if stack_up {
		frames_in := stack.stats.frames_in
		next = min(next, net.poll(&stack, now))
		// Packets looped back were taken in just now, after the serving pass:
		// a held request they settled (a refused connect, say) is served once more.
		if stack.stats.frames_in != frames_in {
			next = now
		}
		if stack.addr != last_addr { // say what the address became
			last_addr = stack.addr
			text: [TEXT_MAX]u8
			t := str.Buf{buf = text[:]}
			str.write_string(&t, "netd: ")
			if stack.addr != 0 {
				net.write_ip(&t, stack.addr)
				str.write_byte(&t, '/')
				str.write_u64(&t, u64(intrinsics.count_ones(u32(stack.mask))))
				str.write_string(&t, stack.dhcp.state == .Off ? ", static" : " from dhcp")
				str.write_string(&t, ", gateway ")
				net.write_ip(&t, stack.gw)
			} else {
				str.write_string(&t, "no address")
			}
			str.write_byte(&t, '\n')
			rt.print(str.to_string(&t))
		}
	}
	return next
}

// --- /net ---
//
// A node is its kind in the low byte, then the protocol, the conversation
// and that conversation's generation, so a fid on a conversation that has
// been closed and made again never reaches the new one. The numbers are
// upstream's, since they are the qids' paths.

Kind :: enum u8 {
	None,
	Root,
	Ipifc, // /ipifc
	Ifc, // /ipifc/0
	Ifc_Ctl, // /ipifc/0/ctl
	Ifc_Status, // /ipifc/0/status
	Proto, // /icmp, /udp, /tcp
	Clone,
	Cs, // /cs
	Dns, // /dns
	Query, // an open of cs or dns: its Query_Kind in sub, the query and its generation
	Conv, // /PROTO/N, and its files:
	Ctl,
	Data,
	Local,
	Remote,
	Status,
	Listen, // TCP's only
}

Query_Kind :: enum u8 {
	None,
	Cs,
	Dns,
}

Net_Node :: bit_field u64 {
	kind:  Kind | 8,
	sub:   u8   | 8, // a conversation's net.Proto, or a query's Query_Kind
	index: u32  | 16, // the conversation, or the query
	gen:   u32  | 32,
}

as_node :: proc "contextless" (n: p9.Node) -> Net_Node {
	return transmute(Net_Node)u64(n)
}

as_p9 :: proc "contextless" (n: Net_Node) -> p9.Node {
	return p9.Node(transmute(u64)n)
}

proto_of :: proc "contextless" (n: Net_Node) -> net.Proto {
	return net.Proto(n.sub)
}

ROOT :: p9.Node(1) // Net_Node{kind = .Root}

File_Info :: struct {
	name: string,
	mode: u32,
}

@(rodata)
FILES := #partial [Kind]File_Info {
	.Ifc_Ctl    = {"ctl", 0o666},
	.Ifc_Status = {"status", 0o444},
	.Clone      = {"clone", 0o666},
	.Ctl        = {"ctl", 0o666},
	.Data       = {"data", 0o666},
	.Local      = {"local", 0o444},
	.Remote     = {"remote", 0o444},
	.Status     = {"status", 0o444},
	.Listen     = {"listen", 0o666},
	.Cs         = {"cs", 0o666},
	.Dns        = {"dns", 0o666},
	.Query      = {"cs", 0o666},
}

// Queries: each open of /cs or /dns, with its answer.
QUERIES :: 16

Query :: struct {
	used:   bool,
	gen:    u32,
	answer: [dynamic; ANSWER_MAX]u8, // lines, each read one at a time
}

queries: [QUERIES]Query

query_node :: proc "contextless" (which: Query_Kind, q: int) -> p9.Node {
	return as_p9({kind = .Query, sub = u8(which), index = u32(q), gen = queries[q].gen})
}

// The query a node is, if it is still the one the node was made for.
query_at :: proc "contextless" (n: Net_Node) -> ^Query {
	if n.index >= QUERIES {
		return nil
	}
	q := &queries[n.index]
	return q if q.used && q.gen == n.gen else nil
}

// What netd keeps beside each of vx:net's conversations.
Conv_Info :: struct {
	gen:     u32, // bumped each time the conversation is made
	refs:    u32, // open fids on its files
	headers: bool, // UDP: datagrams read and written with Plan 9's header
}

convs: [net.CONVS]Conv_Info

node :: proc "contextless" (kind: Kind, proto: net.Proto = .None, conv: u32 = 0) -> p9.Node {
	gen := kind >= .Conv ? convs[conv % net.CONVS].gen : 0 // only a conversation's nodes go stale
	return as_p9({kind = kind, sub = u8(proto), index = conv, gen = gen})
}

// The node with another kind, in the same conversation.
with_kind :: proc "contextless" (n: Net_Node, k: Kind) -> p9.Node {
	m := n
	m.kind = k
	return as_p9(m)
}

// The conversation a node is in, if it is still the one the node was made for.
conv_at :: proc "contextless" (n: Net_Node) -> ^net.Conv {
	if !stack_up {
		return nil
	}
	c, ok := net.conv_get(&stack, net.Conv_Id(n.index))
	return c if ok && c.proto == proto_of(n) && convs[n.index].gen == n.gen else nil
}

// A conversation directory's last file: TCP's has listen too.
last_file :: proc "contextless" (dir: Net_Node) -> Kind {
	return proto_of(dir) == .Tcp ? .Listen : .Status
}

fs_attach :: proc "contextless" (ctx: rawptr, aname: string) -> (root: p9.Node, st: vx.Status) {
	if len(aname) != 0 {
		return 0, .Err_Not_Found
	}
	return ROOT, .Ok
}

fs_walk :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string) -> (child: p9.Node, st: vx.Status) {
	d := as_node(dir)
	#partial switch d.kind {
	case .Root:
		switch name {
		case "ipifc":
			return node(.Ipifc), .Ok
		case "icmp":
			return node(.Proto, .Icmp), .Ok
		case "udp":
			return node(.Proto, .Udp), .Ok
		case "tcp":
			return node(.Proto, .Tcp), .Ok
		case "cs":
			return node(.Cs), .Ok
		case "dns":
			return node(.Dns), .Ok
		}
	case .Ipifc:
		if name == "0" {
			return node(.Ifc), .Ok
		}
	case .Ifc:
		switch name {
		case "ctl":
			return node(.Ifc_Ctl), .Ok
		case "status":
			return node(.Ifc_Status), .Ok
		}
	case .Proto:
		if name == "clone" {
			return node(.Clone, proto_of(d)), .Ok
		}
		// A conversation's number, in decimal, without leading zeros.
		if len(name) > 2 || (len(name) > 1 && name[0] == '0') {
			return 0, .Err_Not_Found
		}
		id, ok := str.parse_u64(name)
		if !ok || id >= net.CONVS {
			return 0, .Err_Not_Found
		}
		child = node(.Conv, proto_of(d), u32(id))
		return child, conv_at(as_node(child)) != nil ? .Ok : .Err_Not_Found
	case .Conv:
		if conv_at(d) == nil {
			return 0, .Err_Not_Found
		}
		for k := Kind.Ctl; k <= last_file(d); k = Kind(u8(k) + 1) {
			if FILES[k].name == name {
				return with_kind(d, k), .Ok
			}
		}
	}
	return 0, .Err_Not_Found
}

fs_parent :: proc "contextless" (ctx: rawptr, n: p9.Node) -> (parent: p9.Node, st: vx.Status) {
	m := as_node(n)
	#partial switch m.kind {
	case .Ipifc, .Proto, .Cs, .Dns, .Query:
		return ROOT, .Ok
	case .Ifc:
		return node(.Ipifc), .Ok
	case .Ifc_Ctl, .Ifc_Status:
		return node(.Ifc), .Ok
	case .Clone, .Conv:
		return node(.Proto, proto_of(m)), .Ok
	}
	return with_kind(m, .Conv), .Ok
}

@(private="file")
number_buf: [str.U64_DIGITS]u8 // a conversation directory's name, while its stat is used

fs_stat :: proc "contextless" (ctx: rawptr, n: p9.Node, out: ^p9.Stat) -> vx.Status {
	m := as_node(n)
	k := m.kind
	dir := k == .Root || k == .Ipifc || k == .Ifc || k == .Proto || k == .Conv
	if k >= .Conv && conv_at(m) == nil {
		return .Err_Not_Found // closed since
	}
	name := "/"
	#partial switch k {
	case .Ipifc:
		name = "ipifc"
	case .Ifc:
		name = "0"
	case .Proto:
		#partial switch proto_of(m) {
		case .Icmp:
			name = "icmp"
		case .Udp:
			name = "udp"
		case .Tcp:
			name = "tcp"
		}
	case .Conv:
		name = str.format_u64(number_buf[:], u64(m.index))
	case .Query:
		if query_at(m) == nil {
			return .Err_Not_Found
		}
		name = Query_Kind(m.sub) == .Dns ? "dns" : "cs"
	case:
		if !dir {
			name = FILES[k].name
		}
	}
	out^ = {
		qid = {type = dir ? p9.QTDIR : p9.QTFILE, path = u64(n)},
		mode = dir ? p9.DMDIR | 0o555 : FILES[k].mode,
		name = name,
		uid = "net",
		gid = "net",
		muid = "net",
	}
	return .Ok
}

fs_readdir :: proc "contextless" (ctx: rawptr, dir: p9.Node, index: u32) -> (child: p9.Node, st: vx.Status) {
	ROOT_NAMES :: [?]string{"ipifc", "icmp", "udp", "tcp", "cs", "dns"}
	d := as_node(dir)
	#partial switch d.kind {
	case .Root:
		names := ROOT_NAMES
		if index < len(names) {
			return fs_walk(ctx, dir, names[index])
		}
	case .Ipifc:
		if index == 0 {
			return node(.Ifc), .Ok
		}
	case .Ifc:
		if index < 2 {
			return node(index != 0 ? .Ifc_Status : .Ifc_Ctl), .Ok
		}
	case .Proto:
		if index == 0 {
			return node(.Clone, proto_of(d)), .Ok
		}
		left := index // the clone file is entry 0, then the conversations in order
		for &c, id in stack.conv {
			if stack_up && c.proto == proto_of(d) {
				left -= 1
				if left == 0 {
					return node(.Conv, proto_of(d), u32(id)), .Ok
				}
			}
		}
	case .Conv:
		if conv_at(d) != nil && index <= u32(last_file(d)) - u32(Kind.Ctl) {
			return with_kind(d, Kind(u32(Kind.Ctl) + index)), .Ok
		}
	}
	return 0, .Err_Not_Found
}

fs_open :: proc "contextless" (ctx: rawptr, n: p9.Node, mode: p9.Open_Mode) -> vx.Status {
	m := as_node(n)
	k := m.kind
	if mode.rclose {
		return .Err_Access
	}
	if p9.writes(mode) && FILES[k].mode & 0o222 == 0 {
		return .Err_Access
	}
	if k == .Clone && !stack_up {
		return .Err_Bad_State // no driver yet
	}
	if k == .Query && query_at(m) == nil {
		return .Err_Not_Found
	}
	if k > .Conv && conv_at(m) == nil {
		return .Err_Not_Found
	}
	if k == .Listen { // the fid moves to a new connection (fs_clone); this open may be made again
		return conv_at(m).tcb.state == .Listen ? .Ok : .Err_Bad_State
	}
	if k > .Conv {
		convs[m.index].refs += 1
	}
	return .Ok
}

// Opening a clone file makes a conversation, and opening a listen file
// takes a connection the listener made (waiting for one); either way the fid
// becomes that conversation's ctl. Opening cs or dns makes a query of its own.
fs_clone :: proc "contextless" (ctx: rawptr, n: p9.Node, mode: p9.Open_Mode) -> (opened: p9.Node, st: vx.Status) {
	m := as_node(n)
	#partial switch m.kind {
	case .Cs, .Dns:
		for &q, i in queries {
			if q.used {
				continue
			}
			q.used = true
			q.gen += 1
			clear(&q.answer)
			return query_node(m.kind == .Cs ? .Cs : .Dns, i), .Ok
		}
		return 0, .Err_No_Memory
	case .Clone, .Listen:
		id: net.Conv_Id
		if m.kind == .Clone {
			id = net.conv_new(&stack, proto_of(m)) or_return
		} else {
			id = net.tcp_accept(&stack, conv_at(m)) or_return
		}
		convs[id] = {gen = convs[id].gen + 1, refs = 1}
		return node(.Ctl, proto_of(m), u32(id)), .Ok
	}
	return 0, .Err_Not_Found
}

// A conversation lasts while any of its files is open.
fs_clunk :: proc "contextless" (ctx: rawptr, n: p9.Node, opened: bool) {
	m := as_node(n)
	if !opened {
		return
	}
	if m.kind == .Query {
		if q := query_at(m); q != nil {
			q.used = false
		}
		return
	}
	if m.kind <= .Conv || conv_at(m) == nil {
		return
	}
	info := &convs[m.index]
	if info.refs == 0 {
		return
	}
	info.refs -= 1
	if info.refs != 0 {
		return
	}
	info.gen += 1 // fids that outlive it see it gone, even while TCP finishes closing it
	net.conv_free(&stack, net.Conv_Id(m.index), rt.clock_read())
}

ifc_status :: proc "contextless" (t: ^str.Buf) {
	str.write_string(t, "dev=")
	str.write_string(t, link.up ? "ether0" : "none")
	str.write_string(t, " addr=")
	if stack_up && stack.addr != 0 {
		net.write_ip(t, stack.addr)
		str.write_byte(t, '/')
		str.write_u64(t, u64(intrinsics.count_ones(u32(stack.mask))))
		str.write_string(t, " gw=")
		net.write_ip(t, stack.gw)
	} else {
		str.write_string(t, "none")
	}
	if stack_up && stack.dhcp.state != .Off {
		str.write_string(t, " dhcp")
		if stack.addr != 0 {
			str.write_string(t, " lease=")
			str.write_u64(t, u64(stack.dhcp.lease))
			str.write_byte(t, 's')
		}
	} else if stack_up {
		str.write_string(t, " static")
	}
	str.write_byte(t, '\n')
}

addr_port :: proc "contextless" (t: ^str.Buf, addr: net.Ip4, port: net.Port) {
	net.write_ip(t, addr)
	str.write_byte(t, '!')
	str.write_u64(t, u64(port))
	str.write_byte(t, '\n')
}

// --- Queries: /cs and /dns ---

Service :: struct {
	name: string,
	port: net.Port,
}

@(rodata)
SERVICES := [?]Service{{"echo", 7}, {"ssh", 22}, {"domain", 53}, {"http", 80}, {"https", 443}, {"9fs", 564}}

// A service, by number or by name; 0 if neither.
service_port :: proc "contextless" (s: string) -> net.Port {
	if len(s) <= 5 {
		if v, ok := str.parse_u64(s); ok {
			return v <= 65535 ? net.Port(v) : 0
		}
	}
	for svc in SERVICES {
		if svc.name == s {
			return svc.port
		}
	}
	return 0
}

// More than an answer can hold, so a cut is seen.
ANSWER_SCRATCH :: 2048

// Keeps what fits of an answer; Err_Range if that is not all of it, which
// fails the query (the bytes that fit are kept, as upstream's are).
keep_answer :: proc "contextless" (q: ^Query, t: ^str.Buf) -> vx.Status {
	clear(&q.answer)
	whole := str.to_bytes(t)
	n := append(&q.answer, ..whole)
	return t.failed || n < len(whole) ? .Err_Range : .Ok
}

// "NET!HOST!SERVICE" into the clone files and addresses to dial (or, with
// HOST "*", to announce): a line for each address.
cs_query :: proc "contextless" (q: ^Query, query: string, now: vx.Instant) -> vx.Status {
	rest := query
	network, _ := str.split_iterator(&rest, '!')
	host, _ := str.split_iterator(&rest, '!')
	service := rest
	proto: string
	switch network {
	case "tcp", "net":
		proto = "tcp"
	case "udp":
		proto = "udp"
	case "icmp":
		proto = "icmp"
	case:
		return .Err_Invalid
	}
	ports := proto != "icmp"
	port := ports ? service_port(service) : 0
	if len(host) == 0 || (ports && port == 0) || (!ports && len(service) != 0) {
		return .Err_Invalid
	}
	addrs: [net.DNS_ADDRS]net.Ip4
	count := 1
	any := host == "*"
	if !any {
		count = net.resolve(&stack, host, addrs[:], now) or_return
	}
	scratch: [ANSWER_SCRATCH]u8
	t := str.Buf{buf = scratch[:]}
	for addr in addrs[:count] {
		str.write_string(&t, "/net/")
		str.write_string(&t, proto)
		str.write_string(&t, "/clone ")
		if any {
			str.write_byte(&t, '*')
		} else {
			net.write_ip(&t, addr)
		}
		if ports {
			str.write_byte(&t, '!')
			str.write_u64(&t, u64(port))
		}
		str.write_byte(&t, '\n')
	}
	return keep_answer(q, &t)
}

// "NAME ip" (or "NAME"): a line "NAME ip ADDR" for each address.
dns_query :: proc "contextless" (q: ^Query, w: []string, now: vx.Instant) -> vx.Status {
	if len(w) < 1 || len(w) > 2 || (len(w) == 2 && w[1] != "ip") {
		return .Err_Invalid // only A records so far
	}
	addrs: [net.DNS_ADDRS]net.Ip4
	count := net.resolve(&stack, w[0], addrs[:], now) or_return
	scratch: [ANSWER_SCRATCH]u8
	t := str.Buf{buf = scratch[:]}
	for addr in addrs[:count] {
		str.write_string(&t, w[0])
		str.write_string(&t, " ip ")
		net.write_ip(&t, addr)
		str.write_byte(&t, '\n')
	}
	return keep_answer(q, &t)
}

// A query's answer, a line a read: the line that starts at offset.
query_read :: proc "contextless" (answer: []u8, offset: u64, buf: []u8) -> u32 {
	if offset >= u64(len(answer)) {
		return 0
	}
	line := answer[offset:]
	if nl := str.index_byte(string(line), '\n'); nl >= 0 {
		line = line[:nl + 1]
	}
	return u32(copy(buf, line))
}

// Plan 9's UDP header: remote, local and interface addresses, each IPv6
// (IPv4 mapped: ten zero bytes, two 0xff, the four), then the ports.
UDP_HEADER :: 52

Mapped :: struct #packed {
	zero: [10]u8,
	ones: [2]u8,
	addr: u32be,
}
#assert(size_of(Mapped) == 16)

Udp_Header :: struct #packed {
	remote, local, ifc: Mapped,
	rport, lport:       u16be,
}
#assert(size_of(Udp_Header) == UDP_HEADER)

mapped :: proc "contextless" (addr: net.Ip4) -> Mapped {
	return {ones = {0xff, 0xff}, addr = u32be(addr)}
}

fs_read :: proc "contextless" (ctx: rawptr, n: p9.Node, offset: u64, buf: []u8) -> (count: u32, st: vx.Status) {
	m := as_node(n)
	k := m.kind
	c: ^net.Conv
	if k > .Conv {
		if c = conv_at(m); c == nil {
			return 0, .Err_Not_Found
		}
	}
	#partial switch k {
	case .Data:
		if c.proto == .Tcp { // what has arrived, or wait for some
			got, tst := net.tcp_read(&stack, c, buf, rt.clock_read())
			return u32(got), tst
		}
		// A datagram, or wait for one; after its header, if asked for.
		headers := convs[m.index].headers
		skip := headers ? UDP_HEADER : 0
		if len(buf) < skip {
			return 0, .Err_Too_Small
		}
		d, got, ok := net.conv_read(c, buf[skip:])
		if !ok {
			return 0, .Err_Should_Wait
		}
		if headers {
			h := Udp_Header {
				remote = mapped(d.addr),
				local  = mapped(stack.addr),
				ifc    = mapped(stack.addr),
				rport  = u16be(d.port),
				lport  = u16be(c.lport),
			}
			copy(buf, memory.ptr_to_bytes(&h))
		}
		return u32(skip + got), .Ok
	case .Query:
		q := query_at(m)
		if q == nil {
			return 0, .Err_Not_Found
		}
		return query_read(q.answer[:], offset, buf), .Ok
	}
	text: [TEXT_MAX]u8
	t := str.Buf{buf = text[:]}
	#partial switch k {
	case .Ifc_Status:
		ifc_status(&t)
	case .Ctl:
		str.write_u64(&t, u64(m.index))
	case .Local:
		addr_port(&t, c.raddr >> 24 == 127 ? c.raddr : stack.addr, c.lport) // loopback's own
	case .Remote:
		addr_port(&t, c.raddr, c.rport)
	case .Status:
		switch {
		case c.proto == .Tcp:
			str.write_string(&t, net.tcp_state_name(c.tcb.state))
			str.write_byte(&t, '\n')
		case c.raddr != 0:
			str.write_string(&t, "Open\n")
		case:
			str.write_string(&t, c.lport != 0 ? "Announced\n" : "Closed\n")
		}
	}
	whole := str.to_bytes(&t)
	if offset >= u64(len(whole)) {
		return 0, .Ok
	}
	return u32(copy(buf, whole[offset:])), .Ok
}

// "ADDR" or "ADDR!PORT" into its parts; port 0 if none. Not ok if malformed.
parse_addr_port :: proc "contextless" (s: string) -> (addr: net.Ip4, port: net.Port, ok: bool) {
	bang := str.index_byte(s, '!')
	if bang < 0 {
		addr, ok = net.parse_ip(s)
		return
	}
	addr = net.parse_ip(s[:bang]) or_return
	p := str.parse_u64(s[bang + 1:]) or_return // "ADDR!" with no port is malformed too
	if p > 65535 {
		return
	}
	return addr, net.Port(p), true
}

Words :: [dynamic; 4]string

// Splits a control message into words (at most 4), dropping a final newline.
words :: proc "contextless" (data: []u8) -> (w: Words) {
	rest := string(data)
	if len(rest) > 0 && rest[len(rest) - 1] == '\n' {
		rest = rest[:len(rest) - 1]
	}
	for word in str.split_iterator(&rest, ' ') {
		if len(word) == 0 {
			continue
		}
		if append(&w, word) == 0 {
			break
		}
	}
	return
}

ifc_ctl :: proc "contextless" (w: []string) -> vx.Status {
	if !stack_up {
		return .Err_Bad_State
	}
	if len(w) == 1 && w[0] == "dhcp" {
		net.dhcp_start(&stack, rt.clock_read())
		return .Ok
	}
	if (len(w) != 2 && len(w) != 3) || w[0] != "add" {
		return .Err_Invalid
	}
	slash := str.index_byte(w[1], '/')
	if slash < 0 || len(w[1]) - slash > 3 {
		return .Err_Invalid
	}
	addr, ok := net.parse_ip(w[1][:slash])
	bits, bok := str.parse_u64(w[1][slash + 1:])
	if !ok || !bok || bits < 1 || bits > 32 {
		return .Err_Invalid
	}
	gw: net.Ip4
	if len(w) == 3 {
		gok: bool
		if gw, gok = net.parse_ip(w[2]); !gok {
			return .Err_Invalid
		}
	}
	net.set_addr(&stack, addr, bits == 32 ? 0xffff_ffff : ~(net.Ip4(0xffff_ffff) >> bits), gw)
	return .Ok
}

// A TCP connect is held until the connection is made or fails: the same
// write is made again after every event, and finds the connection under way.
tcp_connect :: proc "contextless" (c: ^net.Conv, addr: net.Ip4, port: net.Port) -> vx.Status {
	if c.raddr == 0 {
		st := net.tcp_connect(&stack, c, addr, port, rt.clock_read())
		return st == .Ok ? .Err_Should_Wait : st
	}
	if c.raddr != addr || c.rport != port {
		return .Err_Bad_State // connected elsewhere already
	}
	#partial switch c.tcb.state {
	case .Syn_Sent, .Syn_Rcvd:
		return .Err_Should_Wait
	case .Closed:
		return c.tcb.error != .Ok ? c.tcb.error : .Err_Peer_Closed
	}
	return .Ok
}

conv_ctl :: proc "contextless" (c: ^net.Conv, id: u32, w: []string) -> vx.Status {
	if len(w) == 1 && w[0] == "hangup" {
		if c.proto == .Tcp {
			net.tcp_close(&stack, c, rt.clock_read())
		}
		return .Ok
	}
	if len(w) == 1 && w[0] == "headers" && c.proto == .Udp {
		convs[id].headers = true
		return .Ok
	}
	if len(w) == 2 && w[0] == "connect" {
		addr, port, ok := parse_addr_port(w[1])
		if c.proto == .Tcp {
			if !ok || port == 0 {
				return .Err_Invalid
			}
			return tcp_connect(c, addr, port)
		}
		if !ok {
			return .Err_Invalid
		}
		return net.conv_connect(&stack, c, addr, port)
	}
	if len(w) == 2 && w[0] == "announce" {
		p := w[1]
		if len(p) > 2 && str.has_prefix(p, "*!") {
			p = p[2:]
		}
		if len(p) > 5 {
			return .Err_Invalid
		}
		v, ok := str.parse_u64(p)
		if !ok || v > 65535 {
			return .Err_Invalid
		}
		if c.proto == .Tcp {
			return net.tcp_listen(&stack, c, net.Port(v))
		}
		return net.conv_announce(&stack, c, net.Port(v))
	}
	return .Err_Invalid
}

fs_write :: proc "contextless" (ctx: rawptr, n: p9.Node, offset: u64, data: []u8) -> (count: u32, st: vx.Status) {
	m := as_node(n)
	k := m.kind
	c: ^net.Conv
	if k > .Conv {
		if c = conv_at(m); c == nil {
			return 0, .Err_Not_Found
		}
	}
	#partial switch k {
	case .Data:
		if c.proto == .Tcp { // what fits; wait only if nothing does
			taken, tst := net.tcp_write(&stack, c, data, rt.clock_read())
			return u32(taken), tst
		}
		if convs[m.index].headers { // the header says where it goes
			if len(data) < UDP_HEADER {
				return 0, .Err_Invalid
			}
			h := intrinsics.unaligned_load((^Udp_Header)(raw_data(data[:UDP_HEADER])))
			if h.remote.zero != {} || h.remote.ones != {0xff, 0xff} {
				return 0, .Err_Invalid
			}
			net.conv_write(&stack, c, net.Ip4(h.remote.addr), net.Port(h.rport), data[UDP_HEADER:], rt.clock_read()) or_return
			return u32(len(data)), .Ok
		}
		// One datagram, all of it or none.
		net.conv_write(&stack, c, 0, 0, data, rt.clock_read()) or_return
		return u32(len(data)), .Ok
	case .Query: // held while the name is looked up
		q := query_at(m)
		if q == nil {
			return 0, .Err_Not_Found
		}
		if !stack_up {
			return 0, .Err_Bad_State
		}
		if Query_Kind(m.sub) == .Cs {
			text := string(data)
			if len(text) > 0 && text[len(text) - 1] == '\n' {
				text = text[:len(text) - 1]
			}
			return u32(len(data)), cs_query(q, text, rt.clock_read())
		}
		w := words(data)
		return u32(len(data)), dns_query(q, w[:], rt.clock_read())
	case .Ifc_Ctl:
		w := words(data)
		return u32(len(data)), ifc_ctl(w[:])
	case .Ctl:
		w := words(data)
		return u32(len(data)), conv_ctl(c, m.index, w[:])
	}
	return 0, .Err_Access
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	link.connector = rt.spawn_take("srv:ether0")
	server.listen = rt.spawn_take("listen")
	pst := vx.Status.Err_Bad_Handle
	if link.connector != vx.HANDLE_NONE && server.listen != vx.HANDLE_NONE {
		server.port, pst = rt.port_create()
	}
	if pst != .Ok {
		rt.print("netd: FAILED: no connector to /srv/ether0, or no listen channel\n")
		rt.exits("no connector to /srv/ether0, or no listen channel")
	}
	server.fs = {
		attach  = fs_attach,
		walk    = fs_walk,
		parent  = fs_parent,
		stat    = fs_stat,
		open    = fs_open,
		clone   = fs_clone,
		read    = fs_read,
		readdir = fs_readdir,
		write   = fs_write,
		clunk   = fs_clunk,
	}
	server.name = "netd"
	server.conns = conns[:]
	server.event = event
	server.tick = tick
	rt.print("netd: serving /srv/net\n")
	rt.exits(p9ring.serve(&server) == .Ok ? "" : "cannot serve")
}
