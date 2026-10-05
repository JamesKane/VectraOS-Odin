# ADR-0013: Extended register state and protection keys, as upstream's ADR-0035

Status: accepted, 2026-10-05: upstream's ADR-0035 (accepted upstream the same day, `338c0fa`, amended in its M6 step 6c4, `e2942df`), followed here.

## Context

Upstream's M6 step 6c changes the kernel/user ABI (its 01 §3) under its ADR-0035: a thread's whole FP/SIMD state for a debugger, what the CPU offers user code for runtime dispatch, and protection keys. The ABI is a contract this tree copies (ADR-0002): `abi/vx/syscalls.def` is upstream's table, and `abi/vx/abi.odin` must say what upstream's `abi.h` says, so that programs, debuggers and the manual (`man/2/as`, `exception`, `thread`, copied as contracts) agree on both trees.

## Decision

This tree follows upstream's ADR-0035 as written, in Odin's terms:

- **`thread_state`:** `.Get_Xstate` and `.Set_Xstate` (the architecture's own image, `Cpu_Info.xstate_size` bytes, at most `XSTATE_MAX`, a page; a set checked as XRSTOR would, `.Err_Invalid`), and `.Get_Cpu` with thread 0, a `Cpu_Info` (`xstate_size`, `keys`; XCR0 and `mxcsr_mask` on x86_64; on aarch64 the ID registers user code needs, what the kernel does not save zeroed). `.Get_Fpregs` and `.Set_Fpregs` stay, the legacy part alone.
- **Protection keys:** `as_key_alloc` and `as_key_free` (`syscalls.def`, upstream's lines), with the task handle's MANAGE; a key on a mapping in `as_map`'s and `as_protect`'s flags word, bits 8-11, which is `vx.Map_Flags` here, a `bit_field` of the options byte and the key (CODING.md: packed fields are `bit_field`s), as `as_query` reports it; `vx.Key_Rights` for `rt.keys_set` and `rt.keys_get`, the unprivileged instruction; `.Protection_Key`, an exception kind, with the key in `Exception.key` (upstream's `reserved`) and the interrupted rights in `Exception.rights`, which `rt.note_resume` writes back.
- **Behaviour:** as upstream's: 15 keys on x86 with PKU, none on aarch64 (no CPU it runs on has FEAT_S1POE); a new task's first thread has key 0 alone open, a thread its own task makes takes its creator's rights; the kernel's user copies obey the caller's rights (`.Err_Access`); in-task handlers run with key 0 opened.

Where this tree's kernel differs from upstream's is inside the kernel only, and ADR-0004 governs it:

- **Where the state is saved.** Upstream's kernel is built for general registers alone, saves each thread's FP/SIMD state at a switch between threads, into a page allocated with the thread, and so needs `simd_begin`/`simd_end` sections for its own NEON page copies. This kernel uses vector registers everywhere (ADR-0004) and saves the user's state eagerly at every entry from user mode. The thread's XSAVE area is the page at the top of its kernel stack, under its user trap frame: one per thread, page-sized at most (the kernel refuses to boot otherwise), its size from CPUID leaf 0Dh for the XCR0 the kernel sets, x87, SSE, AVX, AVX-512's three components where the CPU has all three, and PKRU where it has PKU. Entries from user mode save there with XSAVEOPT where the CPU has it (the area is the thread's alone, at a fixed address, untouched between the XRSTOR that left it and the next entry, which XSAVEOPT's modified optimization needs), else XSAVE; nested entries from the kernel save the kernel's own state below, with XSAVE (stack memory is reused, so never XSAVEOPT); every exit loads with XRSTOR. No SIMD sections are needed: the kernel's NEON page copies are ordinary calls.
- **PKRU in the kernel.** With eager save, the live PKRU in the kernel is the running thread's, and the area's is what user mode gets back. A thread's rights are kept beside it at each switch (`Thread.rights`: read as it leaves the CPU, loaded as the next thread arrives), so a thread woken in the kernel copies to and from user memory under its own rights; the kernel's changes to a thread's rights (a handler's key 0 opened, a debugger's `.Set_Xstate`) are made in both the register or `Thread.rights` and the area.

## Consequences

- The ABI, the manual's pages and every observable behaviour are upstream's; `Exception` grows by 8 bytes, as upstream's.
- The trap path's XSAVE area grows from under 1 KiB to about 2.7 KiB where the CPU has AVX-512; a kernel stack (16 KiB) holds the user frame and one nested kernel frame with room to spare.
- Upstream's `docs/adr/0035-extended-state-and-protection-keys.md` is the reference for the ABI's details; this record says only how this tree meets it.
