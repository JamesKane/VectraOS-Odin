// tdata.S (x86_64): threadtest's initialised thread-local variable, which
// Odin cannot declare (a @(thread_local) takes no initial value): eight
// bytes of .tdata, each thread's copy found from the thread pointer as the
// compiler finds one (local-exec: %fs:0, plus the offset lld gives).

    .section .tdata, "awT", @progbits
    .p2align 3
tl_init:
    .quad 0x12345678

    .text

// vx_tl_init() -> ^u64: the calling thread's copy.
    .globl vx_tl_init
    .type vx_tl_init, @function
vx_tl_init:
    movq %fs:0, %rax
    leaq tl_init@tpoff(%rax), %rax
    ret

    .section .note.GNU-stack, "", @progbits
