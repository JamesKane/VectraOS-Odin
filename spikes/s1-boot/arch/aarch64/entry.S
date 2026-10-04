// entry.S (aarch64): Limine enters _start at EL1 with its own page tables
// and stack. Before any Odin code runs, FP and SIMD are enabled (ADR-0004).

	.section .text
	.global _start
_start:
	msr	daifset, #0xf
	msr	spsel, #1		// the kernel runs on SP_EL1; SP_EL0 is user space's
	adrp	x0, vx_boot_stack_top
	add	x0, x0, :lo12:vx_boot_stack_top
	mov	sp, x0
	mov	x29, xzr
	mov	x30, xzr

	// CPACR_EL1.FPEN = 0b11: no trap on FP or SIMD at EL0 or EL1.
	mrs	x0, cpacr_el1
	orr	x0, x0, #(3 << 20)
	msr	cpacr_el1, x0
	isb

	bl	kmain
1:	wfi
	b	1b

	.global vx_read_ttbr1
vx_read_ttbr1:
	mrs	x0, ttbr1_el1
	ret

	.global vx_read_mair
vx_read_mair:
	mrs	x0, mair_el1
	ret

	.global vx_write_mair
vx_write_mair:
	msr	mair_el1, x0
	isb
	ret

	.global vx_read_cpacr
vx_read_cpacr:
	mrs	x0, cpacr_el1
	ret

	.global vx_dsb_isb
vx_dsb_isb:
	dsb	ish
	isb
	ret
