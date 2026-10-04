# P0 spike results

_2026-10-03, macOS host (Apple M4 Max), Odin `dev-2026-09:a2fb372b7`, LLVM 22.1.8 (Homebrew `llvm@22`, `lld@22`), QEMU with edk2, Homebrew Limine 12.9.0._

| Spike | Result | Evidence |
|---|---|---|
| S1 freestanding kernel booted by Limine | **Go** | `spikes/s1-boot/run.sh {x86_64,aarch64}` prints the banner, HHDM and usable memory on both |
| S2 frame pointers in every function | **Go**, via the IR pipeline | `odin -build-mode:llvm-ir` → `llc --frame-pointer=all`: `push %rbp; mov %rsp,%rbp` and `stp x29, x30` in leaf functions too; DWARF kept |
| S3 SIMD in the kernel, eager save across traps | **Go** | Vector registers survive a trap whose handler wipes them and runs Odin SIMD code; the negative control (restore removed) reports 508/512 and 510/512 bytes corrupted |
| S4 ABI generated from `.def` tables | **Go** | `out/build abi` writes `abi/vx/abi_gen.odin`: 62 syscalls, 12 rights, 21 statuses; passes `-vet -strict-style` |
| S5 kernel build time | **Go at spike size** | Odin to IR plus parallel `llc` in under 0.1 s; re-measure at P1 size against the 1 s budget |

## What the spikes settled

- **The kernel's compile pipeline:** Odin → LLVM IR per package → `llc --frame-pointer=all -relocation-model=static` (plus `-code-model=kernel` on x86_64) → `ld.lld` with the linker script. The IR step is also where later passes can go (a call-graph check for recursion, function attributes).
- **Kernel flags:** `-no-crt -default-to-nil-allocator -disable-init-fini -no-rtti -no-thread-local -reloc-mode:static -debug -vet -strict-style -warnings-as-errors`, plus `-disable-red-zone` on x86_64. The Odin runtime needs no external symbols on freestanding targets.
- **`-disable-init-fini` is required:** `builtin.ll`'s `__$startup_runtime` and `__$cleanup_runtime` carry no `noredzone` attribute. The kernel never calls them.
- **Odin's `context`** works from a `proc "c"` entry with `runtime.default_context()` (nil allocator).
- **Limine's IDs and layouts** port directly to Odin structs. Responses are read with `intrinsics.volatile_load`, because Limine writes them behind the compiler's back.
- **aarch64 entry must `msr spsel, #1`.** Limine enters with `SPSel=0`, which would route kernel exceptions to the SP_EL0 vectors.
- **Vector state in numbers:** the spike kernel holds 441 vector instructions on x86_64 and 513 on aarch64; there is no avoiding them. Limine enters x86_64 with `CR0=0x80010013`; after the entry stub, `CR4=0x40620`, `XCR0=7` (x87, SSE, AVX). On aarch64, `CPACR_EL1=0x300000`.

## Watch items

- **Inline assembly.** Odin's new `asm { … }` blocks parse instructions natively and validate them against `core:rexcode`'s encoding tables. On aarch64, `mrs x0, mair_el1` is rejected ("operands matched none of the expected encoding forms"), and the feature is undocumented. The kernel uses clang-assembled `.S` stubs (ADR-0003). Revisit when Odin documents it; small `msr`/`mrs` stubs cost a call each.
- **`core:rexcode`** ships an AArch64 and x86 decoder in Odin's core library. That matters for `vx-debug`'s disassembler in P4: upstream wrote its own aarch64 disassembler.
- **Limine.** The spikes used Homebrew's 12.9.0 binaries; `build` now builds the vendored 12.9.1 from source (ADR-0005).

## Found during P0's foundation

- **Odin's IR is not reproducible by default.** The threaded checker numbers entities and orders debug metadata differently from run to run, and the debug info records the wall-clock time as `ODIN_COMPILE_TIMESTAMP` (ignoring `SOURCE_DATE_EPOCH`). `build` passes `-no-threaded-checker -thread-count:1` and rewrites that one constant to `SOURCE_DATE_EPOCH` in the IR before `llc`. Kernels and disk images are then byte-identical between builds. (Not reliably: see P4.)
- **`core:os` process API:** a `nil` `stdin` in `Process_Desc` closes the child's input rather than inheriting it; pass `os.stdin` to inherit. Slice literals appended inside a loop alias one stack array: build command lines with an allocated `[dynamic]string`.

## Found during P1

- **`foreign` variables are broken in freestanding ELF builds:** Odin emits `weak dllimport externally_initialized global` with no initializer, which `llc` rejects. Workaround in ADR-0003 (Odin-owned `@(export)` data; address-only symbols as foreign procedures).
- **Globals are not `dso_local`,** so aarch64 code reaches some through a `.got` even at `-relocation-model=static`. An unplaced `.got` landed after the boot stack, outside the kernel's mappings, and the first access faulted inside a panic loop. The linker scripts now put `.got` in `.data`.
- **Procedure-local statics are numbered nondeterministically** (`proc-.state-4433`), even with the single-threaded checker. `build` renumbers them per module in the IR.
- **Symbol names:** polymorphic and some runtime procedures carry their signature in the symbol (`response:proc"contextless"(...)`), and file-private ones a file prefix (`[main.odin]::selftests`). The kernel's symbol map trims both, so backtraces read like upstream's (`kernel_main_on_kstack+0x88`).
- **Odin's runtime trap** after a failed bounds check is `ud2` (x86_64) or `brk #1` (aarch64); its message goes to a freestanding stderr that discards it. The trap handler names it.

## Found during P2

- **Non-constant global initialisers need Odin's startup code.** A global like `x := f()` is filled in by `__$startup_runtime`, which the kernel and user programs never run (`-disable-init-fini`). The global stays zero, silently: a pool with size 0 made `pool_alloc` spin for ever. Both builds now pass `-disable-non-constant-globals`, which makes such an initialiser a compile error.
- **No `intrinsics.syscall` on freestanding targets.** User space reaches the kernel through a six-instruction `vx_syscall` stub per architecture (`lib/rt/arch`). `_start` itself is an ordinary `proc "c"`: the kernel enters user mode exactly as a C call would.
- **Debugging with lldb:** QEMU's `-gdb tcp::1234` plus `lldb` (`gdb-remote 1234`, `thread backtrace all`) gives a symbolized backtrace for every CPU, through the Odin kernel's DWARF and frame pointers.

- **A package that another imports cannot have `main :: proc() -> int`** (Odin's rule for the main package). Programs that host tests import name the entry `vx_main` directly (`@(export, link_name="vx_main") vx_main :: proc() -> int`); the rest may call it `main`, exported under the same link name.
- **Parallel porting worked.** Five libraries and two servers were ported by agents in their own worktrees against the frozen M2 snapshot, each checked against upstream's C compiled with clang (byte-identical 9P sessions and tar output, identical model-checker results, identical namespace results over ~475,000 lines of random operations). They found one upstream bug (a 256-byte ustar path overruns `vx_tar_entry` by one byte).

## Found during P4

- **`-thread-count:1` still checks on two threads.** Odin's thread pool always has the main thread plus thread-count workers, and the main thread runs tasks while it waits, so files' entities are collected in a racy order. That order reaches the IR: polymorphic instances (`obj_type_of(T)`) change places (the sort meant to order procedures ties on them), and with them the numbered names (`csbs$pkg$N`, `proc-.state-N`, `_proclit$anon-N`), the compile unit's constant list and the metadata numbering. Seven or eight different kernels in ten builds. No flag fixes it: `scrub_ir` canonicalizes every module instead (tools/build/ircanon.odin), and ten builds then hash identically, IR included.
- **A polymorphic instance's DISubprogram carries a wrong line,** that of the call site that instantiated it first, in another file (`rt::thread_state(..., ^Regs)` at syscall.odin:782 in a 345-line file). LLVM puts that line in the line table at the procedure's entry. `scrub_ir` gives it its first parameter's line, which is the generic's declaration.
- **Odin has no `-ffile-prefix-map`.** Its DWARF and its source-location strings (bounds-check messages, `#caller_location`) name files by absolute path. `scrub_ir` maps the repository root to `/src`, as clang's `-ffile-prefix-map` does for the C side, fixing each string's length where it is used; two checkouts at different paths then give identical images, kernels, programs and libraries.
- **`-o:speed` makes a single module,** written as `ir/.ll`, and in it lib/rt's foreign declaration of `vx_main` hides the program's exported definition, so `_start` calls an undefined symbol. `build` passes `-use-separate-modules` in every mode.
- **LLVM 22's loop-idiom pass emits `strlen`** at `-o:speed` (the kernel's symbol-map scan), and Odin's freestanding runtime defines memset, memcpy and memmove but not strlen; Odin has no `-fno-builtin`. `scrub_ir` gives a module that calls strlen without defining it a weak byte-loop definition.

## Not yet covered

- Preemption and migration in the vector-state test: they need threads (P2). (SMP entry, asynchronous interrupts and XSAVE sizing from CPUID leaf 0Dh are done in P1.)
- XSAVEOPT or XSAVES in place of XSAVE, behind a benchmark.
- The Fedora 44 host.
