# ADR-0015: Robust futexes, as upstream's ADR-0037

Status: proposed, 2026-10-05: upstream's ADR-0037 (proposed upstream the same day, `225e876`, its M6 step 6d3; still proposed at `d26fbc7`), followed here.

## Context

Upstream's M6 step 6d3 changes the kernel/user ABI under its ADR-0037: robust futexes in Linux's layout, which musl's `PTHREAD_MUTEX_ROBUST` is written against, so a lock held by a thread that dies (killed, crashed, exec'd) does not leave its waiters asleep for ever. It adds `thread_set_robust` to `abi/vx/syscalls.def` (upstream's line, copied: ADR-0002), changes how the kernel keys futexes, and gives the POSIX layer's thread ids a form a lock word can hold. `man/2/futex` and `man/7/posix` are upstream's.

## Decision

This tree follows upstream's ADR-0037 as written, in Odin's terms:

- **The lock word** is Linux's: `vx.FUTEX_WAITERS` (bit 31), `vx.FUTEX_OWNER_DIED` (bit 30), the owner in `vx.FUTEX_OWNER_MASK`.
- **`thread_set_robust(head, size, owner)`** (`rt.thread_set_robust`): the calling thread's list, three words at an 8-aligned user `head`, `size` 24, `owner` 1 to 2^30 - 1, else `.Err_Invalid`; head 0 unregisters. The thread keeps `robust_head` and `robust_owner`.
- **The walk** (`futex_robust_walk`), as the thread ends (`thread_exit_current`, which a kill and its task's end come through, while its address space is there) and at `task_exec` before the address spaces change places, after which the list is gone: at most 2048 entries and the pending one, read through the fault-safe copies; each word whose owner bits are the thread's is set to `OWNER_DIED`, `WAITERS` kept, by a fault-safe compare-and-swap, and one waiter woken if `WAITERS` was set. The compare-and-swap (`vx_user_cas32`: `lock cmpxchg` on x86_64, `ldaxr`/`stlxr` on aarch64) joins the fixup table beside the copies and `vx_user_load32`.
- **Futexes keyed by VMO and offset**, found from the task's mappings under its lock, not by physical address: one VMO mapped twice, or a pager's page evicted and supplied again in another page, is one futex. A `futex_wait` on a word whose page is absent, or whose load faults, answers `.Err_Bad_State`, so the caller loads it again and retries.
- **The musl back end's thread ids:** the first thread's is the pid; another's is its slot in the back end's table (1 to 255) shifted left 22, plus the pid, so it fits a lock word's 30 owner bits (6d2a's bit-30 ids misjudged musl's recursive and error-checking mutexes' owners). `tkill` finds the kernel thread through the slot; a `tkill` to oneself is pending on the thread; `rt_sigpending` reports the thread's set too; `set_robust_list` and `get_robust_list` map onto `thread_set_robust`. At most 255 threads besides the first (`EAGAIN` past them).

## Consequences

- The ABI and every observable behaviour are upstream's; a `futex_wait` on an absent page now answers `.Err_Bad_State`.
- ktest checks the refusals, a thread exiting with a lock (and one it lists but does not own, left alone), a raw child killed holding a lock in a shared VMO with the waiter in ktest's own task, and a waiter across an evict and supply; ctest checks the POSIX side.
- Upstream's `docs/adr/0037-robust-futexes.md` is the reference for the rest: its alternatives, and the known gap of pids past 2^22.
