package rt

import "base:runtime"
import vx "abi:vx"
import "vx:ndb"

// The kernel enters _start with the task's bootstrap channel, like a C call:
// an aligned stack, a zero return address, the handle as the first argument.
// _start reads the spawn message from it and calls the program's vx_main,
// whose return value ends the thread. A program defines it, Odin's way:
//
//	@(export, link_name = "vx_main")
//	main :: proc() -> int { ... }
//
// It runs with a default context; its allocator is nil until user space has
// arenas.
foreign _ {
	vx_main :: proc "odin" () -> int ---
}

SPAWN_MAX_ARGS :: 32

// What the spawn message said: the program's name, its arguments, the
// kernel command line (the root task's), and its handles by name.
Spawn :: struct {
	name:         string,
	cmdline:      string,
	args:         [SPAWN_MAX_ARGS]string,
	argc:         int,
	text:         string, // the records, for what the runtime does not read itself (mount=, bind=)
	handles:      [vx.CHANNEL_MAX_HANDLES]vx.Handle,
	handle_names: [vx.CHANNEL_MAX_HANDLES]string,
	handle_count: int,
}

spawn: Spawn
self: vx.Handle // the task itself, from the spawn message's "self"

@(private="file")
spawn_msg: [64 * 1024]u8
@(private="file")
spawn_scratch: [16 * 1024]u8

@(export, link_name="_start")
start :: proc "c" (bootstrap: vx.Handle, arg2: u64) -> ! {
	read_spawn(bootstrap)
	context = runtime.default_context()
	exit_status := vx_main()
	flush()
	thread_exit(i64(exit_status))
}

// The handle the spawn message names `name`, taken: a second call gets
// HANDLE_NONE.
spawn_take :: proc "contextless" (name: string) -> vx.Handle {
	for i in 0 ..< spawn.handle_count {
		if spawn.handle_names[i] == name && spawn.handles[i] != vx.HANDLE_NONE {
			h := spawn.handles[i]
			spawn.handles[i] = vx.HANDLE_NONE
			return h
		}
	}
	return vx.HANDLE_NONE
}

@(private="file")
read_spawn :: proc "contextless" (bootstrap: vx.Handle) {
	got: [vx.CHANNEL_MAX_HANDLES]vx.Handle
	size, st := channel_read(bootstrap, spawn_msg[:], got[:])
	_ = handle_close(bootstrap)
	if st != .Ok {
		return
	}
	header := cast(^vx.Msg_Header)&spawn_msg[0]
	ok := size.bytes >= size_of(vx.Msg_Header) && header.ordinal == vx.SPAWN
	r := ndb.Reader{src = string(spawn_msg[size_of(vx.Msg_Header):size.bytes]), scratch = spawn_scratch[:]}
	named: [vx.CHANNEL_MAX_HANDLES]bool
	res := ndb.Result.Record
	for ok {
		rec: ndb.Record
		res = ndb.next(&r, &rec)
		if res != .Record {
			break
		}
		switch {
		case ndb.has(&rec, "spawn"):
			spawn.name, _ = ndb.get(&rec, "spawn")
		case ndb.has(&rec, "cmdline"):
			spawn.cmdline, _ = ndb.get(&rec, "cmdline")
		case ndb.has(&rec, "arg"):
			if spawn.argc < SPAWN_MAX_ARGS {
				spawn.args[spawn.argc], _ = ndb.get(&rec, "arg")
				spawn.argc += 1
			}
		case ndb.has(&rec, "handle") && !ndb.has(&rec, "mount"):
			index, iok := ndb.get_u64(&rec, "index")
			ok = iok && index < u64(size.handles) && !named[index]
			if ok {
				named[index] = true
				spawn.handle_names[index], _ = ndb.get(&rec, "handle")
			}
		}
	}
	if !ok || res == .Error {
		print("vx-rt: malformed spawn message\n")
		for h in got[:size.handles] {
			_ = handle_close(h)
		}
		spawn = {}
		return
	}
	spawn.text = r.src
	spawn.handle_count = int(size.handles)
	copy(spawn.handles[:], got[:size.handles])
	self = spawn_take("self")
}
