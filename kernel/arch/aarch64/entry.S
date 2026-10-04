// entry.S (aarch64): the kernel's entry points and the exception vectors.
//
// FP and SIMD are enabled before any Odin code runs, on every CPU, and every
// exception saves the interrupted context's vector state (q0-q31, FPCR, FPSR)
// in its frame before Odin's trap handler runs, and restores it after
// (ADR-0004): Odin's code uses NEON registers anywhere, the kernel's included.
//
// Each of the 16 vector entries reserves a frame on the stack, saves x0 and
// x1, puts its own index in x1 and branches to trap_common. That saves the
// rest: the general registers, ELR, SPSR, ESR, FAR and SP_EL0 (Trap_Frame in
// arch_arm64.odin), then the vector state above them, and calls
// aarch64_trap(frame, index).

#define GP_FRAME 288                // Trap_Frame
#define FP_AREA (32 * 16 + 16)      // q0-q31, FPCR, FPSR
#define FRAME_SIZE (GP_FRAME + FP_AREA)

.macro ENABLE_SIMD
    mrs x9, cpacr_el1
    orr x9, x9, #(3 << 20)          // FPEN: no trap on FP or SIMD at EL0 or EL1
    msr cpacr_el1, x9
    isb
.endm

    .text

// Limine enters here at EL1 with its own tables and stack, and SPSel 0. The
// kernel runs on SP_EL1 (SP_EL0 is user space's), moves to its boot stack,
// ends the frame chain so backtraces stop here, and never returns.
    .globl _start
    .type _start, %function
_start:
    msr daifset, #0xf
    msr spsel, #1
    adrp x0, vx_boot_stack_top
    add x0, x0, :lo12:vx_boot_stack_top
    mov sp, x0
    mov x29, xzr
    mov x30, xzr
    ENABLE_SIMD
    bl kernel_main
    brk #0

// Limine starts each other CPU here, with its limine_mp_info in x0. Its idle
// stack is in the kernel stack region, which only the kernel's tables map: it
// loads them first. smp.odin left the top of the stack in extra_argument
// (offset 32), with the CPU's index just above it.
    .globl ap_start
    .type ap_start, %function
ap_start:
    msr daifset, #0xf
    msr spsel, #1
    adrp x1, ap_park_tables
    add x1, x1, :lo12:ap_park_tables
    ldp x2, x3, [x1]
    dsb ish
    msr ttbr1_el1, x2
    msr ttbr0_el1, x3
    isb
    tlbi vmalle1
    dsb ish
    isb
    ldr x1, [x0, #32]
    mov sp, x1
    mov x29, xzr
    mov x30, xzr
    ENABLE_SIMD
    ldr x0, [sp, #8]
    bl ap_main
    brk #0

// A CPU past MAX_CPUS: onto the kernel's tables, as Limine's are about to be
// reclaimed, and halted for good.
    .globl ap_park
    .type ap_park, %function
ap_park:
    msr daifset, #0xf
    adrp x1, ap_park_tables
    add x1, x1, :lo12:ap_park_tables
    ldp x2, x3, [x1]
    dsb ish
    msr ttbr1_el1, x2
    msr ttbr0_el1, x3
    isb
    tlbi vmalle1
    dsb ish
    isb
1:  wfe
    b 1b

// run_on_stack(top, fn): fn on a new stack, with the frame chain ended.
    .globl vx_run_on_stack
    .type vx_run_on_stack, %function
vx_run_on_stack:
    mov sp, x0
    mov x29, xzr
    blr x1
    brk #0

.macro ENTRY index
    .p2align 7
    sub sp, sp, #FRAME_SIZE
    stp x0, x1, [sp, #0]
    mov x1, #\index
    b trap_common
.endm

// An exception taken in the kernel checks its stack before pushing anything: a
// kernel stack is the top half of a 32 KiB slot (kstack.odin), so a stack
// pointer in it has bit 14 set, and one that has overflowed into the guard
// below has it clear. Pushing there would fault again, for ever. The check
// trades x0 against sp to have a register free, and trades back if all is well.
.macro ENTRY_KERNEL index
    .p2align 7
    sub sp, sp, #FRAME_SIZE
    add sp, sp, x0          // sp = sp' + x0
    sub x0, sp, x0          // x0 = sp'
    tbz x0, #14, kernel_stack_overflow
    sub x0, sp, x0          // x0 = x0 again
    sub sp, sp, x0          // sp = sp' again
    stp x0, x1, [sp, #0]
    mov x1, #\index
    b trap_common
.endm

    .p2align 11
    .globl aarch64_vectors
aarch64_vectors:
    ENTRY 0         // current EL, SP0: synchronous
    ENTRY 1         //                  IRQ
    ENTRY 2         //                  FIQ
    ENTRY 3         //                  SError
    ENTRY_KERNEL 4  // current EL, SPx: synchronous
    ENTRY_KERNEL 5  //                  IRQ
    ENTRY_KERNEL 6  //                  FIQ
    ENTRY_KERNEL 7  //                  SError
    ENTRY 8         // lower EL, AArch64: synchronous
    ENTRY 9         //                    IRQ
    ENTRY 10        //                    FIQ
    ENTRY 11        //                    SError
    ENTRY 12        // lower EL, AArch32 (never used)
    ENTRY 13
    ENTRY 14
    ENTRY 15

// x0: the stack pointer the frame would have gone to. On a stack of its own,
// the kernel says what happened and stops (arch_arm64.odin).
kernel_stack_overflow:
    adrp x1, overflow_stack_top
    add x1, x1, :lo12:overflow_stack_top
    mov sp, x1
    mov x29, xzr
    bl aarch64_kernel_stack_fault
    brk #0

trap_common:
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]
    stp x8, x9, [sp, #64]
    stp x10, x11, [sp, #80]
    stp x12, x13, [sp, #96]
    stp x14, x15, [sp, #112]
    stp x16, x17, [sp, #128]
    stp x18, x19, [sp, #144]
    stp x20, x21, [sp, #160]
    stp x22, x23, [sp, #176]
    stp x24, x25, [sp, #192]
    stp x26, x27, [sp, #208]
    stp x28, x29, [sp, #224]
    str x30, [sp, #240]
    mrs x2, elr_el1
    mrs x3, spsr_el1
    stp x2, x3, [sp, #248]
    mrs x2, esr_el1
    mrs x3, far_el1
    stp x2, x3, [sp, #264]
    mrs x2, sp_el0
    str x2, [sp, #280]
    add x2, sp, #GP_FRAME
    stp q0, q1, [x2, #0]
    stp q2, q3, [x2, #32]
    stp q4, q5, [x2, #64]
    stp q6, q7, [x2, #96]
    stp q8, q9, [x2, #128]
    stp q10, q11, [x2, #160]
    stp q12, q13, [x2, #192]
    stp q14, q15, [x2, #224]
    stp q16, q17, [x2, #256]
    stp q18, q19, [x2, #288]
    stp q20, q21, [x2, #320]
    stp q22, q23, [x2, #352]
    stp q24, q25, [x2, #384]
    stp q26, q27, [x2, #416]
    stp q28, q29, [x2, #448]
    stp q30, q31, [x2, #480]
    mrs x3, fpcr
    mrs x4, fpsr
    add x2, x2, #512
    stp x3, x4, [x2]
    mov x0, sp
    bl aarch64_trap
    .globl trap_restore
    .type trap_restore, %function
trap_restore:
    add x2, sp, #GP_FRAME
    ldp q0, q1, [x2, #0]
    ldp q2, q3, [x2, #32]
    ldp q4, q5, [x2, #64]
    ldp q6, q7, [x2, #96]
    ldp q8, q9, [x2, #128]
    ldp q10, q11, [x2, #160]
    ldp q12, q13, [x2, #192]
    ldp q14, q15, [x2, #224]
    ldp q16, q17, [x2, #256]
    ldp q18, q19, [x2, #288]
    ldp q20, q21, [x2, #320]
    ldp q22, q23, [x2, #352]
    ldp q24, q25, [x2, #384]
    ldp q26, q27, [x2, #416]
    ldp q28, q29, [x2, #448]
    ldp q30, q31, [x2, #480]
    add x2, x2, #512
    ldp x3, x4, [x2]
    msr fpcr, x3
    msr fpsr, x4
    ldr x2, [sp, #280]
    msr sp_el0, x2
    ldp x2, x3, [sp, #248]
    msr elr_el1, x2
    msr spsr_el1, x3
    ldp x2, x3, [sp, #16]
    ldp x4, x5, [sp, #32]
    ldp x6, x7, [sp, #48]
    ldp x8, x9, [sp, #64]
    ldp x10, x11, [sp, #80]
    ldp x12, x13, [sp, #96]
    ldp x14, x15, [sp, #112]
    ldp x16, x17, [sp, #128]
    ldp x18, x19, [sp, #144]
    ldp x20, x21, [sp, #160]
    ldp x22, x23, [sp, #176]
    ldp x24, x25, [sp, #192]
    ldp x26, x27, [sp, #208]
    ldp x28, x29, [sp, #224]
    ldr x30, [sp, #240]
    ldp x0, x1, [sp, #0]
    add sp, sp, #FRAME_SIZE
    eret

    .bss
    .p2align 4
overflow_stack:
    .skip 8192
overflow_stack_top:
