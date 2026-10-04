// Upstream's DNS fuzzer corpus (tests/fuzz/corpus/dns) through the fuzzer's
// driver: at most DNS_ADDRS addresses come back, and the digest of the query
// and the lookup's result for each input is upstream's.
package dns_test

import "core:testing"
import nt "../nettest"

CORPUS := #load_directory("corpus")

@(test)
test_corpus :: proc(t: ^testing.T) {
	Case :: struct {
		name:   string,
		digest: u64,
	}
	// From upstream's dns_fuzz.c, built with clang and the cross-check's digest.
	cases := []Case {
		{"a", 0x1fc12a9c15d3471a}, // one A record, its owner compressed
		{"cname", 0xc26ed27ad090c9aa}, // a CNAME, then the A record of its target, uncompressed
		{"nxdomain", 0x52af0816826dfa0d}, // no such name
	}
	testing.expect_value(t, len(CORPUS), len(cases))
	f := new(nt.Dns_Fuzz)
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
		nt.dns_fuzz(f, data)
		testing.expectf(t, f.violations == 0, "%s: %d violations", c.name, f.violations)
		testing.expectf(t, f.digest == c.digest, "%s: digest %x, upstream's %x", c.name, f.digest, c.digest)
	}
}
