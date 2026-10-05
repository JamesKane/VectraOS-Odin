# ADR-0004: Vector state in the kernel

Status: accepted, 2026-10-04: implemented in P1 for kernel traps (`kernel/arch/*/entry.S`), tested by `tests/qemu/simd.ndb`. Per-thread save areas arrive with threads in P2.

## Context

Upstream builds its kernel with `-mgeneral-regs-only`, so kernel entry never saves FP or SIMD state. Odin's runtime and code generation use SSE and NEON: a trivial freestanding object holds 571 vector instructions on x86_64 and 939 on aarch64 (2026-10-03). Disabling them with `-target-features` works on that object but fights the compiler and its runtime from then on.

## Decision

The Odin kernel uses vector registers, and accounts for them:

- **Enable early.** The assembly entry enables FP and SIMD before calling any Odin code, on the boot CPU and on every secondary CPU:
  - x86_64: `CR0.EM=0`, `CR0.MP=1`, `CR4.OSFXSR`, `CR4.OSXMMEXCPT`, `CR4.OSXSAVE`, then `XCR0` for x87, SSE and AVX.
  - aarch64: `CPACR_EL1.FPEN=0b11`.
- **A bounded kernel ISA.** The kernel is built for x86-64-v3 without AVX-512, and for ARMv8-A with NEON but without SVE or SME. The kernel's own vector state therefore has a fixed size, whatever user threads use.
- **Eager save on every entry.** Syscall, IRQ and exception entry save the interrupted context's vector state before the first Odin instruction runs, and restore it on the way out. Nested IRQs save the kernel's state the same way.
  - x86_64: `XSAVEOPT` (`XSAVES` once supervisor components matter) into the thread's area, with the size from CPUID leaf 0xD.
  - aarch64: `q0`–`q31`, `FPCR` and `FPSR`.
- **Save areas are budgeted.** Each thread's area comes from a typed pool charged to its task's budget (no general allocator). Areas are 64-byte aligned, and every kernel stack is 16-byte aligned at each call into Odin.
- **Context switch** saves and restores the full set. On x86_64, `vzeroupper` at the user/kernel transitions avoids AVX-to-SSE penalties.
- **Tests:** `vx.selftest=simd` (`tests/qemu/simd.ndb`) fills every vector register with a pattern and keeps it live across eight timer interrupts, each of which wipes every vector register; only the trap path's save and restore bring the pattern back (512 bytes: ymm0-15 or q0-31). With the restore removed, the test fails on both architectures. With threads (P2), a ktest checks user vector registers across syscalls, preemption and migration. `./build bench` reports entry cost.
- **Unlike upstream,** x86_64 sets CR4.OSXSAVE and enables AVX in XCR0, so user code may use AVX from the start; the kernel saves what XCR0 enables, sized by CPUID leaf 0Dh at boot.

## Amended 2026-10-05: upstream's M6 step 6c (ADR-0013)

- **XCR0** holds every user component the CPU has: x87, SSE, AVX, AVX-512's three where it has all three, and PKRU where it has PKU (protection keys). The entry stub turns on x87, SSE and AVX before any Odin runs; `simd_init` adds the rest on every CPU.
- **The thread's area** is the XSAVE area under its user trap frame, at the top of its kernel stack, sized from CPUID for that XCR0 (about 2.7 KiB with AVX-512); the kernel refuses to boot if it and the frame do not fit in that page. Entries from user mode save there with XSAVEOPT where the CPU has it, nested entries from the kernel with XSAVE; every exit loads with XRSTOR. A debugger reads and writes the whole area (`.Get_Xstate`, `.Set_Xstate`).
- **The kernel's ISA**, as built: each architecture's base, x86-64 (SSE2) and armv8-a with NEON; the "x86-64-v3 without AVX-512" above was never what the build gave llc. User programs are built for userland's baseline, x86-64-v3 and armv8.2-a (upstream's 6c3); the kernel's state stays small whatever theirs is.
- **The kernel's own SIMD** needs no sections (upstream's `simd_begin`/`simd_end`): the user's state is saved at entry, so a NEON page copy is an ordinary call.

## Consequences

- A larger trap frame and a slower kernel entry than upstream's. Lazy save (trap on first use) is a later optimisation, adopted only behind a benchmark, and probably buys little, since nearly every kernel path touches vector registers.
- `arch` and the entry stubs diverge most from upstream's in this tree.
- If user threads use AVX-512, SVE or SME, the user save area grows; the kernel's does not. SME stays trapped (upstream 01 §11).
