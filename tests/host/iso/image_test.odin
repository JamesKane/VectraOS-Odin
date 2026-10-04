// The image every suite here reads: the ISO upstream's tests read
// (out/host/test.iso, which its build makes with make_test_iso and
// write_iso, with Rock Ridge and Joliet). The image was made by upstream's
// own write_iso, compiled with clang from build.c at 1976c1f, with
// SOURCE_DATE_EPOCH=1759536000; test.iso.gz is that image cut before
// big.bin's extent, its last 147 sectors, which load_image makes again from
// the pattern make_test_iso writes. The whole image's SHA-256 is checked, so
// the bytes are upstream writer's exactly; writer_test checks this tree's
// port of the writer (tools/build/iso.odin) against them.
package iso_test

import "core:bytes"
import "core:compress/gzip"
import "core:crypto/sha2"
import "core:encoding/hex"
import "core:testing"
import "vx:iso"

FIXTURE :: #load("test.iso.gz")
IMAGE_SHA256 :: "750a934fa683638debd1242d51d185f96d12d2c528fe668a70bc763777cfc5a1"
IMAGE_SECTORS :: 194
BIG_LBA :: 47 // big.bin's extent: the image's tail
BIG_SIZE :: 300_000

// make_test_iso's big.bin, byte i.
big_byte :: proc(i: u64) -> u8 {
	return u8((i * 7 + i / 251) & 0xff)
}

// The whole image, from the fixture; the caller deletes it.
load_image :: proc(t: ^testing.T) -> []u8 {
	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	if err := gzip.load_from_bytes(FIXTURE, &buf); err != nil {
		testing.fail_now(t, "test.iso.gz does not decompress")
	}
	head := bytes.buffer_to_bytes(&buf)
	testing.expect_value(t, len(head), BIG_LBA * iso.SECTOR)
	image := make([]u8, IMAGE_SECTORS * iso.SECTOR)
	copy(image, head)
	for i in 0 ..< u64(BIG_SIZE) {
		image[BIG_LBA * iso.SECTOR + i] = big_byte(i)
	}
	h: sha2.Context_256
	sha2.init_256(&h)
	sha2.update(&h, image)
	digest: [sha2.DIGEST_SIZE_256]u8
	sha2.final(&h, digest[:])
	testing.expect_value(t, string(hex.encode(digest[:], context.temp_allocator)), IMAGE_SHA256)
	return image
}

image_read :: proc "contextless" (ctx: rawptr, off: u64, buf: []u8) -> bool {
	m := (^[]u8)(ctx)^
	if off > u64(len(m)) || u64(len(buf)) > u64(len(m)) - off {
		return false
	}
	copy(buf, m[off:])
	return true
}

dev_of :: proc(image: ^[]u8) -> iso.Dev {
	return iso.Dev{ctx = image, read = image_read}
}
