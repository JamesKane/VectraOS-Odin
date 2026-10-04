# ADR-0008: compiler-rt's builtins, vendored from LLVM 22.1.8

Status: accepted, 2026-10-04. The import was reviewed by James Kane, 2026-10-04 (`third_party/VENDOR.ndb`).

## Context

Code that clang compiles calls a few routines it expects a runtime library to provide: software 128-bit floating point (aarch64's `long double` is IEEE quad, so musl's `printf` and `strtold` need `__addtf3`, `__multf3` and the like), complex multiplication (`__muldc3`), 128-bit integer division, and more. On Linux they come from libgcc or compiler-rt's builtins. The pinned toolchain (ADR-0001) has none for our targets: Homebrew's `llvm@22` ships compiler-rt for Darwin only, and Fedora's `compiler-rt` package for the host only. Writing them is a large, exacting job that LLVM has already done and tests. Upstream VectraOS made the same import for the same reason (its ADR-0008).

## Decision

- **compiler-rt's builtins** from the LLVM 22.1.8 release, the same release as the pinned clang, are vendored under `third_party/compiler-rt`: only `lib/builtins` and `LICENSE.TXT`, unchanged, as `subset=` in `VENDOR.ndb` records. The tree was copied from upstream VectraOS's vendored copy at `002a9a8` and matches the record's tree hash (`b1951f11…17ce`); it is LLVM's code, not upstream VectraOS's, so ADR-0002's clean-room rule does not apply to it. The release tarball (the whole monorepo since LLVM 18) is signed by an LLVM release manager's key (fingerprint `FFB3 3689 80F3 E6BB 5737 145A 316C 56D0 64CA CBA5`, Douglas Yung, from `releases.llvm.org/release-keys.asc`; confirm it against a second source when reviewing). Licence: Apache-2.0 with LLVM exceptions.
- **`tools/build` builds `libclang_rt.builtins.a`** for each architecture into the `vectra-musl` sysroot (ADR-0007), from `ports/compiler-rt/port.ndb`: it reads the lists named there from the vendored `CMakeLists.txt` (`GENERIC_SOURCES`, `GENERIC_TF_SOURCES`, and x86_64's `x86_80_BIT_SOURCES`), adds `atomic.c`, `clear_cache.c` and each architecture's files, and lets an architecture's file replace the generic one of the same name, as CMake's `filter_builtin_sources` does. That is the set for a hosted ELF target that is neither Apple nor Fuchsia, less what is left out:
  - `emutls.c`, `enable_execute_stack.c`, `eprintf.c`: emulated TLS and helpers for old toolchains; musl has native TLS.
  - `gcc_personality_v0.c`: needs `unwind.h`; nothing unwinds by tables.
  - aarch64's outline atomics (the `lse.S` helpers): clang does not call them for our triple.
  - aarch64's SME ABI routines and `emupac.cpp`: SME stays trapped (ADR-0004), and the second is C++.
- **Flags** as upstream's CMake sets them (`-std=c11 -fno-builtin -fvisibility=hidden`, at `-O2`), with frame pointers kept, as for musl (ADR-0007), against musl's headers for `<arch>-vectra-unknown-musl`. The objects are compiled once per architecture and cached (`out/compiler-rt/<arch>`), keyed on the tree, the port file, the build tool and musl's headers.

## Consequences

- C programs link the builtins after `libc.a`. The kernel and the Odin programs do not use them.
- Upgrading is replacing the subset with the next release's when the toolchain pin moves, and comparing the CMake lists and conditions with `port.ndb` again.
