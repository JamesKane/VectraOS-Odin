// Monocypher 4.0.3 (ADR-0011), vendored C behind this thin layer as
// ADR-0007 has it: BLAKE2b, which names the content store's objects
// (lib/store), and Ed25519 (RFC 8032, with SHA-512), which checks release
// signatures once records are signed (upstream's M10).
//
// Monocypher is linked as C: tools/build/cobj.odin builds
// third_party/monocypher into libmonocypher.a, which an Odin program that
// names the port links, and a host test that says `// host-links:
// monocypher`. Nothing here allocates, and every procedure is contextless,
// so the libraries above it stay so. Lengths cross the C boundary only from
// slices, and an output's size is checked before Monocypher writes it.
package crypto

import "base:intrinsics"

BLAKE2B_MAX :: 64 // the longest BLAKE2b hash, in bytes

// crypto_blake2b_ctx, as monocypher.h declares it for a 64-bit target
// (size_t is a uint). Monocypher says not to rely on its contents; only its
// size and alignment matter here, to hold it on the caller's stack.
Blake2b :: struct {
	hash:         [8]u64,
	input_offset: [2]u64,
	input:        [16]u64,
	input_idx:    uint,
	hash_size:    uint,
}
#assert(size_of(uint) == 8)
#assert(size_of(Blake2b) == 224)
#assert(align_of(Blake2b) == 8)
#assert(offset_of(Blake2b, input_offset) == 64)
#assert(offset_of(Blake2b, input) == 80)
#assert(offset_of(Blake2b, input_idx) == 208)
#assert(offset_of(Blake2b, hash_size) == 216)

@(private="file")
foreign _ {
	crypto_blake2b :: proc "c" (hash: [^]u8, hash_size: uint, message: [^]u8, message_size: uint) ---
	crypto_blake2b_init :: proc "c" (ctx: ^Blake2b, hash_size: uint) ---
	crypto_blake2b_update :: proc "c" (ctx: ^Blake2b, message: [^]u8, message_size: uint) ---
	crypto_blake2b_final :: proc "c" (ctx: ^Blake2b, hash: [^]u8) ---
	crypto_ed25519_check :: proc "c" (signature: ^[64]u8, public_key: ^[32]u8, message: [^]u8, message_size: uint) -> i32 ---
}

// A hash size Monocypher would write past: a caller's bug, never input's.
@(private="file")
check_size :: proc "contextless" (n: int) {
	if n < 1 || n > BLAKE2B_MAX {
		intrinsics.trap()
	}
}

// The BLAKE2b hash of message, len(out) bytes long (1 to 64), into out.
blake2b :: proc "contextless" (out: []u8, message: []u8) {
	check_size(len(out))
	crypto_blake2b(raw_data(out), uint(len(out)), raw_data(message), uint(len(message)))
}

// A hash in progress, of size bytes: begin, add any number of times, end once.
blake2b_begin :: proc "contextless" (h: ^Blake2b, size: int) {
	check_size(size)
	crypto_blake2b_init(h, uint(size))
}

blake2b_add :: proc "contextless" (h: ^Blake2b, data: []u8) {
	crypto_blake2b_update(h, raw_data(data), uint(len(data)))
}

// Writes the hash, as long as blake2b_begin said, into out, which must be
// exactly that long. h is used up (Monocypher wipes it).
blake2b_end :: proc "contextless" (h: ^Blake2b, out: []u8) {
	if uint(len(out)) != h.hash_size {
		intrinsics.trap()
	}
	crypto_blake2b_final(h, raw_data(out))
}

// Whether signature is public_key's Ed25519 signature (RFC 8032) of message.
@(require_results)
ed25519_check :: proc "contextless" (signature: ^[64]u8, public_key: ^[32]u8, message: []u8) -> bool {
	return crypto_ed25519_check(signature, public_key, raw_data(message), uint(len(message))) == 0
}
