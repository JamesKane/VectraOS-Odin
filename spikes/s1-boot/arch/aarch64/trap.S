// trap.S (aarch64): spike S3. An exception vector table whose synchronous,
// current-EL entry saves the general and vector registers (ADR-0004: eagerly,
// before any Odin code), calls trap_handler, restores and returns.

	.section .text
	.balign 2048
	.global vx_vectors
vx_vectors:
	.rept 4			// current EL with SP_EL0: unused
	.balign 128
	b	.
	.endr
	.balign 128		// current EL with SP_ELx, synchronous
	b	vx_sync_entry
	.rept 3
	.balign 128
	b	.
	.endr
	.rept 8			// lower EL: unused in the spike
	.balign 128
	b	.
	.endr

// Frame: x0-x30, elr, spsr (34 slots, 272 bytes), then q0-q31 (512), fpcr, fpsr.
	FRAME = 272 + 512 + 16
vx_sync_entry:
	sub	sp, sp, #FRAME
	stp	x0, x1, [sp, #0]
	stp	x2, x3, [sp, #16]
	stp	x4, x5, [sp, #32]
	stp	x6, x7, [sp, #48]
	stp	x8, x9, [sp, #64]
	stp	x10, x11, [sp, #80]
	stp	x12, x13, [sp, #96]
	stp	x14, x15, [sp, #112]
	stp	x16, x17, [sp, #128]
	stp	x18, x19, [sp, #144]
	stp	x20, x21, [sp, #160]
	stp	x22, x23, [sp, #176]
	stp	x24, x25, [sp, #192]
	stp	x26, x27, [sp, #208]
	stp	x28, x29, [sp, #224]
	mrs	x0, elr_el1
	mrs	x1, spsr_el1
	stp	x30, x0, [sp, #240]
	str	x1, [sp, #256]
	add	x0, sp, #272
	stp	q0, q1, [x0, #0]
	stp	q2, q3, [x0, #32]
	stp	q4, q5, [x0, #64]
	stp	q6, q7, [x0, #96]
	stp	q8, q9, [x0, #128]
	stp	q10, q11, [x0, #160]
	stp	q12, q13, [x0, #192]
	stp	q14, q15, [x0, #224]
	stp	q16, q17, [x0, #256]
	stp	q18, q19, [x0, #288]
	stp	q20, q21, [x0, #320]
	stp	q22, q23, [x0, #352]
	stp	q24, q25, [x0, #384]
	stp	q26, q27, [x0, #416]
	stp	q28, q29, [x0, #448]
	stp	q30, q31, [x0, #480]
	mrs	x1, fpcr
	mrs	x2, fpsr
	add	x3, x0, #512
	stp	x1, x2, [x3]

	mov	x29, sp			// a frame record chain for the unwinder
	mov	x0, sp
	bl	trap_handler

	add	x0, sp, #272
	add	x3, x0, #512
	ldp	x1, x2, [x3]
	msr	fpcr, x1
	msr	fpsr, x2
	ldp	q0, q1, [x0, #0]
	ldp	q2, q3, [x0, #32]
	ldp	q4, q5, [x0, #64]
	ldp	q6, q7, [x0, #96]
	ldp	q8, q9, [x0, #128]
	ldp	q10, q11, [x0, #160]
	ldp	q12, q13, [x0, #192]
	ldp	q14, q15, [x0, #224]
	ldp	q16, q17, [x0, #256]
	ldp	q18, q19, [x0, #288]
	ldp	q20, q21, [x0, #320]
	ldp	q22, q23, [x0, #352]
	ldp	q24, q25, [x0, #384]
	ldp	q26, q27, [x0, #416]
	ldp	q28, q29, [x0, #448]
	ldp	q30, q31, [x0, #480]
	ldp	x30, x0, [sp, #240]
	ldr	x1, [sp, #256]
	msr	elr_el1, x0
	msr	spsr_el1, x1
	ldp	x0, x1, [sp, #0]
	ldp	x2, x3, [sp, #16]
	ldp	x4, x5, [sp, #32]
	ldp	x6, x7, [sp, #48]
	ldp	x8, x9, [sp, #64]
	ldp	x10, x11, [sp, #80]
	ldp	x12, x13, [sp, #96]
	ldp	x14, x15, [sp, #112]
	ldp	x16, x17, [sp, #128]
	ldp	x18, x19, [sp, #144]
	ldp	x20, x21, [sp, #160]
	ldp	x22, x23, [sp, #176]
	ldp	x24, x25, [sp, #192]
	ldp	x26, x27, [sp, #208]
	ldp	x28, x29, [sp, #224]
	add	sp, sp, #FRAME
	eret

	.global vx_install_vectors
vx_install_vectors:
	adrp	x0, vx_vectors
	add	x0, x0, :lo12:vx_vectors
	msr	vbar_el1, x0
	isb
	ret

// vx_vreg_trap_test(in: 512 bytes, out: 512 bytes): q0-q31 from `in`, a trap,
// then q0-q31 to `out`. The registers are live across the brk.
	.global vx_vreg_trap_test
vx_vreg_trap_test:
	ldp	q0, q1, [x0, #0]
	ldp	q2, q3, [x0, #32]
	ldp	q4, q5, [x0, #64]
	ldp	q6, q7, [x0, #96]
	ldp	q8, q9, [x0, #128]
	ldp	q10, q11, [x0, #160]
	ldp	q12, q13, [x0, #192]
	ldp	q14, q15, [x0, #224]
	ldp	q16, q17, [x0, #256]
	ldp	q18, q19, [x0, #288]
	ldp	q20, q21, [x0, #320]
	ldp	q22, q23, [x0, #352]
	ldp	q24, q25, [x0, #384]
	ldp	q26, q27, [x0, #416]
	ldp	q28, q29, [x0, #448]
	ldp	q30, q31, [x0, #480]
	brk	#0x5c
	stp	q0, q1, [x1, #0]
	stp	q2, q3, [x1, #32]
	stp	q4, q5, [x1, #64]
	stp	q6, q7, [x1, #96]
	stp	q8, q9, [x1, #128]
	stp	q10, q11, [x1, #160]
	stp	q12, q13, [x1, #192]
	stp	q14, q15, [x1, #224]
	stp	q16, q17, [x1, #256]
	stp	q18, q19, [x1, #288]
	stp	q20, q21, [x1, #320]
	stp	q22, q23, [x1, #352]
	stp	q24, q25, [x1, #384]
	stp	q26, q27, [x1, #416]
	stp	q28, q29, [x1, #448]
	stp	q30, q31, [x1, #480]
	ret

// Wipes every vector register: what an Odin handler is free to do.
	.global vx_clobber_vregs
vx_clobber_vregs:
	.irp n, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
	movi	v\n\().2d, #0xffffffffffffffff
	.endr
	ret

	.global vx_read_esr
vx_read_esr:
	mrs	x0, esr_el1
	ret
