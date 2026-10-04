package kernel

import "base:intrinsics"

// The Limine boot protocol, base revision 6: the kernel asks with request
// structures in its image, between two markers, and Limine fills in their
// responses before it enters _start.

COMMON_MAGIC_0 :: 0xc7b1dd30df4c8b88
COMMON_MAGIC_1 :: 0x0a82e883a194f07b

MEMMAP_USABLE :: 0

Hhdm_Response :: struct {
	revision: u64,
	offset:   u64,
}

Hhdm_Request :: struct {
	id:       [4]u64,
	revision: u64,
	response: ^Hhdm_Response,
}

Memmap_Entry :: struct {
	base:   u64,
	length: u64,
	type:   u64,
}

Memmap_Response :: struct {
	revision:    u64,
	entry_count: u64,
	entries:     [^]^Memmap_Entry,
}

Memmap_Request :: struct {
	id:       [4]u64,
	revision: u64,
	response: ^Memmap_Response,
}

@(export, link_section=".limine_requests_start")
limine_requests_start := [4]u64{0xf6b8f4b39de7d1ae, 0xfab91a6940fcb9cf, 0x785c6ed015d3e316, 0x181e920a7852b9d9}

@(export, link_section=".limine_requests")
limine_base_revision := [3]u64{0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, 6}

@(export, link_section=".limine_requests")
hhdm_request := Hhdm_Request{id = {COMMON_MAGIC_0, COMMON_MAGIC_1, 0x48dcf1cb8ad2b852, 0x63984e959a98244b}}

@(export, link_section=".limine_requests")
memmap_request := Memmap_Request{id = {COMMON_MAGIC_0, COMMON_MAGIC_1, 0x67cf3d9d378a806f, 0xe304acdfc50c3c62}}

// Both architectures put cpu_count at offset 24: x86_64 splits the second
// word into flags and the BSP's LAPIC ID, aarch64 has flags and the BSP's
// MPIDR as words of their own.
Mp_Response :: struct {
	revision:  u64,
	flags:     u64,
	bsp_id:    u64,
	cpu_count: u64,
	cpus:      rawptr,
}

Mp_Request :: struct {
	id:       [4]u64,
	revision: u64,
	response: ^Mp_Response,
	flags:    u64,
}

@(export, link_section=".limine_requests")
mp_request := Mp_Request{id = {COMMON_MAGIC_0, COMMON_MAGIC_1, 0x95a67b819a1b857e, 0xa0b61b723b6a73e0}}

@(export, link_section=".limine_requests_end")
limine_requests_end := [2]u64{0xadc0e0531bb10d03, 0x9572709f31764c62}

// Limine writes these behind the compiler's back, so every read is volatile.
base_revision_supported :: proc "contextless" () -> bool {
	return intrinsics.volatile_load(&limine_base_revision[2]) == 0
}

hhdm_response :: proc "contextless" () -> ^Hhdm_Response {
	return intrinsics.volatile_load(&hhdm_request.response)
}

memmap_response :: proc "contextless" () -> ^Memmap_Response {
	return intrinsics.volatile_load(&memmap_request.response)
}

mp_response :: proc "contextless" () -> ^Mp_Response {
	return intrinsics.volatile_load(&mp_request.response)
}
