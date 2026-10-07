# ADR-0019: CPU time, sampled as 9front's, as upstream's ADR-0041

Status: accepted, 2026-10-07 (proposed 2026-10-07): upstream's ADR-0041 (proposed upstream the same day, `5096568`, its M6 step 6d9b; accepted in `bdae968`), followed here.

## Context

Upstream's M6 step 6d9b gives the kernel CPU time under its ADR-0041: a tick that samples a busy CPU's thread as 9front's `accounttime` does, `thread_state`'s `VX_STATE_GET_TIMES` and `vx_cpu_times` in the ABI, and `user=` and `sys=` in procfs's wait records, from which the musl back end answers `times`, `getrusage`, `wait4`'s rusage and the CPU-time clocks. Its 01 §8 is amended: a busy CPU takes a 10 ms tick, an idle one stays tickless. The ABI and procfs's wait record are contracts this tree copies (ADR-0002): `abi/vx/abi.odin` must say what upstream's `abi.h` says, and the manual's pages (`man/2/thread`, `man/4/procfs`, `man/7/posix`, `man/1/time`) are upstream's.

## Decision

This tree follows upstream's ADR-0041 as written, in Odin's terms:

- **A tick while busy.** A CPU running a thread, not its idle one, arms its timer for a tick every 10 ms (`TICK`, `Cpu.tick_at`), in fixed phase from when it left idle (`schedule_locked` starts it again only once it has passed); the timer is armed for whichever comes first, the tick, the slice's end, a sleeper or a budget (`sched_arm_timer`). Each tick charges the running thread one tick of user or system time by whether the interrupt came from user mode: `timer_interrupt(from_user)`, which both architectures' traps pass (`x86_trap`'s CS, `aarch64_trap`'s vector index), and `sched_timer(from_user)`, which charges every tick a late interrupt covers. An idle CPU arms no tick.
- **Kept per thread, summed per task.** `Thread.ticks`, an array indexed by `Cpu_Time` (`.User`, `.Sys`), added to atomically; a task adds a thread's to `Task.gone_ticks` when the thread is reaped, under the task's lock, so a task's time is that plus its live threads'.
- **The ABI:** `vx.Thread_State_Op.Get_Times` after `.Get_Sched`, and `vx.Cpu_Times` (`user`, `sys`, `vx.Duration`, nanoseconds in multiples of 10 ms). `thread_state(task, thread, .Get_Times, &times)` with INSPECT on the task, at any time: the thread's, or with thread 0 the whole task's (its reaped threads' too); `.Err_Not_Found` for a thread it does not have.
- **Children's in the wait record.** procfs reads an ending process's task's times, adds its own ended children's (`Proc.child_user`, `child_sys`, as 9front's `TCUser` and `TCSys`), adds the sum to its parent's, and writes it in the parent's record as `user=` and `sys=` in milliseconds, between `status=` and `real=`. The musl back end sums the records `wait4` takes into `times`' `cutime` and `cstime` and `getrusage(RUSAGE_CHILDREN)` (a forked child starts at none), and gives each to `wait4`'s rusage; `times` (in `_SC_CLK_TCK`'s 100ths, its result the monotonic clock in them), `getrusage` (`SELF`, `THREAD`, `CHILDREN`), `CLOCK_PROCESS_CPUTIME_ID` and `CLOCK_THREAD_CPUTIME_ID` (`clock_getres` 10 ms) read `.Get_Times`. `getpriority` answers 0 and `setpriority` to any other value is `EPERM`.

## Consequences

- `times`, `getrusage`, `wait4`'s rusage and the CPU-time clocks report real figures, to 10 ms, statistical as 9front's: a process that runs less than a tick at a time may be charged nothing, or a tick for a moment's work.
- A busy CPU takes up to 100 more interrupts a second; an idle one none.
- ctest's `test_cpu_time` (copied at `8385e74`) checks a spin's user time, a child's in wait4's rusage, times and `RUSAGE_CHILDREN`, and the priorities; rctest's `time` checks; tests/host/procfs checks the wait record's fields.
- Upstream's `docs/adr/0041-cpu-time.md` is the reference for the rest: 9front's and Fuchsia's models, and the gaps (another thread's or process's CPU-time clock is not given; children's times are lost across `execve`).
