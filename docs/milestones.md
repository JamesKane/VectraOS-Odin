# Milestones

Where VectraOS-Odin stands against [the plan](PLAN.md)'s phases, which follow upstream's milestones. A step's commit is recorded in the commit after it.

Updated 2026-10-04.

| Phase | Upstream milestone | Status | Gate |
|---|---|---|---|
| P0 | — | Done (2026-10-04) | Spikes S1–S5 go; `build`, Limine from source, reproducible images |
| **P1** | M1 First light (kernel) | Done (2026-10-04) | `panic`, `phys`, `timer`, `smp`, `lower-half`, `stack-overflow`, `write-text`, `write-text-alias`, `simd` on both architectures |
| **P2** | M2 A shell in a namespace (+ M1's user-space half) | Done (2026-10-04) | `m2/boot`, `m2/cons`, `m2/ktest`, `m2/ns`, `m2/shell` on both architectures |
| P3 | M3 Mount the network | Not started | `net`, `netd`, `tcp`, `mount`, `u9fs`, `pci`, `iso` |
| P4 | M4 POSIX and debugging | Not started | `posix`, `rc`, `rcscript`, `sbase`, `lua`, `dbg` |
| P5 | M5 Storage | Not started | `block`, `fsd*` |

## P0

| Commit | Step |
|---|---|
| `1ad01fa` | The plan, ADRs 0001–0004, spikes S1–S5 |
| `8cc8f86` | `tools/build`, Limine 12.9.1 from source, `lib/ndb` and `lib/utf`, the scenario runner |

## P1

The kernel boots through Limine on x86_64 and aarch64, builds its own page tables (W^X, an empty lower half, a direct map), runs on kernel stacks with guard pages, brings up every CPU, and keeps time with the TSC and APIC timer or the generic timer and GICv3. A fault anywhere ends in a panic that names it and prints a symbolized backtrace. Every trap saves and restores vector state (ADR-0004).

Not yet: M1's user-space half (now in P2); ACPI, the IOMMU and device objects (P3); the kernel log as a file (with `/proc`, P2).

## P2

`gsh` runs in a namespace served over 9P rings, on x86_64 and aarch64: `ls /`, `/proc` through procfs, pipes, binds, and a console driver killed from the shell and restarted by svcd while the shell carries on (`m2/shell`, M2's exit test). The kernel's own tests pass from user space: 141 checks on x86_64, 138 on aarch64 (`m2/ktest`). Scenarios are upstream's as M2 left them (`tests/qemu/m2/`).

| Commit | Step |
|---|---|
| `8c2a62d` | abi:vx types, the M2-era scenarios, docs/CODING.md |
| `262bd31`, `3da0af8`, `341d3f5`, `288527a` | lib/ring and lib/check, lib/tar and lib/sha256, lib/p9, lib/ns (ported in parallel by agents, each checked against upstream's C) |
| `2adbbaf` | Kernel objects, the scheduler, IPC, syscalls, user mode; lib/rt; svcd says hello |
| `d4fe579` | ktest passes; bootfs.tar; tools/abigen |
| `b08a7e1` | Device objects and IRQ routing, the 9P ring transport, the full runtime |
| `da4a061` | svcd, the UART console drivers, gsh and its commands |
| `1f1780b` | constest and nstest, with= scenarios; m2/cons passes |
| `d087b34` | bootfs and procfs; m2/boot, m2/ns and m2/shell pass |

Not yet: the top-level (current-upstream) `boot`, `shell`, `ktest`, `cons`, `ns` and `proc` scenarios, which also expect M3 and M4 work (`/net`, exit strings, notes, namespace groups).

## Idiom clean-up after P2 — 2026-10-03

A four-part review of P0–P2 for idiomatic Odin (kernel, libraries, user programs, build tool and host tests) found the same C habits everywhere: one `u64` for every kind of address, `[^]T` with a separate length, integer flag words, status ladders, untyped pools, array-plus-count pairs and helpers copied per package. Applied area by area, behaviour unchanged (P1+P2 gate, host tests and image reproducibility after each merge); the rules it settled on are in docs/CODING.md.

Bugs fixed along the way: `./build test` could pass having run nothing; port-target and port-load failures were silent; ~64 MiB image buffers were never freed (peak 591 → 129 MB); unchecked ELF symbol-table reads in the build tool; `iorange_create` stored a 65,536-port range as a count of 0 (upstream has the same bug); `p9.serve`'s −1/0 length sentinels; misaligned typed stores into byte buffers in `rt`; `read_spawn` trapping on a short message; file leaks in `gsh` pipelines and `nstest`; svcd's unchecked boot-image rounding.

| Commit | Step |
|---|---|
| `9338e12` | Typed ABI sets: `vx.Rights`, `Map_Options`, `Vmo_Options`, `Task_Info_Options` |
| `e7a2ec6` | Build tool (output byte-identical to before) |
| merge of `c1dc6ad` | Libraries; new `vx:str` and `vx:memory` |
| merge of `4c220e0` | Kernel: `Paddr`/`Uva`/`Pte`, `Pool($T)`, `handle_get_as`, statuses inside, slices over multi-pointers |
| merge of `12e215a` | Host tests: `expect_value`, tables, shared `p9test` |
| merge of `ff01ffd` | User programs |
