// The users table, users(6): lines id:name:leader:members, as fsd reads
// /adm/users from its adm branch and distd reads it through fsd (upstream's
// lib/vx-users, M6 step 6b). Users are advisory until keyd (upstream's M10):
// a client names who it attaches as (Tattach's uname), and can name anyone
// (upstream docs/11 §9). Administration is membership of the group whose id
// is 0.
package users

import "vx:str"

MAX :: 127 // users a file may name; none comes on top
MEMBERS :: 32
NONE_ID :: u32(0xffff_fffe) // none's id when the file has no none
NO_LEADER :: max(u32)
DEFAULT :: "0:adm:adm:\n1:none::\n" // when there is no file

User :: struct {
	id:   u32,
	lead: u32, // the group's leader's id, or NO_LEADER
	name: [dynamic; 32]u8,
	memb: [dynamic; MEMBERS]u32,
}

// A table, empty until parsed; once parsed it always has none.
Table :: struct {
	users: [dynamic; MAX + 1]User, // and none, whether the file names it or not
	none:  u32, // none's index
}

// The index of the user named name, or none's.
named :: proc "contextless" (t: ^Table, name: string) -> u32 {
	for &u, i in t.users {
		if string(u.name[:]) == name {
			return u32(i)
		}
	}
	return t.none
}

by_id :: proc "contextless" (t: ^Table, id: u32) -> ^User {
	for &u in t.users {
		if u.id == id {
			return &u
		}
	}
	return nil
}

in_group :: proc "contextless" (t: ^Table, uid, gid: u32) -> bool {
	g := by_id(t, gid)
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

leads :: proc "contextless" (t: ^Table, uid, gid: u32) -> bool {
	g := by_id(t, gid)
	if g == nil {
		return false
	}
	if g.lead != NO_LEADER {
		return g.lead == uid
	}
	return in_group(t, uid, gid) // no leader: every member leads
}

// Whether the user named name administers: is in group 0, and is not none.
adm :: proc "contextless" (t: ^Table, name: string) -> bool {
	who := named(t, name)
	return who != t.none && int(who) < len(t.users) && in_group(t, t.users[who].id, 0)
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

// The table from users(6) text, built in next first. False if it is
// malformed: an id that is no number, a name missing or too long, a leader
// or member who is no user, too many users or members; t is then left as it
// was. A line may stop after its name, its leader and members then none.
@(require_results)
parse :: proc "contextless" (t: ^Table, text: string, next: ^Table) -> bool {
	clear(&next.users)
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
				if len(next.users) == MAX || len(name) == 0 || len(name) > 32 {
					return false
				}
				u := User{lead = NO_LEADER}
				ok: bool
				if u.id, ok = number(id); !ok {
					return false
				}
				_ = append(&u.name, name)
				_ = append(&next.users, u)
				continue
			}
			u := &next.users[i]
			i += 1
			if len(lead) > 0 {
				k := index_named(next.users[:], lead)
				if k == len(next.users) {
					return false
				}
				u.lead = next.users[k].id
			}
			for len(memb) > 0 {
				m := field(&memb, ',')
				if len(m) == 0 {
					continue
				}
				k := index_named(next.users[:], m)
				if k == len(next.users) || append(&u.memb, next.users[k].id) == 0 {
					return false
				}
			}
		}
	}
	next.none = u32(index_named(next.users[:], "none"))
	if int(next.none) == len(next.users) { // none, whether the file says so or not
		u := User{id = NONE_ID, lead = NO_LEADER}
		_ = append(&u.name, "none")
		_ = append(&next.users, u)
	}
	t^ = next^
	return true
}

// A user the file no longer has, kept in its place in a table (merge).
GONE_ID :: u32(0xffff_fffd)

// t made fresh, each user t has still at the index it has in t, a user
// fresh adds where t has no one, and a user fresh no longer has left in its
// place as gone (GONE_ID, no name), for an index handed out (fsd's nodes
// carry one) never to come to mean someone else (upstream's M6 step 6d5c).
// Users are the same user by id. The table is built in next first. False,
// and t as it was, if they do not fit.
@(require_results)
merge :: proc "contextless" (t: ^Table, fresh: ^Table, next: ^Table) -> bool {
	placed: [MAX + 1]bool
	clear(&next.users)
	for &u in t.users {
		j := 0
		for j < len(fresh.users) && (placed[j] || fresh.users[j].id != u.id || u.id == GONE_ID) {
			j += 1
		}
		if j < len(fresh.users) {
			_ = append(&next.users, fresh.users[j])
			placed[j] = true
		} else {
			_ = append(&next.users, User{id = GONE_ID, lead = NO_LEADER})
		}
	}
	for &u, j in fresh.users {
		if placed[j] {
			continue
		}
		if len(next.users) == MAX + 1 {
			return false
		}
		_ = append(&next.users, u)
	}
	next.none = u32(index_named(next.users[:], "none"))
	t^ = next^
	return true
}
