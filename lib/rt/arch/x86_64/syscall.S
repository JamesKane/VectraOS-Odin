// syscall.S (x86_64): the one way into the kernel. vx_syscall(nr, a0..a5):
// the number in rax and the arguments in rdi, rsi, rdx, r10, r8, r9, as
// SYSCALL wants them; rcx and r11 are the CPU's.

    .text
    .globl vx_syscall
    .type vx_syscall, @function
vx_syscall:
    movq %rdi, %rax
    movq %rsi, %rdi
    movq %rdx, %rsi
    movq %rcx, %rdx
    movq %r8, %r10
    movq %r9, %r8
    movq 8(%rsp), %r9
    syscall
    ret

    .section .note.GNU-stack, "", @progbits
