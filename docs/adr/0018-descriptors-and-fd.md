# ADR-0018: Descriptors past 2, and `/fd`, as upstream's ADR-0040

Status: accepted, 2026-10-07 (proposed 2026-10-06): upstream's ADR-0040 (proposed upstream the same day, `e194269`, its M6 step 6d7b2; accepted in `bdae968`), followed here.

## Context

Upstream's M6 step 6d7b2 makes the spawn message's `fd=` records, until then the musl back end's own, part of the spawn message's ABI for descriptors past 2, for native programs as for POSIX ones, and gives every process a `/fd` naming its descriptors, so rc's `<{...}` and `>{...}` work as 9front's. The spawn message is a contract this tree copies (ADR-0002), and the manual's pages (`man/1/rc`, `man/7/namespace`) are upstream's.

## Decision

This tree follows upstream's ADR-0040 as written, in Odin's terms:

- **Descriptors 3 to 9 in the spawn message** are the musl back end's `fd=` records: `fd=N pipe=read|write end=NAME`, a channel end in the message carrying the pipe protocol, or `fd=N file=PATH flags=F offset=O [token=T]`, an open file, joined by its token once or else opened again by its name at the offset (the spawn message's comment in `abi/vx/abi.odin`). vx:rt keeps them (`rt.fds_from_spawn` at start-up; `rt.fd_pipe`, `rt.fd_file`), beside 0 to 2 from `stdin`, `stdout` and `stderr`; the musl back end takes them beside the three handles too, its whole table from them only when there are no handles (a POSIX parent's message).
- **A redirected file is the file:** rc gives a file it opened for 3 to 9 as a `file=` record with a token (`p9.client_share`), so a program that never reads it takes nothing from it; a here document, a capture and a pipe are relays or channels, as for 0 to 2; a file a native program was given is passed on without the token, which was good once.
- **`/fd/N`** is a copy of the opener's descriptor N, 0 to 9: the musl back end opens it as `dup`; vx:ns opens it for a native program through its `open_dev` hook, which `procns.from_spawn` sets (a file the process serves itself, `ns.Dev`, read and written with vx:rt's pipe reader, `rt.pipe_read`, factored out of `rt.read`, and `rt.pipe_send`), a file given as a descriptor joined or opened again. A descriptor the process does not have is `.Err_Not_Found`; `/fd` itself is not listed.
- **rc's `<{cmd}` and `>{cmd}`** are 9front's `Xpipefd`: a word (vx:rc's `Pipefd` node and instruction) that has the host make a pipe and start `cmd` in a child on its far end, not waited for (`rc.Host.pipefd`, cmd/rc's `pipe_fd`), and gives the command `/fd/N`, N the lowest descriptor from 3 its redirections leave free, the near end that descriptor (`rc.Fd_Pipefd`) until it has run.

## Consequences

- `cmp <{a} <{b}` and a program written for 9front that reads `/fd/3` work, natively and through musl.
- As upstream's: a file a native program passes on is opened again by name, not shared; `/fd` is a name in the process, not a device in its namespace.
- rc_test's pipefd block (tests/host/rc) and rctest's 13 checks test it; the rc cross-check's hosts have upstream's test host's pipes.
- Upstream's `docs/adr/0040-descriptors-and-fd.md` is the reference for the rest.
