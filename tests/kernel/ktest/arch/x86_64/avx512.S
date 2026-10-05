// avx512.S (x86_64): ktest's use of AVX-512 where rt.cpu_has offers it
// (upstream's M6 step 6c3): an instruction only AVX-512 has, on a register
// only AVX-512 has, so the kernel must have its state in XCR0.

    .text

// vx_avx512_double(z: ^[8]u64): z's eight lanes doubled, in zmm16.
    .globl vx_avx512_double
    .type vx_avx512_double, @function
vx_avx512_double:
    vmovdqu64 (%rdi), %zmm16
    vpaddq %zmm16, %zmm16, %zmm16
    vmovdqu64 %zmm16, (%rdi)
    vzeroupper
    ret

    .section .note.GNU-stack, "", @progbits
