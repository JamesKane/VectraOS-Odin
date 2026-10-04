// syscall_cp.S (aarch64): the entry to a cancellation point (musl's
// pthread_cancel.c), as musl's arch/aarch64/syscall_cp.s is on Linux: the
// thread's cancel flag checked, then the call, through __vx_syscall.
// Cancellation by a signal arriving inside [__cp_begin, __cp_end) waits for
// threads.

    .text
    .globl __cp_begin, __cp_end, __cp_cancel, __syscall_cp_asm
    .hidden __cp_cancel
    .type __syscall_cp_asm, %function
__syscall_cp_asm:
__cp_begin:
    bti c
    ldr w9, [x0]
    cbnz w9, __cp_cancel
    mov x0, x1                 // (cancel, nr, u, v, w, x, y, z) to (nr, u, v, w, x, y, z)
    mov x1, x2
    mov x2, x3
    mov x3, x4
    mov x4, x5
    mov x5, x6
    mov x6, x7
    b __vx_syscall
__cp_end:
__cp_cancel:
    b __cancel
