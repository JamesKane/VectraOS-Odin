// note.S (x86_64): the in-task exception handler a program's notify installs
// (note.odin). The kernel starts it as if called, with the Exception it put
// on the stack in rdi. It saves the FP/SIMD registers, which the kernel does
// not put in an Exception, before any Odin runs: all XCR0 enables, with
// XSAVE, in 4 KiB of the stack (the kernel enables x87, SSE and AVX, which
// take less than 1 KiB). Then vx_note_dispatch, and vx_note_resume, which
// does not return.

    .text
    .globl vx_note_entry
    .hidden vx_note_entry
    .type vx_note_entry, @function
vx_note_entry:
    movq %rdi, %rbx        // the Exception, kept across the calls
    subq $4096, %rsp
    andq $-64, %rsp
    xorl %eax, %eax        // XSAVE needs a zeroed header (bytes 512-575)
    movq %rax, 512(%rsp)
    movq %rax, 520(%rsp)
    movq %rax, 528(%rsp)
    movq %rax, 536(%rsp)
    movq %rax, 544(%rsp)
    movq %rax, 552(%rsp)
    movq %rax, 560(%rsp)
    movq %rax, 568(%rsp)
    movl $-1, %eax
    movl $-1, %edx
    xsave64 (%rsp)
    movq %rbx, %rdi
    call vx_note_dispatch
    movl $-1, %eax
    movl $-1, %edx
    xrstor64 (%rsp)
    movq %rbx, %rdi
    call vx_note_resume
    ud2

    .section .note.GNU-stack, "", @progbits
