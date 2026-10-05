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

// The calling thread's protection-key rights (ADR-0035), its own register,
// read and set with the unprivileged instructions (x86's RDPKRU and WRPKRU,
// arch/x86_64/thread.S): no syscall. On aarch64, and on an x86 without PKU,
// there are none: 0.
when ODIN_ARCH == .amd64 {
	foreign _ {
		vx_rdpkru :: proc "c" () -> u32 ---
		vx_wrpkru :: proc "c" (v: u32) ---
	}
}

rights_get :: proc "contextless" () -> u64 {
	when ODIN_ARCH == .amd64 {
		if cpu().keys != 0 {
			return u64(vx_rdpkru())
		}
	}
	return 0
}

rights_set :: proc "contextless" (rights: u64) {
	when ODIN_ARCH == .amd64 {
		if cpu().keys != 0 {
			vx_wrpkru(u32(rights))
		}
	}
}

// Sets the calling thread's rights to a key: .Read, or .Read and .Write, or
// none (PKU has no write-only key: .Write alone is read and write).
@(require_results)
keys_set :: proc "contextless" (key: u32, rights: vx.Key_Rights) -> vx.Status {
	keys := cpu().keys
	if keys == 0 {
		return .Err_Unsupported
	}
	if key > keys || rights - {.Read, .Write} != {} {
		return .Err_Invalid
	}
	r := rights_get() &~ (3 << (2 * key))
	if .Write not_in rights {
		r |= 2 << (2 * key) // WD: no writes
	}
	if rights == {} {
		r |= 1 << (2 * key) // AD: no access at all
	}
	rights_set(r)
	return .Ok
}

// The calling thread's rights to a key, as it has them; every right where
// there are no keys.
keys_get :: proc "contextless" (key: u32) -> vx.Key_Rights {
	keys := cpu().keys
	if keys == 0 || key > keys {
		return {.Read, .Write}
	}
	r := (rights_get() >> (2 * key)) & 3
	if r & 1 != 0 {
		return {}
	}
	return r & 2 != 0 ? {.Read} : {.Read, .Write}
}
