// overflow.S (x86_64): ktest's note-stack case (ADR-0036): the stack pointer
// moved to memory nothing maps, then a push, which faults with no room on
// that stack for the kernel to divert the thread to its handler.

    .text

// vx_push_at(sp: u64) -> !
    .globl vx_push_at
    .type vx_push_at, @function
vx_push_at:
    movq %rdi, %rsp
    pushq %rax
    ud2

    .section .note.GNU-stack, "", @progbits
