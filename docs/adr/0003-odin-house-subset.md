# ADR-0003: Odin and the house subset

Status: proposed, 2026-10-03.

## Context

Upstream's house subset (its 04 §1.1) gets its safety from a small kernel and from tooling: sanitizers, kcfi, branch protection, the static analyzer and clang-tidy. Odin gives some of that in the language and lacks the rest.

## Decision

- **Odin for all first-party code**, kernel included. Assembly only for entry points, context switch and exception vectors (`kernel/arch/`, `rt/`), assembled by clang. Vendored code stays C.
- **Flags everywhere:** `-vet -vet-shadowing -vet-cast -strict-style -warnings-as-errors -debug`. The kernel also uses `-no-crt -default-to-nil-allocator -disable-init-fini -no-rtti -no-thread-local -reloc-mode:static`, plus `-disable-red-zone` on x86_64. `-disable-init-fini` is required: Odin's `__$startup_runtime` carries no `noredzone` attribute (spikes/RESULTS.md).
- **The compile pipeline:** Odin emits LLVM IR per package (`-build-mode:llvm-ir`); `llc --frame-pointer=all -relocation-model=static` (plus `-code-model=kernel` on x86_64) makes the objects; `ld.lld` links them with the linker script. User space uses the same pipeline.
- **Assembly is clang-assembled `.S`**, not Odin's `asm` blocks, which are undocumented and reject system-register instructions (spikes/RESULTS.md).
- **The rules carried over** (PLAN §3): one package per component; zero is initialisation; slices, not NUL-terminated strings; handles with generations, never pointers, across a boundary; every foreign size, offset or count through a `ckd` helper; `@(require_results)` on the kernel's and authorization paths' status-returning procedures; typed pools in the kernel and arenas in user space; one `.def` table per list, expanded by `build`; `@(private="file")` by default.
- **Bounds checks stay on** in every build, kernel included. Their failure procedures are routed to `panic`, and the kernel installs them before its first checked access.
- **Frame pointers in every function**, leaf functions included, from `llc --frame-pointer=all` in the pipeline above (spike S2).

## Lost, and accepted

- **kcfi** and **branch protection / CET.** No Odin flag. kcfi needs type identifiers only a front end has. Branch protection and CET are module flags and function attributes, so a pass in the IR pipeline could add them later.
- **The clang static analyzer and clang-tidy.** `-vet` covers a little; review covers the rest.
- **"No recursion in the kernel"** is not enforced by a compiler. A call-graph check over the kernel's LLVM IR is planned for `./build check`.
- **Integer overflow is defined (wrapping) in Odin**, not a UBSan trap. The `ckd` rule carries the weight on every foreign value.

## Consequences

Any further exception needs its own ADR.
