// install: the system from an install medium onto a disk (upstream's docs/06
// §8, its M5 step 9c). The medium's objects are the store image (the
// store.tar module, its manifest's storeimage): the release's record
// (records/*.ndb) and every object of its base tree. install
//
// 1. checks the whole tree in the image: each directory, file index and block
//    against its name, as the live system's check of its own medium;
// 2. writes a GPT on the disk: an ESP (FAT32, 512 MiB, or -e mib) and the
//    system volume (the rest);
// 3. writes slot a on the ESP (06 §7): Limine at the firmware's fallback path,
//    the slot's kernel, bootfs and modules under \EFI\vectra\a, the slot
//    table (\EFI\vectra\slots.ndb) and Limine's configuration made from it
//    (vx:slots): each file with its BLAKE2b hash, which Limine checks;
//    vx.system vx.slot=a, with the live command line's other words;
// 4. makes the system volume (vx:fs): its branches store, cfg, home and adm,
//    the users adm, none and the first user (vectra unless -u names another;
//    it owns home), and the release's objects and record copied into store,
//    where distd finds them. The slot's command line gets vx.user= the first
//    user, as plan9.ini's user=: the console shell runs as it (upstream's
//    6d8).
//
//   install [-y] [-p] [-e mib] [-u user]   the disk is the one connect= names; see install(8)
//
// Without -y it only checks the medium and says what it would do: the disk
// is erased only when asked to be. -p: power off when done (through
// /srv/acpi, connect=acpi). No UEFI boot entry is made: Limine at the
// fallback path is what the firmware boots (upstream, 2026-10-04).
package install

import vx "abi:vx"
import "vx:acpi"
import "vx:crypto"
import "vx:driver"
import "vx:fat"
import "vx:fs"
import "vx:gpt"
import "vx:memory"
import "vx:ndb"
import "vx:p9"
import "vx:rt"
import "vx:slots"
import "vx:store"
import "vx:str"
import "vx:tar"
import usage "gen:usage/install"

when ODIN_ARCH == .amd64 {
	ARCH :: "x86_64"
	LOADER :: "BOOTX64.EFI"
} else {
	ARCH :: "aarch64"
	LOADER :: "BOOTAA64.EFI"
}

fail :: proc "contextless" (what: string, st: vx.Status = .Ok) -> ! {
	rt.print("install: FAILED: ", what)
	if st != .Ok {
		rt.print(": ", p9.error_text(st))
	}
	rt.print("\n")
	rt.exits(what)
}

say :: proc "contextless" (a: string, b := "") {
	rt.print("install: ", a, b, "\n")
}

// --- The medium ---

image: []u8

// An object of the image; ok is false if it has none of that name.
object :: proc "contextless" (h: store.Hash) -> (data: []u8, ok: bool) {
	rel := store.path(h)
	e: tar.Entry
	if tar.find(image, string(rel[:]), &e) != .Ok || e.dir {
		return nil, false
	}
	return e.data, true
}

objects, file_bytes: u64

@(private="file")
check_scratch: [1 << 16]u8

// The tree under dir checked whole: every object present and sound. As deep
// as the tree: a directory's text is the image's, so the scratch the reader
// decodes into is the only state shared between levels, and each record's
// values are used before the next level reads into it.
check_tree :: proc "contextless" (dir: store.Hash) -> vx.Status {
	text, found := object(dir)
	if !found {
		return .Err_Not_Found
	}
	if store.dir_check(dir, text) != .Ok {
		return .Err_Io
	}
	objects += 1
	r := ndb.Reader{src = string(text), scratch = check_scratch[:]}
	rec: ndb.Record
	for ndb.next(&r, &rec) == .Record {
		r.scratch_used = 0
		e, est := store.dir_entry(&rec)
		if est != .Ok {
			return .Err_Io
		}
		if store.is_link(e) {
			continue
		}
		if store.is_dir(e) {
			check_tree(e.hash) or_return
			continue
		}
		idx, have := object(e.hash)
		if !have {
			return .Err_Not_Found
		}
		x, xst := store.index_check(e.hash, idx)
		if xst != .Ok || x.size != e.size {
			return .Err_Io
		}
		objects += 1
		for i in 0 ..< store.index_blocks(x) {
			bh: store.Hash
			copy(bh[:], x.hashes[i * store.HASH:][:store.HASH])
			data, ok := object(bh)
			if !ok {
				return .Err_Not_Found
			}
			if store.block_check(x, i, data) != .Ok {
				return .Err_Io
			}
			objects += 1
		}
		file_bytes += x.size
	}
	return .Ok
}

@(private="file")
file_scratch: [1 << 16]u8

// A file of the tree at path, its bytes in memory of its own (mem_alloc's,
// which mem_free gives back); ok is false if there is none.
tree_file :: proc "contextless" (tree: store.Hash, path: string) -> (data: []u8, ok: bool) {
	e := store.Entry{mode = 0o040555, hash = tree}
	rest := path
	for name in str.split_iterator(&rest, '/') {
		text := object(e.hash) or_return
		if !store.is_dir(e) {
			return nil, false
		}
		st: vx.Status
		if e, st = store.dir_find(text, name, file_scratch[:]); st != .Ok {
			return nil, false
		}
	}
	idx := object(e.hash) or_return
	if store.is_dir(e) {
		return nil, false
	}
	x, xst := store.index_check(e.hash, idx)
	if xst != .Ok {
		return nil, false
	}
	p := mem_alloc(nil, int(max(x.size, 1)))
	if p == nil {
		return nil, false
	}
	out := ([^]u8)(p)[:x.size]
	for i in 0 ..< store.index_blocks(x) {
		bh: store.Hash
		copy(bh[:], x.hashes[i * store.HASH:][:store.HASH])
		block := object(bh) or_return
		copy(out[i * store.BLOCK:], block)
	}
	return out, true
}

// --- Memory, for vx:fs and the files read whole ---

mem_alloc :: proc "contextless" (ctx: rawptr, n: int) -> rawptr {
	size, ok := memory.page_round(u64(n))
	if !ok {
		return nil
	}
	vmo, st := rt.vmo_create(size)
	if st != .Ok {
		return nil
	}
	at, mst := rt.as_map(rt.self, vmo, 0, size, {.Write})
	_ = rt.handle_close(vmo)
	return mst == .Ok ? rawptr(uintptr(at)) : nil
}

mem_free :: proc "contextless" (ctx: rawptr, p: rawptr, n: int) {
	size, _ := memory.page_round(u64(n))
	_ = rt.as_unmap(rt.self, u64(uintptr(p)), size)
}

// --- The disk: the whole of it, and its partitions as devices ---

disk: driver.Blk

gpt_write :: proc "contextless" (ctx: rawptr, lba: u64, buf: []u8) -> bool {
	return driver.blk_write(&disk, lba * u64(disk.sector), buf) == .Ok
}

// A partition: its first byte on the disk.
Part_Dev :: struct {
	base: u64,
}

esp, sys: Part_Dev

esp_read :: proc "contextless" (ctx: rawptr, off: u64, buf: []u8) -> bool {
	return driver.blk_read(&disk, (^Part_Dev)(ctx).base + off, buf) == .Ok
}

esp_write :: proc "contextless" (ctx: rawptr, off: u64, data: []u8) -> bool {
	return driver.blk_write(&disk, (^Part_Dev)(ctx).base + off, data) == .Ok
}

esp_flush :: proc "contextless" (ctx: rawptr) -> bool {
	return driver.blk_flush(&disk) == .Ok
}

sys_read :: proc "contextless" (ctx: rawptr, addr: fs.Addr, buf: ^[fs.BLKSZ]u8) -> vx.Status {
	return driver.blk_read(&disk, (^Part_Dev)(ctx).base + u64(addr), buf[:])
}

sys_write :: proc "contextless" (ctx: rawptr, addr: fs.Addr, buf: ^[fs.BLKSZ]u8) -> vx.Status {
	return driver.blk_write(&disk, (^Part_Dev)(ctx).base + u64(addr), buf[:])
}

sys_barrier :: proc "contextless" (ctx: rawptr) -> vx.Status {
	return driver.blk_flush(&disk)
}

// --- The ESP ---

vol_fat: fat.Vol

// The entry at path, made (and its directories) if it is not there.
fat_path :: proc "contextless" (path: string, attr: fat.Attrs) -> (out: fat.Entry, st: vx.Status) {
	d := fat.root_entry(&vol_fat)
	rest := path
	for {
		slash := str.index_byte(rest, '/')
		last := slash < 0
		name := last ? rest : rest[:slash]
		st = fat.lookup(&vol_fat, &d, name, &out)
		if st == .Err_Not_Found {
			st = fat.create(&vol_fat, &d, name, last ? attr : {.Directory}, &out)
		}
		if st != .Ok || last {
			return
		}
		d = out
		rest = rest[slash + 1:]
	}
}

fat_put_file :: proc "contextless" (path: string, data: []u8) -> vx.Status {
	e := fat_path(path, {}) or_return
	for at := 0; at < len(data); {
		n := min(len(data) - at, 1 << 20)
		fat.write(&vol_fat, &e, u64(at), data[at:][:n]) or_return
		at += n
	}
	return .Ok
}

@(private="file")
HEX := "0123456789abcdef"

// A file of the tree onto the ESP; its BLAKE2b-512 hash in hex, for Limine,
// into hash if there is one.
slot_file :: proc "contextless" (tree: store.Hash, from, to: string, hash: ^[dynamic; slots.HASH_HEX]u8) -> vx.Status {
	data, ok := tree_file(tree, from)
	if !ok {
		return .Err_Not_Found
	}
	if hash != nil {
		h: [64]u8
		crypto.blake2b(h[:], data)
		clear(hash)
		for v in h {
			_ = append(hash, HEX[v >> 4], HEX[v & 15])
		}
	}
	st := fat_put_file(to, data)
	mem_free(nil, raw_data(data), max(len(data), 1))
	return st
}

// --- The system volume ---

vol: fs.Vol
branch: ^fs.Branch // store's
now: i64

vol_dir :: proc "contextless" (dir: ^fs.File, name: string) -> (fs.File, vx.Status) {
	f, st := fs.walk(&vol, &branch.t, dir, name)
	if st == .Err_Not_Found {
		f, st = fs.create(&vol, &branch.t, dir, name, fs.DMDIR | 0o755, 0, 0, now)
	}
	return f, st
}

vol_file :: proc "contextless" (dir: ^fs.File, name: string, data: []u8) -> vx.Status {
	f, st := fs.walk(&vol, &branch.t, dir, name)
	if st == .Ok {
		return .Ok // an object shared by two files: there already
	}
	f = fs.create(&vol, &branch.t, dir, name, 0o444, 0, 0, now) or_return
	if len(data) > 0 {
		return fs.write(&vol, &branch.t, &f, 0, data, now, 0)
	}
	return .Ok
}

copied: u64

// Every object of the image into the store branch, as b2/xx/<hex>.
copy_objects :: proc "contextless" () -> vx.Status {
	root := fs.root(&vol, &branch.t) or_return
	b2 := vol_dir(&root, "b2") or_return
	t := tar.open(image)
	e: tar.Entry
	st: vx.Status
	for st = tar.next(&t, &e); st == .Ok; st = tar.next(&t, &e) {
		path := tar.entry_path(&e)
		if e.dir || len(path) != 70 || !str.has_prefix(path, "b2/") {
			continue
		}
		d: fs.File
		if d, st = vol_dir(&b2, path[3:5]); st == .Ok {
			st = vol_file(&d, path[6:], e.data)
		}
		copied += 1
		if copied % 1024 == 0 && st == .Ok {
			st = fs.commit(&vol) // the log stays small
		}
		if st != .Ok {
			return st
		}
	}
	return st == .Err_Not_Found ? .Ok : st // the archive's end
}

// The first user (-u; vectra unless told otherwise): the system's, who owns
// home and leads adm, and the console shell's (vx.user, upstream's 6d8).
first_user := "vectra"

// Whether a name can be a user(6)'s: 1 to 31 bytes, none of its separators,
// and neither of the users the system has already.
user_name_ok :: proc "contextless" (u: string) -> bool {
	if len(u) == 0 || len(u) > 31 || u == "adm" || u == "none" {
		return false
	}
	for c in transmute([]u8)u {
		if c == ':' || c == ',' || c == ' ' || c == '\n' || c == '=' {
			return false
		}
	}
	return true
}

// users(6), as tools/vxfs mkfs makes it: adm (the first user in its group),
// none, the first user.
make_users :: proc "contextless" () -> vx.Status {
	text: [160]u8
	users, _ := str.join(text[:], "0:adm:adm:", first_user, "\n1:none::\n1000:", first_user, ":", first_user, ":\n")
	br := fs.branch_open(&vol, "adm") or_return
	root := fs.root(&vol, &br.t) or_return
	f := fs.create(&vol, &br.t, &root, "users", 0o664, 0, 0, now) or_return
	fs.write(&vol, &br.t, &f, 0, transmute([]u8)users, now, 0) or_return
	br = fs.branch_open(&vol, "home") or_return
	root = fs.root(&vol, &br.t) or_return
	fs.setattr(&vol, &br.t, &root, {valid = {.Uid, .Gid}, uid = 1000, gid = 1000}, now) or_return
	// tmp, the first user's /tmp on disk (upstream's M6 step 6e1c2), as
	// 9front's /usr/$user/tmp.
	_ = fs.create(&vol, &br.t, &root, "tmp", fs.DMDIR | 0o700, 1000, 1000, now) or_return
	return .Ok
}

// --- Power ---

power_off :: proc "contextless" () -> ! {
	c := rt.spawn_take("srv:acpi")
	if c == vx.HANDLE_NONE {
		fail("-p, but no connector to /srv/acpi (connect=acpi)")
	}
	req := vx.Msg_Header{ordinal = acpi.POWER_OFF}
	rep: vx.Msg_Header
	call := vx.Call{wr_bytes = &req, wr_len = size_of(req), rd_bytes = &rep, rd_cap = size_of(rep)}
	_ = rt.channel_call(c, &call, rt.clock_read() + 10_000_000_000)
	fail("the machine is still on")
}

// --- Starting ---

// The connector to the disk: the first srv: handle but srv:acpi, taken.
find_disk :: proc "contextless" () -> (h: vx.Handle, name: string) {
	for i in 0 ..< rt.spawn.handle_count {
		n := rt.spawn.handle_names[i]
		if len(n) > 4 && str.has_prefix(n, "srv:") && n != "srv:acpi" && rt.spawn.handles[i] != vx.HANDLE_NONE {
			h = rt.spawn.handles[i]
			rt.spawn.handles[i] = vx.HANDLE_NONE
			return h, n[4:]
		}
	}
	fail("no connector to a disk (connect=)")
}

ESP_TYPE :: "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
SYSTEM_TYPE :: "7C6D3E1A-2B4F-4E0A-9C1D-56F2A8B90E35"

table: slots.Table
table_text: [4096]u8
conf: [4096]u8
g: gpt.Gpt
record_scratch: [16384]u8

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	yes, off := false, false
	esp_mib: u64 = 512
	args := rt.args()
	for i := 0; i < len(args); i += 1 {
		switch {
		case args[i] == "-y":
			yes = true
		case args[i] == "-p":
			off = true
		case args[i] == "-u" && i + 1 < len(args):
			i += 1
			first_user = args[i]
			if !user_name_ok(first_user) {
				fail("not a name for a user (users(6))", .Err_Invalid)
			}
		case args[i] == "-e" && i + 1 < len(args):
			i += 1
			esp_mib = 0
			for c in transmute([]u8)args[i] {
				esp_mib = esp_mib * 10 + u64(i64(c) - '0') // as upstream reads it: unchecked
			}
		case:
			fail(usage.TEXT) // from install(8)'s usage fence (tools/build/man.odin)
		}
	}
	now = rt.clock_utc()
	// The medium: the record, and the tree it names for this architecture.
	vmo := rt.spawn_take("storeimage")
	rec: ndb.Record
	size: u64
	size_ok := vmo != vx.HANDLE_NONE && rt.spawn_record("storeimage", &rec)
	if size_ok {
		size, size_ok = ndb.get_u64(&rec, "size")
	}
	padded, pok := memory.page_round(size)
	at: u64
	mst := vx.Status.Err_Invalid
	if size_ok && pok {
		at, mst = rt.as_map(rt.self, vmo, 0, padded, {})
	}
	if mst != .Ok {
		fail("no store image (this is not an install medium)")
	}
	image = ([^]u8)(uintptr(at))[:size]
	record: string
	rname_buf: [dynamic; 63]u8 // the record's name: the entry is reused for the next one
	t := tar.open(image)
	for e in tar.entries(&t) {
		e := e
		path := tar.entry_path(&e)
		if len(path) > 12 && len(path) - 8 < 64 && str.has_prefix(path, "records/") {
			record = string(e.data)
			clear(&rname_buf)
			_ = append(&rname_buf, path[8:])
		}
	}
	if record == "" {
		fail("no release record on the medium")
	}
	tree: store.Hash
	have := false
	seq: u64
	rd := ndb.Reader{src = record, scratch = record_scratch[:]}
	for ndb.next(&rd, &rec) == .Record {
		rd.scratch_used = 0
		if !store.release_known(&rec) {
			fail("the release record has a key release(6) does not name")
		}
		if ndb.has(&rec, "release") {
			seq, _ = ndb.get_u64(&rec, "release")
		}
		set, _ := ndb.get(&rec, "set")
		arch, _ := ndb.get(&rec, "arch")
		if set == "base" && arch == ARCH {
			text, _ := ndb.get(&rec, "tree")
			tree, have = store.parse(text)
		}
	}
	if !have {
		fail("the record names no base tree for this architecture")
	}
	if st := check_tree(tree); st != .Ok {
		fail("the medium's tree is not whole and sound", st)
	}
	rt.print("install: release ", seq, " on the medium, checked: ", objects, " objects, ", file_bytes >> 20, " MiB of files\n")

	// The disk.
	connector, disk_name := find_disk()
	if st := driver.blk_open(&disk, connector, {}); st != .Ok {
		fail("cannot open a session on the disk", st)
	}
	if disk.sector != 512 {
		fail("the disk's sectors are not 512 bytes (the ESP's FAT32 needs that)")
	}
	first: u64 = 2048
	esp_sectors := esp_mib << 11
	sys_first := first + esp_sectors
	if disk.sectors < sys_first + (64 << 11) + 34 {
		fail("the disk is too small: the ESP and 64 MiB at least")
	}
	if !yes {
		say("would erase /srv/", disk_name)
		say("(-y to do it)")
		return 0
	}
	say("erasing /srv/", disk_name)

	g = {sector = 512, sectors = disk.sectors}
	seed: [64]u8
	hc: crypto.Blake2b
	crypto.blake2b_begin(&hc, 64)
	crypto.blake2b_add(&hc, tree[:])
	crypto.blake2b_add(&hc, memory.ptr_to_bytes(&now))
	crypto.blake2b_add(&hc, memory.ptr_to_bytes(&disk.sectors))
	crypto.blake2b_end(&hc, seed[:])
	esp_part := gpt.Part{first = first, last = sys_first - 1}
	sys_part := gpt.Part{first = sys_first, last = disk.sectors - 34}
	copy(g.disk_guid[:], seed[0:16])
	copy(esp_part.guid[:], seed[16:32])
	copy(sys_part.guid[:], seed[32:48])
	for x in ([3]^gpt.Guid{&g.disk_guid, &esp_part.guid, &sys_part.guid}) { // version 4 GUIDs
		x[7] = x[7] & 0x0f | 0x40
		x[8] = x[8] & 0x3f | 0x80
	}
	esp_part.type, _ = gpt.guid(ESP_TYPE)
	sys_part.type, _ = gpt.guid(SYSTEM_TYPE)
	_ = append(&esp_part.name, "EFI system partition")
	_ = append(&sys_part.name, "vectra")
	_ = append(&g.parts, esp_part, sys_part)
	if st := gpt.write(&g, gpt_write, nil); st != .Ok {
		fail("cannot write the partition table", st)
	}

	// The ESP, and slot a in it.
	esp.base, sys.base = first * 512, sys_first * 512
	fd := fat.Dev{ctx = &esp, read = esp_read, write = esp_write, flush = esp_flush}
	serial := u32(seed[48]) | u32(seed[49]) << 8 | u32(seed[50]) << 16 | u32(seed[51]) << 24
	if st := fat.format(fd, esp_sectors, first, "VECTRA", serial); st != .Ok {
		fail("cannot format the ESP", st)
	}
	if st := fat.mount(&vol_fat, fd); st != .Ok {
		fail("cannot mount the new ESP", st)
	}
	vol_fat.now = now / 1_000_000_000
	// The firmware's fallback path: what it boots.
	st := slot_file(tree, "boot/limine/" + LOADER, "EFI/BOOT/" + LOADER, nil)
	sl := &table.slots[.A]
	for name, i in slots.FILE_NAMES {
		if st != .Ok {
			break
		}
		from_buf, to_buf: [64]u8
		from, _ := str.join(from_buf[:], "boot/vx/", name)
		to, _ := str.join(to_buf[:], "EFI/vectra/a/", name) // slot a's directory
		st = slot_file(tree, from, to, &sl.hash[i])
	}
	if st != .Ok {
		fail("cannot write slot a", st)
	}
	// The slot table, slot a booting, and Limine's configuration made from it
	// (vx:slots): the live command line's words but vx.live and a vx.user=
	// go on.
	table.boot = .A
	sl.used, sl.release = true, seq
	x := store.hex(tree)
	_ = append(&sl.tree, string(x[:]))
	line := rt.spawn.cmdline
	for word in str.split_iterator(&line, ' ') {
		dropped := word == "vx.live" || (len(word) > 8 && str.has_prefix(word, "vx.user="))
		if word != "" && !dropped && len(table.cmdline) + len(word) + 2 < slots.CMDLINE_MAX + 1 {
			if len(table.cmdline) > 0 {
				_ = append(&table.cmdline, ' ')
			}
			_ = append(&table.cmdline, word)
		}
	}
	// The first user, as plan9.ini's user=: the console shell runs as it (6d8).
	if len(table.cmdline) + 9 + len(first_user) + 1 < slots.CMDLINE_MAX + 1 {
		if len(table.cmdline) > 0 {
			_ = append(&table.cmdline, ' ')
		}
		_ = append(&table.cmdline, "vx.user=")
		_ = append(&table.cmdline, first_user)
	}
	w := ndb.Writer{buf = table_text[:]}
	if !slots.print(&table, &w) {
		fail("cannot write the slot table")
	}
	if st = fat_put_file("EFI/vectra/slots.ndb", transmute([]u8)ndb.written(&w)); st != .Ok {
		fail("cannot write the slot table", st)
	}
	c, fits := slots.limine(&table, conf[:])
	if !fits {
		fail("Limine's configuration does not fit")
	}
	if st = fat_put_file("boot/limine/limine.conf", transmute([]u8)c); st == .Ok {
		st = fat.flush(&vol_fat)
	}
	if st != .Ok {
		fail("cannot write Limine's configuration", st)
	}
	say("slot a written; the ESP is FAT32 \"VECTRA\"")

	// The system volume.
	vd := fs.Dev {
		ctx     = &sys,
		read    = sys_read,
		write   = sys_write,
		barrier = sys_barrier,
		size    = (g.parts[1].last - sys_first + 1) * 512 / fs.BLKSZ * fs.BLKSZ,
	}
	branches := [4]string{"store", "cfg", "home", "adm"}
	if st = fs.mkfs(&vol, vd, {alloc = mem_alloc, free = mem_free}, 1024, 0, branches[:], 0o755, 0, 0, now); st != .Ok {
		fail("cannot make the system volume", st)
	}
	if st = make_users(); st == .Ok {
		branch, st = fs.branch_open(&vol, "store")
	}
	if st != .Ok {
		fail("cannot make the volume's users", st)
	}
	if st = copy_objects(); st != .Ok {
		fail("cannot copy the objects into the store", st)
	}
	root, records: fs.File
	if root, st = fs.root(&vol, &branch.t); st == .Ok {
		if records, st = vol_dir(&root, "records"); st == .Ok {
			st = vol_file(&records, string(rname_buf[:]), transmute([]u8)record)
		}
	}
	if st != .Ok {
		fail("cannot write the release's record into the store", st)
	}
	if st = fs.commit(&vol); st != .Ok {
		fail("cannot commit the system volume", st)
	}
	if st = driver.blk_flush(&disk); st != .Ok {
		fail("cannot flush the disk", st)
	}
	rt.print("install: done: ", copied, " objects in the store, release ", seq, " in slot a\n")
	if off {
		power_off()
	}
	return 0
}
