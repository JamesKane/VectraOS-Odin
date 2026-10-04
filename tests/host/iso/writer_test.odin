// This tree's ISO writer (tools/build/iso.odin's write_iso, with Rock Ridge
// and Joliet) against upstream's: ./build check writes make_test_iso's image
// to out/host/test.iso at TEST_ISO_EPOCH, the date upstream's fixture was
// written at, before it runs this suite from the repository root; it must
// be upstream's image byte for byte (whose SHA-256 load_image checks).
package iso_test

import "core:fmt"
import "core:os"
import "core:testing"
import "vx:iso"

WRITTEN :: "out/host/test.iso"

@(test)
test_writer_matches_upstream :: proc(t: ^testing.T) {
	want := load_image(t)
	defer delete(want)
	got, err := os.read_entire_file(WRITTEN, context.allocator)
	if err != nil {
		testing.fail_now(t, fmt.tprintf("cannot read %s (./build check writes it): %v", WRITTEN, err))
	}
	defer delete(got)
	testing.expect_value(t, len(got), len(want))
	first := -1
	for i in 0 ..< min(len(got), len(want)) {
		if got[i] != want[i] {
			first = i
			break
		}
	}
	testing.expectf(t, first < 0, "%s differs from upstream's image first at byte %d (sector %d)", WRITTEN, first, first / iso.SECTOR)
}
