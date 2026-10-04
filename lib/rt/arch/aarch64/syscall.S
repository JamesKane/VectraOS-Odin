// syscall.S (aarch64): the one way into the kernel. vx_syscall(nr, a0..a5):
// the number in x8 and the arguments in x0-x5, as svc wants them.

    .text
    .globl vx_syscall
    .type vx_syscall, %function
vx_syscall:
    mov x8, x0
    mov x0, x1
    mov x1, x2
    mov x2, x3
    mov x3, x4
    mov x4, x5
    mov x5, x6
    svc #0
    ret
