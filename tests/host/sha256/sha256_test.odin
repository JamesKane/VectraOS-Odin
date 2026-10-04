// lib/sha256, ported from upstream's tests/host/sha256_test.c: the FIPS 180
// test vectors, and the same digest whatever pieces the input arrives in.
// Added here: agreement with core:crypto/sha2 on random inputs.
package sha256_test

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:math/rand"
import "core:testing"
import "vx:sha256"

digest :: proc(data: []u8) -> [sha256.DIGEST_SIZE]u8 {
	h := sha256.begin()
	sha256.add(&h, data)
	return sha256.end(&h)
}

digest_is :: proc(data: []u8, want_hex: string) -> bool {
	d := digest(data)
	got := hex.encode(d[:])
	defer delete(got)
	return string(got) == want_hex
}

@(test)
test_vectors :: proc(t: ^testing.T) {
	testing.expect(t, digest_is(nil, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"))
	testing.expect(t, digest_is(transmute([]u8)string("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
	two_blocks := "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
	testing.expect(t, digest_is(transmute([]u8)two_blocks, "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"))

	million := make([]u8, 1000000)
	defer delete(million)
	for &c in million {
		c = 'a'
	}
	testing.expect(t, digest_is(million, "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"))

	// Split at every point around the block boundaries: the digest must not change.
	whole := digest(million[:200])
	for cut in 0 ..= 200 {
		h := sha256.begin()
		sha256.add(&h, million[:cut])
		sha256.add(&h, million[cut:200])
		pieces := sha256.end(&h)
		testing.expectf(t, whole == pieces, "cut at %d", cut)
	}
}

// Random lengths around several blocks, each fed in three random pieces,
// against core:crypto/sha2.
@(test)
test_against_core :: proc(t: ^testing.T) {
	buf: [700]u8
	for _ in 0 ..< 500 {
		n := rand.int_max(len(buf) + 1)
		data := buf[:n]
		for &c in data {
			c = u8(rand.uint32())
		}
		a := rand.int_max(n + 1)
		b := a + rand.int_max(n - a + 1)
		h := sha256.begin()
		sha256.add(&h, data[:a])
		sha256.add(&h, data[a:b])
		sha256.add(&h, data[b:])
		got := sha256.end(&h)

		ctx: sha2.Context_256
		sha2.init_256(&ctx)
		sha2.update(&ctx, data)
		want: [sha2.DIGEST_SIZE_256]u8
		sha2.final(&ctx, want[:])
		testing.expectf(t, got == want, "%d bytes, cut at %d and %d", n, a, b)
	}
}
