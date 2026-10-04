// entry.S (x86_64): Limine enters _start in long mode with its own page tables
// and stack. Before any Odin code runs, FP and SIMD are enabled (ADR-0004).

	.section .text
	.global _start
_start:
	cli
	lea	vx_boot_stack_top(%rip), %rsp
	xor	%ebp, %ebp

	// CR0: clear EM (2), set MP (1), clear TS (3).
	mov	%cr0, %rax
	and	$~((1 << 2) | (1 << 3)), %rax
	or	$(1 << 1), %rax
	mov	%rax, %cr0

	// CR4: OSFXSR (9), OSXMMEXCPT (10).
	mov	%cr4, %rax
	or	$((1 << 9) | (1 << 10)), %rax
	mov	%rax, %cr4

	// XSAVE (CPUID.1:ECX.26) -> CR4.OSXSAVE (18), then XCR0 = x87 | SSE,
	// plus AVX (CPUID.1:ECX.28) when present.
	mov	$1, %eax
	cpuid
	bt	$26, %ecx
	jnc	1f
	mov	%ecx, %esi
	mov	%cr4, %rax
	or	$(1 << 18), %rax
	mov	%rax, %cr4
	mov	$3, %eax
	bt	$28, %esi
	jnc	2f
	or	$4, %eax
2:	xor	%edx, %edx
	xor	%ecx, %ecx
	xsetbv
1:
	fninit
	call	kmain
3:	hlt
	jmp	3b

	.global vx_outb
vx_outb:			// (port: u16, value: u8)
	mov	%di, %dx
	mov	%sil, %al
	outb	%al, %dx
	ret

	.global vx_inb
vx_inb:				// (port: u16) -> u8
	mov	%di, %dx
	inb	%dx, %al
	movzbl	%al, %eax
	ret

	.global vx_read_cr0
vx_read_cr0:
	mov	%cr0, %rax
	ret

	.global vx_read_cr4
vx_read_cr4:
	mov	%cr4, %rax
	ret

	.global vx_read_xcr0
vx_read_xcr0:
	xor	%ecx, %ecx
	xgetbv
	shl	$32, %rdx
	or	%rdx, %rax
	ret

	.section .note.GNU-stack, "", @progbits
