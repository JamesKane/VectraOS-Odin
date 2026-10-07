# ADR-0020: Reservations, no-access and shared mappings, resizable VMOs, as upstream's ADR-0042

Status: accepted, 2026-10-07 (proposed 2026-10-07): upstream's ADR-0042 (proposed upstream the same day, `c5700f0`, its M6 step 6e1a1; accepted upstream the same day, `4e5770f`), followed here.

## Context

Upstream's M6 step 6e1a1 gives `as_reserve`, reserved since M1, its arguments under its ADR-0042, and adds `VX_AS_FIXED`, `VX_AS_RELEASE`, `VX_MAP_NOACCESS`, `VX_MAP_SHARED` and `VX_VMO_RESIZABLE` to the ABI; its step 6e1a2 builds the POSIX personality's `mprotect`, `PROT_NONE`, `MAP_SHARED` anonymous memory and `mremap` on them. The ABI is a contract this tree copies (ADR-0002): `abi/vx/abi.odin` must say what upstream's `abi.h` says, and the manual's pages (`man/2/as`, `man/2/vmo`, `man/7/posix`, `man/7/sharing`) are upstream's.

## Decision

This tree follows upstream's ADR-0042 as written, in Odin's terms:

- **`as_reserve(task, size, align, flags, &address)`**, with MANAGE on the task (`rt.as_reserve`): a reservation (`Task.resv`, 32 a task) that `as_map`'s own placement (`task_place`) never lands in, kept for the task's `as_map` at addresses inside it. `align` is 0 (a page) or a power of two up to 2^39. Without flags the base is random and aligned: sixteen draws, made before the task's lock, from the kernel's generator, a `vx:drbg` (upstream's vx-rand DRBG, as upstream's kernel includes it) mixed once from the bootloader's entropy (`boot.seed`), the tag `as_reserve` and the clock; the first that meets no mapping, no reservation and not `map_next` is taken, else `.Err_No_Memory`. With `vx.As_Options{.Fixed}` it is at `*address`, or `.Err_Exists` with `*address` the start of the first mapping or reservation in the way (`task_in_way`). `.Release` gives back the reservation starting at `*address` of exactly `size` bytes and unmaps what is in it. `as_unmap` inside a reservation leaves it reserved; a mapping at an address lies wholly inside one reservation or outside every one (`.Err_Range`, `task_resv_fits`). A forked task has its parent's; `task_exec` swaps them with the address space.
- **`vx.Map_Option.No_Access`** on `as_map` or `as_protect`, alone (`.Err_Invalid` beside `.Write` or `.Exec`): a mapping with no page entries, so any touch faults; it keeps its VMO and place, and `as_protect` gives it access again. A pager's fault (`pager_fault`), the debugger's private copy (`mapping_privatize`) and `as_protect` map no page of it.
- **`.Shared`** on `as_map` only (`.Err_Invalid` from `as_protect`, which keeps a mapping's): `task_fork_copy` maps the same VMO in the child, as it does a pager's.
- **`vx.Vmo_Option.Resizable`** on `vmo_create` (one kind at most): `vmo_op` `.Resize` changes its size through the pager's `vmo_resize`, pages added zero (if memory runs out, it keeps the size it reached), pages past a shrink out of every mapping and freed. Its page list is read under its lock, as a pager's is (`vmo_locked`): `task_map`, `task_protect`, `vmo_rw` through a bounce buffer (`.Err_Range` for a page a shrink took meanwhile), a fork's copy, the debugger's `mem_op` (`.Err_Invalid` past its end) and private copy. Any other anonymous VMO is not resized (`.Err_Unsupported`), and its readers take no lock.

## Consequences

- The loader can reserve a shared object's span, map its segments inside and leave guard pages no-access; a JIT can reserve an arena and fill it; `mprotect(PROT_NONE)` faults.
- Reservations' bases are random; `as_map`'s own placement stays a bump pointer from a fixed base, so crash addresses in the scenarios do not move. Without the bootloader's entropy the bases are predictable.
- ktest's `test_address_space` (upstream's 55 checks) and ctest's `test_mapping_kinds` test it.
- Upstream's `docs/adr/0042-reservations-and-mapping-kinds.md` is the reference for the rest: Fuchsia's VMARs and resizable VMOs, Windows' placeholders.
