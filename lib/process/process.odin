// vx:process, registering a process with procfs (upstream ADR-0011), the
// user-space half of Plan 9's rfork. Everything else about processes is a
// file in /proc.
//
// A process's pid is its first task's kernel id, which is never reused.
// Whoever spawns a child registers it before it runs, with a channel call on
// procfs's listen channel (the post /srv/proc, or the connector a namespace
// mounted /proc from) carrying a handle to the child's task. procfs keeps the
// handle: it watches for the task's end, to queue a wait record for the
// parent, and it is what posts notes and stops. exec keeps the task
// (ADR-0012), so it needs no registering.
package process

import vx "abi:vx"

REGISTER :: u32(0x636f_7270) // "proc", beside P9_CONNECT on the same channel
PROF :: u32(0x666f_7270) // "prof": a process's profiling ring (vx:prof)

Flag :: enum u32 {
	No_Wait = 0, // the parent wants no wait record (Plan 9's RFNOWAIT): it watches the task itself
	Note_Group = 1, // a note group of its own, rather than the parent's (RFNOTEG)
	Set_Sid = 2, // a session of its own too, and a note group (POSIX's setsid, posix_spawn's SETSID)
}
Flags :: bit_set[Flag; u32]

#assert(u32(Flag.Set_Sid) == 2) // PROC_SETSID is 4 on the wire

// REGISTER: arg[0] the parent's pid, arg[1] the Flags, arg[2] a note group
// in the parent's session for the child to join (0: none, as the flags say);
// handles [the child's task]. The reply: header.flags 0 or a vx.Status,
// arg[0] the child's pid.
//
// PROF: arg[0] the process's pid, arg[1] where it maps the ring; handles
// [the ring's VMO]. procfs maps it too, and takes it only if the nonce in it
// is what the process's memory has at that address. The reply: header.flags
// 0 or a vx.Status.
Msg :: struct {
	header: vx.Msg_Header,
	arg:    [3]i64,
}

#assert(size_of(Msg) == 40)

// The status a reply carries in its header's flags.
reply_status :: proc "contextless" (m: ^Msg) -> vx.Status {
	return vx.Status(i32(m.header.flags))
}
