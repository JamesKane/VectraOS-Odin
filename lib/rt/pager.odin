package rt

import vx "abi:vx"

// Pagers (abi:vx explains each): resource needs .Pager, or is the root one.

@(require_results)
pager_create :: proc "contextless" (resource, port: vx.Handle, key: u64, deadline: vx.Duration) -> (vx.Handle, vx.Status) {
	h: vx.Handle
	st := status(vx_syscall(.Pager_Create, u64(resource), u64(port), key, u64(deadline), addr(&h)))
	return h, st
}

// A VMO of size bytes whose pages the pager supplies; key names it in requests.
@(require_results)
vmo_create_pager :: proc "contextless" (pager: vx.Handle, key: u32, size: u64) -> (vx.Handle, vx.Status) {
	h: vx.Handle
	st := status(vx_syscall(.Vmo_Create, size, u64(transmute(u32)vx.Vmo_Options{.Pager}), addr(&h), u64(pager), u64(key)))
	return h, st
}

@(require_results)
pager_supply :: proc "contextless" (pager, vmo: vx.Handle, offset, size: u64, source: vx.Handle, source_offset: u64) -> vx.Status {
	return status(vx_syscall(.Pager_Supply, u64(pager), u64(vmo), offset, size, u64(source), source_offset))
}

// The dirty pages of [offset, offset + size), as ranges in out: how many.
@(require_results)
pager_dirty :: proc "contextless" (pager, vmo: vx.Handle, offset, size: u64, out: ^[vx.PAGER_RANGES]vx.Pager_Range) -> (int, vx.Status) {
	r := vx_syscall(.Pager_Op, u64(pager), u64(vmo), u64(vx.Pager_Op.Dirty), offset, size, addr(out))
	return max(int(r), 0), status(r)
}

// .Clean or .Evict over [offset, offset + size); .Resize is pager_resize,
// .Idle pager_idle and .Dirty pager_dirty.
@(require_results)
pager_op :: proc "contextless" (pager, vmo: vx.Handle, op: vx.Pager_Op, offset, size: u64) -> vx.Status {
	return status(vx_syscall(.Pager_Op, u64(pager), u64(vmo), u64(op), offset, size))
}

// Whether the caller's handle is the VMO's only reference: the pager may let it go.
@(require_results)
pager_idle :: proc "contextless" (pager, vmo: vx.Handle) -> (bool, vx.Status) {
	r := vx_syscall(.Pager_Op, u64(pager), u64(vmo), u64(vx.Pager_Op.Idle))
	return r == 1, status(r)
}

// A pager's own VMO's new size.
@(require_results)
pager_resize :: proc "contextless" (pager, vmo: vx.Handle, size: u64) -> vx.Status {
	return status(vx_syscall(.Pager_Op, u64(pager), u64(vmo), u64(vx.Pager_Op.Resize), 0, size))
}

// A resizable anonymous VMO's new size (ADR-0020); a pager-backed
// one's is its pager's (.Err_Access), any other .Err_Unsupported.
@(require_results)
vmo_resize :: proc "contextless" (vmo: vx.Handle, size: u64) -> vx.Status {
	return status(vx_syscall(.Vmo_Op, u64(vmo), u64(vx.Vmo_Resize_Op.Resize), size))
}
