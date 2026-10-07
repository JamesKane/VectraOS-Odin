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
  | odin | pinned build under `/opt/odin/` | pinned build under `/opt/odin/` |
  | clang, llc, llvm-objcopy, llvm-ar | `/opt/homebrew/opt/llvm@22/bin/` | `/usr/bin/` |
  | ld.lld | `/opt/homebrew/opt/lld@22/bin/` | `/usr/bin/` |
  | nasm | `/opt/homebrew/bin/nasm` | `/usr/bin/nasm` |

  A Swift toolchain's clang (Apple clang 21) comes first on `PATH` on the macOS host, which is why `PATH` is never used.

## Consequences

- Moving the Odin pin is a change to `build` plus an amendment to this ADR. Odin's LLVM and the pinned clang move together.
- Homebrew bottles are not signed packages in the sense of upstream ADR-0001. Building Odin and LLVM from source is a later hardening step.

## Amendment, 2026-10-07: Odin from source on macOS too

Homebrew upgraded `odin` to `dev-2026-10` on 2026-10-07 and removed the pinned bottle, which stopped every build mid-port. The macOS host now uses the same pinned build as Fedora: Odin's source at `a2fb372b7`, built with `build_odin.sh release` against Homebrew's `llvm@22` (22.1.8) and installed whole (compiler, `base`, `core`, `vendor`) in `/opt/odin`. `build` and `tools/build/tools.odin` call `/opt/odin/odin` on both hosts. To make it again:

```
git clone https://github.com/odin-lang/Odin /opt/odin
git -C /opt/odin checkout a2fb372b7
cd /opt/odin && LLVM_CONFIG=/opt/homebrew/opt/llvm@22/bin/llvm-config ./build_odin.sh release
```

The build from source was checked against the bottle it replaces: the tree built with each is byte-identical (every program and kernel image, both architectures). Odin names its own `base:` and `core:` files by absolute path in what it compiles, so the build canonicalizes that root to `/odin` (tools/build/ircanon.odin), as it does the repository's to `/src`: a compiler installed at another path, building another checkout, gives the same bytes.
