package bus_acpi

// The OS layer ACPICA calls (acpiosxf.h), exported under ACPICA's names
// (ADR-0012): one thread, so locks and semaphores are counters and deferred
// work runs at once; memory from a heap of its own (ACPICA frees without
// saying how much); and the few C library functions ACPICA calls, since it
// is told the C library is the system's (Odin's runtime gives memset, memcpy
// and memmove). Every procedure is proc "c" and needs no context.
//
// Tables, memory, ports and PCI configuration space are in tables.odin and
// regions.odin.

import "base:intrinsics"
import vx "abi:vx"
import "acpica"
import "vx:rt"

// --- A heap: free lists by power of two, over one VMO ---

HEAP_BYTES :: 8 << 20
HEAP_CLASSES :: 17 // 16 bytes to 1 MiB

heap: []u8 // the VMO, mapped
heap_top: int // what has been handed out at least once
heap_free: [HEAP_CLASSES]^Block

// Before each allocation: its class, and a mark that it is one of ours.
Block :: struct {
	cls:   u32,
	magic: u32,
	next:  ^Block, // on a free list
}

#assert(size_of(Block) == 16)

BLOCK_MAGIC :: 0x6b6c_6261

@(export, link_name = "AcpiOsAllocate")
os_allocate :: proc "c" (size: acpica.Size) -> rawptr {
	cls: u32
	for (u64(16) << cls) < size + size_of(Block) {
		cls += 1
		if cls >= HEAP_CLASSES {
			return nil
		}
	}
	b := heap_free[cls]
	if b != nil {
		heap_free[cls] = b.next
	} else {
		want := 16 << cls
		if len(heap) - heap_top < want {
			return nil
		}
		b = cast(^Block)raw_data(heap[heap_top:])
		heap_top += want
	}
	b^ = {cls = cls, magic = BLOCK_MAGIC}
	return intrinsics.ptr_offset(b, 1)
}

@(export, link_name = "AcpiOsFree")
os_free :: proc "c" (memory: rawptr) {
	if memory == nil {
		return
	}
	b := intrinsics.ptr_offset(cast(^Block)memory, -1)
	if b.magic != BLOCK_MAGIC {
		return // not ours: kept rather than corrupt the lists
	}
	b.magic = 0
	b.next = heap_free[b.cls]
	heap_free[b.cls] = b
}

// --- One thread: locks, semaphores, threads, time ---

@(export, link_name = "AcpiOsInitialize")
os_initialize :: proc "c" () -> acpica.Status {
	return .Ok
}

@(export, link_name = "AcpiOsTerminate")
os_terminate :: proc "c" () -> acpica.Status {
	return .Ok
}

the_lock: i32 // every lock: there is no one to exclude

@(export, link_name = "AcpiOsCreateLock")
os_create_lock :: proc "c" (out: ^rawptr) -> acpica.Status {
	out^ = &the_lock
	return .Ok
}

@(export, link_name = "AcpiOsDeleteLock")
os_delete_lock :: proc "c" (lock: rawptr) {}

@(export, link_name = "AcpiOsAcquireLock")
os_acquire_lock :: proc "c" (lock: rawptr) -> acpica.Cpu_Flags {
	return 0
}

@(export, link_name = "AcpiOsReleaseLock")
os_release_lock :: proc "c" (lock: rawptr, flags: acpica.Cpu_Flags) {}

// A semaphore is its count. With one thread, what is not there now never
// comes, so a wait that would block times out at once.
@(export, link_name = "AcpiOsCreateSemaphore")
os_create_semaphore :: proc "c" (max_units, initial_units: u32, out: ^rawptr) -> acpica.Status {
	count := cast(^u32)os_allocate(size_of(u32))
	if count == nil {
		return .No_Memory
	}
	count^ = initial_units
	out^ = count
	return .Ok
}

@(export, link_name = "AcpiOsDeleteSemaphore")
os_delete_semaphore :: proc "c" (sem: rawptr) -> acpica.Status {
	os_free(sem)
	return .Ok
}

@(export, link_name = "AcpiOsWaitSemaphore")
os_wait_semaphore :: proc "c" (sem: rawptr, units: u32, timeout: u16) -> acpica.Status {
	count := cast(^u32)sem
	if count^ < units {
		return .Time
	}
	count^ -= units
	return .Ok
}

@(export, link_name = "AcpiOsSignalSemaphore")
os_signal_semaphore :: proc "c" (sem: rawptr, units: u32) -> acpica.Status {
	(cast(^u32)sem)^ += units
	return .Ok
}

@(export, link_name = "AcpiOsGetThreadId")
os_get_thread_id :: proc "c" () -> acpica.Thread_Id {
	return 1
}

@(export, link_name = "AcpiOsExecute")
os_execute :: proc "c" (type: acpica.Execute_Type, function: acpica.Osd_Exec_Callback, ctx: rawptr) -> acpica.Status {
	function(ctx) // at once: there is no other thread to give it to
	return .Ok
}

@(export, link_name = "AcpiOsWaitEventsComplete")
os_wait_events_complete :: proc "c" () {}

never: u32 // a futex word nothing wakes, to sleep on

@(export, link_name = "AcpiOsSleep")
os_sleep :: proc "c" (milliseconds: u64) {
	_ = rt.futex_wait(&never, 0, rt.clock_read() + vx.Instant(milliseconds * 1_000_000))
}

@(export, link_name = "AcpiOsStall")
os_stall :: proc "c" (microseconds: u32) {
	until := rt.clock_read() + vx.Instant(u64(microseconds) * 1000)
	for rt.clock_read() < until {}
}

@(export, link_name = "AcpiOsGetTimer")
os_get_timer :: proc "c" () -> u64 {
	return u64(rt.clock_read()) / 100 // in 100 ns units
}

// The SCI: no events are delivered yet.
@(export, link_name = "AcpiOsInstallInterruptHandler")
os_install_interrupt_handler :: proc "c" (interrupt: u32, handler: acpica.Osd_Handler, ctx: rawptr) -> acpica.Status {
	return .Ok
}

@(export, link_name = "AcpiOsRemoveInterruptHandler")
os_remove_interrupt_handler :: proc "c" (interrupt: u32, handler: acpica.Osd_Handler) -> acpica.Status {
	return .Ok
}

@(export, link_name = "AcpiOsSignal")
os_signal :: proc "c" (function: u32, info: rawptr) -> acpica.Status {
	return .Ok
}

@(export, link_name = "AcpiOsEnterSleep")
os_enter_sleep :: proc "c" (state: u8, rega, regb: u32) -> acpica.Status {
	return .Ok
}

@(export, link_name = "AcpiOsPredefinedOverride")
os_predefined_override :: proc "c" (init: ^acpica.Predefined_Names, new_value: ^cstring) -> acpica.Status {
	new_value^ = nil
	return .Ok
}

@(export, link_name = "AcpiOsTableOverride")
os_table_override :: proc "c" (existing: ^acpica.Table_Header, new_table: ^^acpica.Table_Header) -> acpica.Status {
	new_table^ = nil
	return .Ok
}

@(export, link_name = "AcpiOsPhysicalTableOverride")
os_physical_table_override :: proc "c" (existing: ^acpica.Table_Header, new_address: ^acpica.Physical_Address, new_length: ^u32) -> acpica.Status {
	new_address^ = 0
	new_length^ = 0
	return .Ok
}

// --- Output ---

@(export, link_name = "AcpiOsVprintf")
os_vprintf :: proc "c" (format: cstring, args: ^intrinsics.c_va_list) {
	buf: [256]u8
	n := acpica.vsnprintf(&buf[0], len(buf), format, args)
	if n > 0 {
		rt.print(string(buf[:min(int(n), len(buf) - 1)]))
	}
}

@(export, link_name = "AcpiOsPrintf")
os_printf :: proc "c" (format: cstring, #c_vararg args: ..rawptr) {
	list: intrinsics.c_va_list
	intrinsics.c_va_start(&list, args)
	os_vprintf(format, &list)
	intrinsics.c_va_end(&list)
}

// --- The stack protector ACPICA is compiled with (global guard) ---

@(export, link_name = "__stack_chk_guard")
stack_chk_guard: u64 = 0x2e0f_5b3c_9d81_a647 // a constant, as upstream's runtime has it

// A smashed stack in ACPICA ends in a trap, which the kernel reports as the
// task's fault.
@(export, link_name = "__stack_chk_fail")
stack_chk_fail :: proc "c" () -> ! {
	intrinsics.trap()
}

// --- The C library functions ACPICA calls ---

@(export, link_name = "memcmp")
c_memcmp :: proc "c" (a, b: [^]u8, n: uint) -> i32 {
	for i in 0 ..< n {
		if a[i] != b[i] {
			return i32(a[i]) - i32(b[i])
		}
	}
	return 0
}

@(export, link_name = "strlen")
c_strlen :: proc "c" (s: [^]u8) -> uint {
	n: uint
	for s[n] != 0 {
		n += 1
	}
	return n
}

@(export, link_name = "strcmp")
c_strcmp :: proc "c" (a, b: [^]u8) -> i32 {
	i := 0
	for a[i] != 0 && a[i] == b[i] {
		i += 1
	}
	return i32(a[i]) - i32(b[i])
}

@(export, link_name = "strncmp")
c_strncmp :: proc "c" (a, b: [^]u8, n: uint) -> i32 {
	for i in 0 ..< n {
		if a[i] != b[i] || a[i] == 0 {
			return i32(a[i]) - i32(b[i])
		}
	}
	return 0
}

@(export, link_name = "strcpy")
c_strcpy :: proc "c" (d, s: [^]u8) -> [^]u8 {
	i := 0
	for {
		d[i] = s[i]
		if s[i] == 0 {
			return d
		}
		i += 1
	}
}

@(export, link_name = "strncpy")
c_strncpy :: proc "c" (d, s: [^]u8, n: uint) -> [^]u8 {
	i: uint
	for ; i < n && s[i] != 0; i += 1 {
		d[i] = s[i]
	}
	for ; i < n; i += 1 {
		d[i] = 0
	}
	return d
}

@(export, link_name = "strcat")
c_strcat :: proc "c" (d, s: [^]u8) -> [^]u8 {
	_ = c_strcpy(d[c_strlen(d):], s)
	return d
}

@(export, link_name = "strchr")
c_strchr :: proc "c" (s: [^]u8, c: i32) -> [^]u8 {
	for i := 0; ; i += 1 {
		if s[i] == u8(c) {
			return s[i:]
		}
		if s[i] == 0 {
			return nil
		}
	}
}

@(export, link_name = "toupper")
c_toupper :: proc "c" (c: i32) -> i32 {
	return c >= 'a' && c <= 'z' ? c - 32 : c
}

@(export, link_name = "tolower")
c_tolower :: proc "c" (c: i32) -> i32 {
	return c >= 'A' && c <= 'Z' ? c + 32 : c
}

@(export, link_name = "isdigit")
c_isdigit :: proc "c" (c: i32) -> i32 {
	return i32(c >= '0' && c <= '9')
}

@(export, link_name = "isupper")
c_isupper :: proc "c" (c: i32) -> i32 {
	return i32(c >= 'A' && c <= 'Z')
}

@(export, link_name = "islower")
c_islower :: proc "c" (c: i32) -> i32 {
	return i32(c >= 'a' && c <= 'z')
}

@(export, link_name = "isalpha")
c_isalpha :: proc "c" (c: i32) -> i32 {
	return i32(c_isupper(c) != 0 || c_islower(c) != 0)
}

@(export, link_name = "isxdigit")
c_isxdigit :: proc "c" (c: i32) -> i32 {
	return i32(c_isdigit(c) != 0 || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))
}

@(export, link_name = "isspace")
c_isspace :: proc "c" (c: i32) -> i32 {
	return i32(c == ' ' || (c >= 9 && c <= 13))
}

@(export, link_name = "isprint")
c_isprint :: proc "c" (c: i32) -> i32 {
	return i32(c >= 32 && c < 127)
}
