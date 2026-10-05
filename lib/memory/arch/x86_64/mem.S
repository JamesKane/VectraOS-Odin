// mem.S (x86_64): the four functions the compiler may call even in
// freestanding code, memcpy, memset, memmove and memcmp, for the kernel and
// every native program (upstream's vx-mem; M6 step 6c2). The build assembles
// this file into both and leaves out the Odin runtime's own (byte loops), so
// these are what Odin's copies, LLVM's calls and the native ports' C reach.
//
// memcpy and memset are the string instructions, which ERMS and FSRM make as
// fast as vector code for the sizes the kernel copies. memmove and memcmp go
// eight bytes at a time, two a round for memmove, where both pointers share
// their alignment, and by bytes at the edges and where they do not: only
// aligned words are touched. The direction flag is clear at every call
// (SysV; the kernel's trap entry clears it).

    .text

// memcpy(dst, src, n) -> dst
    .globl memcpy
    .type memcpy, @function
memcpy:
    movq %rdi, %rax
    movq %rdx, %rcx
    rep movsb
    ret
    .size memcpy, . - memcpy

// memset(dst, c, n) -> dst
    .globl memset
    .type memset, @function
memset:
    movq %rdi, %r9
    movl %esi, %eax
    movq %rdx, %rcx
    rep stosb
    movq %r9, %rax
    ret
    .size memset, . - memset

// memmove(dst, src, n) -> dst: forwards unless the destination starts inside
// the source, then backwards. Each round loads both of its words before it
// stores either, so overlapping words come out right either way.
    .globl memmove
    .type memmove, @function
memmove:
    movq %rdi, %rax
    cmpq %rsi, %rdi
    jbe 1f                 // dst <= src: forwards
    leaq (%rsi,%rdx), %rcx
    cmpq %rcx, %rdi
    jb 20f                 // dst inside [src, src + n): backwards
1:  cmpq $16, %rdx
    jb 4f
    movl %edi, %ecx
    xorl %esi, %ecx
    testb $7, %cl
    jnz 4f                 // not co-aligned: bytes
2:  testb $7, %dil         // bytes up to the alignment
    jz 3f
    movb (%rsi), %cl
    movb %cl, (%rdi)
    incq %rsi
    incq %rdi
    decq %rdx
    jmp 2b
3:  cmpq $16, %rdx
    jb 4f
    movq (%rsi), %rcx
    movq 8(%rsi), %r8
    movq %rcx, (%rdi)
    movq %r8, 8(%rdi)
    addq $16, %rsi
    addq $16, %rdi
    subq $16, %rdx
    jmp 3b
4:  testq %rdx, %rdx       // the rest, a byte at a time
    jz 9f
5:  movb (%rsi), %cl
    movb %cl, (%rdi)
    incq %rsi
    incq %rdi
    decq %rdx
    jnz 5b
9:  ret
20: addq %rdx, %rsi        // backwards, from the ends
    addq %rdx, %rdi
    cmpq $16, %rdx
    jb 24f
    movl %edi, %ecx
    xorl %esi, %ecx
    testb $7, %cl
    jnz 24f
22: testb $7, %dil
    jz 23f
    decq %rsi
    decq %rdi
    movb (%rsi), %cl
    movb %cl, (%rdi)
    decq %rdx
    jmp 22b
23: cmpq $16, %rdx
    jb 24f
    movq -8(%rsi), %rcx
    movq -16(%rsi), %r8
    movq %rcx, -8(%rdi)
    movq %r8, -16(%rdi)
    subq $16, %rsi
    subq $16, %rdi
    subq $16, %rdx
    jmp 23b
24: testq %rdx, %rdx
    jz 9b
25: decq %rsi
    decq %rdi
    movb (%rsi), %cl
    movb %cl, (%rdi)
    decq %rdx
    jnz 25b
    ret
    .size memmove, . - memmove

// memcmp(a, b, n) -> int: the first differing byte's difference, the bytes
// unsigned. The first differing word is compared by bytes.
    .globl memcmp
    .type memcmp, @function
memcmp:
    cmpq $16, %rdx
    jb 4f
    movl %edi, %ecx
    xorl %esi, %ecx
    testb $7, %cl
    jnz 4f
2:  testb $7, %dil
    jz 3f
    movzbl (%rdi), %eax
    movzbl (%rsi), %ecx
    subl %ecx, %eax
    jnz 9f
    incq %rdi
    incq %rsi
    decq %rdx
    jmp 2b
3:  cmpq $8, %rdx
    jb 4f
    movq (%rdi), %rax
    cmpq (%rsi), %rax
    jne 4f
    addq $8, %rdi
    addq $8, %rsi
    subq $8, %rdx
    jmp 3b
4:  xorl %eax, %eax
    testq %rdx, %rdx
    jz 9f
5:  movzbl (%rdi), %eax
    movzbl (%rsi), %ecx
    subl %ecx, %eax
    jnz 9f
    incq %rdi
    incq %rsi
    decq %rdx
    jnz 5b
9:  ret
    .size memcmp, . - memcmp

    .section .note.GNU-stack, "", @progbits
