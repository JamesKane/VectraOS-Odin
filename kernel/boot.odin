package kernel

import "base:intrinsics"

// The Limine boot protocol, base revision 6. The kernel asks for what it
// needs with request structures in its image; Limine finds them between the
// start and end markers and fills in their responses before entering _start.
// Limine writes them behind the compiler's back, so every read of a response
// pointer is volatile.

@(private="file")
MAGIC_0 :: 0xc7b1dd30df4c8b88
@(private="file")
MAGIC_1 :: 0x0a82e883a194f07b

Memmap_Type :: enum u64 {
	Usable                 = 0,
	Reserved               = 1,
	Acpi_Reclaimable       = 2,
	Acpi_Nvs               = 3,
	Bad_Memory             = 4,
	Bootloader_Reclaimable = 5,
	Executable_And_Modules = 6,
	Framebuffer            = 7,
	Reserved_Mapped        = 8,
}

Memmap_Entry :: struct {
	base:   u64,
	length: u64,
	type:   Memmap_Type,
}

Memmap_Response :: struct {
	revision:    u64,
	entry_count: u64,
	entries:     [^]^Memmap_Entry,
}

Hhdm_Response :: struct {
	revision: u64,
	offset:   u64,
}

// Mp_Response and Mp_Info are the architecture's (arch_*.odin): x86_64 packs
// the flags and the BSP's LAPIC ID into one word, aarch64 has the flags and
// the BSP's MPIDR as words of their own.

Cmdline_Response :: struct {
	revision: u64,
	cmdline:  cstring,
}

Address_Response :: struct {
	revision:      u64,
	physical_base: u64,
	virtual_base:  u64,
}

Rsdp_Response :: struct {
	revision: u64,
	address:  u64, // in the HHDM (physical only under base revision 3)
}

Tsc_Response :: struct {
	revision:  u64,
	frequency: u64,
}

Entropy_Response :: struct {
	revision:    u64,
	value_count: u64,
	values:      [^]u64,
}

Request :: struct($R: typeid) {
	id:       [4]u64,
	revision: u64,
	response: ^R,
}

@(export, link_section=".limine_requests_start")
limine_requests_start := [4]u64{0xf6b8f4b39de7d1ae, 0xfab91a6940fcb9cf, 0x785c6ed015d3e316, 0x181e920a7852b9d9}

@(export, link_section=".limine_requests")
limine_base_revision := [3]u64{0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, 6}

@(export, link_section=".limine_requests")
hhdm_request := Request(Hhdm_Response){id = {MAGIC_0, MAGIC_1, 0x48dcf1cb8ad2b852, 0x63984e959a98244b}}

@(export, link_section=".limine_requests")
memmap_request := Request(Memmap_Response){id = {MAGIC_0, MAGIC_1, 0x67cf3d9d378a806f, 0xe304acdfc50c3c62}}

@(export, link_section=".limine_requests")
cmdline_request := Request(Cmdline_Response){id = {MAGIC_0, MAGIC_1, 0x4b161536e598651e, 0xb390ad4a2f1f303a}}

@(export, link_section=".limine_requests")
address_request := Request(Address_Response){id = {MAGIC_0, MAGIC_1, 0x71ba76863cc55f63, 0xb2644a48c516a487}}

@(export, link_section=".limine_requests")
rsdp_request := Request(Rsdp_Response){id = {MAGIC_0, MAGIC_1, 0xc5e77b6b397e7b43, 0x27637845accdcf3c}}

@(export, link_section=".limine_requests")
tsc_request := Request(Tsc_Response){id = {MAGIC_0, MAGIC_1, 0x10f2ee1d87d195e4, 0xf747a2b78f6ddb31}}

// 32 bytes of the bootloader's entropy, for user space (root.odin).
Entropy_Request :: struct {
	id:          [4]u64,
	revision:    u64,
	response:    ^Entropy_Response,
	value_count: u64,
}

@(export, link_section=".limine_requests")
entropy_request := Entropy_Request{id = {MAGIC_0, MAGIC_1, 0x65ea80255d5682c5, 0x9117240723f493eb}, value_count = 4}

Mp_Request :: struct {
	id:       [4]u64,
	revision: u64,
	response: ^Mp_Response,
	flags:    u64,
}

@(export, link_section=".limine_requests")
mp_request := Mp_Request{id = {MAGIC_0, MAGIC_1, 0x95a67b819a1b857e, 0xa0b61b723b6a73e0}, flags = MP_REQUEST_FLAGS}

@(export, link_section=".limine_requests_end")
limine_requests_end := [2]u64{0xadc0e0531bb10d03, 0x9572709f31764c62}

response :: proc "contextless" (r: ^Request($R)) -> ^R {
	return intrinsics.volatile_load(&r.response)
}

// Addresses the kernel keeps apart by type: a physical address is never
// dereferenced (phys_to_virt gives its direct-map alias), and a user address
// only through copy_from_user and copy_to_user (syscall.odin). Kernel
// virtual addresses are pointers.
Paddr :: distinct u64
Uva :: distinct u64

Phys_Range :: struct {
	base, end: Paddr,
}

MAX_RAM_RANGES :: 128

// What the kernel keeps from the responses: Limine's own memory, where they
// live, is reclaimed once every CPU runs on the kernel's tables.
Boot_Info :: struct {
	hhdm:           u64, // virtual address = physical address + hhdm
	usable_bytes:   u64,
	cpu_count:      u64,
	cmdline:        string, // from limine.conf; empty if there is none
	kernel_phys:    Paddr, // where the kernel image is loaded, physically contiguous
	kernel_virt:    u64,
	tsc_hz:         u64, // x86_64: the TSC's frequency, from Limine
	rsdp:           Paddr, // the ACPI RSDP's physical address, or 0
	seed:           [4]u64, // the bootloader's entropy, for user space (root.odin)
	seeded:         bool,
	// Every range of RAM and firmware memory, whatever it is used for.
	ram:            [MAX_RAM_RANGES]Phys_Range,
	ram_count:      int,
	ram_incomplete: bool,
}

boot: Boot_Info

@(private="file")
boot_cmdline: [256]u8

phys_to_virt :: #force_inline proc "contextless" (pa: Paddr) -> rawptr {
	return rawptr(uintptr(u64(pa) + boot.hhdm))
}

// The physical address behind a pointer into the direct map.
virt_to_phys :: #force_inline proc "contextless" (p: rawptr) -> Paddr {
	return Paddr(u64(uintptr(p)) - boot.hhdm)
}

// Early pages, before the physical allocator exists: taken from the top of
// the largest usable region, downwards, and never returned. phys_init hands
// the allocator that region minus [early_next, early_top), then closes this
// one by setting early_limit to early_next.
early_next, early_limit, early_top: Paddr

// The physical address of `pages` zeroed, contiguous 4 KiB pages, or 0.
early_alloc :: proc "contextless" (pages: u64) -> Paddr {
	if early_next == 0 || u64(early_next - early_limit) < pages * PAGE_SIZE {
		return 0
	}
	early_next -= Paddr(pages * PAGE_SIZE)
	intrinsics.mem_zero(phys_to_virt(early_next), int(pages * PAGE_SIZE))
	return early_next
}

// Reads the responses. False if Limine does not speak base revision 6, or
// left out one the kernel cannot do without.
boot_read :: proc "contextless" () -> bool {
	if intrinsics.volatile_load(&limine_base_revision[2]) != 0 {
		return false
	}
	hh := response(&hhdm_request)
	mm := response(&memmap_request)
	addr := response(&address_request)
	if hh == nil || mm == nil || addr == nil {
		return false
	}
	boot.hhdm = hh.offset
	boot.kernel_phys = Paddr(addr.physical_base)
	boot.kernel_virt = addr.virtual_base

	largest: u64
	for e in mm.entries[:mm.entry_count] {
		#partial switch e.type {
		case .Usable, .Bootloader_Reclaimable, .Executable_And_Modules, .Acpi_Reclaimable, .Acpi_Nvs, .Reserved_Mapped:
			if boot.ram_count < MAX_RAM_RANGES {
				boot.ram[boot.ram_count] = {Paddr(e.base), Paddr(e.base + e.length)}
				boot.ram_count += 1
			} else {
				boot.ram_incomplete = true
			}
		}
		if e.type != .Usable {
			continue
		}
		boot.usable_bytes += e.length
		if e.length > largest {
			largest = e.length
			early_limit = Paddr(e.base)
			early_next = Paddr(e.base + e.length)
			early_top = early_next
		}
	}

	boot.cpu_count = 1
	if mp := intrinsics.volatile_load(&mp_request.response); mp != nil {
		boot.cpu_count = mp.cpu_count
	}
	if r := response(&rsdp_request); r != nil && r.address != 0 {
		boot.rsdp = Paddr(r.address - boot.hhdm) // the response is in memory reclaim_boot_memory frees
	}
	if tsc := response(&tsc_request); tsc != nil {
		boot.tsc_hz = tsc.frequency
	}
	if e := intrinsics.volatile_load(&entropy_request.response); e != nil && e.value_count >= len(boot.seed) {
		copy(boot.seed[:], e.values[:len(boot.seed)])
		boot.seeded = true
	}
	if c := response(&cmdline_request); c != nil && c.cmdline != nil {
		// Copied: the original is in memory reclaim_boot_memory frees.
		src := cast([^]u8)c.cmdline
		n := 0
		for n < len(boot_cmdline) && src[n] != 0 {
			boot_cmdline[n] = src[n]
			n += 1
		}
		boot.cmdline = string(boot_cmdline[:n])
	}
	return true
}

// The next space-separated word of rest^, which moves past it:
// `for w in cmdline_word(&rest)`.
cmdline_word :: proc "contextless" (rest: ^string) -> (word: string, ok: bool) {
	s := rest^
	i := 0
	for i < len(s) && s[i] == ' ' {
		i += 1
	}
	start := i
	for i < len(s) && s[i] != ' ' {
		i += 1
	}
	rest^ = s[i:]
	return s[start:i], start < i
}

// Whether the kernel command line holds this word.
cmdline_has :: proc "contextless" (word: string) -> bool {
	rest := boot.cmdline
	for w in cmdline_word(&rest) {
		if w == word {
			return true
		}
	}
	return false
}
