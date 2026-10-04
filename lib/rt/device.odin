package rt

import vx "abi:vx"

// Device objects, minted from a Resource (abi:vx explains each).

vmo_create_physical :: proc "contextless" (resource: vx.Handle, pa, size: u64) -> (vx.Handle, vx.Status) {
	h: vx.Handle
	r := vx_syscall(.Vmo_Create, size, u64(vx.VMO_PHYSICAL), u64(uintptr(&h)), u64(resource), pa)
	return h, r < 0 ? vx.Status(r) : .Ok
}

irq_create :: proc "contextless" (resource: vx.Handle, line: u32) -> (vx.Handle, vx.Status) {
	h: vx.Handle
	r := vx_syscall(.Irq_Create, u64(resource), u64(line), 0, u64(uintptr(&h)))
	return h, r < 0 ? vx.Status(r) : .Ok
}

irq_ack :: proc "contextless" (irq: vx.Handle) -> vx.Status {
	r := vx_syscall(.Irq_Ack, u64(irq))
	return r < 0 ? vx.Status(r) : .Ok
}

iorange_create :: proc "contextless" (resource: vx.Handle, base: u16, count: u32) -> (vx.Handle, vx.Status) {
	h: vx.Handle
	r := vx_syscall(.Iorange_Create, u64(resource), u64(base), u64(count), u64(uintptr(&h)))
	return h, r < 0 ? vx.Status(r) : .Ok
}
