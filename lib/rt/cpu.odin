package rt

import "base:intrinsics"
import vx "abi:vx"

// What the kernel saves of a thread's FP/SIMD state and lets user code use
// (ADR-0035): asked once, then kept. Code that chooses a path by the CPU
// reads it. Two threads asking at once both write the same answer.
@(private="file")
cpu_info: vx.Cpu_Info
@(private="file")
cpu_known: bool

cpu :: proc "contextless" () -> ^vx.Cpu_Info {
	if !intrinsics.atomic_load_explicit(&cpu_known, .Acquire) && thread_state(vx.HANDLE_NONE, 0, .Get_Cpu, &cpu_info) == .Ok {
		intrinsics.atomic_store_explicit(&cpu_known, true, .Release)
	}
	return &cpu_info
}
