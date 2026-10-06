package rt

import "base:intrinsics"
import vx "abi:vx"

// Notes (ADR-0010): Plan 9's notify, for Odin programs.
//
// A note is a string: one another process posted (thread_interrupt), or a
// fault in Plan 9's words ("sys: trap: fault read addr=0x0 pc=0x401000"). A
// program that calls notify(handler) has each one handed to handler, with
// the Exception it came in. The handler answers .Cont, to go on where the
// thread was diverted from, with the registers in the Exception (perhaps
// changed), or .Dflt, to end the program with the note as its exit string.
// A program that has not called notify ends with the note at once: the
// kernel sees to that.
//
// A fault that no handler takes is not ended here, though: note_crash takes
// the handler away and runs the instruction again, so it faults with nothing
// in the task to catch it, and goes where any unhandled fault goes: the
// task's exception port, then the kernel's default, which ends the task with
// the trap's words.
//
// The handler runs on the thread's own stack, below where it was diverted
// from, or on its note stack (ADR-0036). FP/SIMD registers, which the kernel
// does not put in an Exception, are saved by vx_note_entry (arch/*/note.S)
// before any Odin runs, and loaded again after; the handler is given them as
// fp, in the architecture's image (x86_64's XSAVE standard format, aarch64's
// vx.Fpregs), and what it changes there is what the thread goes on with.

Noted :: enum u32 {
	Cont, // go on where the thread was
	Dflt, // end the program with the note
}

Note_Handler :: #type proc "contextless" (e: ^vx.Exception, note: string, fp: rawptr) -> Noted

foreign _ {
	vx_note_entry :: proc "c" () --- // note.S, the in-task handler: an address only
}

@(private="file")
note_fn: Note_Handler

// The stack x86_64's entry takes for the XSAVE image (note.S): what this
// CPU's needs (Cpu_Info.xstate_size), 64-aligned, and 64 for the alignment;
// the most the kernel allows (a page) until notify asks. A handler on a
// small alternate stack has the rest (SIGSTKSZ is 8 KiB on x86_64): a page
// whatever the CPU needs ran a fault on such a stack past its end
// (upstream's M6 step 6d4b).
@(export, link_name = "vx_note_xsave_bytes")
note_xsave_bytes: u64 = 4096 + 64

// How .Dflt ends the program: exits, which flushes output first, unless a C
// library's back end (ports/musl/vx) has its own.
note_exit: proc "contextless" (note: string) -> !

// Hands every note to handler from now on; nil goes back to ending the
// program at the first one.
@(require_results)
notify :: proc "contextless" (handler: Note_Handler) -> vx.Status {
	when ODIN_ARCH == .amd64 {
		if size := u64(cpu().xstate_size); size >= 576 && size <= 4096 {
			note_xsave_bytes = ((size + 63) &~ 63) + 64
		}
	}
	note_fn = handler
	entry := handler != nil ? u64(uintptr(rawptr(vx_note_entry))) : 0
	return exception_bind(self, vx.HANDLE_NONE, entry, {.In_Task})
}

@(private="file")
regs_pc :: proc "contextless" (r: ^vx.Regs) -> ^u64 {
	when ODIN_ARCH == .amd64 {
		return &r.rip
	} else {
		return &r.pc
	}
}

// The fault in e again, with no in-task handler: x86_64's int3 reports the
// instruction after it, so the pc goes back to it; every other fault
// reports the instruction itself.
note_crash :: proc "contextless" (e: ^vx.Exception) -> ! {
	_ = exception_bind(self, vx.HANDLE_NONE, 0, {.In_Task})
	when ODIN_ARCH == .amd64 {
		if e.kind == .Breakpoint {
			e.regs.rip -= 1
		}
	}
	_ = exception_resume(self, 0, .Continue, &e.regs)
	intrinsics.trap() // exception_resume does not return
}

// What vx_note_entry calls, with the Exception the kernel put on the stack.
// Returns to go on.
@(export, link_name="vx_note_dispatch")
note_dispatch :: proc "c" (e: ^vx.Exception, fp: rawptr) {
	text: [vx.ERRMAX]u8
	note: string
	if e.kind == .Interrupt {
		note = string(e.note[:min(e.code, vx.ERRMAX)])
	} else {
		note = vx.trap_note(e.kind, e.code, e.address, regs_pc(&e.regs)^, &text)
	}
	if h := note_fn; h != nil && h(e, note, fp) == .Cont {
		return
	}
	if e.kind != .Interrupt {
		note_crash(e) // a fault: where unhandled faults go
	}
	if note_exit != nil {
		note_exit(note)
	}
	exits(note)
}

// Resumes the thread where it was diverted from, with the registers it has.
// The protection-key rights the kernel opened key 0 from go back first
// (ADR-0035).
@(export, link_name="vx_note_resume")
note_resume :: proc "c" (e: ^vx.Exception) -> ! {
	rights_set(e.rights)
	_ = exception_resume(self, 0, .Continue, &e.regs)
	intrinsics.trap() // exception_resume does not return
}
