// syscall_cp.S (x86_64): the entry to a cancellation point (musl's
// pthread_cancel.c), as musl's arch/x86_64/syscall_cp.s is on Linux: the
// thread's cancel flag checked, then the call, through __vx_syscall.
// Cancellation by a signal arriving inside [__cp_begin, __cp_end) waits for
// threads.

    .text
    .globl __cp_begin, __cp_end, __cp_cancel, __syscall_cp_asm
    .hidden __cp_cancel
    .type __syscall_cp_asm, @function
__syscall_cp_asm:
__cp_begin:
    endbr64
    movl (%rdi), %eax
    testl %eax, %eax
    jnz __cp_cancel
    movq %rsi, %rdi            // (cancel, nr, u, v, w, x, y, z) to (nr, u, v, w, x, y, z)
    movq %rdx, %rsi
    movq %rcx, %rdx
    movq %r8, %rcx
    movq %r9, %r8
    movq 8(%rsp), %r9
    pushq 16(%rsp)
    call __vx_syscall
    addq $8, %rsp
__cp_end:
    ret
__cp_cancel:
    jmp __cancel

    .section .note.GNU-stack, "", @progbits
