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
import "vx:users"

#assert(users.MAX + 1 <= 128, "a user index is 7 bits of the node id")

// /adm/users, users(6); not file-private: tests/host reads it.
ut: users.Table

@(private="file")
ut_next: users.Table

uid_of :: proc "contextless" (node: Id) -> u32 {
	return int(node.user) < len(ut.users) ? ut.users[node.user].id : users.NONE_ID
}

is_none :: proc "contextless" (node: Id) -> bool {
	return node.user == ut.none || int(node.user) >= len(ut.users)
}

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
			ok = st == .Ok && users.parse(&ut, string(users_text[:got]), &ut_next)
		}
	}
	if ok {
		return
	}
	if len(ut.users) > 0 {
		rt.print("fsd: /adm/users is malformed: the users stay as they were\n")
		return
	}
	_ = users.parse(&ut, users.DEFAULT, &ut_next)
	rt.print("fsd: no /adm/users it can read: adm and none only\n")
}
