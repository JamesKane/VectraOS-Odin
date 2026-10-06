# ADR-0016: Scheduling contexts, as upstream's ADR-0038

Status: proposed, 2026-10-06: upstream's ADR-0038 (proposed upstream the same day, `bf794b7`, its M6 step 6d6c), followed here.

## Context

Upstream's M6 step 6d6c changes the kernel/user ABI (its 01 §3, §8) under its ADR-0038: the four calls `abi/vx/syscalls.def` had reserved, `sched_ctx_create`, `sched_ctx_bind`, `sched_ctx_configure` and `sched_reserve`, which answered `.Err_Unsupported`, a `SchedContext` object, and `thread_state`'s `.Get_Sched`. The ABI is a contract this tree copies (ADR-0002): `abi/vx/abi.odin` must say what upstream's `abi.h` says, and the manual's page (`man/2/sched`) is upstream's.

## Decision

This tree follows upstream's ADR-0038 as written, in Odin's terms:

- **The ABI:** `vx.Sched_Params` (an intent, flags 0, a realtime context's period, 1 ms to 10 s, and budget, 100 µs up to the period), `vx.Core_Set`, `vx.CORE_ANY`, `vx.core_tier`, `vx.core_min_capacity`, `vx.DOMAIN_ANY`, `vx.Reserve_Flags` (`.No_Smt_Siblings`, `.Same_Llc`, a `bit_set` as CODING.md has flag words), and `vx.Sched_Info`; `.Get_Sched` after `.Set_Note_Stack`. vx:rt's wrappers, `rt.sched_ctx_create`, `sched_ctx_bind`, `sched_ctx_configure`, `sched_reserve` and `rt.intent_set` (upstream's `vx_intent_set`, its 09 §5.7, in vx-rt until libvx).
- **The object:** `Sched_Ctx` (`kernel/sched.odin`), from its own pool, handles with WRITE, MANAGE, INSPECT, DUPLICATE and TRANSFER; a bound thread holds a reference (`Thread.ctx`), let go as it is reaped or destroyed. A realtime context is admitted, its budget over its period in millionths of a CPU, while every admitted one comes to at most 80% of the CPUs online, else `.Err_Refused`; reconfigured, it keeps what it had if the new budget is refused.
- **The policy:** a band of the ready queue per intent, highest first (`[vx.Intent]Fifo(Thread)`), round robin in 10 ms slices within a band; a thread made ready above one running preempts it (`kick_for`: this CPU if idle, an idle one, else the one running the lowest band below it). A realtime context is a constant-bandwidth server: charged at each switch and timer tick for the time its threads ran, throttled when spent (its threads on other CPUs interrupted), filled at its next period; the timer is armed for both.
- **Reservations:** whole CPUs from the last, never the first, all or `.Err_Refused`; a reserved CPU runs only its context's threads bound to it (`Thread.core`, a `Maybe(u32)`), and what ran there leaves, interrupted. A thread requeued where it may no longer run gets a CPU that may, by interrupt.
- **Visible:** a channel message's `sender_intent` is its sender's; `.Get_Sched` gives any thread's `Sched_Info` with INSPECT on its task, thread 0 the caller's own.

Where this tree differs is inside the kernel only: a context reconfigured while spent is filled and its threads may run at once, where upstream leaves it throttled for a refill that never comes if it is no longer realtime (UPSTREAM-FINDINGS).

## Consequences

- The ABI, the manual's pages and every observable behaviour are upstream's.
- The sched scenario's schedtest, in Odin, measures a realtime context's share and a reserved CPU's under 32 busy threads, and admission and reservation refusals.
- Upstream's `docs/adr/0038-scheduling-contexts.md` is the reference for the rest: its alternatives, and the gaps (limits system-wide until keyd, no tiers or NUMA domains, no IRQ steering, donation through `channel_call` its 6d6c2).
