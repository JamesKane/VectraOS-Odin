package kernel

import vx "abi:vx"
import "vx:memory"
import "vx:ndb"

// Starts the root task from the boot module of that name: svcd, or whatever
// `vx.root=NAME` on the kernel command line names (ktest, for the kernel's
// own tests). It gets the debug-write capability, and starts like every task,
// with a bootstrap channel holding its spawn message (abi:vx): a handle to
// itself, the boot image (the bootfs.tar module, copied into a VMO), the
// store image when there is one (the store.tar module, likewise: an install
// medium's objects, upstream's docs/06 §8), the ACPI tables (acpi.odin), the
// root Resource (device.odin) and the kernel command line.

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
	image:  []u8,
	name:   string, // a literal, or in the kernel's copy of the command line
	bootfs: []u8, // empty if the image has no bootfs.tar
	store:  []u8, // empty if it has no store.tar
}

// The value of `key=value` on the kernel command line, or "".
cmdline_value :: proc "contextless" (key: string) -> string {
	rest := boot.cmdline
	for word in cmdline_word(&rest) {
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
	root_module.name = name
	if b := find_module("bootfs.tar"); b != nil {
		root_module.bootfs = b.address[:b.size]
	}
	if s := find_module("store.tar"); s != nil {
		root_module.store = s.address[:s.size]
	}
}

// A channel end's rights, and a ring end's.
CHANNEL_END_RIGHTS :: vx.Rights{.Read, .Write, .Wait, .Signal, .Duplicate, .Transfer, .Inspect}

@(private="file")
ROOT_RESOURCE_RIGHTS :: vx.Rights{.Manage, .Pager, .Duplicate, .Transfer, .Inspect}
@(private="file")
READ_ONLY_RIGHTS :: vx.Rights{.Read, .Map, .Duplicate, .Transfer, .Inspect} // the boot image and the ACPI tables

@(private="file")
spawn_text: [1024]u8

// Writes the root task's spawn message into a new channel and returns the
// end it reads from: a handle to itself, the boot image, the store image, the
// ACPI tables, the root Resource, and the command line. The message holds the
// references.
@(private="file")
root_spawn_message :: proc "contextless" (t: ^Task) -> ^Channel {
	w := ndb.Writer{buf = spawn_text[:]}
	given: [dynamic; 5]Moved_Handle
	give :: proc "contextless" (w: ^ndb.Writer, given: ^[dynamic; 5]Moved_Handle, name: string, h: Moved_Handle) {
		ndb.put(w, "handle", name)
		ndb.put_u64(w, "index", u64(len(given)))
		_ = ndb.end(w)
		_ = append(given, h) // five at most, and there are five
	}
	// A module copied into a read-only VMO, with its record: NAME size=N.
	give_image :: proc "contextless" (w: ^ndb.Writer, given: ^[dynamic; 5]Moved_Handle, name: string, image: []u8) {
		v, st := vmo_create(u64(len(image)))
		if st != .Ok {
			kpanic(name == "bootimage" ? "no memory for the boot image" : "no memory for the store image")
		}
		vmo_write(v, 0, image)
		give(w, given, name, {&v.obj, READ_ONLY_RIGHTS})
		ndb.flag(w, name)
		ndb.put_u64(w, "size", u64(len(image)))
		_ = ndb.end(w)
	}
	ndb.put(&w, "spawn", root_module.name)
	_ = ndb.end(&w)
	object_ref(&t.obj)
	give(&w, &given, "self", {&t.obj, vx.ALL_RIGHTS})
	if len(root_module.bootfs) > 0 {
		give_image(&w, &given, "bootimage", root_module.bootfs)
	}
	if len(root_module.store) > 0 {
		give_image(&w, &given, "storeimage", root_module.store)
	}
	if acpi, acpi_size, ok := acpi_export(); ok {
		give(&w, &given, "acpi", {&acpi.obj, READ_ONLY_RIGHTS})
		ndb.flag(&w, "acpi")
		ndb.put_u64(&w, "size", acpi_size)
		_ = ndb.end(&w)
	}
	give(&w, &given, "resource", {&root_resource().obj, ROOT_RESOURCE_RIGHTS})
	ndb.put(&w, "cmdline", boot.cmdline)
	fits := ndb.end(&w)
	if boot.seeded { // the root task seeds everything after it from this
		ndb.put(&w, "entropy", string(memory.ptr_to_bytes(&boot.seed)))
		fits = ndb.end(&w)
	}
	if !fits {
		kpanic("the root task's spawn message does not fit")
	}

	text := ndb.written(&w)
	m := msg_alloc(u32(size_of(vx.Msg_Header) + len(text)), u32(len(given)))
	ours, theirs, st := channel_create()
	if m == nil || st != .Ok {
		kpanic("cannot make the root task's channel")
	}
	msg_header(m)^ = {ordinal = vx.SPAWN}
	copy(msg_body(m)[size_of(vx.Msg_Header):], text)
	copy(msg_handles(m), given[:]) // the message takes our references
	if channel_write(ours, m) != .Ok {
		kpanic("cannot send the root task's spawn message")
	}
	object_release(&ours.obj) // the message stays queued; then the root task sees PEER_CLOSED
	return theirs
}

start_root_task :: proc "contextless" () {
	t, st := task_create(root_module.name, 0)
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
