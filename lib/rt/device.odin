package rt

import vx "abi:vx"

// Device objects, minted from a Resource (abi:vx explains each).

@(require_results)
vmo_create_physical :: proc "contextless" (resource: vx.Handle, pa, size: u64) -> (vx.Handle, vx.Status) {
	h: vx.Handle
	st := status(vx_syscall(.Vmo_Create, size, u64(transmute(u32)vx.Vmo_Options{.Physical}), addr(&h), u64(resource), pa))
	return h, st
}

@(require_results)
irq_create :: proc "contextless" (resource: vx.Handle, line: u32) -> (vx.Handle, vx.Status) {
	h: vx.Handle
	st := status(vx_syscall(.Irq_Create, u64(resource), u64(line), 0, addr(&h)))
	return h, st
}

@(require_results)
irq_ack :: proc "contextless" (irq: vx.Handle) -> vx.Status {
	return status(vx_syscall(.Irq_Ack, u64(irq)))
}

@(require_results)
iorange_create :: proc "contextless" (resource: vx.Handle, base: u16, count: u32) -> (vx.Handle, vx.Status) {
	h: vx.Handle
	st := status(vx_syscall(.Iorange_Create, u64(resource), u64(base), u64(count), addr(&h)))
	return h, st
}
