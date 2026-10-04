package fsd

// Users are /adm/users, in users(6)'s format, id:name:leader:members, read
// from the adm branch (again whenever that file is written and closed);
// without one, adm and none. Permissions are Plan 9's, as gefs checks them:
// a class's bits grant what they allow (owner, group, then other), none gets
// only other's, a directory's x is search, a new entry takes its directory's
// group and no more of its bits, and owners are adm's to give. They are
// advisory until keyd (upstream's M10): a client names who it attaches as
// (Tattach's uname), and can name anyone (upstream docs/11 §9).

import "vx:fs"
import "vx:rt"
import "vx:str"

MAX_USERS :: 127 // a user index is 7 bits of the node id
MAX_MEMBERS :: 32
NONE_ID :: u32(0xffff_fffe) // none's id when the users file has no none
NO_LEADER :: max(u32)

User :: struct {
	id:   u32,
	lead: u32, // the group's leader's id, or NO_LEADER
	name: [dynamic; 32]u8,
	memb: [dynamic; MAX_MEMBERS]u32,
}

users: [MAX_USERS + 1]User // and none, whether the file names it or not: index 127 fits 7 bits
nusers: u32
none_user: u32 // none's index

user_named :: proc "contextless" (name: string) -> u32 {
	for i in 0 ..< nusers {
		if string(users[i].name[:]) == name {
			return i
		}
	}
	return none_user
}

user_by_id :: proc "contextless" (id: u32) -> ^User {
	for &u in users[:nusers] {
		if u.id == id {
			return &u
		}
	}
	return nil
}

in_group :: proc "contextless" (uid, gid: u32) -> bool {
	g := user_by_id(gid)
	if g == nil {
		return false
	}
	if g.id == uid {
		return true
	}
	for m in g.memb {
		if m == uid {
			return true
		}
	}
	return false
}

leads :: proc "contextless" (uid, gid: u32) -> bool {
	g := user_by_id(gid)
	if g == nil {
		return false
	}
	if g.lead != NO_LEADER {
		return g.lead == uid
	}
	return in_group(uid, gid) // no leader: every member leads
}

uid_of :: proc "contextless" (node: Id) -> u32 {
	return node.user < nusers ? users[node.user].id : NONE_ID
}

is_none :: proc "contextless" (node: Id) -> bool {
	return node.user == none_user || node.user >= nusers
}

// The text up to sep, and line moved past it.
@(private="file")
field :: proc "contextless" (line: ^string, sep: u8) -> string {
	n := str.index_byte(line^, sep)
	if n < 0 {
		f := line^
		line^ = ""
		return f
	}
	f := line[:n]
	line^ = line[n + 1:]
	return f
}

// A decimal of up to 32 bits, all digits.
@(private="file")
number :: proc "contextless" (s: string) -> (v: u32, ok: bool) {
	if len(s) == 0 {
		return
	}
	n: u64
	for c in transmute([]u8)s {
		if c < '0' || c > '9' {
			return
		}
		n = n * 10 + u64(c - '0')
		if n > u64(max(u32)) {
			return
		}
	}
	return u32(n), true
}

@(private="file")
index_named :: proc "contextless" (t: []User, name: string) -> int {
	for &u, k in t {
		if string(u.name[:]) == name {
			return k
		}
	}
	return len(t)
}

@(private="file")
next_users: [MAX_USERS]User

// The table from users(6) text. False if it is malformed: a field missing,
// an id that is no number, a leader or member who is no user; the table is
// then left as it was.
@(private="file")
parse_users :: proc "contextless" (text: string) -> bool {
	next := next_users[:]
	n := 0
	for pass in 0 ..< 2 { // names first, so leaders and members may come later
		rest := text
		i := 0
		for len(rest) > 0 {
			line := field(&rest, '\n')
			if len(line) == 0 || line[0] == '#' {
				continue
			}
			id := field(&line, ':')
			name := field(&line, ':')
			lead := field(&line, ':')
			memb := line
			if pass == 0 {
				if n == MAX_USERS || len(name) == 0 || len(name) > cap(next[n].name) {
					return false
				}
				ok: bool
				next[n].id, ok = number(id)
				if !ok {
					return false
				}
				clear(&next[n].name)
				_ = append(&next[n].name, name)
				next[n].lead = NO_LEADER
				clear(&next[n].memb)
				n += 1
				continue
			}
			u := &next[i]
			i += 1
			if len(lead) > 0 {
				k := index_named(next[:n], lead)
				if k == n {
					return false
				}
				u.lead = next[k].id
			}
			for len(memb) > 0 {
				m := field(&memb, ',')
				if len(m) == 0 {
					continue
				}
				k := index_named(next[:n], m)
				if k == n || append(&u.memb, next[k].id) == 0 {
					return false
				}
			}
		}
	}
	copy(users[:], next[:n])
	nusers = u32(n)
	none_user = u32(index_named(users[:nusers], "none"))
	if none_user == nusers { // none, whether the file says so or not
		users[nusers] = {id = NONE_ID, lead = NO_LEADER}
		_ = append(&users[nusers].name, "none")
		none_user = nusers
		nusers += 1
	}
	return true
}

@(private="file")
DEFAULT_USERS :: "0:adm:adm:\n1:none::\n"

@(private="file")
users_text: [64 * 1024]u8

// The users table from the adm branch's /users, or the default.
load_users :: proc "contextless" () {
	ok := false
	if br, st := fs.branch_open(&vol, "adm"); st == .Ok {
		root, f: fs.File
		got: u64
		root, st = fs.root(&vol, &br.t)
		if st == .Ok {
			f, st = fs.walk(&vol, &br.t, &root, "users")
		}
		if st == .Ok && f.d.length < len(users_text) {
			got, st = fs.read(&vol, &br.t, &f, 0, users_text[:])
			ok = st == .Ok && parse_users(string(users_text[:got]))
		}
	}
	if ok {
		return
	}
	if nusers > 0 {
		rt.print("fsd: /adm/users is malformed: the users stay as they were\n")
		return
	}
	_ = parse_users(DEFAULT_USERS)
	rt.print("fsd: no /adm/users it can read: adm and none only\n")
}
