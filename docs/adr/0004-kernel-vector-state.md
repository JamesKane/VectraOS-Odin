# ADR-0004: Vector state in the kernel

Status: proposed, 2026-10-03.

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
- **Tests:** a ktest fills user vector registers with a pattern and checks them across syscalls, IRQs, preemption and migration between CPUs; a scenario drives an IRQ storm during vector-heavy kernel paths. `./build bench` reports entry cost.

## Consequences

- A larger trap frame and a slower kernel entry than upstream's. Lazy save (trap on first use) is a later optimisation, adopted only behind a benchmark, and probably buys little, since nearly every kernel path touches vector registers.
- `arch` and the entry stubs diverge most from upstream's in this tree.
- If user threads use AVX-512, SVE or SME, the user save area grows; the kernel's does not. SME stays trapped (upstream 01 §11).
