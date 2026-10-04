package kernel

import vx "abi:vx"
import "vx:ndb"

// Starts the root task from the boot module of that name: svcd, or whatever
// `vx.root=NAME` on the kernel command line names (ktest, for the kernel's
// own tests). It gets the debug-write capability, and starts like every task,
// with a bootstrap channel holding its spawn message (abi:vx): a handle to
// itself, the boot image (the bootfs.tar module, copied into a VMO), the root
// Resource (device.odin) and the kernel command line.

@(private="file")
Limine_File :: struct {
	revision: u64,
	address:  [^]u8,
	size:     u64,
	path:     cstring,
}

@(private="file")
Module_Response :: struct {
	revision:     u64,
	module_count: u64,
	modules:      [^]^Limine_File,
}

@(export, link_section=".limine_requests")
module_request := Request(Module_Response){id = {0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, 0x3e7e279702be32af, 0xca1c4f3bd1280cee}}

@(private="file")
find_module :: proc "contextless" (want: string) -> ^Limine_File {
	r := response(&module_request)
	if r == nil {
		return nil
	}
	for f in r.modules[:r.module_count] {
		path := string(f.path)
		n := len(want)
		if len(path) > n && path[len(path) - n - 1] == '/' && path[len(path) - n:] == want {
			return f
		}
	}
	return nil
}

// The root task's image, found while Limine's module records are still there
// (they are in memory reclaim_boot_memory frees; the image itself is not).
@(private="file")
root_module: struct {
	image:    []u8,
	name:     [24]u8,
	name_len: int,
	bootfs:   []u8, // empty if the image has no bootfs.tar
}

// The value of `key=value` on the kernel command line, or "".
cmdline_value :: proc "contextless" (key: string) -> string {
	c := boot.cmdline
	i := 0
	for i < len(c) {
		for i < len(c) && c[i] == ' ' {
			i += 1
		}
		start := i
		for i < len(c) && c[i] != ' ' {
			i += 1
		}
		word := c[start:i]
		if len(word) > len(key) && word[len(key)] == '=' && word[:len(key)] == key {
			return word[len(key) + 1:]
		}
	}
	return ""
}

find_root_module :: proc "contextless" () {
	name := cmdline_value("vx.root")
	if name == "" || len(name) > 23 {
		name = "svcd"
	}
	m := find_module(name)
	if m == nil {
		kpanic("no module for the root task")
	}
	root_module.image = m.address[:m.size]
	copy(root_module.name[:], name)
	root_module.name_len = len(name)
	if b := find_module("bootfs.tar"); b != nil {
		root_module.bootfs = b.address[:b.size]
	}
}

// A channel end's rights, and a ring end's.
CHANNEL_END_RIGHTS :: vx.Rights{.Read, .Write, .Wait, .Signal, .Duplicate, .Transfer, .Inspect}

@(private="file")
ROOT_RESOURCE_RIGHTS :: vx.Rights{.Manage, .Duplicate, .Transfer, .Inspect}
@(private="file")
BOOT_IMAGE_RIGHTS :: vx.Rights{.Read, .Map, .Duplicate, .Transfer, .Inspect}

@(private="file")
spawn_text: [1024]u8

// Writes the root task's spawn message into a new channel and returns the
// end it reads from. The message holds references to t and to the boot image.
@(private="file")
root_spawn_message :: proc "contextless" (t: ^Task) -> ^Channel {
	w := ndb.Writer{buf = spawn_text[:]}
	ndb.put(&w, "spawn", string(root_module.name[:root_module.name_len]))
	_ = ndb.end(&w)
	ndb.put(&w, "handle", "self")
	ndb.put_u64(&w, "index", 0)
	_ = ndb.end(&w)
	image: ^Vmo
	if len(root_module.bootfs) > 0 {
		st: vx.Status
		image, st = vmo_create(u64(len(root_module.bootfs)))
		if st != .Ok {
			kpanic("no memory for the boot image")
		}
		vmo_write(image, 0, root_module.bootfs)
		ndb.put(&w, "handle", "bootimage")
		ndb.put_u64(&w, "index", 1)
		_ = ndb.end(&w)
		ndb.flag(&w, "bootimage")
		ndb.put_u64(&w, "size", u64(len(root_module.bootfs)))
		_ = ndb.end(&w)
	}
	ndb.put(&w, "handle", "resource")
	ndb.put_u64(&w, "index", image != nil ? 2 : 1)
	_ = ndb.end(&w)
	ndb.put(&w, "cmdline", boot.cmdline)
	if !ndb.end(&w) {
		kpanic("the root task's spawn message does not fit")
	}

	count := u32(image != nil ? 3 : 2)
	text := ndb.written(&w)
	m := msg_alloc(u32(size_of(vx.Msg_Header) + len(text)), count)
	ours, theirs, st := channel_create()
	if m == nil || st != .Ok {
		kpanic("cannot make the root task's channel")
	}
	msg_header(m)^ = {ordinal = vx.SPAWN}
	copy(msg_body(m)[size_of(vx.Msg_Header):], text)
	handles := msg_handles(m)
	object_ref(&t.obj)
	handles[0] = {&t.obj, vx.ALL_RIGHTS}
	if image != nil {
		handles[1] = {&image.obj, BOOT_IMAGE_RIGHTS} // the message takes our reference
	}
	handles[count - 1] = {&root_resource().obj, ROOT_RESOURCE_RIGHTS}
	if channel_write(ours, m) != .Ok {
		kpanic("cannot send the root task's spawn message")
	}
	object_release(&ours.obj) // the message stays queued; then the root task sees PEER_CLOSED
	return theirs
}

start_root_task :: proc "contextless" () {
	t, st := task_create(string(root_module.name[:root_module.name_len]), 0)
	if st != .Ok {
		kpanic("cannot create the root task")
	}
	t.may_debug_write = true

	entry, lst := elf_load(t, root_module.image)
	if lst != .Ok {
		kpanic("cannot load the root task")
	}

	stack, sst := vmo_create(USER_STACK_SIZE)
	if sst != .Ok {
		kpanic("cannot give the root task a stack")
	}
	if _, mst := task_map(t, stack, 0, stack.size, {.Write}, USER_STACK_TOP - USER_STACK_SIZE); mst != .Ok {
		kpanic("cannot give the root task a stack") // the page below stays unmapped
	}
	object_release(&stack.obj)

	bootstrap := root_spawn_message(t)
	start, hst := handle_add(t, &bootstrap.obj, CHANNEL_END_RIGHTS)
	th, tst := thread_create(t)
	if hst != .Ok || tst != .Ok || thread_start(th, entry, USER_STACK_TOP, u64(start), 0) != .Ok {
		kpanic("cannot start the root task")
	}
	object_release(&bootstrap.obj) // its handle holds it
	object_release(&th.obj) // running, it holds its own reference
	object_release(&t.obj) // its handle to itself and its thread keep it
}
