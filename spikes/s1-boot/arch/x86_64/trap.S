// trap.S (x86_64): spike S3. An int3 gate whose entry saves the general
// registers and, with XSAVE, the vector state (ADR-0004: eagerly, before any
// Odin code), calls trap_handler, restores and returns.

	.section .text
	.global vx_int3_entry
vx_int3_entry:
	push	%rbp
	mov	%rsp, %rbp		// a frame record for the unwinder
	push	%rax
	push	%rbx
	push	%rcx
	push	%rdx
	push	%rsi
	push	%rdi
	push	%r8
	push	%r9
	push	%r10
	push	%r11
	push	%r12
	push	%r13
	push	%r14
	push	%r15
	mov	%rsp, %rbx		// the general-register frame
	sub	$4096, %rsp		// the XSAVE area: 64-byte aligned, zeroed header
	and	$~63, %rsp
	xor	%eax, %eax
	mov	%rax, 512(%rsp)
	mov	%rax, 520(%rsp)
	mov	%rax, 528(%rsp)
	mov	%rax, 536(%rsp)
	mov	%rax, 544(%rsp)
	mov	%rax, 552(%rsp)
	mov	%rax, 560(%rsp)
	mov	%rax, 568(%rsp)
	mov	$-1, %eax
	mov	$-1, %edx
	xsave	(%rsp)

	mov	%rbx, %rdi
	call	trap_handler

	mov	$-1, %eax
	mov	$-1, %edx
	xrstor	(%rsp)
	mov	%rbx, %rsp
	pop	%r15
	pop	%r14
	pop	%r13
	pop	%r12
	pop	%r11
	pop	%r10
	pop	%r9
	pop	%r8
	pop	%rdi
	pop	%rsi
	pop	%rdx
	pop	%rcx
	pop	%rbx
	pop	%rax
	pop	%rbp
	iretq

	.global vx_lidt
vx_lidt:			// (descriptor: ^[10]u8)
	lidt	(%rdi)
	ret

	.global vx_read_cs
vx_read_cs:
	mov	%cs, %ax
	movzwl	%ax, %eax
	ret

// vx_vreg_trap_test(in: 512 bytes, out: 512 bytes): ymm0-15 from `in`, an
// int3, then ymm0-15 to `out`. The registers are live across the trap.
	.global vx_vreg_trap_test
vx_vreg_trap_test:
	.irp n, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
	vmovdqu	\n*32(%rdi), %ymm\n
	.endr
	int3
	.irp n, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
	vmovdqu	%ymm\n, \n*32(%rsi)
	.endr
	vzeroupper
	ret

// Wipes every vector register: what an Odin handler is free to do.
	.global vx_clobber_vregs
vx_clobber_vregs:
	vpcmpeqd %ymm0, %ymm0, %ymm0
	.irp n, 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
	vmovdqa	%ymm0, %ymm\n
	.endr
	vzeroupper
	ret

	.section .note.GNU-stack, "", @progbits
