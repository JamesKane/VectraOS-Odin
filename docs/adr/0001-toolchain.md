# ADR-0001: Toolchain

Status: proposed, 2026-10-03.

## Context

Every binary comes out of one compiler and one linker. Odin compiles first-party code; clang assembles the entry stubs and builds vendored C; lld links everything. Odin `dev-2026-09` is built on LLVM 22.1.8, the release upstream pins for clang and lld (upstream ADR-0001), so one LLVM release covers the whole tree.

## Decision

- **Odin `dev-2026-09:a2fb372b7`.** `build` checks `odin version` and refuses any other.
- **clang, llc, llvm-objcopy, llvm-ar and ld.lld 22.1.8.** `build` checks each one's `--version`.
- **nasm 3.02**, for Limine's x86_64 loader only.
- **Hosts:** macOS (primary) and Fedora 44 (CI). `build` calls every tool by absolute path:

  | Tool | macOS | Fedora 44 |
  |---|---|---|
  | odin | `/opt/homebrew/bin/odin` | pinned build under `/opt/odin/` |
  | clang, llc, llvm-objcopy, llvm-ar | `/opt/homebrew/opt/llvm@22/bin/` | `/usr/bin/` |
  | ld.lld | `/opt/homebrew/opt/lld@22/bin/` | `/usr/bin/` |
  | nasm | `/opt/homebrew/bin/nasm` | `/usr/bin/nasm` |

  A Swift toolchain's clang (Apple clang 21) comes first on `PATH` on the macOS host, which is why `PATH` is never used.

## Consequences

- Moving the Odin pin is a change to `build` plus an amendment to this ADR. Odin's LLVM and the pinned clang move together.
- Homebrew bottles are not signed packages in the sense of upstream ADR-0001. Building Odin and LLVM from source is a later hardening step.
