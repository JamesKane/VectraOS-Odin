# ADR-0014: Note stacks, as upstream's ADR-0036

Status: accepted, 2026-10-06 (proposed 2026-10-05): upstream's ADR-0036 (proposed upstream 2026-10-05, `cfd25d8`, its M6 step 6d2b; accepted upstream 2026-10-06, `d3f7de5`), followed here.

## Context

Upstream's M6 step 6d2b changes the kernel/user ABI (its 01 §3) under its ADR-0036: a stack per thread for its in-task handler, so that a fault on an overflowed stack (its stack pointer in the guard page, with no room below it for the kernel's `vx_exception`) can still be caught, and POSIX's `sigaltstack` with an `SA_ONSTACK` handler means what it does on Linux. The ABI is a contract this tree copies (ADR-0002): `abi/vx/abi.odin` must say what upstream's `abi.h` says, and the manual's pages (`man/2/thread`, `man/2/exception`, `man/7/notes`, `man/7/posix`) are upstream's.

## Decision

This tree follows upstream's ADR-0036 as written, in Odin's terms:

- **`thread_state`:** `.Get_Note_Stack` and `.Set_Note_Stack`, with thread 0, the calling thread's note stack, a `vx.Note_Stack{base, size}`: size 0 for none, else at least `vx.NOTE_STACK_MIN` (2048) bytes inside user memory (`.Err_Range`); another thread's is `.Err_Invalid`. The thread keeps it in `Thread.note_stack` and `note_stack_size`, which only it changes; a new thread, fork's and exec's among them, has none.
- **The divert** (`exception_divert`): to the top of the note stack when the thread has one and its stack pointer is not on it, else below its stack pointer as before. Every note uses it, faults and interrupts alike.
- **vx:rt:** a note handler (`rt.Note_Handler`) takes a third argument, `fp`, the FP/SIMD state `vx_note_entry` saved, in the architecture's image (x86_64's XSAVE standard format, aarch64's `vx.Fpregs`); what the handler changes there is what the thread goes on with. rc and proctest take it, as upstream's do.
- **The musl back end:** `sigaltstack` sets the note stack (`ENOMEM` under `MINSIGSTKSZ`, `EPERM` while on it, `SS_AUTODISARM` refused); an `SA_ONSTACK` handler the kernel did not put on it is switched there (`be_on_stack`); a forked child sets its own again. A handler's `ucontext` carries the registers the note or fault interrupted (x86_64's `gregs`, with `fpregs` pointing at the XSAVE image; aarch64's registers, with an `fpsimd_context` in `__reserved`), and the thread resumes with what the handler leaves.

## Consequences

- The ABI, the manual's pages and every observable behaviour are upstream's.
- ktest checks the native case (a thread's stack pointer moved to unmapped memory, then a push: the handler runs on the note stack), ctest the POSIX one (a stack overflow caught on a `SIGSTKSZ` alternate stack in a 64 KiB thread).
- Upstream's `docs/adr/0036-note-stacks.md` is the reference for the rest: its alternatives and the note entry's room.
