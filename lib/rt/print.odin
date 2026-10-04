package rt

// Console output. Until the console is a server (/srv/cons, P2's driver
// step), output goes to the kernel log through debug_write, a line at a time
// (or when the buffer fills), so lines from different programs do not
// interleave.

@(private="file")
line: [512]u8
@(private="file")
line_len: int

// Sends out what has been printed without a newline yet.
flush :: proc "contextless" () {
	if line_len > 0 {
		_ = debug_write(string(line[:line_len]))
		line_len = 0
	}
}

print :: proc "contextless" (args: ..string) {
	for s in args {
		for i in 0 ..< len(s) {
			line[line_len] = s[i]
			line_len += 1
			if s[i] == '\n' || line_len == len(line) {
				flush()
			}
		}
	}
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
	print(string(buf[i:]))
}

print_i64 :: proc "contextless" (v: i64) {
	if v < 0 {
		print("-")
		print_u64(u64(0) - u64(v))
	} else {
		print_u64(u64(v))
	}
}
