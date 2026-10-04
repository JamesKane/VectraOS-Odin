package kernel

// What user-space drivers get from the kernel: the Resource, Irq and IoRange
// objects, and physical VMOs. The Resource is root authority over device
// space; the kernel gives it to the root task, which mints narrower objects
// from it for each driver. Irq, IoRange and physical VMOs arrive with the
// UART drivers (P2's driver step); until then those syscalls answer
// .Err_Unsupported.

Resource :: struct {
	using obj: Object,
}

Irq :: struct {
	using obj: Object,
}

Iorange :: struct {
	using obj: Object,
}

resource_pool := Pool{size = (size_of(Resource) + 15) &~ 15}
irq_pool := Pool{size = (size_of(Irq) + 15) &~ 15}
iorange_pool := Pool{size = (size_of(Iorange) + 15) &~ 15}

root_resource :: proc "contextless" () -> ^Resource {
	r := cast(^Resource)pool_alloc(&resource_pool)
	if r == nil {
		kpanic("no memory for the root resource")
	}
	object_init(&r.obj, .Resource)
	return r
}

irq_destroy :: proc "contextless" (q: ^Irq) {
	pool_free(&irq_pool, q)
}
