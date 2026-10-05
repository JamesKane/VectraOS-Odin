// mem.S (aarch64): the four functions the compiler may call even in
// freestanding code, memcpy, memset, memmove and memcmp, for the kernel and
// every native program (upstream's vx-mem; M6 step 6c2). The build assembles
// this file into both and leaves out the Odin runtime's own (byte loops), so
// these are what Odin's copies, LLVM's calls and the native ports' C reach.
//
// Eight bytes at a time, two a round (a load or store pair), where both
// pointers share their alignment; bytes at the edges and where they do not.
// Only aligned words are touched, so device memory, which faults an
// unaligned access, is safe to copy where a byte copy was. Scalar registers
// only: no vector state is touched.

    .text

// Forwards: x3 the destination, x1 the source, x2 the count; x4 and x5
// scratch. Each round loads both of its words before it stores either, so a
// destination below an overlapping source comes out right.
.macro FORWARDS
    cmp x2, #16
    b.lo 3f
    eor x4, x3, x1
    tst x4, #7
    b.ne 3f            // not co-aligned: bytes
1:  tst x3, #7         // bytes up to the alignment
    b.eq 2f
    ldrb w4, [x1], #1
    strb w4, [x3], #1
    sub x2, x2, #1
    b 1b
2:  cmp x2, #16
    b.lo 3f
    ldp x4, x5, [x1], #16
    stp x4, x5, [x3], #16
    sub x2, x2, #16
    b 2b
3:  cbz x2, 4f         // the rest, a byte at a time
5:  ldrb w4, [x1], #1
    strb w4, [x3], #1
    subs x2, x2, #1
    b.ne 5b
4:
.endm

// memcpy(dst, src, n) -> dst
    .globl memcpy
    .type memcpy, %function
memcpy:
    mov x3, x0
    FORWARDS
    ret
    .size memcpy, . - memcpy

// memset(dst, c, n) -> dst
    .globl memset
    .type memset, %function
memset:
    mov x3, x0
    and w1, w1, #0xff
    cmp x2, #16
    b.lo 3f
1:  tst x3, #7
    b.eq 2f
    strb w1, [x3], #1
    sub x2, x2, #1
    b 1b
2:  mov x4, #0x0101010101010101
    mul x4, x4, x1     // the byte in each of the word's eight
6:  cmp x2, #16
    b.lo 3f
    stp x4, x4, [x3], #16
    sub x2, x2, #16
    b 6b
3:  cbz x2, 4f
5:  strb w1, [x3], #1
    subs x2, x2, #1
    b.ne 5b
4:  ret
    .size memset, . - memset

// memmove(dst, src, n) -> dst: forwards unless the destination starts inside
// the source, then backwards, from the ends.
    .globl memmove
    .type memmove, %function
memmove:
    cmp x0, x1
    b.ls 10f           // dst <= src
    add x4, x1, x2
    cmp x0, x4
    b.lo 20f           // dst inside [src, src + n)
10: mov x3, x0
    FORWARDS
    ret
20: add x3, x0, x2
    add x1, x1, x2
    cmp x2, #16
    b.lo 23f
    eor x4, x3, x1
    tst x4, #7
    b.ne 23f
21: tst x3, #7
    b.eq 22f
    ldrb w4, [x1, #-1]!
    strb w4, [x3, #-1]!
    sub x2, x2, #1
    b 21b
22: cmp x2, #16
    b.lo 23f
    ldp x4, x5, [x1, #-16]!
    stp x4, x5, [x3, #-16]!
    sub x2, x2, #16
    b 22b
23: cbz x2, 24f
25: ldrb w4, [x1, #-1]!
    strb w4, [x3, #-1]!
    subs x2, x2, #1
    b.ne 25b
24: ret
    .size memmove, . - memmove

// memcmp(a, b, n) -> int: the first differing byte's difference, the bytes
// unsigned. The first differing word is compared by bytes.
    .globl memcmp
    .type memcmp, %function
memcmp:
    cmp x2, #16
    b.lo 3f
    eor x4, x0, x1
    tst x4, #7
    b.ne 3f
1:  tst x0, #7
    b.eq 2f
    ldrb w4, [x0], #1
    ldrb w5, [x1], #1
    subs w4, w4, w5
    b.ne 9f
    sub x2, x2, #1
    b 1b
2:  cmp x2, #8
    b.lo 3f
    ldr x4, [x0]
    ldr x5, [x1]
    cmp x4, x5
    b.ne 3f
    add x0, x0, #8
    add x1, x1, #8
    sub x2, x2, #8
    b 2b
3:  cbz x2, 8f
5:  ldrb w4, [x0], #1
    ldrb w5, [x1], #1
    subs w4, w4, w5
    b.ne 9f
    subs x2, x2, #1
    b.ne 5b
8:  mov w0, #0
    ret
9:  mov w0, w4
    ret
    .size memcmp, . - memcmp
