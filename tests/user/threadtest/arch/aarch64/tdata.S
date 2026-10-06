// tdata.S (aarch64): threadtest's initialised thread-local variable, which
// Odin cannot declare (a @(thread_local) takes no initial value): eight
// bytes of .tdata, each thread's copy found from the thread pointer as the
// compiler finds one (local-exec: TPIDR_EL0, plus the offset lld gives).

    .section .tdata, "awT", %progbits
    .p2align 3
tl_init:
    .xword 0x12345678

    .text

// vx_tl_init() -> ^u64: the calling thread's copy.
    .globl vx_tl_init
    .type vx_tl_init, %function
vx_tl_init:
    mrs x0, tpidr_el0
    add x0, x0, #:tprel_hi12:tl_init, lsl #12
    add x0, x0, #:tprel_lo12_nc:tl_init
    ret
