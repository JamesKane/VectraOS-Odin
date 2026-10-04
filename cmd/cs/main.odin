// cs QUERY: asks the connection server (/net/cs) what to dial for
// "NET!HOST!SERVICE", and prints its answer, a line for each address.
// cs -d NAME: asks /net/dns for NAME's addresses instead.
package cs

import vx "abi:vx"
import "vx:ns"
import "vx:p9"
import "vx:procns"
import "vx:rt"
import "vx:str"

space: ns.Namespace

// Sends the query (which waits while the name is looked up).
@(require_results)
ask :: proc(f: ^ns.File, path, q: string, dns: bool) -> vx.Status {
	procns.from_spawn(&space) or_return
	ns.open(&space, path, p9.ORDWR, f) or_return
	text_buf: [256]u8
	text, _ := str.join(text_buf[:], q, dns ? " ip" : "")
	_ = ns.write(f, transmute([]u8)text) or_return
	return .Ok
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	args := rt.args()
	dns := len(args) == 2 && args[0] == "-d"
	if len(args) != (dns ? 2 : 1) || len(args[dns ? 1 : 0]) > 250 {
		rt.print("usage: cs NET!HOST!SERVICE, or cs -d NAME\n")
		return 1
	}
	q := args[dns ? 1 : 0]
	f: ns.File
	if st := ask(&f, dns ? "/net/dns" : "/net/cs", q, dns); st != .Ok {
		rt.print("cs: ", q, ": ", st == .Err_Not_Found ? "no such name" : p9.error_text(st), "\n")
		return 1
	}
	// Each read is a line, from the start of the answer.
	f.offset = 0
	line: [256]u8
	for {
		n, _ := ns.read(&f, line[:])
		if n <= 0 {
			break
		}
		rt.print(string(line[:n]))
	}
	ns.close(&f)
	return 0
}
