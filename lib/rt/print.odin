package rt

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

print :: proc "contextless" (args: ..string) {
	for s in args {
		put(s)
	}
}

// Sends out what has been printed without a newline yet.
flush :: proc "contextless" () {
	console_flush()
	stdout_flush()
}

print_u64 :: proc "contextless" (v: u64) {
	buf: [20]u8
	i := len(buf)
	n := v
	for {
		i -= 1
		buf[i] = u8('0' + n % 10)
		n /= 10
		if n == 0 {
			break
		}
	}
	put(string(buf[i:]))
}

print_i64 :: proc "contextless" (v: i64) {
	if v < 0 {
		put("-")
		print_u64(u64(0) - u64(v))
	} else {
		print_u64(u64(v))
	}
}

// A duration in nanoseconds, as milliseconds with three decimals.
print_millis :: proc "contextless" (ns: u64) {
	us := ns / 1000
	frac := [4]u8{'.', u8('0' + us % 1000 / 100), u8('0' + us % 100 / 10), u8('0' + us % 10)}
	print_u64(us / 1000)
	put(string(frac[:]))
}
