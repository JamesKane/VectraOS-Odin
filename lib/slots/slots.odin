// The ESP's boot slots (upstream's docs/06 §7, M5 step 9d), as install
// writes them and distd changes them. Three slots, \EFI\vectra\{a,b,c}\,
// each a release's kernel, root task modules and bootfs; one Limine, at the
// firmware's fallback path, whose configuration has an entry per slot in
// use, each path with its file's BLAKE2b-512 hash (which Limine checks), and
// the slot that boots as its default_entry. No UEFI boot entries: choosing a
// slot is rewriting the configuration (upstream, 2026-10-04; its 06 §9.3
// BootNext trial boot waits for its M12).
//
// The table, \EFI\vectra\slots.ndb, says what each slot holds:
//
//   slot=a release=1 tree=b2:... kernel=<128 hex> svcd=... ktest=... bootfs=...
//   slot=b release=2 tree=b2:... ...
//   boot=b previous=a cmdline="vx.skip=gsh"
//
// and the configuration is made from it alone, so the two never disagree.
// Each entry's command line is vx.system vx.slot=X, then the table's cmdline.
package slots

import vx "abi:vx"
import "vx:ndb"
import "vx:str"

FILES :: 4 // per slot
HASH_HEX :: 128 // a file's BLAKE2b-512, in hex
TREE_MAX :: 3 + 64 // the longest tree kept: b2: and a hash
CMDLINE_MAX :: 255 // the longest command line kept

Name :: enum u8 {
	A,
	B,
	C,
}

// Each file's name in the slot's directory, and its key in the table.
FILE_NAMES := [FILES]string{"kernel.elf", "svcd", "ktest", "bootfs.tar"}
FILE_KEYS := [FILES]string{"kernel", "svcd", "ktest", "bootfs"}

Slot :: struct {
	used:    bool,
	release: u64,
	tree:    [dynamic; TREE_MAX]u8,
	hash:    [FILES][dynamic; HASH_HEX]u8, // each file's BLAKE2b-512, hex
}

Table :: struct {
	slots:          [Name]Slot,
	boot, previous: Maybe(Name),
	cmdline:        [dynamic; CMDLINE_MAX]u8, // what each entry's command line has after vx.system vx.slot=X
}

// The slot's letter.
letter :: proc "contextless" (n: Name) -> u8 {
	return 'a' + u8(n)
}

// A slot's letter as a name; ok is false if v is not one.
@(private="file")
name_of :: proc "contextless" (v: string) -> (n: Name, ok: bool) {
	if len(v) != 1 || v[0] < 'a' || v[0] > 'c' {
		return
	}
	return Name(v[0] - 'a'), true
}

// v into a field of its own, as upstream keeps it: cut at the field's
// capacity, and at a NUL, which ends a C string (a value may hold one, as
// x"hex").
@(private="file")
set :: proc "contextless" (dst: ^[dynamic; $N]u8, v: string) {
	clear(dst)
	v := v
	v = v[:min(len(v), N)]
	if i := str.index_byte(v, 0); i >= 0 {
		v = v[:i]
	}
	append(dst, v)
}

// The table from its text: .Err_Invalid if it is not one, or no slot in use
// boots. scratch holds each record's decoded values while it is read.
@(require_results)
parse :: proc "contextless" (t: ^Table, text: string, scratch: []u8) -> vx.Status {
	t^ = {}
	r := ndb.Reader {
		src     = text,
		scratch = scratch,
	}
	rec: ndb.Record
	res: ndb.Result
	for {
		res = ndb.next(&r, &rec)
		if res != .Record {
			break
		}
		r.scratch_used = 0 // what the record holds is copied out before the next
		name, _ := ndb.get(&rec, "slot")
		if n, ok := name_of(name); ok {
			sl := &t.slots[n]
			sl.release, sl.used = ndb.get_u64(&rec, "release")
			tree, _ := ndb.get(&rec, "tree")
			set(&sl.tree, tree)
			for key, f in FILE_KEYS {
				h, _ := ndb.get(&rec, key)
				if len(h) != HASH_HEX {
					sl.used = false
				}
				set(&sl.hash[f], h)
			}
			continue
		}
		// Any other record, a slot= that names no slot included, may say
		// which slot boots, and the command line.
		boot, _ := ndb.get(&rec, "boot")
		prev, _ := ndb.get(&rec, "previous")
		if n, ok := name_of(boot); ok {
			t.boot = n
		}
		if n, ok := name_of(prev); ok {
			t.previous = n
		}
		if cmdline, ok := ndb.get(&rec, "cmdline"); ok {
			set(&t.cmdline, cmdline)
		}
	}
	boot, booting := t.boot.?
	if res != .End || !booting || !t.slots[boot].used {
		return .Err_Invalid
	}
	if prev, ok := t.previous.?; ok && !t.slots[prev].used {
		t.previous = nil
	}
	return .Ok
}

// The table's text into w. False if it does not fit, or no slot boots.
@(require_results)
print :: proc "contextless" (t: ^Table, w: ^ndb.Writer) -> bool {
	boot, booting := t.boot.?
	if !booting {
		return false // upstream writes boot=` here, which no parse accepts
	}
	for &sl, n in t.slots {
		if !sl.used {
			continue
		}
		l := [1]u8{letter(n)}
		ndb.put(w, "slot", string(l[:]))
		ndb.put_u64(w, "release", sl.release)
		ndb.put(w, "tree", string(sl.tree[:]))
		for key, f in FILE_KEYS {
			ndb.put(w, key, string(sl.hash[f][:]))
		}
		_ = ndb.end(w) // a failure is kept: the last end reports it
	}
	b := [1]u8{letter(boot)}
	p := [1]u8{'-'}
	if prev, ok := t.previous.?; ok {
		p[0] = letter(prev)
	}
	ndb.put(w, "boot", string(b[:]))
	ndb.put(w, "previous", string(p[:]))
	ndb.put(w, "cmdline", string(t.cmdline[:]))
	return ndb.end(w)
}

// Limine's configuration for the table, written at the start of out; ok is
// false if it does not fit with a byte to spare (upstream's NUL).
@(require_results)
limine :: proc "contextless" (t: ^Table, out: []u8) -> (text: string, ok: bool) {
	entry, def := 0, 0
	for &sl, n in t.slots {
		if !sl.used {
			continue
		}
		entry += 1
		if boot, booting := t.boot.?; booting && n == boot {
			def = entry
		}
	}
	b := str.Buf {
		buf = out,
	}
	str.write_string(
		&b,
		"# Written from \\EFI\\vectra\\slots.ndb (install, distd: M5 step 9). One entry for each slot in use;\n" +
		"# each path carries its file's BLAKE2b hash, which Limine checks. The default is the slot that boots.\n" +
		"\ntimeout: 0\ndefault_entry: ",
	)
	str.write_byte(&b, u8('0' + def))
	str.write_byte(&b, '\n')
	for &sl, n in t.slots {
		if !sl.used {
			continue
		}
		l := [1]u8{letter(n)}
		slot := string(l[:])
		str.write_string(&b, "\n/VectraOS (slot ")
		str.write_string(&b, slot)
		str.write_string(&b, ", release ")
		str.write_u64(&b, sl.release)
		str.write_string(&b, ")\n    protocol: limine\n")
		for name, f in FILE_NAMES {
			str.write_string(&b, f == 0 ? "    path: boot():/EFI/vectra/" : "    module_path: boot():/EFI/vectra/")
			str.write_string(&b, slot)
			str.write_byte(&b, '/')
			str.write_string(&b, name)
			str.write_byte(&b, '#')
			str.write_string(&b, string(sl.hash[f][:]))
			str.write_byte(&b, '\n')
		}
		str.write_string(&b, "    cmdline: vx.system vx.slot=")
		str.write_string(&b, slot)
		if len(t.cmdline) > 0 {
			str.write_byte(&b, ' ')
			str.write_string(&b, string(t.cmdline[:]))
		}
		str.write_byte(&b, '\n')
	}
	if b.failed || b.len + 1 >= len(out) {
		return "", false
	}
	return str.to_string(&b), true
}

// The slot a new release goes to: neither the one that boots nor the
// previous; ok is false if there is none.
@(require_results)
free_slot :: proc "contextless" (t: ^Table) -> (n: Name, ok: bool) {
	for _, i in t.slots {
		if boot, booting := t.boot.?; booting && i == boot {
			continue
		}
		if prev, has := t.previous.?; has && i == prev {
			continue
		}
		return i, true
	}
	return
}
