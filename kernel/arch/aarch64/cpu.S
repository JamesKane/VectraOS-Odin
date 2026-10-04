// cpu.S (aarch64): instructions Odin has no way to say, one small procedure
// each (ADR-0003: clang-assembled stubs, not Odin's asm blocks).

    .arch armv8.1-a
    .text

.macro READ name, reg
    .globl vx_read_\name
    .type vx_read_\name, %function
vx_read_\name:
    mrs x0, \reg
    ret
.endm

.macro WRITE name, reg
    .globl vx_write_\name
    .type vx_write_\name, %function
vx_write_\name:
    msr \reg, x0
    isb
    ret
.endm

    READ ttbr1, ttbr1_el1
    READ mair, mair_el1
    WRITE mair, mair_el1
    READ tpidr_el1, tpidr_el1
    READ cntfrq, cntfrq_el0
    READ mpidr, mpidr_el1
    READ current_el, CurrentEL
    READ elr, elr_el1
    READ esr, esr_el1
    READ far, far_el1
    READ icc_iar1, icc_iar1_el1

    .globl vx_read_cntvct
    .type vx_read_cntvct, %function
vx_read_cntvct:            // ordered after earlier instructions
    isb
    mrs x0, cntvct_el0
    ret

// (vectors, index: u64): VBAR_EL1, and this CPU's index in TPIDR_EL1.
    .globl vx_cpu_set
    .type vx_cpu_set, %function
vx_cpu_set:
    msr vbar_el1, x0
    msr tpidr_el1, x1
    isb
    ret

// (ttbr1, ttbr0: u64): the kernel's tables and an empty user half, then every
// cached translation dropped.
    .globl vx_switch_tables
    .type vx_switch_tables, %function
vx_switch_tables:
    dsb ishst
    msr ttbr1_el1, x0
    msr ttbr0_el1, x1
    isb
    tlbi vmalle1
    dsb ish
    isb
    ret

// A descriptor written by a store is only certain to be seen by the table
// walker after a DSB, and by this CPU's later instructions after an ISB.
    .globl vx_pte_publish
    .type vx_pte_publish, %function
vx_pte_publish:
    dsb ishst
    isb
    ret

    .globl vx_timer_arm
    .type vx_timer_arm, %function
vx_timer_arm:              // (count: u64): enabled, not masked
    msr cntv_cval_el0, x0
    mov x1, #1
    msr cntv_ctl_el0, x1
    isb
    ret

    .globl vx_timer_disarm
    .type vx_timer_disarm, %function
vx_timer_disarm:
    msr cntv_ctl_el0, xzr
    isb
    ret

// The GICv3 CPU interface, through system registers: enabled, every priority
// let through, group 1 on.
    .globl vx_gic_cpu_init
    .type vx_gic_cpu_init, %function
vx_gic_cpu_init:
    mrs x0, icc_sre_el1
    orr x0, x0, #1
    msr icc_sre_el1, x0
    isb
    mov x0, #0xff
    msr icc_pmr_el1, x0
    msr icc_bpr1_el1, xzr
    mov x0, #1
    msr icc_igrpen1_el1, x0
    isb
    ret

    .globl vx_write_icc_eoir1
    .type vx_write_icc_eoir1, %function
vx_write_icc_eoir1:
    msr icc_eoir1_el1, x0
    ret

// wfi wakes on a pending interrupt even while IRQs are masked; unmasking for
// a moment then takes it.
    .globl vx_wait
    .type vx_wait, %function
vx_wait:
    wfi
    msr daifclr, #2
    isb
    msr daifset, #2
    ret

    .globl vx_halt
    .type vx_halt, %function
vx_halt:
    msr daifset, #0xf
    wfi
    b vx_halt

    .globl vx_pause
    .type vx_pause, %function
vx_pause:
    yield
    ret

// The caller's frame pointer: this procedure makes no frame of its own.
    .globl vx_frame_address
    .type vx_frame_address, %function
vx_frame_address:
    mov x0, x29
    ret

// ADR-0004's test (main.odin, vx.selftest=simd): q0-q31 filled from `in` stay
// live while interrupts run, until *fired reaches target; then they go to
// `out`. The timer interrupt meanwhile wipes them (vx_clobber_vregs), so only
// the trap path's save and restore can bring them back.
// (in, out: ^[512]u8, fired: ^u64, target: u64)
    .globl vx_vreg_irq_test
    .type vx_vreg_irq_test, %function
vx_vreg_irq_test:
    ldp q0, q1, [x0, #0]
    ldp q2, q3, [x0, #32]
    ldp q4, q5, [x0, #64]
    ldp q6, q7, [x0, #96]
    ldp q8, q9, [x0, #128]
    ldp q10, q11, [x0, #160]
    ldp q12, q13, [x0, #192]
    ldp q14, q15, [x0, #224]
    ldp q16, q17, [x0, #256]
    ldp q18, q19, [x0, #288]
    ldp q20, q21, [x0, #320]
    ldp q22, q23, [x0, #352]
    ldp q24, q25, [x0, #384]
    ldp q26, q27, [x0, #416]
    ldp q28, q29, [x0, #448]
    ldp q30, q31, [x0, #480]
    msr daifclr, #2
1:  ldar x4, [x2]
    cmp x4, x3
    b.lo 1b
    msr daifset, #2
    stp q0, q1, [x1, #0]
    stp q2, q3, [x1, #32]
    stp q4, q5, [x1, #64]
    stp q6, q7, [x1, #96]
    stp q8, q9, [x1, #128]
    stp q10, q11, [x1, #160]
    stp q12, q13, [x1, #192]
    stp q14, q15, [x1, #224]
    stp q16, q17, [x1, #256]
    stp q18, q19, [x1, #288]
    stp q20, q21, [x1, #320]
    stp q22, q23, [x1, #352]
    stp q24, q25, [x1, #384]
    stp q26, q27, [x1, #416]
    stp q28, q29, [x1, #448]
    stp q30, q31, [x1, #480]
    ret

    .globl vx_clobber_vregs
    .type vx_clobber_vregs, %function
vx_clobber_vregs:
    .irp n, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    movi v\n\().2d, #0xffffffffffffffff
    .endr
    ret

// (root: u64): the user half's tables in TTBR0, every cached translation
// dropped (no ASIDs yet).
    .globl vx_switch_user_root
    .type vx_switch_user_root, %function
vx_switch_user_root:
    msr ttbr0_el1, x0
    isb
    tlbi vmalle1
    dsb ish
    isb
    ret

    .globl vx_write_icc_sgi1r
    .type vx_write_icc_sgi1r, %function
vx_write_icc_sgi1r:
    msr icc_sgi1r_el1, x0
    isb
    ret

// The kernel reaches user memory directly (syscall.odin's checked copies):
// SCTLR_EL1.SPAN set, so taking an exception never sets PSTATE.PAN, and PAN
// cleared now.
    .globl vx_pan_off
    .type vx_pan_off, %function
vx_pan_off:
    mrs x0, sctlr_el1
    orr x0, x0, #(1 << 23)
    msr sctlr_el1, x0
    msr pan, #0
    isb
    ret
