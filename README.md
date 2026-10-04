# VectraOS-Odin

A clean-room re-implementation of [VectraOS](https://github.com/JamesKane/VectraOS) in Odin, judged by behaviour: the same QEMU scenarios, serial output, wire formats and disk formats as the C23 reference.

- [docs/PLAN.md](docs/PLAN.md): the plan, phases and work streams
- [docs/adr/](docs/adr/README.md): decisions
- [docs/milestones.md](docs/milestones.md): progress, phase by phase
- [spikes/RESULTS.md](spikes/RESULTS.md): what the spikes and the phases since found about Odin

Status: P1 done (M1's kernel): the kernel boots on x86_64 and aarch64 with its own page tables, guard-paged kernel stacks, SMP, timers, symbolized panics and vector state saved at every trap. P2 (M2, a shell in a namespace) is next. See [docs/milestones.md](docs/milestones.md).

## Build it

```sh
./build all                       # the kernel and the Limine loaders, for x86_64 and aarch64
./build image                     # GPT disk images: out/<arch>/debug/vectra-<arch>.img (reproducible)
./build qemu --arch aarch64       # boot one on the serial console; Ctrl-A X quits
./build test [scenario...]        # boot headless and check tests/qemu/*.ndb (--arch, --release)
./build check                     # host tests under ASan, vendor-check
./build vendor-check              # check third_party/ against VENDOR.ndb
./build loc                       # the line-count ledger
./build abi                       # generate abi/vx/abi_gen.odin from the .def tables
```

`./build` compiles the build tool (`tools/build`) when its sources change. The toolchain is pinned (ADR-0001): Odin `dev-2026-09:a2fb372b7` and LLVM 22.1.8 (clang, llc, lld), plus nasm 3.02, mtools and QEMU. On macOS they come from Homebrew (`odin`, `llvm@22`, `lld@22`, `nasm`, `mtools`, `qemu`); `build` calls each by absolute path and refuses other versions.

Upstream's kernel scenarios (`panic`, `phys`, `timer`, `smp`, `lower-half`, `stack-overflow`, `write-text`, `write-text-alias`) pass, with this tree's `simd`; the rest start passing as the milestones land.
