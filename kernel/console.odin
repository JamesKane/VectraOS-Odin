package kernel

import "base:intrinsics"

// Console output, the kernel's symbol map, backtraces and panic.
//
// The kernel prints through kput. Each CPU builds its line in its own buffer
// and prints it whole, after a timestamp (time.odin), under the console lock,
// so lines from different CPUs never interleave. A line longer than the
// buffer goes out in pieces. Everything printed is also kept in kmesg, a ring
// of the latest output.

@(private="file")
console_line: [MAX_CPUS][dynamic; 512]u8

// A user thread's line of debug_write output (console_user_write).
User_Line :: [dynamic; 160]u8

@(private="file")
console_lock: Spinlock

@(private="file")
panicking: bool

// A driver has the console's device (device.odin): from then on the kernel
// writes to it only to report a panic.
console_handed_off: bool

kmesg: struct {
	buf:     [16 * 1024]u8,
	written: u64, // in all; the ring holds the last len(buf) bytes
}

// Writes to the log and the device. Called with the console lock held.
console_emit :: proc "contextless" (s: string) {
	for i in 0 ..< len(s) {
		kmesg.buf[kmesg.written % len(kmesg.buf)] = s[i]
		kmesg.written += 1
	}
	if !console_handed_off || intrinsics.atomic_load_explicit(&panicking, .Relaxed) {
		arch_console_write(s)
	}
}

@(private="file")
console_flush :: proc "contextless" () {
	line := &console_line[arch_cpu_index()]
	spin_lock(&console_lock)
	kput_stamp()
	console_emit(string(line[:]))
	spin_unlock(&console_lock)
	clear(line)
}

kput :: proc "contextless" (s: string) {
	line := &console_line[arch_cpu_index()]
	for c in transmute([]u8)s {
		append(line, c)
		if c == '\n' || len(line) == cap(line) {
			console_flush()
		}
	}
}

// One debug_write call's bytes, into the writing thread's line. User threads
// can move between CPUs between two calls, so each has a line of its own,
// which goes out whole when it ends (or fills).
console_user_write :: proc "contextless" (s: string, line: ^User_Line) {
	for c in transmute([]u8)s {
		append(line, c)
		if c != '\n' && len(line) < cap(line) {
			continue
		}
		spin_lock(&console_lock)
		kput_stamp()
		console_emit(string(line[:]))
		spin_unlock(&console_lock)
		clear(line)
	}
}

kput_u64 :: proc "contextless" (v: u64) {
	buf: [20]u8
	i := len(buf)
	n := v
	for {
		i -= 1
		buf[i] = u8('0' + n % 10)
		n /= 10
		if n == 0 {
			break
		}
	}
	kput(string(buf[i:]))
}

kput_hex :: proc "contextless" (v: u64) {
	digits := "0123456789abcdef"
	buf: [18]u8
	buf[0], buf[1] = '0', 'x'
	n := 2
	shift := 60
	for shift > 0 && (v >> uint(shift)) & 0xf == 0 {
		shift -= 4
	}
	for ; shift >= 0; shift -= 4 {
		buf[n] = digits[(v >> uint(shift)) & 0xf]
		n += 1
	}
	kput(string(buf[:n]))
}

// The symbol map, which build links into .rodata: for each function, in
// address order, a little-endian u64 address and its NUL-terminated name,
// then an address of all ones. The entries are not aligned.
//
// A symbol that only marks an address (the linker script's, or assembly's) is
// declared as a foreign procedure: Odin emits foreign variables as weak
// dllimport globals, which ELF linking cannot take (spikes/RESULTS.md).
foreign _ {
	vx_symbols :: proc "c" () ---
}

// The function containing pc, or "" if there is none.
@(private="file")
symbol_for :: proc "contextless" (pc: u64) -> (name: string, offset: u64) {
	p := cast([^]u8)rawptr(vx_symbols)
	for {
		addr := intrinsics.unaligned_load(cast(^u64)p)
		if addr == max(u64) || addr > pc {
			break
		}
		s := p[8:]
		n := 0
		for s[n] != 0 {
			n += 1
		}
		name = string(s[:n])
		offset = pc - addr
		p = p[8 + n + 1:]
	}
	return
}

@(private="file")
kput_frame :: proc "contextless" (index: int, pc, lookup: u64) {
	kput("  #")
	kput_u64(u64(index))
	kput(" ")
	kput_hex(pc)
	if name, offset := symbol_for(lookup); name != "" {
		kput(" ")
		kput(name)
		kput("+")
		kput_hex(offset + (pc - lookup))
	}
	kput("\n")
}

// Walks the frame-pointer chain. On both architectures a frame holds the
// caller's frame pointer, then the return address. The walk stops at a null,
// misaligned or lower-half pointer, or one that does not move up the stack.
backtrace :: proc "contextless" (pc, fp: u64) {
	i := 0
	if pc != 0 {
		kput_frame(i, pc, pc)
		i += 1
	}
	f := fp
	for ; i < 32 && f != 0 && f & 7 == 0 && i64(f) < 0; i += 1 {
		frame := cast([^]u64)uintptr(f)
		ret := frame[1]
		if ret == 0 {
			break
		}
		kput_frame(i, ret, ret - 1) // ret - 1 is inside the call, even at a function's end
		if frame[0] <= f {
			break
		}
		f = frame[0]
	}
}

// Starts a panic message: "vx: panic: " and whatever the caller adds with kput.
panic_start :: proc "contextless" () {
	if intrinsics.atomic_exchange(&panicking, true) {
		arch_halt() // a fault inside a panic, or two CPUs at once: stop
	}
	if len(console_line[arch_cpu_index()]) > 0 {
		kput("\n")
	}
	kput("vx: panic: ")
}

// Ends the message, prints the backtrace from pc and fp, and stops this CPU.
panic_end :: proc "contextless" (pc, fp: u64) -> ! {
	kput("\n")
	backtrace(pc, fp)
	arch_halt()
}

kpanic :: proc "contextless" (why: string) -> ! {
	panic_start()
	kput(why)
	panic_end(0, arch_frame_address())
}
