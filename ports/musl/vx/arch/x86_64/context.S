// context.S (x86_64): what the back end reaches only by instructions Odin
// cannot say.

    .text

// __vx_ehdr() -> ^Elf_Header: the program's ELF header, which lld places at
// the start of the first loaded segment (AT_PHDR is found from it).
    .globl __vx_ehdr
    .type __vx_ehdr, @function
__vx_ehdr:
    endbr64
    leaq __ehdr_start(%rip), %rax
    ret

// __vx_fork_save(ctx) -> i32 and __vx_fork_resume(ctx) -> !: setjmp and
// longjmp for fork alone. save keeps the return address, the stack pointer
// as it will be on return, and the callee-saved registers, and returns 0;
// resume, in the forked child's copy of memory, puts them back and returns
// 1 from save.
    .globl __vx_fork_save
    .type __vx_fork_save, @function
__vx_fork_save:
    endbr64
    movq (%rsp), %rax
    movq %rax, 0(%rdi)
    leaq 8(%rsp), %rax
    movq %rax, 8(%rdi)
    movq %rbx, 16(%rdi)
    movq %rbp, 24(%rdi)
    movq %r12, 32(%rdi)
    movq %r13, 40(%rdi)
    movq %r14, 48(%rdi)
    movq %r15, 56(%rdi)
    xorl %eax, %eax
    ret

    .globl __vx_fork_resume
    .type __vx_fork_resume, @function
__vx_fork_resume:
    endbr64
    movq 16(%rdi), %rbx
    movq 24(%rdi), %rbp
    movq 32(%rdi), %r12
    movq 40(%rdi), %r13
    movq 48(%rdi), %r14
    movq 56(%rdi), %r15
    movq 8(%rdi), %rsp
    movl $1, %eax
    jmpq *0(%rdi)

    .section .note.GNU-stack, "", @progbits
