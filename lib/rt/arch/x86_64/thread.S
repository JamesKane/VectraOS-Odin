// thread.S (x86_64): what a thread reaches only by instructions Odin cannot
// say. The thread pointer is the FS base, which the kernel keeps per thread
// and sets through thread_state; by the C library's convention its first
// word is the thread pointer itself.

    .text

// vx_thread_word() -> u64: the word the thread pointer points at, read
// through it as a C library does (%fs:0).
    .globl vx_thread_word
    .type vx_thread_word, @function
vx_thread_word:
    movq %fs:0, %rax
    ret

// vx_fp_probe_put(v: u64, ctl: u32) and vx_fp_probe_get(ctl: ^u32) -> u64:
// a vector register and the FP control register (all of ymm7 and MXCSR), for
// ktest's check that the kernel keeps each thread's FP/SIMD state. ymm7's
// four lanes are v and three of its own (~v, v ^ 0x5555..., v + 1), its upper
// half AVX's, which XSAVE keeps (ADR-0035), so a lane lost or mixed with
// another thread's shows: get returns v, or 0 for a register that is all
// zero (a new thread's), and 0xbad0bad0bad0bad0 for any other. ymm7 is
// caller-saved and Odin's code between a put and a get has no reason to use
// it, so what a get finds is what the kernel kept.
    .globl vx_fp_probe_put
    .type vx_fp_probe_put, @function
vx_fp_probe_put:
    movq %rdi, -40(%rsp)
    movq %rdi, %rax
    notq %rax
    movq %rax, -32(%rsp)
    movabsq $0x5555555555555555, %rax
    xorq %rdi, %rax
    movq %rax, -24(%rsp)
    leaq 1(%rdi), %rax
    movq %rax, -16(%rsp)
    vmovdqu -40(%rsp), %ymm7
    movl %esi, -4(%rsp)
    ldmxcsr -4(%rsp)
    ret

    .globl vx_fp_probe_get
    .type vx_fp_probe_get, @function
vx_fp_probe_get:
    stmxcsr -4(%rsp)
    movl -4(%rsp), %eax
    movl %eax, (%rdi)
    vmovdqu %ymm7, -40(%rsp)
    movq -40(%rsp), %rax       // lane 0: v
    movq -32(%rsp), %rcx
    orq -24(%rsp), %rcx
    orq -16(%rsp), %rcx
    orq %rax, %rcx
    jz 2f                      // all zero: a new thread's
    movq %rax, %rdx
    notq %rdx
    cmpq -32(%rsp), %rdx
    jne 1f
    movabsq $0x5555555555555555, %rdx
    xorq %rax, %rdx
    cmpq -24(%rsp), %rdx
    jne 1f
    leaq 1(%rax), %rdx
    cmpq -16(%rsp), %rdx
    je 2f
1:  movabsq $0xbad0bad0bad0bad0, %rax
2:  ret

// vx_rdpkru() -> u32 and vx_wrpkru(v: u32): the thread's protection-key
// rights (PKRU, ADR-0035), unprivileged where the kernel set CR4.PKE.
    .globl vx_rdpkru
    .type vx_rdpkru, @function
vx_rdpkru:
    xorl %ecx, %ecx
    rdpkru
    ret

    .globl vx_wrpkru
    .type vx_wrpkru, @function
vx_wrpkru:
    movl %edi, %eax
    xorl %ecx, %ecx
    xorl %edx, %edx
    wrpkru
    ret

// vx_cycles() -> u64: the cycle counter the clock is made from, which user
// code may always read.
    .globl vx_cycles
    .type vx_cycles, @function
vx_cycles:                 // () -> u64
    rdtsc
    shlq $32, %rdx
    orq %rdx, %rax
    ret

    .section .note.GNU-stack, "", @progbits
