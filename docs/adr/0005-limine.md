# ADR-0005: Limine

Status: accepted, 2026-10-04. The import was reviewed by James Kane, 2026-10-04 (`third_party/VENDOR.ndb`).

## Context

The kernel boots through the Limine protocol on both architectures, as upstream's does (upstream ADR-0002). The P0 spikes used Homebrew's Limine 12.9.0 binaries; the base system must build its loader from pinned, reviewed source instead.

## Decision

- **Release:** Limine 12.9.1, `limine-12.9.1.tar.xz`, sha256 `c1096fdd506487fbd92c113baa9e153a9973cf766483cc3928e13fd29b976b32`, the release upstream pins. Its signature verifies against Mintsuki's key `05D29860D0A0668AAEFB9D691F3C021BECA23821` (checked 2026-10-04; the extracted tree is byte-identical to upstream's vendored copy, tree hash `d682c822…7482d`).
- **Vendored unchanged** under `third_party/limine/`, the whole tarball.
- **Built by `build`, not by Limine's autoconf and make.** `ports/limine/port.ndb` and `config.h` give the source sets and flags `configure` chose for the pinned clang. They are copied once from upstream (ADR-0002's copy-once rule), since they are data about Limine's build, not upstream's code. `build` compiles in parallel, preprocesses the linker script, links without the symbol map, writes the map itself (Limine's `gensyms.sh` step), links again, and turns the ELF into the loader with `llvm-objcopy -O binary`, padded to 4 KiB.
- **Built:** the `uefi-x86_64` and `uefi-aarch64` loaders only. No BIOS stages, ISO images or the `limine` host tool.
- The kernel declares its Limine requests in Odin (`kernel/limine.odin`), from `limine-protocol/include/limine.h`.

## Consequences

- The x86_64 loader needs `nasm` (pinned in ADR-0001); the aarch64 one does not.
- On every Limine upgrade: verify the signature, replace the tree, capture `configure`'s flags and `config.h` again, compare `common/common.mk` with `port.ndb`.
