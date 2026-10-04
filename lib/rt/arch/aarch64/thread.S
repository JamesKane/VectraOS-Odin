// thread.S (aarch64): what a thread reaches only by instructions Odin cannot
// say. The thread pointer is TPIDR_EL0, which the kernel keeps per thread.

    .text

// vx_thread_word() -> u64: the word the thread pointer points at, read
// through it as a C library does.
    .globl vx_thread_word
    .type vx_thread_word, %function
vx_thread_word:
    mrs x0, tpidr_el0
    ldr x0, [x0]
    ret

// vx_fp_probe_put(v: u64, ctl: u32) and vx_fp_probe_get(ctl: ^u32) -> u64:
// a vector register and the FP control register (v7 and FPCR), for ktest's
// check that the kernel keeps each thread's FP/SIMD state. v7 is
// caller-saved and Odin's code between a put and a get has no reason to use
// it, so what a get finds is what the kernel kept.
    .globl vx_fp_probe_put
    .type vx_fp_probe_put, %function
vx_fp_probe_put:
    fmov d7, x0
    mov w1, w1
    msr fpcr, x1
    ret

    .globl vx_fp_probe_get
    .type vx_fp_probe_get, %function
vx_fp_probe_get:
    mrs x1, fpcr
    str w1, [x0]
    fmov x0, d7
    ret
