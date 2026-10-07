# ADR-0022: Environment groups, as upstream's ADR-0044

Status: proposed, 2026-10-07: upstream's ADR-0044 (proposed upstream the same day, `59ed740`, its M6 step 6e1c1, with 6e1c2 and 6e1c3 its later steps; still proposed at `a6f0916`), followed here.

## Context

Upstream's M6 step 6e1c (split in three: 6e1c1 `/env`, 6e1c2 the temporary directory, 6e1c3 identity) gives every process an environment group as 9front's `Egrp`: `/env`, shared by a process and its children unless `rfork e` or `E` says otherwise, served by a new server, envd. It adds the `envgroup=` spawn record and the `srv:env` connector to the spawn message's conventions, and `/env` to every process that has a connector to envd. The spawn message, the scenarios and the manual's pages (`man/4/envd`, `man/1/rc`) are contracts this tree copies (ADR-0002).

## Decision

This tree follows upstream's ADR-0044 as written, in Odin's terms:

- **envd** (`servers/envd`) serves the groups, posted as `/srv/env` (`boot/svc/env.ndb`, with `entropy`). A group is a directory of variables, each a file holding its value. An attach names one: `new` (empty), `+TOKEN` (a copy: `rfork e`) or `TOKEN` (that group). Its token, the root's qid path, is 64 random bits from the server's generator (`p9.Shared.random`, seeded from the manifest's entropy); a group goes with its last fid (`p9.Fs.fid_node`). No permissions: the token is the capability.
- **`/env` is the process's own.** vx:ns keeps a connection apart from the namespace's (`ns.ENV_CONN`, the slot past `MAX_CONNS` that no mount and no group table names; `Namespace.env_root`) and resolves `/env` and the names below it on that connection before the table (`resolve_env`), attaching on first use through the `env_attach` hook, which vx:procns sets in `from_spawn`. A process without a connector to envd has no such `/env`: the table decides.
- **Children share it.** `procns.spawn_records` gives each child the group's token (`envgroup=TOKEN`) and a duplicate of envd's connector (`srv:env`); a process attaches to the group its parent named, and after a POSIX fork (`procns.after_fork`) to its parent's, through a connection of its own. A process with no group to join starts a new one filled from its `env=` records. `connect=env` in a manifest gives a service the connector (the console shell's, rctest's and ctest's).
- **`env=` records stay**, the program's environment at start; `/env` is the shared store beside them.
- **rc** writes each variable and function that changed since its last spawn to `/env` as it starts a program (9front's `Updenv`: `updenv`, its FNV-1a hashes kept per name); `rfork e` gives the shell a copy of its group, `rfork E` an empty one (`procns.env_fork`).

The later steps are recorded in [milestones](../milestones.md): 6e1c2 (each user's own `/tmp`: tmpfs's trees by aname) and 6e1c3 (identity: POSIX's user and group ids from users(6), `/sys/name`).

## Consequences

- `cat /env/NAME`, `ls /env` and `echo value > /env/NAME` work for native and POSIX programs alike; a child's write is its parent's and siblings' to read; rc's `rfork e` and `E` mean what they mean in 9front.
- A process that starts children costs one connection and attach to envd; one that never touches `/env` and starts none costs nothing.
- As upstream's: a child whose parent exits before the child first uses `/env` finds the group gone and starts its own; rc writes variables at spawns, not at assignments, and does not remove one it deletes; envd's groups are in its memory and go with it.
- rctest's `/env` checks and ctest's `test_env_group` (copied at upstream's `59ed740`) test it.
- Upstream's `docs/adr/0044-environment-groups.md` is the reference for the rest.
