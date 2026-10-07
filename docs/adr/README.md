# Architecture decision records

| ADR | Title | Status |
|---|---|---|
| [0001](0001-toolchain.md) | Toolchain | proposed |
| [0002](0002-clean-room.md) | A clean-room rewrite, judged by behaviour | proposed |
| [0003](0003-odin-house-subset.md) | Odin and the house subset | proposed |
| [0004](0004-kernel-vector-state.md) | Vector state in the kernel | proposed |
| [0005](0005-limine.md) | Limine | accepted |
| [0006](0006-u9fs.md) | u9fs, vendored as a host test tool | accepted |
| [0007](0007-musl-odin-backend.md) | musl, vendored unchanged, with a back end in Odin | accepted |
| [0008](0008-compiler-rt.md) | compiler-rt's builtins, vendored from LLVM 22.1.8 | accepted |
| [0009](0009-lua.md) | Lua 5.5.1, vendored unchanged, as `/bin/lua` | accepted |
| [0010](0010-sbase.md) | sbase, vendored unchanged, as the POSIX userland's commands | accepted |
| [0011](0011-monocypher.md) | Monocypher 4.0.3, vendored unchanged, behind a thin Odin layer | accepted |
| [0012](0012-acpica.md) | ACPICA 20260930, its core vendored unchanged, with an OS layer in Odin, for `bus-acpi` | accepted |
| [0013](0013-extended-state-and-protection-keys.md) | Extended register state and protection keys, as upstream's ADR-0035 | accepted |
| [0014](0014-note-stacks.md) | Note stacks, as upstream's ADR-0036 | accepted |
| [0015](0015-robust-futexes.md) | Robust futexes, as upstream's ADR-0037 | accepted |
| [0016](0016-scheduling-contexts.md) | Scheduling contexts, as upstream's ADR-0038 | accepted |
| [0017](0017-current-directory.md) | The current directory, as upstream's ADR-0039 | accepted |
| [0018](0018-descriptors-and-fd.md) | Descriptors past 2, and `/fd`, as upstream's ADR-0040 | accepted |
| [0019](0019-cpu-time.md) | CPU time, sampled as 9front's, as upstream's ADR-0041 | accepted |

Upstream's own ADRs are followed as written. One that changes the kernel/user ABI or anything observable becomes an ADR here when its step is ported, saying so in its title (0013-0019); the rest are recorded in [milestones](../milestones.md) when their step is ported, or, if they bear only on steps not yet reached, when they are amended. Upstream's ADR-0033 (the native target's C library and C++ support), amended 2026-10-06 (`fdec8be`, `3a589e0`, `c419045`: llvm-libc, libc++ and libc++abi as toolchain runtimes; C++ on the native target; the sysroot and `.cfg`), is of the last kind: its steps, 6e2 and 6f2, are not ported yet.
