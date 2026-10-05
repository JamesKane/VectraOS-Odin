package build

import "core:sys/linux"

// The terminal's width on standard output, or 0 when it is not a terminal.
terminal_cols :: proc() -> u32 {
	Winsize :: struct {
		row, col, xpixel, ypixel: u16,
	}
	ws: Winsize
	_ = linux.ioctl(linux.Fd(1), linux.TIOCGWINSZ, uintptr(&ws))
	return u32(ws.col)
}
