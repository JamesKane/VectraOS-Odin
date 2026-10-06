// note.S (aarch64): the in-task exception handler a program's notify
// installs (note.odin). The kernel starts it with the Exception it put on
// the stack in x0, and sp just below it. It saves the FP/SIMD registers,
// which the kernel does not put in an Exception, before any Odin runs:
// q0-q31, FPCR and FPSR. Then vx_note_dispatch, and vx_note_resume, which
// does not return.

    .text
    .globl vx_note_entry
    .hidden vx_note_entry
    .type vx_note_entry, %function
vx_note_entry:
    mov x19, x0             // the Exception, kept across the calls
    sub sp, sp, #528
    stp q0, q1, [sp, #0]
    stp q2, q3, [sp, #32]
    stp q4, q5, [sp, #64]
    stp q6, q7, [sp, #96]
    stp q8, q9, [sp, #128]
    stp q10, q11, [sp, #160]
    stp q12, q13, [sp, #192]
    stp q14, q15, [sp, #224]
    stp q16, q17, [sp, #256]
    stp q18, q19, [sp, #288]
    stp q20, q21, [sp, #320]
    stp q22, q23, [sp, #352]
    stp q24, q25, [sp, #384]
    stp q26, q27, [sp, #416]
    stp q28, q29, [sp, #448]
    stp q30, q31, [sp, #480]
    mrs x9, fpcr
    mrs x10, fpsr
    add x11, sp, #512
    stp x9, x10, [x11]
    mov x0, x19
    mov x1, sp              // the saved state, a vx.Fpregs: the handler's fp
    bl vx_note_dispatch
    ldp q0, q1, [sp, #0]
    ldp q2, q3, [sp, #32]
    ldp q4, q5, [sp, #64]
    ldp q6, q7, [sp, #96]
    ldp q8, q9, [sp, #128]
    ldp q10, q11, [sp, #160]
    ldp q12, q13, [sp, #192]
    ldp q14, q15, [sp, #224]
    ldp q16, q17, [sp, #256]
    ldp q18, q19, [sp, #288]
    ldp q20, q21, [sp, #320]
    ldp q22, q23, [sp, #352]
    ldp q24, q25, [sp, #384]
    ldp q26, q27, [sp, #416]
    ldp q28, q29, [sp, #448]
    ldp q30, q31, [sp, #480]
    add x11, sp, #512
    ldp x9, x10, [x11]
    msr fpcr, x9
    msr fpsr, x10
    mov x0, x19
    bl vx_note_resume
    brk #0
