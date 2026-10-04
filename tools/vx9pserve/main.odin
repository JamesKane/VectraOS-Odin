// vx9pserve: serves a directory over 9P2000 (with lib/p9's own framework,
// upstream 04 §5 M3), for VectraOS to mount: `mount tcp!10.0.2.2!5640 /n/host`.
//
//	vx9pserve --listen ADDR:PORT DIR   one process per connection
//	vx9pserve --stdio DIR              one connection, on stdin and stdout
//	                                   (QEMU's guestfwd=...-cmd: runs it so)
//
// Messages are framed as 9P frames them: each begins with its size. A
// message too big for the msize, or too broken to answer, ends the
// connection.
//
// Build: odin build tools/vx9pserve -collection:vx=lib -collection:abi=abi -out:out/host/vx9pserve
// (after any ./build command has generated abi/vx/abi_gen.odin).
package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "vx:p9"
import "hostfs"

MSIZE :: 65536

// Fills buf from fd; false at the end of the stream, or on an error.
read_full :: proc(fd: posix.FD, buf: []u8) -> bool {
	for got := 0; got < len(buf); {
		n := posix.read(fd, raw_data(buf[got:]), c.size_t(len(buf[got:])))
		if n <= 0 {
			if n < 0 && posix.errno() == .EINTR {
				continue
			}
			return false
		}
		got += int(n)
	}
	return true
}

write_full :: proc(fd: posix.FD, buf: []u8) -> bool {
	for done := 0; done < len(buf); {
		n := posix.write(fd, raw_data(buf[done:]), c.size_t(len(buf[done:])))
		if n <= 0 {
			if n < 0 && posix.errno() == .EINTR {
				continue
			}
			return false
		}
		done += int(n)
	}
	return true
}

Connection :: struct {
	h:         hostfs.Hostfs,
	s:         p9.Server,
	req, resp: [MSIZE]u8,
}

// Serves one connection until it ends. Returns the exit status: 0 when the
// client hangs up, 1 when it breaks the protocol or the directory cannot be
// opened.
serve :: proc(dir: string, in_, out: posix.FD) -> int {
	k := new(Connection)
	defer free(k)
	if !hostfs.init(&k.h, &k.s, dir, MSIZE) {
		fmt.eprintfln("vx9pserve: cannot open %s", dir)
		return 1
	}
	defer hostfs.destroy(&k.h)
	for {
		free_all(context.temp_allocator)
		if !read_full(in_, k.req[:4]) {
			return 0 // the client hung up
		}
		size := int(k.req[0]) | int(k.req[1]) << 8 | int(k.req[2]) << 16 | int(k.req[3]) << 24
		if size < 7 || size > MSIZE || !read_full(in_, k.req[4:size]) {
			return 1
		}
		n, res := p9.serve(&k.s, k.req[:size], k.resp[:])
		if res != .Reply {
			return 1 // nothing here waits, so .Defer cannot happen
		}
		if !write_full(out, k.resp[:n]) {
			return 0
		}
	}
}

// Prints what the last call's errno says, as perror does.
perror :: proc(what: string) {
	fmt.eprintfln("%s: %s", what, posix.strerror(posix.errno()))
}

listen_on :: proc(where_, dir: string) -> int {
	colon := strings.last_index_byte(where_, ':')
	if colon < 0 || colon >= 64 {
		return 2
	}
	host := strings.clone_to_cstring(where_[:colon], context.temp_allocator)
	// As atoi reads it: the leading digits, so a bad port is 0.
	port := 0
	for ch in transmute([]u8)where_[colon + 1:] {
		if ch < '0' || ch > '9' {
			break
		}
		port = port * 10 + int(ch - '0')
	}
	a := posix.sockaddr_in {
		sin_family = .INET,
		sin_port   = posix.in_port_t(u16(port)),
	}
	when ODIN_OS == .Darwin {
		a.sin_len = size_of(a)
	}
	if posix.inet_pton(.INET, host, &a.sin_addr) != .SUCCESS {
		return 2
	}
	s := posix.socket(.INET, .STREAM)
	one: c.int = 1
	posix.setsockopt(s, posix.SOL_SOCKET, .REUSEADDR, &one, size_of(one))
	if s < 0 || posix.bind(s, (^posix.sockaddr)(&a), size_of(a)) != .OK || posix.listen(s, 16) != .OK {
		perror("vx9pserve: listen")
		return 1
	}
	posix.fcntl(s, .SETFD, posix.FD_CLOEXEC)
	posix.signal(.SIGCHLD, auto_cast posix.SIG_IGN) // children are reaped by the kernel
	for {
		conn := posix.accept(s, nil, nil)
		if conn < 0 {
			if posix.errno() == .EINTR {
				continue
			}
			perror("vx9pserve: accept")
			return 1
		}
		if posix.fork() == 0 {
			posix.close(s)
			posix._exit(c.int(serve(dir, conn, conn)))
		}
		posix.close(conn)
	}
}

main :: proc() {
	args := os.args
	switch {
	case len(args) == 3 && args[1] == "--stdio":
		os.exit(serve(args[2], posix.STDIN_FILENO, posix.STDOUT_FILENO))
	case len(args) == 4 && args[1] == "--listen":
		os.exit(listen_on(args[2], args[3]))
	}
	fmt.eprintln("usage: vx9pserve --listen ADDR:PORT DIR | --stdio DIR")
	os.exit(2)
}
