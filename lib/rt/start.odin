package rt

import "base:runtime"
import vx "abi:vx"
import "vx:memory"
import "vx:ndb"
import "vx:str"

// The kernel enters _start with the task's bootstrap channel, like a C call:
// an aligned stack, a zero return address, the handle as the first argument.
// _start reads the spawn message from it and calls the program's vx_main,
// whose return value ends the program: 0 with the empty exit string
// (success), anything else with its decimal value, as APE's exit(n) does
// (ADR-0010). A program defines it, Odin's way:
//
//	@(export, link_name = "vx_main")
//	vx_main :: proc() -> int { ... }
//
// It runs with a default context; its allocator is nil until user space has
// arenas.
//
// A C library's back end (ports/musl/vx, ADR-0007) uses this package for its
// calls and its spawn message but has an entry of its own, and no vx_main:
// it is built with -define:VX_RT_START=false, which leaves _start out.
RT_START :: #config(VX_RT_START, true)


// arg= and env= records each: a spawn message (64 KiB) holds about that many
// short ones. A sender with more fails (E2BIG); a message with more is
// refused, not cut short.
SPAWN_MAX_ARGS :: 4096

// What the spawn message said: the program's name, its arguments and
// environment, the kernel command line (the root task's), and its handles by
// name. handles and handle_names are indexed by the message's index= values.
Spawn :: struct {
	name:         string,
	cmdline:      string,
	args:         [dynamic; SPAWN_MAX_ARGS]string, // in order
	argv0:        string, // argv0=, the POSIX argv[0] (has_argv0), rather than spawn=
	has_argv0:    bool,
	envs:         [dynamic; SPAWN_MAX_ARGS]string, // env=, each NAME=VALUE, in order
	text:       string, // the records, for what the runtime does not read itself (mount=, bind=)
	handles:      [vx.CHANNEL_MAX_HANDLES]vx.Handle,
	handle_names: [vx.CHANNEL_MAX_HANDLES]string,
	handle_count: int,
}

spawn: Spawn
self: vx.Handle // the task itself, from the spawn message's "self"

// The bootstrap message: its header, then its records.
@(private="file")
spawn_msg: struct {
	header:  vx.Msg_Header,
	records: [64 * 1024 - size_of(vx.Msg_Header)]u8,
}
#assert(size_of(spawn_msg) == 64 * 1024)
@(private="file")
spawn_scratch: [64 * 1024]u8 // decoded values, which never grow

foreign _ {
	vx_main :: proc "odin" () -> int ---
}

// Not exported without RT_START: then nothing reaches it, and it is not
// compiled, nor is the vx_main it calls asked for.
@(export=RT_START, link_name="_start")
start :: proc "c" (bootstrap: vx.Handle, arg2: u64) -> ! {
	read_spawn(bootstrap)
	stdio_init()
	context = runtime.default_context()
	exit_status := vx_main()
	if exit_status == 0 {
		exits("")
	}
	buf: [str.I64_DIGITS]u8
	exits(str.format_i64(buf[:], i64(exit_status)))
}

// The program's arguments, from the spawn message's arg= records.
args :: proc "contextless" () -> []string {
	return spawn.args[:]
}

// The first record of the spawn message that has `key`. Its values stay
// valid until the next call.
@(require_results)
spawn_record :: proc "contextless" (key: string, out: ^ndb.Record) -> bool {
	@(static) scratch: [vx.CHANNEL_MAX_BYTES]u8
	r := ndb.Reader{src = spawn.text, scratch = scratch[:]}
	for ndb.next(&r, out) == .Record {
		if ndb.has(out, key) {
			return true
		}
	}
	return false
}

// The size of the boot image, from the spawn message's bootimage record
// (svcd's and bootfs's); ok is false without one. Round it with
// memory.page_round before mapping it: it is the parent's number.
@(require_results)
boot_image_size :: proc "contextless" () -> (size: u64, ok: bool) {
	rec: ndb.Record
	spawn_record("bootimage", &rec) or_return
	return ndb.get_u64(&rec, "size")
}

// The handle the spawn message names `name`, taken: a second call gets
// HANDLE_NONE.
spawn_take :: proc "contextless" (name: string) -> vx.Handle {
	for &h, i in spawn.handles[:spawn.handle_count] {
		if spawn.handle_names[i] == name && h != vx.HANDLE_NONE {
			taken := h
			h = vx.HANDLE_NONE
			return taken
		}
	}
	return vx.HANDLE_NONE
}

// Reads the spawn message from the bootstrap channel, which it closes, into
// spawn and self. _start calls it; a C library's back end, from its own
// entry.
read_spawn :: proc "contextless" (bootstrap: vx.Handle) {
	got: [vx.CHANNEL_MAX_HANDLES]vx.Handle
	size, st := channel_read(bootstrap, memory.ptr_to_bytes(&spawn_msg), got[:])
	_ = handle_close(bootstrap)
	if st != .Ok {
		return
	}
	ok := size.bytes >= size_of(vx.Msg_Header) && spawn_msg.header.ordinal == vx.SPAWN
	r: ndb.Reader
	if ok {
		r = {src = string(spawn_msg.records[:size.bytes - size_of(vx.Msg_Header)]), scratch = spawn_scratch[:]}
	}
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
			arg, _ := ndb.get(&rec, "arg")
			ok = append(&spawn.args, arg) == 1 // more than fit: refused
		case ndb.has(&rec, "argv0"):
			spawn.argv0, _ = ndb.get(&rec, "argv0")
			spawn.has_argv0 = true
		case ndb.has(&rec, "env"):
			env, _ := ndb.get(&rec, "env")
			ok = append(&spawn.envs, env) == 1
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
		close_all(..got[:size.handles])
		spawn = {}
		return
	}
	spawn.text = r.src
	spawn.handle_count = int(size.handles)
	copy(spawn.handles[:], got[:size.handles])
	self = spawn_take("self")
}
