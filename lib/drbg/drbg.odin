// vx:drbg, a deterministic random bit generator over SHA-256, in the manner
// of NIST SP 800-90A's Hash_DRBG, simplified. Its state is a 32-byte key and
// a counter. Output block i is SHA-256("out" || key || counter + i); after
// each request the key is replaced by SHA-256("key" || key || counter), so
// state taken later says nothing of output already given. Seeding and mixing
// replace the key by SHA-256("mix" || key || data). The counter goes into the
// hash as 8 little-endian bytes, as upstream's does on both its targets.
//
// It is only as good as its seed: VectraOS's comes from the bootloader's
// entropy (Limine's, from the firmware and the CPU), which the kernel gives
// svcd, and svcd and every POSIX parent give each child a seed of its own
// from theirs (`entropy=` in the spawn message).
package drbg

import "vx:memory"
import "vx:sha256"

Drbg :: struct {
	key:     [sha256.DIGEST_SIZE]u8,
	counter: u64le,
	seeded:  bool,
}

@(private="file")
hash :: proc "contextless" (d: ^Drbg, tag: string, data: []u8) -> [sha256.DIGEST_SIZE]u8 {
	h := sha256.begin()
	sha256.add(&h, transmute([]u8)tag)
	sha256.add(&h, d.key[:])
	sha256.add(&h, data)
	return sha256.end(&h)
}

// The counter's value before it moves on, as the bytes that are hashed.
@(private="file")
next_counter :: proc "contextless" (d: ^Drbg) -> (c: u64le) {
	c = d.counter
	d.counter += 1
	return
}

// Adds data to the state. A generator is seeded once it has been given a
// seed (`seed` true), not by mixing alone.
mix :: proc "contextless" (d: ^Drbg, data: []u8, seed: bool) {
	d.key = hash(d, "mix", data)
	if seed {
		d.seeded = true
	}
}

// Fills out with the generator's output.
read :: proc "contextless" (d: ^Drbg, out: []u8) {
	for at := 0; at < len(out); {
		c := next_counter(d)
		block := hash(d, "out", memory.ptr_to_bytes(&c))
		at += copy(out[at:], block[:])
	}
	c := next_counter(d)
	d.key = hash(d, "key", memory.ptr_to_bytes(&c))
}
