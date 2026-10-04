// context.S (aarch64): what the back end reaches only by instructions Odin
// cannot say.

    .text

// __vx_ehdr() -> ^Elf_Header: the program's ELF header, which lld places at
// the start of the first loaded segment (AT_PHDR is found from it).
    .globl __vx_ehdr
    .type __vx_ehdr, %function
__vx_ehdr:
    bti c
    adrp x0, __ehdr_start
    add x0, x0, :lo12:__ehdr_start
    ret

// __vx_fork_save(ctx) -> i32 and __vx_fork_resume(ctx) -> !: setjmp and
// longjmp for fork alone. save keeps the callee-saved registers, the frame
// and link registers and the stack pointer, and returns 0; resume, in the
// forked child's copy of memory, puts them back and returns 1 from save.
    .globl __vx_fork_save
    .type __vx_fork_save, %function
__vx_fork_save:
    bti c
    stp x19, x20, [x0, #0]
    stp x21, x22, [x0, #16]
    stp x23, x24, [x0, #32]
    stp x25, x26, [x0, #48]
    stp x27, x28, [x0, #64]
    stp x29, x30, [x0, #80]
    mov x9, sp
    str x9, [x0, #96]
    stp d8, d9, [x0, #104]
    stp d10, d11, [x0, #120]
    stp d12, d13, [x0, #136]
    stp d14, d15, [x0, #152]
    mov x0, #0
    ret

    .globl __vx_fork_resume
    .type __vx_fork_resume, %function
__vx_fork_resume:
    bti c
    ldp x19, x20, [x0, #0]
    ldp x21, x22, [x0, #16]
    ldp x23, x24, [x0, #32]
    ldp x25, x26, [x0, #48]
    ldp x27, x28, [x0, #64]
    ldp x29, x30, [x0, #80]
    ldr x9, [x0, #96]
    mov sp, x9
    ldp d8, d9, [x0, #104]
    ldp d10, d11, [x0, #120]
    ldp d12, d13, [x0, #136]
    ldp d14, d15, [x0, #152]
    mov x0, #1
    ret
