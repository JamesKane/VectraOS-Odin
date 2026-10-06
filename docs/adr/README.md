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
| [0014](0014-note-stacks.md) | Note stacks, as upstream's ADR-0036 | proposed |
| [0015](0015-robust-futexes.md) | Robust futexes, as upstream's ADR-0037 | proposed |
