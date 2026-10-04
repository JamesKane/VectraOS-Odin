package rt

import "vx:str"

// Output. To the console driver once start has connected to it (the spawn
// message's "console"), to stdout when the spawn message gives one, and to
// the kernel log before that or without either (console.odin, stdio.odin).

// Where print sends bytes: the console's or stdout's line buffer once one is
// attached; until then, nil, and bytes go to the kernel log.
print_hook: proc "contextless" (s: string)

@(private="file")
put :: proc "contextless" (s: string) {
	if print_hook != nil {
		print_hook(s)
	} else {
		_ = debug_write(s)
	}
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
	for a in args {
		switch v in a {
		case string:
			put(v)
		case u64:
			print_u64(v)
		case i64:
			print_i64(v)
		}
	}
}

// Sends out what has been printed without a newline yet.
flush :: proc "contextless" () {
	console_flush()
	stdout_flush()
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
	print_u64(us / 1000)
	put(string(frac[:]))
}
