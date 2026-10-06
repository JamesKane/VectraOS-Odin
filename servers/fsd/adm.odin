package fsd

// The adm files (upstream docs/11 §9): the adm branch's root has two files
// fsd makes. status, an ndb text of the volume (its commit, space, the last
// check, every label), and ctl, which takes one command a write, adm's to
// give, a failure the write's.

import vx "abi:vx"
import "vx:fs"
import "vx:str"

status_text: [dynamic; 16 * 1024]u8 // what does not fit is cut, as upstream's is

// Each open of status reads a copy of its own, made at the open (and again
// at a read from its start), so two readers at once never share one
// (upstream's M6 step 6d5c): the open moves its fid to the copy's node (the
// framework's clone), and the copy goes with its last fid.
Status_Copy :: struct {
	used: bool,
	fids: u32,
	text: [dynamic; 16 * 1024]u8,
}
status_copies: [STATUS_COPIES]Status_Copy

@(private="file")
check_said: [dynamic; 159]u8 // the last check's verdict, cut as upstream's 160-byte string is

@(private="file")
put :: proc "contextless" (b: ^[dynamic; $N]u8, parts: ..string) {
	for s in parts {
		_ = append(b, s)
	}
}

@(private="file")
put_n :: proc "contextless" (b: ^[dynamic; $N]u8, v: u64) {
	buf: [20]u8
	_ = append(b, str.format_u64(buf[:], v))
}

// status: one ndb record for the volume, then one for each label.
@(require_results)
make_status :: proc "contextless" () -> vx.Status {
	clear(&status_text)
	used, size: u64
	for &a in vol.fs.arenas {
		used += a.used
		size += a.size
	}
	b := &status_text
	put(b, "volume commit=")
	put_n(b, vol.sb.commit)
	put(b, " arenas=")
	put_n(b, u64(len(vol.fs.arenas)))
	put(b, " used=")
	put_n(b, used)
	put(b, " size=")
	put_n(b, size)
	put(b, " users=")
	put_n(b, u64(len(ut.users)))
	put(b, " check=", len(check_said) > 0 ? string(check_said[:]) : "unchecked", halted ? " halted\n" : "\n")
	pfx := [1]u8{u8(fs.Key_Kind.Label)}
	s: fs.Scan
	fs.scan_start(&s, &vol.snap, pfx[:])
	for kv in fs.scan_next(&vol.fs, &s) {
		if len(kv.val) != size_of(fs.Label_Disk) {
			continue
		}
		l := fs.load(fs.Label_Disk, kv.val)
		put(b, "label=", string(kv.key[1:]), " snapshot=")
		put_n(b, u64(l.gen))
		put(b, .Mutable in transmute(fs.Label_Flags)u32(l.flags) ? " branch\n" : "\n")
	}
	fs.scan_end(&vol.fs, &s)
	return vol.fs.err
}

// The words of a ctl command, at most 4, each up to its first NUL as
// upstream's C strings are; none if they do not fit upstream's buffer (an
// over-long word is refused, not cut, so the command that runs is never one
// that was not written).
@(private="file")
WORDS_CAP :: 3 * (fs.LABELMAX + 1) + 16

@(private="file")
is_blank :: proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n'
}

@(private="file")
words :: proc "contextless" (cmd: string) -> (w: [dynamic; 4]string) {
	at := 0 // what upstream's buffer holds: each word and its NUL
	i := 0
	for i < len(cmd) && len(w) < 4 {
		for i < len(cmd) && is_blank(cmd[i]) {
			i += 1
		}
		if i == len(cmd) {
			break
		}
		start := i
		for i < len(cmd) && !is_blank(cmd[i]) {
			if at + 2 > WORDS_CAP {
				return {} // the character and the word's NUL
			}
			at += 1
			i += 1
		}
		if at + 1 > WORDS_CAP {
			return {}
		}
		at += 1
		_ = append(&w, c_name(cmd[start:i]))
	}
	return
}

// The branch named, if fsd has it open.
@(private="file")
open_branch :: proc "contextless" (name: string) -> ^fs.Branch {
	for &br in vol.br {
		if br.open && fs.branch_name(&br) == name {
			return &br
		}
	}
	return nil
}

@(private="file")
run_check :: proc "contextless" () {
	quiesce()
	c: fs.Check
	st := fs.check_volume(&vol, &c)
	clear(&check_said)
	if st == .Ok {
		put(&check_said, "clean")
		return
	}
	put(&check_said, "NOT-CLEAN,leaked=")
	put_n(&check_said, c.leaked)
	put(&check_said, ",unallocated=")
	put_n(&check_said, c.unallocated)
	put(&check_said, ",damaged=")
	put_n(&check_said, c.damaged)
	put(&check_said, ",bad-snapshots=")
	put_n(&check_said, c.bad_snaps)
	put(&check_said, ",bad-deadlists=")
	put_n(&check_said, c.bad_lists)
}

// One ctl command (upstream 11 §9). Its failure is the write's.
@(require_results)
ctl_command :: proc "contextless" (node: Id, cmd: string) -> (st: vx.Status) {
	if !is_adm(node) {
		return .Err_Access
	}
	w := words(cmd)
	if len(w) == 0 {
		return .Err_Invalid
	}
	switch {
	case w[0] == "sync" && len(w) == 1:
		return commit()
	case w[0] == "check" && len(w) == 1:
		commit() or_return
		run_check()
		return .Ok // the verdict is status's to say
	case w[0] == "halt" && len(w) == 1:
		st = commit()
		halted = true
		return st
	}
	if halted {
		return .Err_Bad_State
	}
	switch {
	case w[0] == "snap" && len(w) == 3: // snap BRANCH LABEL: its state now, labelled
		commit() or_return
		st = fs.label(&vol, w[1], w[2], {})
	case w[0] == "fork" && len(w) == 3: // fork LABEL BRANCH
		commit() or_return
		st = fs.label(&vol, w[1], w[2], {.Mutable})
	case w[0] == "del" && len(w) == 2: // del LABEL: not a branch in use, nor adm
		if w[1] == "adm" {
			return .Err_Access
		}
		if open_branch(w[1]) != nil {
			return .Err_Bad_State
		}
		ro_drop(w[1]) // its snapshot, if open: fids on it find nothing now
		st = fs.unlabel(&vol, w[1])
	case w[0] == "rollback" && len(w) == 3: // rollback BRANCH LABEL, the old head kept as BRANCH@before-N
		if w[1] == "adm" {
			return .Err_Access
		}
		commit() or_return
		keep: [dynamic; fs.LABELMAX]u8
		_ = append(&keep, w[1][:min(len(w[1]), fs.LABELMAX - 31)])
		put(&keep, "@before-")
		put_n(&keep, vol.sb.commit)
		st = fs.label(&vol, w[1], string(keep[:]), {})
		br := open_branch(w[1])
		if st == .Ok {
			st = br != nil ? fs.branch_rollback(&vol, br, w[2]) : fs.rollback(&vol, w[1], w[2])
		}
		if st == .Ok && br != nil {
			pcache_forget(branch_slot(br), false) // its files' pages, as they are now
		}
	case:
		return .Err_Invalid
	}
	// Durable once ctl's write returns: a rollback, say, must outlive a power
	// cut right after it (distd's rollback by hand, upstream M5 step 9d).
	if st == .Ok {
		changed()
		st = commit()
	}
	return st
}
