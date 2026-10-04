# ADR-0010: sbase, vendored unchanged, as the POSIX userland's commands

Status: accepted, 2026-10-04. The import was reviewed by James Kane, 2026-10-04 (`third_party/VENDOR.ndb`).

## Context

Upstream's M4 gives the POSIX userland its commands with sbase: suckless's POSIX tools, about 100 small C programs with two small libraries and no dependency but a C library (upstream's ADR-0016). One of the M4-era scenarios this tree is judged by runs them (`tests/qemu/m4/sbase.ndb`, through `tests/posix/sbasetest.c`). First-party commands of some of the same names (`ls`, `cat`, `echo`, `tail`) already serve native programs and `gsh`.

## Decision

- **sbase at commit `c546c3a`** (2026-05-25) is vendored unchanged under `third_party/sbase`. sbase makes no releases, so the import is pinned as u9fs is (ADR-0006): `git.tree=` records the commit's tree id, which the files reproduce. The tree was copied from upstream VectraOS's vendored copy at `002a9a8` and matches the record's tree hash (`ceb8836f…ecb`); it is suckless's code, not upstream VectraOS's, so ADR-0002's clean-room rule does not apply to it. When reviewing, compare against a clone of `git.suckless.org/sbase`. Licence: MIT, with libutf and a few files under their own permissive notices, as `LICENSE` lists.
- **Generated files**, made once at vendoring as sbase's Makefile would, are committed under `ports/sbase/generated/`: `bc.c`, from `bc.y` by `bison -y` (GNU Bison 3.8.2; its skeleton's exception lets the parser be used under sbase's licence), and `getconf.h`, from `scripts/getconf.sh`. Both were copied from upstream and regenerated here on 2026-10-04 (Homebrew's Bison 3.8.2): byte-identical. `ports/sbase/config.h` defines `PREFIX`, which the Makefile passes on the command line, as `/boot`.
- **The build** is `tools/build`'s, from `ports/sbase/port.ndb`: the Makefile's `CPPFLAGS` with `-std=c99 -O2` and frame pointers kept (ADR-0007), its `LIBUTFOBJ` and `LIBUTILOBJ` archived, and each of its `BIN` from its own sources, compiled once per architecture and cached (`out/sbase/<arch>`). The programs are linked into one binary, as the Makefile's `sbase-box` target does: each program's `main` is renamed `NAME_main` by `-Dmain=NAME_main` on its command line (`mkbox` makes edited copies instead; the tree stays unedited), and the build generates the box's `main`, which runs the program its name names (`[` is `test`). `make` is linked alone, as `mkbox` leaves it out: its globals clash with `bc`'s and libutil's. A hundred static programs would each carry musl and the back end. The outputs are `out/<arch>/<mode>/bin/posix/sbase-box` and `make`.
- **Where the commands are to go**: `/boot/bin/posix`, holding `sbase-box`, `make`, and each command's name (and `[`) as a hard link to the box, with bc's library at `/boot/share/misc/bc.library` (`install=`). The POSIX namespace template is to bind `/boot/bin/posix` before `/boot/bin` on `/bin`, as Plan 9's APE binds `/bin/ape` over `/bin`: POSIX programs find sbase's `ls`, native programs and `gsh` keep the first-party commands.
- **Not in an image yet.** sbase links only once musl's back end exists (ADR-0007); until then `./build all` compiles it and does not link it. The image (and the hard links bootfs needs for the box's names) comes with the back end.

## Known issues at `c546c3a`

- `rev` and `tail -m` are broken: sbase commit `3de61ef` (2025-03-21) replaced `(c & 0xC0) == 0x80`, a continuation byte, with `UTF8_POINT(c)`, which is true for the other bytes. `rev` prints lines unreversed, and `tail -m` counts the wrong bytes. Not carried as a patch: the tree stays as sbase has it; take the fix with the next import.
- Commands that need what VectraOS does not have fail when they ask for it: `chroot`, `mknod`, `nice` and `renice`, `chown` and `chgrp` to anyone (one user), `hostname` to set, `logger` (no syslog), `cron`. They are built, since they are part of the set, and report the error they get.

## Consequences

- Upgrading is replacing the tree with a newer commit's, regenerating `bc.c` and `getconf.h`, and checking the Makefile's lists against `port.ndb`.
- sbase's code is not under the house rules; its warnings stay as sbase has them.
- The box needs every program in it free of clashing globals, as sbase's own `sbase-box` does; a new program that clashes is linked alone (`alone=yes`).
