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
// a vector register and the FP control register (xmm7 and MXCSR), for
// ktest's check that the kernel keeps each thread's FP/SIMD state. xmm7 is
// caller-saved and Odin's code between a put and a get has no reason to use
// it, so what a get finds is what the kernel kept.
    .globl vx_fp_probe_put
    .type vx_fp_probe_put, @function
vx_fp_probe_put:
    movq %rdi, %xmm7
    movl %esi, -4(%rsp)
    ldmxcsr -4(%rsp)
    ret

    .globl vx_fp_probe_get
    .type vx_fp_probe_get, @function
vx_fp_probe_get:
    stmxcsr -4(%rsp)
    movl -4(%rsp), %eax
    movl %eax, (%rdi)
    movq %xmm7, %rax
    ret

    .section .note.GNU-stack, "", @progbits
