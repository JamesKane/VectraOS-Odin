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

// The machine off (.Off), with the root Resource: returns only if it did not happen.
@(require_results)
system_power :: proc "contextless" (resource: vx.Handle, op: vx.Power_Op) -> vx.Status {
	return status(vx_syscall(.System_Power, u64(resource), u64(op)))
}

// A DmaDomain for the PCI function whose requester ID is source (devmgr's).
@(require_results)
dma_domain_create :: proc "contextless" (resource: vx.Handle, source: u32) -> (vx.Handle, vx.Status) {
	h: vx.Handle
	st := status(vx_syscall(.Dma_Domain_Create, u64(resource), u64(source), 0, addr(&h)))
	return h, st
}

// The device address of each page of [offset, offset + size), into
// addresses[:size / 4096], and the mapping: options say what the device may
// do. Let go by dma_unmap.
@(require_results)
dma_map :: proc "contextless" (domain, vmo: vx.Handle, offset, size: u64, options: vx.Dma_Options, addresses: []u64) -> (vx.Handle, vx.Status) {
	if u64(len(addresses)) < size / 4096 {
		return vx.HANDLE_NONE, .Err_Invalid
	}
	m := vx.Dma_Mapped {
		addresses = raw_data(addresses),
	}
	st := status(vx_syscall(.Dma_Map, u64(domain), u64(vmo), offset, size, u64(transmute(u32)options), addr(&m)))
	return st == .Ok ? m.mapping : vx.HANDLE_NONE, st
}

// The device is done with the mapping: unmapped, and its handle closed.
@(require_results)
dma_unmap :: proc "contextless" (mapping: vx.Handle) -> vx.Status {
	st := status(vx_syscall(.Dma_Unmap, u64(mapping)))
	_ = handle_close(mapping)
	return st
}

// .Revoke and .Quiesced (the domain's owner), or .Faults: how many the
// IOMMU has reported.
@(require_results)
dma_domain_op :: proc "contextless" (domain: vx.Handle, op: vx.Dma_Op) -> (u64, vx.Status) {
	r := vx_syscall(.Dma_Domain_Op, u64(domain), u64(op))
	return u64(max(r, 0)), status(r)
}
