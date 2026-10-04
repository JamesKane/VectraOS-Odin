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

// An MSI for the PCI function with requester ID `source`, and what the
// device must write, where, to raise it.
@(require_results)
irq_create_msi :: proc "contextless" (resource: vx.Handle, source: u32) -> (vx.Handle, vx.Msi, vx.Status) {
	h: vx.Handle
	msi: vx.Msi
	opts := u64(transmute(u32)vx.Irq_Options{.Msi})
	st := status(vx_syscall(.Irq_Create, u64(resource), u64(source), opts, addr(&h), addr(&msi)))
	return h, msi, st
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

@(require_results)
dma_domain_create :: proc "contextless" (resource: vx.Handle) -> (vx.Handle, vx.Status) {
	h: vx.Handle
	st := status(vx_syscall(.Dma_Domain_Create, u64(resource), 0, addr(&h)))
	return h, st
}

// The device address of each page of [offset, offset + size), into
// addresses[:size / 4096]; the domain holds the VMO until dma_unmap.
@(require_results)
dma_map :: proc "contextless" (domain, vmo: vx.Handle, offset, size: u64, addresses: []u64) -> vx.Status {
	if u64(len(addresses)) < size / 4096 {
		return .Err_Invalid
	}
	return status(vx_syscall(.Dma_Map, u64(domain), u64(vmo), offset, size, addr(raw_data(addresses))))
}

@(require_results)
dma_unmap :: proc "contextless" (domain, vmo: vx.Handle) -> vx.Status {
	return status(vx_syscall(.Dma_Unmap, u64(domain), u64(vmo)))
}
