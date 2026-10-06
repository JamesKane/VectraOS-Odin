package rt

import "vx:str"

// Output. To the console driver once start has connected to it (the spawn
// message's "console"), to stdout when the spawn message gives one, and to
// the kernel log before that or without either (console.odin, stdio.odin).
//
// The output buffers are shared by a program's threads: stdio_lock is held
// by each print, eprint and flush (upstream's M6 step 6d1), so threads' lines
// do not mix.

// Where print sends bytes: the console's or stdout's line buffer once one is
// attached; until then, nil, and bytes go to the kernel log.
print_hook: proc "contextless" (s: string)

@(private)
stdio_lock: Mutex

// Under stdio_lock.
@(private)
put_locked :: proc "contextless" (s: string) {
	if print_hook != nil {
		print_hook(s)
	} else {
		_ = debug_write(s)
	}
}

@(private="file")
put :: proc "contextless" (s: string) {
	mutex_lock(&stdio_lock)
	put_locked(s)
	mutex_unlock(&stdio_lock)
}

// What print takes: text, and numbers in decimal. There is no `any` without
// run-time type information, and a union needs none. An untyped integer
// constant fits both number types, so give it one: u64(n).
Print_Arg :: union {
	string,
	u64,
	i64,
}

// rt.print("bootfs: serving ", u64(files), " files\n")
print :: proc "contextless" (args: ..Print_Arg) {
	mutex_lock(&stdio_lock)
	defer mutex_unlock(&stdio_lock)
	for a in args {
		switch v in a {
		case string:
			put_locked(v)
		case u64:
			buf: [str.U64_DIGITS]u8
			put_locked(str.format_u64(buf[:], v))
		case i64:
			buf: [str.I64_DIGITS]u8
			put_locked(str.format_i64(buf[:], v))
		}
	}
}

// Sends out what has been printed without a newline yet.
flush :: proc "contextless" () {
	mutex_lock(&stdio_lock)
	console_flush()
	stdout_flush()
	mutex_unlock(&stdio_lock)
}

print_u64 :: proc "contextless" (v: u64) {
	buf: [str.U64_DIGITS]u8
	put(str.format_u64(buf[:], v))
}

print_i64 :: proc "contextless" (v: i64) {
	buf: [str.I64_DIGITS]u8
	put(str.format_i64(buf[:], v))
}

// A duration in nanoseconds, as milliseconds with three decimals.
print_millis :: proc "contextless" (ns: u64) {
	us := ns / 1000
	frac := [4]u8{'.', u8('0' + us % 1000 / 100), u8('0' + us % 100 / 10), u8('0' + us % 10)}
	mutex_lock(&stdio_lock)
	buf: [str.U64_DIGITS]u8
	put_locked(str.format_u64(buf[:], us / 1000))
	put_locked(string(frac[:]))
	mutex_unlock(&stdio_lock)
}
