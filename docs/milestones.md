# Milestones

Where VectraOS-Odin stands against [the plan](PLAN.md)'s phases, which follow upstream's milestones. A step's commit is recorded in the commit after it.

Updated 2026-10-04.

| Phase | Upstream milestone | Status | Gate |
|---|---|---|---|
| P0 | — | Done (2026-10-04) | Spikes S1–S5 go; `build`, Limine from source, reproducible images |
| **P1** | M1 First light (kernel) | Done (2026-10-04) | `panic`, `phys`, `timer`, `smp`, `lower-half`, `stack-overflow`, `write-text`, `write-text-alias`, `simd` on both architectures |
| P2 | M2 A shell in a namespace (+ M1's user-space half) | Not started | `boot`, `ktest`, `shell`, `ns`, `proc`, `cons` |
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
