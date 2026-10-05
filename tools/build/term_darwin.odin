package build

import "core:sys/darwin"

// The terminal's width on standard output, or 0 when it is not a terminal.
terminal_cols :: proc() -> u32 {
	Winsize :: struct {
		row, col, xpixel, ypixel: u16,
	}
	ws: Winsize
	_ = darwin.syscall_ioctl(1, darwin.TIOCGWINSZ, &ws)
	return u32(ws.col)
}
