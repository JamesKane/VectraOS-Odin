package kernel

// Spike S3's first half: vector registers work in the kernel once the entry
// stub has enabled them. A lane-wise multiply that LLVM must keep in vector
// registers, checked against scalar arithmetic.

simd_check :: proc "contextless" () {
	a := #simd[4]u32{1, 2, 3, 4}
	b := #simd[4]u32{10, 20, 30, 40}
	c := a * b + a
	lanes := transmute([4]u32)c
	want := [4]u32{11, 42, 93, 164}
	if lanes == want {
		puts("vx: simd lanes ok\n")
	} else {
		puts("vx: simd lanes WRONG\n")
	}
}
