// entry.S (x86_64): the kernel's entry points, the trap path and the context
// switch's stack moves.
//
// FP and SIMD are enabled before any Odin code runs, on every CPU, and every
// trap saves the interrupted context's vector state with XSAVE before Odin's
// trap handler runs, and restores it after (ADR-0004): Odin's code uses SSE
// registers anywhere, the kernel's included.
//
// Each of the 256 vectors has a stub that pushes a zero error code if the CPU
// did not push one, then the vector number. trap_entry swaps GS if the trap
// came from user mode, pushes the general registers so the stack holds a
// Trap_Frame (arch_amd64.odin), saves the vector state below it, 64-byte
// aligned, and calls x86_trap.

#define HAS_ERROR_CODE(v) ((v) == 8 || ((v) >= 10 && (v) <= 14) || (v) == 17 || (v) == 21 || (v) == 29 || (v) == 30)

// CR0: MP (1) and NE (5) and WP (16) on; EM (2) and TS (3) off. CR4: OSFXSR
// (9), OSXMMEXCPT (10) and OSXSAVE (18). XCR0: x87, SSE and, when the CPU
// has it, AVX. The kernel requires XSAVE (arch_amd64.odin checks).
.macro ENABLE_SIMD
    mov %cr0, %rax
    and $~((1 << 2) | (1 << 3)), %rax
    or $((1 << 1) | (1 << 5) | (1 << 16)), %rax
    mov %rax, %cr0
    mov $1, %eax
    cpuid
    mov %ecx, %esi
    mov %cr4, %rax
    or $((1 << 9) | (1 << 10)), %rax
    bt $26, %esi
    jnc 1f
    or $(1 << 18), %rax
1:  mov %rax, %cr4
    bt $26, %esi
    jnc 3f
    mov $3, %eax
    bt $28, %esi
    jnc 2f
    or $4, %eax
2:  xor %edx, %edx
    xor %ecx, %ecx
    xsetbv
3:  fninit
.endm

    .text

// Limine enters here in long mode, with the higher half mapped, on a stack of
// its own. The kernel moves to its boot stack (the linker script), clears the
// frame pointer so backtraces end here, and never returns.
    .globl _start
    .type _start, @function
_start:
    cli
    leaq vx_boot_stack_top(%rip), %rsp
    xorl %ebp, %ebp
    ENABLE_SIMD
    call kernel_main
    ud2

// Limine starts each other CPU here, with its limine_mp_info in rdi. Its idle
// stack is in the kernel stack region, which only the kernel's tables map:
// it loads them first. smp.odin left the top of the stack in extra_argument
// (offset 24), with the CPU's index just above it.
    .globl ap_start
    .type ap_start, @function
ap_start:
    cli
    movq ap_park_tables(%rip), %rax
    movq %rax, %cr3
    movq 24(%rdi), %rsp
    xorl %ebp, %ebp
    ENABLE_SIMD
    movq 8(%rsp), %rdi
    call ap_main
    ud2

// A CPU past MAX_CPUS: onto the kernel's tables, as Limine's are about to be
// reclaimed, and halted for good.
    .globl ap_park
    .type ap_park, @function
ap_park:
    cli
    movq ap_park_tables(%rip), %rax
    movq %rax, %cr3
1:  hlt
    jmp 1b

// run_on_stack(top, fn): fn on a new stack, with the frame chain ended.
    .globl vx_run_on_stack
    .type vx_run_on_stack, @function
vx_run_on_stack:
    movq %rdi, %rsp
    xorl %ebp, %ebp
    call *%rsi
    ud2

.altmacro

.macro STUB v
    .p2align 4
vector_\v:
    .if !HAS_ERROR_CODE(\v)
    pushq $0
    .endif
    pushq $\v
    jmp trap_entry
.endm

.macro TABLE_ENTRY v
    .quad vector_\v
.endm

trap_entry:
    testb $3, 24(%rsp)     // the saved CS: was the CPU in user mode?
    jz 1f
    swapgs
1:  pushq %r15
    pushq %r14
    pushq %r13
    pushq %r12
    pushq %r11
    pushq %r10
    pushq %r9
    pushq %r8
    pushq %rbp
    pushq %rdi
    pushq %rsi
    pushq %rdx
    pushq %rcx
    pushq %rbx
    pushq %rax
    cld
    movq %rsp, %rbx        // the frame; rbx is callee-saved, so it survives x86_trap
    subq vx_xsave_size(%rip), %rsp
    andq $~63, %rsp
    xorl %eax, %eax        // XSAVE needs a zeroed header (bytes 512-575)
    movq %rax, 512(%rsp)
    movq %rax, 520(%rsp)
    movq %rax, 528(%rsp)
    movq %rax, 536(%rsp)
    movq %rax, 544(%rsp)
    movq %rax, 552(%rsp)
    movq %rax, 560(%rsp)
    movq %rax, 568(%rsp)
    movl $-1, %eax
    movl $-1, %edx
    xsave64 (%rsp)
    movq %rbx, %rdi
    call x86_trap
    movl $-1, %eax
    movl $-1, %edx
    xrstor64 (%rsp)
    movq %rbx, %rsp
    popq %rax
    popq %rbx
    popq %rcx
    popq %rdx
    popq %rsi
    popq %rdi
    popq %rbp
    popq %r8
    popq %r9
    popq %r10
    popq %r11
    popq %r12
    popq %r13
    popq %r14
    popq %r15
    addq $16, %rsp         // the vector number and error code
    testb $3, 8(%rsp)      // returning to user mode?
    jz 2f
    swapgs
2:  iretq

    .set i, 0
    .rept 256
    STUB %i
    .set i, i + 1
    .endr

    .section .rodata
    .p2align 3
    .globl x86_vector_table
x86_vector_table:
    .set i, 0
    .rept 256
    TABLE_ENTRY %i
    .set i, i + 1
    .endr

    .section .note.GNU-stack, "", @progbits
