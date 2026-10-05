// The heap (first fit, coalescing, in the caller's buffer), words and
// variables.
package rc

import "base:intrinsics"
import "vx:str"

@(private)
ALIGN :: 16

@(private)
Block :: struct {
	size: int, // the block's, header included
	next: ^Block, // free blocks only, in address order
}
#assert(size_of(Block) == 16)

@(private)
heap_init :: proc "contextless" (r: ^Rc, heap: []u8) -> bool {
	start := uintptr(raw_data(heap))
	base := (start + ALIGN - 1) & ~uintptr(ALIGN - 1)
	if len(heap) < MIN_HEAP + ALIGN {
		return false
	}
	size := (len(heap) - int(base - start)) & ~int(ALIGN - 1)
	r.free = (^Block)(base)
	r.free^ = {
		size = size,
	}
	r.heap_size = size
	return true
}

// n bytes, zeroed; nil when the heap is used up, which stops the script: a
// word or output left out would change what it does.
@(private)
heap_alloc :: proc "contextless" (r: ^Rc, n: int) -> rawptr {
	if n >= 0 && n <= r.heap_size { // larger can never fit, and would overflow need
		need := (n + size_of(Block) + ALIGN - 1) & ~int(ALIGN - 1)
		for p := &r.free; p^ != nil; p = &p^.next {
			b := p^
			if b.size < need {
				continue
			}
			if b.size - need >= 2 * ALIGN + size_of(Block) { // split: the rest stays free
				rest := (^Block)(uintptr(b) + uintptr(need))
				rest^ = {
					size = b.size - need,
					next = b.next,
				}
				p^ = rest
				b.size = need
			} else {
				p^ = b.next
			}
			b.next = nil
			m := rawptr(uintptr(b) + size_of(Block))
			intrinsics.mem_zero(m, b.size - size_of(Block))
			return m
		}
	}
	set_error(r, "out of memory")
	r.failed = true
	return nil
}

@(private)
heap_free :: proc "contextless" (r: ^Rc, p: rawptr) {
	if p == nil {
		return
	}
	b := (^Block)(uintptr(p) - size_of(Block))
	at := &r.free
	for at^ != nil && uintptr(at^) < uintptr(b) {
		at = &at^.next
	}
	b.next = at^
	at^ = b
	if b.next != nil && uintptr(b) + uintptr(b.size) == uintptr(b.next) { // into the next
		b.size += b.next.size
		b.next = b.next.next
	}
	prev := r.free == b ? nil : r.free
	for prev != nil && prev.next != b {
		prev = prev.next
	}
	if prev != nil && uintptr(prev) + uintptr(prev.size) == uintptr(b) { // the previous into it
		prev.size += b.size
		prev.next = b.next
	}
}

// All of an allocation's bytes, as its block's header gives them: what
// indexes into heap memory goes through this, so it stays bounds-checked.
@(private)
payload :: proc "contextless" (p: rawptr) -> []u8 {
	b := (^Block)(uintptr(p) - size_of(Block))
	return ([^]u8)(p)[:b.size - size_of(Block)]
}

// A T, and extra bytes after it, from the heap.
@(private)
heap_new :: proc "contextless" (r: ^Rc, $T: typeid, extra := 0) -> ^T {
	return (^T)(heap_alloc(r, size_of(T) + extra))
}

// --- Words ---

// The room after a word's header: its text, and what an allocation left.
@(private)
word_room :: proc "contextless" (w: ^Word) -> []u8 {
	return payload(w)[size_of(Word):]
}

// A word of s; its allocation, as upstream's, has room for a NUL.
@(private)
new_word :: proc "contextless" (r: ^Rc, s: string) -> ^Word {
	w := heap_new(r, Word, len(s) + 1)
	if w == nil {
		return nil
	}
	w.len = copy(word_room(w), s)
	return w
}

@(private)
free_words :: proc "contextless" (r: ^Rc, w: ^Word) {
	w := w
	for w != nil {
		next := w.next
		heap_free(r, w)
		w = next
	}
}

@(private)
copy_words :: proc "contextless" (r: ^Rc, w: ^Word) -> ^Word {
	head: ^Word
	tail := &head
	for x := w; x != nil; x = x.next {
		tail^ = new_word(r, text(x))
		if tail^ == nil {
			break
		}
		tail = &tail^.next
	}
	return head
}

@(private)
count_words :: proc "contextless" (w: ^Word) -> u32 {
	n: u32
	for x := w; x != nil; x = x.next {
		n += 1
	}
	return n
}

// --- Variables ---

@(private)
Var :: struct {
	next:     ^Var,
	val:      ^Word,
	fn:       ^Code, // a function: its code, from fn_pc
	fn_pc:    u32,
	// Its name follows; upstream's is a C string, so a name is only ever
	// read up to its first NUL.
	name_len: u32,
}
#assert(size_of(Var) == 32) // upstream's rc_var

@(private)
var_name :: proc "contextless" (v: ^Var) -> string {
	return string(payload(v)[size_of(Var):][:v.name_len])
}

@(private)
new_var :: proc "contextless" (r: ^Rc, name: string) -> ^Var {
	v := heap_new(r, Var, len(name) + 1)
	if v == nil {
		return nil
	}
	copy(payload(v)[size_of(Var):], name)
	v.name_len = u32(len(c_name(name)))
	return v
}

@(private)
hash :: proc "contextless" (s: string) -> u32 {
	h: u32 = 2166136261
	for i in 0 ..< len(s) {
		h = (h ~ u32(s[i])) * 16777619
	}
	return h % VARS
}

// The variable named: a local of the running frames, innermost first, then a
// global; made a global if make and there is none.
@(private)
var_find :: proc "contextless" (r: ^Rc, name: string, make: bool) -> ^Var {
	#reverse for f in r.frames {
		for v := f.locals; v != nil; v = v.next {
			if var_name(v) == name {
				return v
			}
		}
	}
	return gvar_find(r, name, make)
}

// A global variable, which is where functions live (rc's gvlook): a local of
// the same name does not hide one.
@(private)
gvar_find :: proc "contextless" (r: ^Rc, name: string, make: bool) -> ^Var {
	bucket := &r.vars[hash(name)]
	for v := bucket^; v != nil; v = v.next {
		if var_name(v) == name {
			return v
		}
	}
	if !make {
		return nil
	}
	v := new_var(r, name)
	if v == nil {
		return nil
	}
	v.next = bucket^
	bucket^ = v
	return v
}

// Sets a variable to w (which it takes): an empty list unsets it, in effect.
@(private)
set_var_words :: proc "contextless" (r: ^Rc, name: string, w: ^Word) {
	v := var_find(r, name, true)
	if v == nil {
		free_words(r, w)
		return
	}
	free_words(r, v.val)
	v.val = w
}

// As rc's: nothing in $status's first word but 0s and a pipeline's |s.
@(private)
true_status :: proc "contextless" (r: ^Rc) -> bool {
	w := get_var(r, "status")
	if w == nil {
		return true
	}
	for c in transmute([]u8)text(w) {
		if c != '0' && c != '|' {
			return false
		}
	}
	return true
}

// The error the host is shown: the parts, cut at upstream's length.
@(private)
set_error :: proc "contextless" (r: ^Rc, parts: ..string) {
	clear(&r.err)
	add_error(r, ..parts)
}

// More of it, each part read as upstream's C reads it, to its first NUL.
@(private)
add_error :: proc "contextless" (r: ^Rc, parts: ..string) {
	for p in parts {
		for c in transmute([]u8)p {
			if c == 0 || len(r.err) == ERR_MAX {
				break
			}
			append(&r.err, c)
		}
	}
}

// Where an error is, as rc's pfln: file:line, or the file alone.
@(private)
place :: proc "contextless" (buf: ^[96]u8, src: string, line: u32) -> string {
	b := str.Buf {
		buf = buf[:],
	}
	str.write_string(&b, c_name(src))
	if line != 0 {
		str.write_byte(&b, ':')
		str.write_u64(&b, u64(line))
	}
	return str.to_string(&b)
}
