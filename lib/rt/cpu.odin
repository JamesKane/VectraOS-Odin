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

// What is above userland's baseline (x86-64-v3, armv8.2-a; M6 step 6c3), to
// choose a code path at run time: a feature counts only when the CPU has it
// and the kernel saves what it needs (AVX-512's registers in XCR0; SVE, whose
// state the kernel does not save yet, never).
when ODIN_ARCH == .amd64 {
	Cpu_Feature :: enum u32 {
		Avx512, // F, DQ, BW and VL
		Vaes,
		Vpclmulqdq,
		Gfni,
		Sha,
	}
} else {
	Cpu_Feature :: enum u32 {
		Aes,
		Pmull,
		Sha2,
		Sha512,
		Sha3,
		Crc32,
		Dotprod,
		Sve,
	}
}

cpu_has :: proc "contextless" (f: Cpu_Feature) -> bool {
	c := cpu()
	when ODIN_ARCH == .amd64 {
		_, b, cx, _ := intrinsics.x86_cpuid(7, 0)
		switch f {
		case .Avx512:
			need := u32(1 << 16 | 1 << 17 | 1 << 30 | 1 << 31)
			return b & need == need && c.xfeatures & 0xe6 == 0xe6 // and opmask, ZMM_Hi256, Hi16_ZMM, AVX saved
		case .Vaes:
			return (cx >> 9) & 1 != 0
		case .Vpclmulqdq:
			return (cx >> 10) & 1 != 0
		case .Gfni:
			return (cx >> 8) & 1 != 0
		case .Sha:
			return (b >> 29) & 1 != 0
		}
	} else {
		isar0 := c.isar0
		switch f {
		case .Aes:
			return (isar0 >> 4) & 0xf >= 1
		case .Pmull:
			return (isar0 >> 4) & 0xf >= 2
		case .Sha2:
			return (isar0 >> 12) & 0xf >= 1
		case .Sha512:
			return (isar0 >> 12) & 0xf >= 2
		case .Sha3:
			return (isar0 >> 32) & 0xf >= 1
		case .Crc32:
			return (isar0 >> 16) & 0xf >= 1
		case .Dotprod:
			return (isar0 >> 44) & 0xf >= 1
		case .Sve:
			return (c.pfr0 >> 32) & 0xf >= 1 // zeroed by the kernel until it saves SVE's state
		}
	}
	return false
}
