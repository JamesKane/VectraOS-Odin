// Upstream's net fuzzer corpus (tests/fuzz/corpus/net) through the fuzzer's
// driver: every frame sent is legal, no queue overflows, and the digest of
// what each input made the stacks send and queue is upstream's.
package net_test

import "core:testing"
import nt "../nettest"

CORPUS := #load_directory("corpus")

@(test)
test_corpus :: proc(t: ^testing.T) {
	Case :: struct {
		name:   string,
		digest: u64,
	}
	// From upstream's net_fuzz.c, built with clang and the cross-check's digest.
	cases := []Case {
		{"arp", 0x98975e601a98144c}, // an ARP request for us
		{"dhcp", 0x24857a1feb21c086}, // a DHCP reply, broadcast
		{"echo", 0x1f7075bdcf5448dc}, // an ARP request, then an echo request for us
		{"tcp", 0x16ae3e00c1dd677f}, // an ARP request, a SYN to the listener with MSS and window scale, then an ACK
		{"udp", 0xc4e6874276be597c}, // a datagram to the UDP conversation's port
	}
	testing.expect_value(t, len(CORPUS), len(cases))
	f := new(nt.Net_Fuzz)
	defer free(f)
	for c in cases {
		data: []u8
		for file in CORPUS {
			if file.name == c.name {
				data = file.data
			}
		}
		if !testing.expectf(t, data != nil, "corpus file %s is missing", c.name) {
			continue
		}
		nt.net_fuzz(f, data)
		testing.expectf(t, f.violations == 0, "%s: %d violations", c.name, f.violations)
		testing.expectf(t, f.digest == c.digest, "%s: digest %x, upstream's %x", c.name, f.digest, c.digest)
	}
}
