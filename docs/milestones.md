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

## P3: M3, mount the network — done 2026-10-04

On macOS, every M3 scenario passes on x86_64 and aarch64: `pci`, `net`, `netd`, `tcp`, `mount`, `iso`, and M3's `boot`, `cons`, `ktest` (188 checks on x86_64, 184 on aarch64), `ns` and `shell`, which replace the `m2/` ones as regression checks. `u9fs` needs Linux user namespaces and runs on Fedora. The shell mounts a host directory over 9P on TCP (`mount tcp!10.0.2.100!5640 /n/host`), served by `vx9pserve`, through devmgr's PCI scan, the virtio-net driver on MSI-X (an APIC vector on x86_64, an LPI through the GIC's ITS on aarch64), netd and `vx:net`. Scenarios are upstream's as M3 left them (`tests/qemu/m3/`).

| Commit | Step |
|---|---|
| `e192ad6` | The M3-era scenarios and the 9P share fixture |
| `6e9388c`, `2110525` | Kernel: ACPI export, MSIs, DMA domains, M3's object fixes; ktest's M3 cases |
| `9e78180` | devmgr, `vx:acpi`, `vx:pci`; svcd's rendezvous posts and claims |
| `365f77b` | The virtio-pci transport; the console reads in pieces |
| merge `64f2633` | Build tool: QEMU networking, host servers, `host=` checks, `image --iso`; u9fs vendored (ADR-0006, review pending) |
| merge `09c00f6` | `vx:net` (Ethernet, ARP, IPv4, ICMP, UDP, DHCP, TCP, DNS), frame-for-frame against upstream's C |
| merge `3a05908` | p9, ns, ring and tar as M3 left them; dialing 9P over TCP; `vx9pserve` in Odin |
| `6a091b8` | drv-virtio-net, ring sessions, nettest |
| `f74978c`, `179bd69` | netd, ping, cs, tcptest; gsh's `mount` |

Found along the way, and recorded in [UPSTREAM-FINDINGS.md](UPSTREAM-FINDINGS.md): an unmount that crashes while a bind still uses the connection (fixed here), and netd's query answers cut off at 256 bytes (kept, byte for byte).

## P4: M4, POSIX and debugging — done 2026-10-04

On macOS, every M4 scenario passes on x86_64 and aarch64 (54 runs): `posix` (ctest's 333 checks), `sbase`, `lua`, `rc`, `rcscript`, `proc`, `dbg`, `shell`, and M4's versions of every earlier scenario, which replace the `m3/` ones. `u9fs` needs Linux user namespaces and runs on Fedora. Scenarios and their C fixtures are upstream's as M4 left them (`tests/qemu/m4/`, ADR-0007).

The POSIX personality is musl 1.2.6, vendored unchanged, with its back end in Odin (ADR-0007): a fd table, files and terminals over the namespace, fork/exec/wait over /proc, signals as notes, poll/select, and sockets over /net. Lua 5.5.1 and sbase run on it. Under it: the M4 kernel (exceptions and the debugger's calls, watchpoints, FORK, task_exec, notes and exit strings, as_unmap); procfs as the one process table, with the debug files and crash directories; nsd, tmpfs, nullfs, sysfs, ptyd; gsh remade on `vx:rc`; `dbg` on `vx:debug`, which reads Odin's DWARF 4 as well as clang's DWARF 5.

Along the way: builds made byte-identical across runs and checkout paths (Odin's IR canonicalized; `/src` for the root), `--release` fixed, shrink-wrapping turned off so every function's frame record is set up at entry (ADR-0003), a ring server's closed connections unmapped. Upstream findings are in [UPSTREAM-FINDINGS.md](UPSTREAM-FINDINGS.md).

Imports reviewed and accepted: musl, compiler-rt, Lua, sbase (ADR-0007 to ADR-0010).

## P5: M5, storage — done 2026-10-04

On macOS, every M5 scenario passes on x86_64 and aarch64 (94 runs in the closing matrix, plus `powercut` from M5's step 11): the block class on virtio-blk and NVMe (with reset, restart and fault injection), GPT through `partd`, `fsd` on `vx:fs` (users and permissions, the adm files, snapshots and the dump view, fsd as pager for mapped files, dref), `dosfs` and `isofs`, `distd`'s verified reads, install from the ISO, boot slots and rollback, ACPI through ACPICA in `bus-acpi` (power off, the CMOS RTC and the wall clock), and the VT-d and SMMUv3 IOMMUs. `u9fs` needs Linux user namespaces. Scenarios are upstream's as M5 left them (`tests/qemu/m5/`).

PLAN's cross-format test holds both ways: volumes upstream's C library and `host/vxfs` wrote mount, check clean and read the same here, and volumes this tree's `vxfs` and `fsd` write are byte-identical or read and check clean with upstream's tool. The power-cut exit test kills QEMU mid-commit and finds every synced file whole after the remount.

New vendored imports: Monocypher (ADR-0011) and ACPICA (ADR-0012), each behind a thin Odin layer, accepted on the upstream review of the same trees. Upstream findings from the storage libraries (FAT, ISO, the block client, vx-fs) are in [UPSTREAM-FINDINGS.md](UPSTREAM-FINDINGS.md). Testing became risk-based: the full matrix at a milestone's close only (docs/CODING.md).

## P6: M6, chasing upstream

Upstream's M6 steps are ported as they land; scenarios are upstream's as of the step last ported (`tests/qemu/m6/`, from `3cb6968`; unchanged at `366394f`, but `tests/user/slottest.ndb`; unchanged again from `08cc12f` to `f9c14e9`, 6c).

| Step | Here | Commit |
|---|---|---|
| 6a1. `lib/vx-guide`, guide(6), `./build man` | `vx:guide`: contextless, allocation-free, no recursion and no statics, freestanding for both targets. `tests/host/guide` ports guide_test.c and guide_fuzz.c and cross-checks every call against upstream's C over its fuzz corpus, the manual's pages and 5,000 mutated inputs (1,000,000 run once), byte for byte but one hostile case (UPSTREAM-FINDINGS) | `cb25411` |
| 6a2. The index and the coverage check | `./build check`'s manual pass, alone as `./build man --check` (`tools/build/man.odin`); `man/missing` is upstream's unchanged, this tree's inventory matching it name for name | `04d25e8` |
| 6a3. Usage messages from pages | A generated Odin package per program, `gen:usage/NAME` (docs/CODING.md); `install` the first to use it | `04d25e8` |
| 6a4. gsh renamed rc | `cmd/rc`, `/boot/bin/rc`, service `rc`, `rc:` messages; the manifests, scripts and host tests that say what is | `1c9b576` |
| 6a5. `man`, `lookman`, `sig`; `/lib/man` in the image | `vx:man`, `cmd/man`, `cmd/lookman`, `cmd/sig`; `m6/man` passes on x86_64 and aarch64 | `a3f838f` |
| 6a6a. rc behaves as 9front's rc | `vx:rc`'s grammar, statuses, errors at file:line, globbing and functions as 9front's; `cmd/rc`'s wait messages and concstatus. rc_test.c's 9front block; the cross-check against upstream's rc.c at `439b30a`, 1,000,000 transcripts, none differing | `12a3004` |
| 6a6b. rc reads and starts as 9front's | Reading a command at a time, here documents, flag and -e -x -s -v -r, `.` -biq, eval; `cmd/rc` a bootstrap running `/rc/lib/rcmain` (upstream's, in the image). Cross-checked at `57e7c3a`, 1,000,000 transcripts, none differing | `ecfeb6b` |
| 6a6c. rc's builtins, exported functions and notes | builtin, exit, shift, whatis, exec, wait; functions exported as `fn#name`; notes to sig* functions, sigexit. Cross-checked at `f33715d` (upstream's rc.c at `3cb6968`): of 1,000,000 transcripts 2 differ, at one heap, where this tree's P4 fix holds a stage's path 64 bytes longer | `14300b7` |
| 6b, the kernel fix (upstream `89b3ce8`) | `as_query` on an ended task answers `Err_Bad_State`; `exception_resume` needs DEBUG for a debugger's stop, MANAGE for an exception port's; ktest checks both | `c0f1e0a` |
| 6b, waves A-E (upstream `b6ab2ae`, `cd2548c`, `b1af1bc`, `300676f`) | The manual's pages at `366394f`, copied as contracts; `man/missing` upstream's, 97 records. Usage from pages for cs, dbg, ping, tail, rc (and its builtins, `usage.TEXT_bind` and the like), dosfs, isofs; a program that prints no usage message needs none. `vx:rc`'s pattern matcher decodes runes with `vx:utf` | `6daab42` |
| 6b, the key tables (upstream `1ac9468`) | svc, driver, store, release and slots `.def` tables beside their parsers, expanded by `tools/abigen`; `ndb.unknown_key`; svcd and devmgr use a manifest with an unknown key (or an error) not at all, install fails on such a release record and distd does not serve it, a slot table or store directory with one is invalid; `./build man --check` holds each format's page to its table. slottest's ESP is 96 MiB | `7b7cd4d` |
| 6c, ADR-0035's ABI (upstream `b348676`, `338c0fa`) | Recorded here as ADR-0013, followed: thread_state's `.Get_Xstate`, `.Set_Xstate`, `.Get_Cpu` and `vx.Cpu_Info`; `as_key_alloc`, `as_key_free`; `vx.Map_Flags` (options and key) for as_map, as_protect and as_query; `.Protection_Key`, with `Exception.key` and `.rights` | `51f2d1d` |
| 6c1. Every x86 FP/SIMD component, by XSAVE (upstream `820b378`) | XCR0 with AVX-512's three where the CPU has all three; the thread's XSAVE area stays at the top of its kernel stack (ADR-0004, ADR-0013), saved at every entry, with XSAVEOPT from user mode; the debugger's view and XRSTOR's checks; `rt.cpu()`; procfs's `xregs`; the note entry's page of stack | `c4cb4f3` |
| 6c2. The copies by words (upstream `9c48c9f`) | `lib/memory/arch/*/mem.S` (upstream's vx-mem) in the kernel and every native program, in place of Odin's runtime byte loops; DC ZVA and NEON page copies on aarch64, no SIMD sections (eager save); aarch64's user copy by words; ktest's `test_mem` on the target | `6f539c2` |
| 6c3. Userland's baseline (upstream `18d6e27`) | x86-64-v3 and armv8.2-a for every user program, the back end, musl, compiler-rt and the ports (odin, llc and clang told the same); the kernel at the base ISA; `rt.cpu_has` | `a6f18a1` |
| 6c4. Protection keys on x86, and `as_protect` (upstream `e2942df`) | CR4.PKE and PKRU in XCR0; keys 1-15; rights live in the kernel for the thread's copies, kept per thread at switches and in the area; `as_protect`'s cuts and limits; `.Err_Access` from a denied copy; handlers with key 0 opened; musl's `SEGV_PKUERR` and `si_pkey`; `rights=` in regs.ndb. Under TCG ktest has 15 keys | `2bef63a` |
| 6c5. aarch64's user copies unprivileged (upstream `b7f3d81`) | LDTR and STTR, the futex word's LDTR and a barrier; no keys on aarch64 | `4e0f42a` |
| vx:guide's header values (upstream `705fd16`) | A header value not UTF-8 once decoded (ndb's hex form) refused; the cross-check against upstream's guide.c at `f9c14e9`, its corpus's new input, 1,000,000 mutated inputs matching | `310e32b` |

After 6a5, `m6/man`, `shell`, `rc`, `rcscript`, `boot`, `ns`, `ktest`, `posix`, `fsd` and `net` pass on x86_64 and aarch64 (2026-10-05).

After 6a6c, `m6/rc`, `rcscript`, `shell`, `boot`, `iso`, `mount`, `netd`, `ns`, `man`, `ktest`, `posix`, `fsd`, `net` and the scenarios that run rc scripts (`fsdadm`, `fsddump`, `fsdperm`, `fsddref`, `dosfs`, `dosfswrite`, `distd`, `install`, `isofs`, `powercut`, `rtc`) pass on x86_64 and aarch64 (`rtc` x86_64 only); `slots` fails on both, as it does at `b626d78` before 6a6 (distd's apply: the store full).

After 6b, `m6/ktest`, `man`, `boot`, `shell`, `rc`, `slots`, `install`, `distd`, `block`, `net`, `dbg`, `proc`, `posix` and `fsd` pass on x86_64 and aarch64, with `acpi` (x86_64) and `acpiarm` (aarch64) (2026-10-05).
