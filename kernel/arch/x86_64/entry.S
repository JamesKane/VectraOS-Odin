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
// has it, AVX; arch_amd64.odin's simd_init adds AVX-512's state. The kernel
// requires XSAVE (simd_init checks).
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
    jz trap_save
    swapgs
trap_save:
    pushq %r15
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
    xorl %eax, %eax        // XRSTOR needs a zeroed header (bytes 512-575)
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
    // From user mode the area is the thread's own, at the top of its kernel
    // stack (ADR-0013): XSAVEOPT, where there is one, skips what is unchanged
    // since the XRSTOR that left it there, which nothing has written over.
    // A frame of the kernel's is stack memory, used again: XSAVE.
    testb $3, 144(%rbx)    // the saved CS
    jz 1f
    cmpq $0, vx_xsaveopt(%rip)
    je 1f
    xsaveopt64 (%rsp)
    jmp 2f
1:  xsave64 (%rsp)
2:  movq %rbx, %rdi
    call x86_trap
// rbx: the general-register frame; rsp: the XSAVE area below it.
trap_restore:
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

// SYSCALL: rip in rcx, rflags in r11, interrupts masked by FMASK, still on
// the user stack. Build a trap frame on the kernel stack and join the common
// path, with vector 0x100.
    .p2align 4
    .globl syscall_entry
    .type syscall_entry, @function
syscall_entry:
    swapgs
    movq %rsp, %gs:8
    movq %gs:0, %rsp
    pushq $0x1b            // ss: user data
    pushq %gs:8            // rsp
    pushq %r11             // rflags
    pushq $0x23            // cs: user code
    pushq %rcx             // rip
    pushq $0               // error code
    pushq $0x100           // vector
    jmp trap_save

// vx_context_switch(save_sp: ^u64, load_sp: u64): saves the callee-saved
// registers on this stack, switches stacks, and restores the other thread's.
// SysV keeps no vector register across a call, so none is saved here; user
// vector state is in each thread's trap frame (ADR-0004). A new thread's
// stack (arch_thread_initial_sp) "returns" into thread_trampoline.
    .globl vx_context_switch
    .type vx_context_switch, @function
vx_context_switch:
    pushq %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    movq %rsp, (%rdi)
    movq %rsi, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret

// A new thread's first stop: its thread pointer is in r12.
    .globl thread_trampoline
    .type thread_trampoline, @function
thread_trampoline:
    movq %r12, %rdi
    xorl %ebp, %ebp
    call thread_entry
    ud2

// vx_enter_user(entry, sp, arg, arg2, kstack_top): user mode at entry with
// interrupts on, through a trap frame built at the top of the thread's
// kernel stack, with vector state in its initial state: the XSAVE area below
// the frame, which arch_enter_user filled (a zero header, so every component
// at its reset value, but for MXCSR, which XRSTOR always loads).
    .globl vx_enter_user
    .type vx_enter_user, @function
vx_enter_user:
    movq %r8, %rsp
    pushq $0x1b            // ss
    pushq %rsi             // rsp
    pushq $0x202           // rflags: IF
    pushq $0x23            // cs
    pushq %rdi             // rip
    pushq $0               // error code
    pushq $0               // vector
    pushq $0               // r15
    pushq $0               // r14
    pushq $0               // r13
    pushq $0               // r12
    pushq $0               // r11
    pushq $0               // r10
    pushq $0               // r9
    pushq $0               // r8
    pushq $0               // rbp
    pushq %rdx             // rdi: arg
    pushq %rcx             // rsi: arg2
    pushq $0               // rdx
    pushq $0               // rcx
    pushq $0               // rbx
    pushq $0               // rax
    movq %rsp, %rbx
    subq vx_xsave_size(%rip), %rsp
    andq $~63, %rsp
    jmp trap_restore

// vx_user_copy(dst, src, n) -> u64: copies to or from user memory, and
// returns the bytes not copied: 0 means it all was. A fault inside resumes at
// vx_user_copy_fault (uaccess_fixup, x86_trap), which returns what is left.
    .globl vx_user_copy, vx_user_copy_fault
    .type vx_user_copy, @function
vx_user_copy:
    movq %rdx, %rcx
    rep movsb
    xorl %eax, %eax
    ret
vx_user_copy_fault:
    movq %rcx, %rax        // rep movsb counts down as it goes: what is left
    ret

// vx_user_load32(src, dst) -> bool: one aligned 32-bit load from user memory
// (a futex word), whole. A fault returns false.
    .globl vx_user_load32, vx_user_load32_fault
    .type vx_user_load32, @function
vx_user_load32:
    movl (%rdi), %eax
    movl %eax, (%rsi)
    movl $1, %eax
    ret
vx_user_load32_fault:
    xorl %eax, %eax
    ret

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
