// drv-virtio-net: the virtio network card, serving the net class protocol
// (lib/driver's netproto.odin) on /srv/ether0.
//
// devmgr starts it with only its device: the function's configuration space,
// its memory BARs, a DMA domain, two MSI-X interrupts (receive, transmit) and
// the post's listen end. It serves one client at a time (netd).
//
// Receiving: the device always holds every receive buffer. A frame it fills
// goes to the client's oldest offered slot, or is dropped if there is none,
// and the buffer goes straight back to the device. Sending: a frame is copied
// from the client's arena into a free transmit buffer; with none free, the
// driver takes nothing more from the client until the device returns one.
//
// One thread, one port: the two interrupts, the listen channel, and the
// client's doorbell and going away.
package virtionet

import vx "abi:vx"
import "vx:driver"
import "vx:memory"
import "vx:ndb"
import "vx:pci"
import "vx:ring"
import "vx:rt"

QSIZE :: 64 // buffers in each virtqueue
BUF :: 2048 // two to a page, so none crosses one
NET_HDR :: 12 // struct virtio_net_hdr, with VERSION_1
VIRTIO_NET_F_MAC :: u64(1) << 5
MTU :: 1500

// Port keys. A client's carry its session number above bit 8, so a packet
// about a client that has gone is never taken for the next one's.
Key :: enum u64 {
	Rx = 1,
	Tx,
	Listen,
	Bell,
	Closed,
}

session: u64 // the current client's number

client_key :: proc "contextless" (k: Key) -> u64 {
	return session << 8 | u64(k)
}

dev: driver.Virtio
rxq, txq: driver.Virtq
rx_buf, tx_buf: []u8 // QSIZE buffers each, mapped here
rx_pages, tx_pages: [QSIZE / 2]u64 // their device addresses, a page each
tx_busy: [QSIZE]bool
mac: [6]u8
irq_rx, irq_tx, port, listen: vx.Handle

Offer :: struct {
	slot:      u32,
	user_data: u64,
}

Client :: struct {
	on:      bool,
	ring:    ring.Ring,
	end:     vx.Handle,
	armed:   bool,
	holding: bool, // a Tx that found no free buffer: taken again once one is free
	held:    vx.Sqe,
	offers:  [driver.NET_SLOTS]Offer, // Rx slots offered, oldest first
	offer_head, offer_count: u32,
}

client: Client

fail :: proc "contextless" (what: string) -> ! {
	rt.print("drv-virtio-net: FAILED: ", what, "\n")
	rt.thread_exit(1)
}

buf_addr :: proc "contextless" (pages: []u64, i: u16) -> u64 {
	return pages[i / 2] + u64(i % 2) * BUF
}

// A VMO of QSIZE buffers, mapped here and given to the device.
make_buffers :: proc "contextless" (pages: []u64) -> []u8 {
	SIZE :: QSIZE * BUF
	vmo, st := rt.vmo_create(SIZE)
	at: u64
	if st == .Ok {
		at, st = rt.as_map(rt.self, vmo, 0, SIZE, {.Write})
	}
	if st == .Ok {
		st = rt.dma_map(dev.dma, vmo, 0, SIZE, pages)
	}
	rt.close_all(vmo) // the mapping and the domain keep it
	if st != .Ok {
		fail("no memory for buffers")
	}
	return (cast([^]u8)uintptr(at))[:SIZE]
}

// Maps the handle the spawn message calls `name` (`size` bytes), or returns nil.
map_handle :: proc "contextless" (name: string, size: u64) -> []u8 {
	h := rt.spawn_take(name)
	if h == vx.HANDLE_NONE {
		return nil
	}
	defer rt.close_all(h) // the mapping keeps it
	at, st := rt.as_map(rt.self, h, 0, size, {.Write})
	return st == .Ok ? (cast([^]u8)uintptr(at))[:size] : nil
}

setup_device :: proc "contextless" () {
	cfg := map_handle("config", pci.CONFIG_SIZE)
	dev.dma = rt.spawn_take("dma")
	if cfg == nil || dev.dma == vx.HANDLE_NONE {
		fail("no configuration space or DMA domain")
	}
	dev.fn.cfg = cast(^[pci.CONFIG_SIZE / 4]u32)raw_data(cfg)
	// The BARs devmgr mapped for it: records `bar=N size=S`; and its MSIs.
	@(static) scratch: [vx.CHANNEL_MAX_BYTES]u8
	r := ndb.Reader{src = rt.spawn.text, scratch = scratch[:]}
	rec: ndb.Record
	msi: [2]vx.Msi
	for ndb.next(&r, &rec) == .Record {
		if n, ok := ndb.get_u64(&rec, "bar"); ok && n < 6 {
			if size, sok := ndb.get_u64(&rec, "size"); sok {
				name := [4]u8{'b', 'a', 'r', u8('0' + n)}
				dev.bar[n] = map_handle(string(name[:]), size)
			}
		} else if m, mok := ndb.get_u64(&rec, "msi"); mok && m < 2 {
			if address, aok := ndb.get_u64(&rec, "address"); aok {
				data, _ := ndb.get_u64(&rec, "data")
				msi[m] = {address = address, data = u32(data)}
			}
		}
	}
	irq_rx = rt.spawn_take("msi0")
	irq_tx = rt.spawn_take("msi1")
	if irq_rx == vx.HANDLE_NONE || irq_tx == vx.HANDLE_NONE || msi[0].address == 0 || msi[1].address == 0 {
		fail("no MSIs")
	}
	if driver.virtio_find(&dev) != .Ok || len(dev.msix) < 2 {
		fail("not a modern virtio device with MSI-X")
	}
	features, st := driver.virtio_start(&dev, VIRTIO_NET_F_MAC)
	if st != .Ok {
		fail("feature negotiation")
	}
	driver.virtio_msix(&dev, 0, msi[0])
	driver.virtio_msix(&dev, 1, msi[1])
	if driver.virtq_init(&dev, &rxq, 0, QSIZE, 0) != .Ok || driver.virtq_init(&dev, &txq, 1, QSIZE, 1) != .Ok {
		fail("the queues")
	}
	if features & VIRTIO_NET_F_MAC != 0 {
		copy(mac[:], dev.device[:6])
	} else {
		mac = {2, 0, 0, 0, 0, 1} // a locally administered address
	}
	rx_buf = make_buffers(rx_pages[:])
	tx_buf = make_buffers(tx_pages[:])
	for i in u16(0) ..< QSIZE {
		driver.virtq_offer(&rxq, i, buf_addr(rx_pages[:], i), BUF, true)
	}
	driver.virtio_ready(&dev)
	driver.virtq_kick(&rxq)
}

// --- The client ---

drop_client :: proc "contextless" () {
	rt.close_all(client.end)
	client = {}
}

// Completes a request. False if the client does not drain its completions.
complete :: proc "contextless" (c: vx.Cqe) -> bool {
	c := c
	slot, ok := ring.produce_slot(&client.ring)
	if !ok {
		return false
	}
	copy(slot, memory.ptr_to_bytes(&c))
	if ring.produce(&client.ring) {
		_ = rt.ring_notify(client.end)
	}
	return true
}

// Sends one frame from the client's arena. False if no transmit buffer is
// free; otherwise the result to complete with.
transmit :: proc "contextless" (e: ^vx.Sqe) -> (result: i64, sent: bool) {
	frame: []u8
	if .Dref in e.flags && e.len >= 14 && e.len <= driver.NET_MAX_FRAME {
		frame, _ = ring.peer_bytes(&client.ring, u64(e.arena_off), u64(e.len))
	}
	if frame == nil {
		return i64(vx.Status.Err_Invalid), true
	}
	d := u16(0)
	for d < QSIZE && tx_busy[d] {
		d += 1
	}
	if d == QSIZE {
		return 0, false
	}
	b := tx_buf[int(d) * BUF:][:BUF]
	for &h in b[:NET_HDR] {
		h = 0 // no offloads
	}
	copy(b[NET_HDR:], frame) // copied once, then the device reads our copy
	tx_busy[d] = true
	driver.virtq_offer(&txq, d, buf_addr(tx_pages[:], d), NET_HDR + e.len, false)
	driver.virtq_kick(&txq)
	return i64(e.len), true
}

// Serves what the client has submitted. False if it broke the protocol.
serve_client :: proc "contextless" () -> bool {
	for client.on {
		e: vx.Sqe
		if client.holding {
			e = client.held
		} else {
			st := ring.consume(&client.ring, memory.ptr_to_bytes(&e))
			if st == .Err_Should_Wait {
				return true
			}
			if st != .Ok {
				return false
			}
		}
		c := vx.Cqe{user_data = e.user_data}
		switch driver.Net_Op(e.opcode) {
		case .Info:
			for b, i in mac {
				c.aux2 |= u64(b) << (8 * uint(i))
			}
			c.aux = MTU
		case .Tx:
			sent: bool
			c.result, sent = transmit(&e)
			client.holding = !sent
			if client.holding {
				client.held = e
				return true // until the device gives a buffer back
			}
		case .Rx:
			if e.target < driver.NET_SLOTS && client.offer_count < driver.NET_SLOTS {
				at := (client.offer_head + client.offer_count) % driver.NET_SLOTS
				client.offer_count += 1
				client.offers[at] = {slot = u32(e.target), user_data = e.user_data}
				continue // completed when a frame comes
			}
			c.result = i64(vx.Status.Err_Invalid)
		case:
			c.result = i64(vx.Status.Err_Invalid)
		}
		if !complete(c) {
			return false
		}
	}
	return true
}

// Frames the device has received: each to the oldest offered slot, or dropped.
service_rx :: proc "contextless" () {
	any := false
	for {
		d, length, ok := driver.virtq_used(&rxq)
		if !ok {
			break
		}
		any = true
		if length > NET_HDR && length <= BUF && client.on && client.offer_count > 0 {
			flen := length - NET_HDR
			offer := client.offers[client.offer_head]
			client.offer_head = (client.offer_head + 1) % driver.NET_SLOTS
			client.offer_count -= 1
			at := int(offer.slot) * driver.NET_SLOT
			copy(ring.arena(&client.ring)[at:][:flen], rx_buf[int(d) * BUF + NET_HDR:][:flen])
			if !complete({user_data = offer.user_data, result = i64(flen), aux2 = u64(at)}) {
				drop_client()
			}
		}
		driver.virtq_offer(&rxq, d, buf_addr(rx_pages[:], d), BUF, true) // straight back to the device
	}
	if any {
		driver.virtq_kick(&rxq)
	}
}

service_tx :: proc "contextless" () {
	for {
		d, _, ok := driver.virtq_used(&txq)
		if !ok {
			return
		}
		tx_busy[d] = false
	}
}

accept_client :: proc "contextless" () {
	for {
		req: vx.Msg_Header
		size, st := rt.channel_read(listen, memory.ptr_to_bytes(&req))
		if st == .Err_Should_Wait {
			return
		}
		if st == .Err_Peer_Closed {
			fail("the listen channel is gone")
		}
		if st != .Ok || size.bytes != size_of(req) || req.ordinal != driver.NET_CONNECT {
			continue
		}
		if client.on { // one client at a time: refuse
			no := vx.Msg_Header{txid = req.txid, ordinal = req.ordinal, flags = rt.SESSION_REFUSED}
			_ = rt.channel_write(listen, memory.ptr_to_bytes(&no))
			continue
		}
		end, ast := rt.session_accept(listen, req, driver.NET_PARAMS, &client.ring)
		if ast != .Ok {
			continue
		}
		client.end = end
		client.on = true
		session += 1
		_ = rt.port_bind(port, client.end, .Peer_Closed, client_key(.Closed))
	}
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	listen = rt.spawn_take("listen")
	if listen == vx.HANDLE_NONE {
		fail("no listen channel")
	}
	setup_device()
	pst: vx.Status
	if port, pst = rt.port_create(); pst != .Ok {
		fail("port_create")
	}
	_ = rt.port_bind(port, irq_rx, .Irq, u64(Key.Rx))
	_ = rt.port_bind(port, irq_tx, .Irq, u64(Key.Tx))
	DIGITS := "0123456789abcdef"
	text: [17]u8
	for b, i in mac {
		text[3 * i], text[3 * i + 1] = DIGITS[b >> 4], DIGITS[b & 15]
		if i < 5 {
			text[3 * i + 2] = ':'
		}
	}
	rt.print("drv-virtio-net: ", string(text[:]), ", serving /srv/ether0\n")

	listen_armed := false
	for {
		service_rx()
		service_tx()
		accept_client()
		if client.on && !serve_client() {
			drop_client()
		}

		// Arm what is idle; sleep unless the client's queue filled meanwhile.
		idle := true
		if client.on && !client.holding {
			seen, _ := rt.counter_read(client.end)
			if !ring.prepare_sleep(&client.ring) {
				idle = false
			} else if !client.armed {
				client.armed = rt.port_bind(port, client.end, .Counter_Ge, client_key(.Bell), seen + 1) == .Ok
			}
		}
		if !listen_armed {
			listen_armed = rt.port_bind(port, listen, .Readable, u64(Key.Listen)) == .Ok
		}
		if idle {
			pk: [8]vx.Packet
			n, _ := rt.port_wait(port, vx.INFINITE, 0, pk[:])
			for p in pk[:n] {
				switch p.key {
				case u64(Key.Rx):
					_ = rt.port_bind(port, irq_rx, .Irq, u64(Key.Rx))
				case u64(Key.Tx):
					_ = rt.port_bind(port, irq_tx, .Irq, u64(Key.Tx))
				case u64(Key.Listen):
					listen_armed = false
				case client_key(.Bell):
					client.armed = false
				case client_key(.Closed):
					if client.on {
						drop_client()
					}
				}
			}
		}
		if client.on {
			ring.end_sleep(&client.ring)
		}
	}
}
