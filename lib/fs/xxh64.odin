package fs

// XXH64, the block hash (upstream docs/11 §12), written from its
// specification (Yann Collet's xxHash, doc/xxhash_spec.md) and checked
// against vectors from the reference implementation (tests/host/fs). A 64-bit
// non-cryptographic hash: it catches failing media and bugs, not tampering.

@(private = "file")
P1 :: u64(0x9E3779B185EBCA87)
@(private = "file")
P2 :: u64(0xC2B2AE3D27D4EB4F)
@(private = "file")
P3 :: u64(0x165667B19E3779F9)
@(private = "file")
P4 :: u64(0x85EBCA77C2B2AE63)
@(private = "file")
P5 :: u64(0x27D4EB2F165667C5)

@(private = "file")
rotl :: #force_inline proc "contextless" (x: u64, r: uint) -> u64 {
	return x << r | x >> (64 - r)
}

@(private = "file")
round :: #force_inline proc "contextless" (acc, lane: u64) -> u64 {
	return rotl(acc + lane * P2, 31) * P1
}

@(private = "file")
merge :: #force_inline proc "contextless" (acc, v: u64) -> u64 {
	return (acc ~ round(0, v)) * P1 + P4
}

xxh64 :: proc "contextless" (data: []u8, seed: u64) -> u64 {
	p := data
	h: u64
	if len(p) >= 32 {
		v1, v2, v3, v4 := seed + P1 + P2, seed + P2, seed, seed - P1
		for len(p) >= 32 {
			v1 = round(v1, get64(p))
			v2 = round(v2, get64(p[8:]))
			v3 = round(v3, get64(p[16:]))
			v4 = round(v4, get64(p[24:]))
			p = p[32:]
		}
		h = rotl(v1, 1) + rotl(v2, 7) + rotl(v3, 12) + rotl(v4, 18)
		h = merge(h, v1)
		h = merge(h, v2)
		h = merge(h, v3)
		h = merge(h, v4)
	} else {
		h = seed + P5
	}
	h += u64(len(data))
	for len(p) >= 8 {
		h ~= round(0, get64(p))
		h = rotl(h, 27) * P1 + P4
		p = p[8:]
	}
	if len(p) >= 4 {
		h ~= u64(get32(p)) * P1
		h = rotl(h, 23) * P2 + P3
		p = p[4:]
	}
	for c in p {
		h ~= u64(c) * P5
		h = rotl(h, 11) * P1
	}
	h ~= h >> 33
	h *= P2
	h ~= h >> 29
	h *= P3
	h ~= h >> 32
	return h
}
