# ADR-0017: The current directory, as upstream's ADR-0039

Status: accepted, 2026-10-06: upstream's ADR-0039 (proposed upstream the same day, `c4eb952`, its M6 step 6d7a; accepted in `d3f7de5`, and so at `5c1bbc9`), followed here.

## Context

Upstream's M6 step 6d7a puts a current directory in the native personality under its ADR-0039 and makes the spawn message's `cwd=` record, until then the musl back end's own, part of the spawn message's ABI (its `abi/vx/abi.h`; here the spawn message's comment in `abi/vx/abi.odin`). The spawn message is a contract this tree copies (ADR-0002): a child of either tree's spawner must start where its parent is, and the manual's pages (`man/1/pwd`, `ls`, `cat`, `rc`, `man/7/namespace`) are upstream's.

## Decision

This tree follows upstream's ADR-0039 as written, in Odin's terms:

- **A process's current directory is a path:** absolute and clean, at most 255 bytes, `/` to start with, kept by vx:rt for the process under an `rt.Mutex` its threads share (`lib/rt/wd.odin`): `rt.getwd(buf)` gives it, `rt.wd_set` sets a path the caller has found to be a directory.
- **A relative name is resolved against it**, lexically, wherever vx:ns takes a name: `walk`, `open`, `create`, `bind` (both names), `mount` and `unmount`, through the namespace's `getwd` hook (`ns.Namespace.getwd`, which `procns.from_spawn` sets to `rt.getwd`; nil in a host test, where a relative name is refused as before). `..` is cleaned away against the path, as 9front's follows dot's name (`fixdotdotname`).
- **Changing it:** `procns.chdir(space, path)` (upstream's `vx_chdir`, libvx's in its 6e1) resolves the name, walks and stats it (`ns.dir_check`): a directory becomes the current directory; anything else is refused, `.Err_Invalid` if it is not a directory, the walk's error otherwise, and the directory is left as it was.
- **Inherited:** `procns.spawn_records` writes `cwd=PATH` for every spawner, before the namespace's records; `rt.read_spawn` reads it at start-up, and a message without one, or with a path not absolute, leaves `/`.
- **One for both personalities:** the musl back end's working directory is vx:rt's (`cwd`, `set_cwd` over `rt.getwd` and `rt.wd_set`), so `chdir`, `getcwd`, rc's `cd` and `rt.getwd` are one directory; its `fd_records` no longer writes `cwd=`, and `from_records` leaves it to vx:rt.
- **rc's `cd`** is 9front's `execcd` (`cmd/rc`): `$cdpath` for a name not starting `/`, `./` or `../`, the directory printed when an entry other than `""` or `.` found it, `$home` without an argument, `Can't cd` and `$status` `can't cd`. A native `pwd` (`cmd/pwd`), 9front's; the native `ls` with no argument lists `.`.

## Consequences

- Relative names work natively, from Odin and from rc, and a spawned child of either personality starts where its parent was.
- As upstream's, the directory is a name, not 9front's channel: after it is renamed, relative names walk the old name and fail.
- cdtest (`tests/user/cdtest`, in Odin, upstream's 24 checks), run by rctest in the rcscript scenario, and rctest's `cd` section check it.
- Upstream's `docs/adr/0039-current-directory.md` is the reference for the rest.
