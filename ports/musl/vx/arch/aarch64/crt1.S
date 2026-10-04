// crt1.S (aarch64): a musl program's entry point on VectraOS (ADR-0007), in
// place of musl's crt/crt1.c, which reads a Linux initial stack. The kernel
// enters _start as if called, with the bootstrap channel as the argument;
// the back end (__vx_start) reads the spawn message from it and builds what
// musl's __libc_start_main expects.

    .text
    .globl _start
    .type _start, %function
_start:
    bti c
    mov x29, xzr
    mov x30, xzr
    mov x9, sp
    and sp, x9, #-16
    adrp x1, main
    add x1, x1, :lo12:main
    bl __vx_start              // the bootstrap channel is already in x0
    brk #0
