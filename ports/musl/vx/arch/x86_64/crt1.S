// crt1.S (x86_64): a musl program's entry point on VectraOS (ADR-0007), in
// place of musl's crt/crt1.c, which reads a Linux initial stack. The kernel
// enters _start as if called, with the bootstrap channel as the argument;
// the back end (__vx_start) reads the spawn message from it and builds what
// musl's __libc_start_main expects.

    .text
    .globl _start
    .type _start, @function
_start:
    endbr64
    xorl %ebp, %ebp
    andq $-16, %rsp
    leaq main(%rip), %rsi
    call __vx_start            // the bootstrap channel is already in rdi
    ud2

    .section .note.GNU-stack, "", @progbits
