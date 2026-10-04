// SHA-256 (FIPS 180-4). Used by `build vendor-check` to verify vendored trees
// against VENDOR.ndb, and anywhere else a published hash must be checked.
//
// Imports nothing and allocates nothing, so the kernel, user space and host
// tools share it.
package sha256

DIGEST_SIZE :: 32

// A hash in progress: begin, add any number of times, end once.
Hasher :: struct {
	state:  [8]u32,
	length: u64, // bytes hashed so far
	block:  [64]u8,
	used:   int, // bytes waiting in block
}

begin :: proc "contextless" () -> Hasher {
	return Hasher{state = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19}}
}

add :: proc "contextless" (h: ^Hasher, data: []u8) {
	h.length += u64(len(data))
	p := data
	for len(p) > 0 {
		n := copy(h.block[h.used:], p)
		h.used += n
		p = p[n:]
		if h.used == len(h.block) {
			compress(h, &h.block)
			h.used = 0
		}
	}
}

// Pads the message and returns its digest. h is used up.
@(require_results)
end :: proc "contextless" (h: ^Hasher) -> (digest: [DIGEST_SIZE]u8) {
	bits := h.length * 8
	pad := [1]u8{0x80}
	add(h, pad[:])
	pad[0] = 0
	for h.used != 56 {
		add(h, pad[:])
	}
	length: [8]u8
	for i in 0 ..< 8 {
		length[i] = u8(bits >> (56 - 8 * uint(i)))
	}
	add(h, length[:])
	for s, i in h.state {
		digest[4 * i] = u8(s >> 24)
		digest[4 * i + 1] = u8(s >> 16)
		digest[4 * i + 2] = u8(s >> 8)
		digest[4 * i + 3] = u8(s)
	}
	return
}

@(private="file", rodata)
K := [64]u32 {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

@(private="file")
ror :: #force_inline proc "contextless" (x: u32, n: uint) -> u32 {
	return x >> n | x << (32 - n)
}

@(private="file")
compress :: proc "contextless" (h: ^Hasher, p: ^[64]u8) {
	w: [64]u32
	for i in 0 ..< 16 {
		w[i] = u32(p[4 * i]) << 24 | u32(p[4 * i + 1]) << 16 | u32(p[4 * i + 2]) << 8 | u32(p[4 * i + 3])
	}
	for i in 16 ..< 64 {
		s0 := ror(w[i - 15], 7) ~ ror(w[i - 15], 18) ~ (w[i - 15] >> 3)
		s1 := ror(w[i - 2], 17) ~ ror(w[i - 2], 19) ~ (w[i - 2] >> 10)
		w[i] = w[i - 16] + s0 + w[i - 7] + s1
	}
	a, b, c, d := h.state[0], h.state[1], h.state[2], h.state[3]
	e, f, g, k := h.state[4], h.state[5], h.state[6], h.state[7]
	for i in 0 ..< 64 {
		t1 := k + (ror(e, 6) ~ ror(e, 11) ~ ror(e, 25)) + ((e & f) ~ (~e & g)) + K[i] + w[i]
		t2 := (ror(a, 2) ~ ror(a, 13) ~ ror(a, 22)) + ((a & b) ~ (a & c) ~ (b & c))
		k = g
		g = f
		f = e
		e = d + t1
		d = c
		c = b
		b = a
		a = t1 + t2
	}
	h.state[0] += a
	h.state[1] += b
	h.state[2] += c
	h.state[3] += d
	h.state[4] += e
	h.state[5] += f
	h.state[6] += g
	h.state[7] += k
}
