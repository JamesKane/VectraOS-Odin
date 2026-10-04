// cpu.S (x86_64): instructions Odin has no way to say, one small procedure
// each (ADR-0003: clang-assembled stubs, not Odin's asm blocks). The SysV
// arguments arrive in rdi, rsi, rdx, rcx.

    .text

    .globl vx_outb
    .type vx_outb, @function
vx_outb:                   // (port: u16, value: u8)
    movw %di, %dx
    movb %sil, %al
    outb %al, %dx
    ret

    .globl vx_inb
    .type vx_inb, @function
vx_inb:                    // (port: u16) -> u8
    movw %di, %dx
    inb %dx, %al
    movzbl %al, %eax
    ret

    .globl vx_rdmsr
    .type vx_rdmsr, @function
vx_rdmsr:                  // (msr: u32) -> u64
    movl %edi, %ecx
    rdmsr
    shlq $32, %rdx
    orq %rdx, %rax
    ret

    .globl vx_wrmsr
    .type vx_wrmsr, @function
vx_wrmsr:                  // (msr: u32, value: u64)
    movl %edi, %ecx
    movl %esi, %eax
    movq %rsi, %rdx
    shrq $32, %rdx
    wrmsr
    ret

    .globl vx_cpuid
    .type vx_cpuid, @function
vx_cpuid:                  // (leaf, subleaf: u32, out: ^[4]u32)
    pushq %rbx
    movq %rdx, %r8
    movl %edi, %eax
    movl %esi, %ecx
    cpuid
    movl %eax, 0(%r8)
    movl %ebx, 4(%r8)
    movl %ecx, 8(%r8)
    movl %edx, 12(%r8)
    popq %rbx
    ret

    .globl vx_rdtsc
    .type vx_rdtsc, @function
vx_rdtsc:                  // () -> u64, ordered after earlier loads
    lfence
    rdtsc
    shlq $32, %rdx
    orq %rdx, %rax
    ret

    .globl vx_read_cr0, vx_read_cr2, vx_read_cr3, vx_read_cr4, vx_write_cr4
    .type vx_read_cr0, @function
    .type vx_read_cr2, @function
    .type vx_read_cr3, @function
    .type vx_read_cr4, @function
    .type vx_write_cr4, @function
vx_read_cr0:
    movq %cr0, %rax
    ret
vx_read_cr2:
    movq %cr2, %rax
    ret
vx_read_cr3:
    movq %cr3, %rax
    ret
vx_read_cr4:
    movq %cr4, %rax
    ret
vx_write_cr4:
    movq %rdi, %cr4
    ret

    .globl vx_read_xcr0
    .type vx_read_xcr0, @function
vx_read_xcr0:
    xorl %ecx, %ecx
    xgetbv
    shlq $32, %rdx
    orq %rdx, %rax
    ret

// (root: u64): the kernel's tables. Clearing and restoring CR4.PGE drops any
// global entries Limine left.
    .globl vx_switch_tables
    .type vx_switch_tables, @function
vx_switch_tables:
    movq %cr4, %rax
    movq %rax, %rcx
    andq $~(1 << 7), %rcx
    movq %rdi, %cr3
    movq %rcx, %cr4
    movq %rax, %cr4
    ret

    .globl vx_invlpg
    .type vx_invlpg, @function
vx_invlpg:
    invlpg (%rdi)
    ret

// (gdtr: ^Descriptor_Ptr, tss_selector: u16): loads the GDT, reloads CS with
// 0x08 and the data segments with 0x10, then the task register.
    .globl vx_load_gdt
    .type vx_load_gdt, @function
vx_load_gdt:
    lgdt (%rdi)
    pushq $0x08
    leaq 1f(%rip), %rax
    pushq %rax
    lretq
1:  movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    ltr %si
    ret

    .globl vx_load_idt
    .type vx_load_idt, @function
vx_load_idt:               // (idtr: ^Descriptor_Ptr)
    lidt (%rdi)
    ret

    .globl vx_cpu_index
    .type vx_cpu_index, @function
vx_cpu_index:              // %gs:16, the per-CPU block's index
    movq %gs:16, %rax
    ret

    .globl vx_pause
    .type vx_pause, @function
vx_pause:
    pause
    ret

// Enables interrupts for exactly one halt: sti takes effect after the next
// instruction, so an interrupt cannot slip in between and be missed.
    .globl vx_wait
    .type vx_wait, @function
vx_wait:
    sti
    hlt
    cli
    ret

    .globl vx_halt
    .type vx_halt, @function
vx_halt:
    cli
    hlt
    jmp vx_halt

    .globl vx_mfence
    .type vx_mfence, @function
vx_mfence:
    mfence
    ret

    .globl vx_write_cr3
    .type vx_write_cr3, @function
vx_write_cr3:
    movq %rdi, %cr3
    ret

// (addresses: ^[4]u64, dr7: u64): the watchpoints, DR7 off while the
// addresses change.
    .globl vx_watch_set
    .type vx_watch_set, @function
vx_watch_set:
    xorl %eax, %eax
    movq %rax, %dr7
    movq 0(%rdi), %rax
    movq %rax, %dr0
    movq 8(%rdi), %rax
    movq %rax, %dr1
    movq 16(%rdi), %rax
    movq %rax, %dr2
    movq 24(%rdi), %rax
    movq %rax, %dr3
    movq %rsi, %dr7
    ret

    .globl vx_read_dr6, vx_write_dr6
    .type vx_read_dr6, @function
    .type vx_write_dr6, @function
vx_read_dr6:
    movq %dr6, %rax
    ret
vx_write_dr6:
    movq %rdi, %dr6
    ret

// The caller's frame pointer: this procedure makes no frame of its own.
    .globl vx_frame_address
    .type vx_frame_address, @function
vx_frame_address:
    movq %rbp, %rax
    ret


// ADR-0004's test (main.odin, vx.selftest=simd): vector registers filled from
// `in` stay live while interrupts run, until *fired reaches target; then they
// go to `out`. The timer interrupt meanwhile wipes them (vx_clobber_vregs_*),
// so only the trap path's save and restore can bring them back.
// (in, out: ^[512]u8, fired: ^u64, target: u64)
    .globl vx_vreg_irq_test_avx
    .type vx_vreg_irq_test_avx, @function
vx_vreg_irq_test_avx:
    .irp n, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
    vmovdqu \n*32(%rdi), %ymm\n
    .endr
    sti
1:  movq (%rdx), %rax
    cmpq %rcx, %rax
    jb 1b
    cli
    .irp n, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
    vmovdqu %ymm\n, \n*32(%rsi)
    .endr
    vzeroupper
    ret

    .globl vx_vreg_irq_test_sse
    .type vx_vreg_irq_test_sse, @function
vx_vreg_irq_test_sse:
    .irp n, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
    movdqu \n*16(%rdi), %xmm\n
    .endr
    sti
1:  movq (%rdx), %rax
    cmpq %rcx, %rax
    jb 1b
    cli
    .irp n, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
    movdqu %xmm\n, \n*16(%rsi)
    .endr
    ret

    .globl vx_clobber_vregs_avx
    .type vx_clobber_vregs_avx, @function
vx_clobber_vregs_avx:
    vpcmpeqd %ymm0, %ymm0, %ymm0
    .irp n, 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
    vmovdqa %ymm0, %ymm\n
    .endr
    vzeroupper
    ret

    .globl vx_clobber_vregs_sse
    .type vx_clobber_vregs_sse, @function
vx_clobber_vregs_sse:
    pcmpeqd %xmm0, %xmm0
    .irp n, 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
    movdqa %xmm0, %xmm\n
    .endr
    ret

    .section .note.GNU-stack, "", @progbits
