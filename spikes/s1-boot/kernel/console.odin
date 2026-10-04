package kernel

puts :: proc "contextless" (s: string) {
	for i in 0 ..< len(s) {
		if s[i] == '\n' {
			putc('\r')
		}
		putc(s[i])
	}
}

put_hex :: proc "contextless" (v: u64) {
	digits := "0123456789abcdef"
	buf: [18]u8
	buf[0], buf[1] = '0', 'x'
	for i in 0 ..< 16 {
		buf[17 - i] = digits[(v >> (u64(i) * 4)) & 0xf]
	}
	puts(string(buf[:]))
}

put_dec :: proc "contextless" (v: u64) {
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
	puts(string(buf[i:]))
}
