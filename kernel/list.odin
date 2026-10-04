package kernel

// Intrusive lists: the kernel has no allocator, so objects carry their own
// links. One element may be on several lists at once, each through a link
// of its own.

// A first-in, first-out queue, linked through each element's `next`.
Fifo :: struct($T: typeid) {
	head, tail: ^T,
}

fifo_push :: proc "contextless" (q: ^Fifo($T), x: ^T) {
	x.next = nil
	if q.tail != nil {
		q.tail.next = x
	} else {
		q.head = x
	}
	q.tail = x
}

// The oldest element, taken off the queue, or nil if it is empty.
fifo_pop :: proc "contextless" (q: ^Fifo($T)) -> ^T {
	x := q.head
	if x != nil {
		q.head = x.next
		if q.head == nil {
			q.tail = nil
		}
		x.next = nil
	}
	return x
}

// Takes x off the singly linked list starting at head^, linked through the
// field named NEXT, if it is there.
unlink :: proc "contextless" (head: ^^$T, x: ^T, $NEXT: string) {
	OFFSET :: offset_of_by_string(T, NEXT)
	for link := head; link^ != nil; link = cast(^^T)(uintptr(link^) + OFFSET) {
		if link^ == x {
			link^ = (cast(^^T)(uintptr(x) + OFFSET))^
			return
		}
	}
}
