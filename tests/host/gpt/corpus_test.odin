// Upstream's GPT fuzzer (tests/fuzz/gpt_fuzz.c) over its corpus
// (tests/fuzz/corpus/gpt), and over hostile variants of it: whatever the
// reader accepts is a table whose partitions lie in its usable range, inside
// the disk, and overlap no other.
package gpt_test

import "core:testing"
import vx "abi:vx"
import "vx:gpt"

CORPUS := #load_directory("corpus")

@(private="file")
gpt_fuzz :: proc(t: ^testing.T, name: string, data: []u8, g: ^gpt.Gpt) -> vx.Status {
	d := Disk {
		bytes   = data,
		sector  = 512,
		sectors = u64(len(data) / 512),
	}
	st := gpt.read(g, 512, d.sectors, disk_read, &d)
	if st != .Ok {
		return st
	}
	testing.expectf(t, g.first_usable <= g.last_usable, "%s: usable range %d..%d", name, g.first_usable, g.last_usable)
	testing.expectf(t, g.last_usable < d.sectors, "%s: usable range past the disk", name)
	for &p, i in g.parts {
		testing.expectf(t, p.first <= p.last && p.first >= g.first_usable && p.last <= g.last_usable, "%s: partition %d at %d..%d", name, i, p.first, p.last)
		for &q in g.parts[:i] {
			testing.expectf(t, !(p.first <= q.last && q.first <= p.last), "%s: partition %d overlaps another", name, i)
		}
	}
	return st
}

@(test)
test_corpus :: proc(t: ^testing.T) {
	g := new(gpt.Gpt)
	defer free(g)
	testing.expect_value(t, len(CORPUS), 1)
	for file in CORPUS {
		testing.expect_value(t, gpt_fuzz(t, file.name, file.data, g), vx.Status.Ok)
		// What upstream's C reads from it (scratch oracle gpt_oracle.c).
		testing.expect_value(t, g.backup, false)
		testing.expect_value(t, len(g.parts), 1)
		testing.expect_value(t, g.first_usable, 34)
		testing.expect_value(t, g.last_usable, 94)
		testing.expect_value(t, g.parts[0].first, 40)
		testing.expect_value(t, g.parts[0].last, 90)
		testing.expect_value(t, string(g.parts[0].name[:]), "EFI")
	}
}

// Not upstream's corpus: the one table cut at each sector, and with each byte
// of its MBR, its primary header and its first entries flipped in turn (the
// entries' CRC catches any other flip in them as surely).
@(test)
test_mutants :: proc(t: ^testing.T) {
	g := new(gpt.Gpt)
	defer free(g)
	data := make([]u8, len(CORPUS[0].data))
	defer delete(data)
	copy(data, CORPUS[0].data)
	for cut := 0; cut < len(data); cut += 512 {
		_ = gpt_fuzz(t, "cut", data[:cut], g)
	}
	for at in 0 ..< 3 * 512 {
		data[at] ~= 0x41
		_ = gpt_fuzz(t, "flipped", data, g)
		data[at] ~= 0x41
	}
}
