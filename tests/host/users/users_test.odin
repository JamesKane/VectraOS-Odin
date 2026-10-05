// lib/users, users(6): a table read, its groups and leaders, who
// administers (group 0, not none), the default, and malformed text refused
// with the table left as it was. Ported from upstream's
// tests/host/users_test.c.
package users_test

import "core:testing"
import "vx:users"

@(test)
test_users :: proc(t: ^testing.T) {
	tab := new(users.Table, context.temp_allocator)
	next := new(users.Table, context.temp_allocator)
	testing.expect(t, users.parse(tab, users.DEFAULT, next))
	testing.expect_value(t, len(tab.users), 2)
	testing.expect(t, users.adm(tab, "adm"))
	testing.expect(t, !users.adm(tab, "none"))
	testing.expect(t, !users.adm(tab, "glenda")) // no such user: none

	text := "# the users\n0:adm:adm:glenda\n1:none::\n100:glenda::\n200:dev:ken:glenda,ken\n201:ken\n"
	testing.expect(t, users.parse(tab, text, next))
	testing.expect_value(t, len(tab.users), 5)
	testing.expect(t, users.adm(tab, "glenda"))
	testing.expect(t, !users.adm(tab, "ken"))
	testing.expect(t, users.in_group(tab, 201, 200))
	testing.expect(t, users.leads(tab, 201, 200))
	testing.expect(t, !users.leads(tab, 100, 200))
	testing.expect_value(t, users.named(tab, "nobody"), tab.none)
	testing.expect_value(t, tab.users[tab.none].id, 1)

	// Malformed: the table stays as it was.
	Case :: struct {
		text, why: string,
	}
	malformed := []Case {
		{"0:adm:adm:\nx:bad::\n", "an id that is no number"},
		{"0:adm:nobody:\n", "a leader who is no user"},
		{"0:adm::ghost\n", "a member who is no user"},
	}
	for c in malformed {
		testing.expectf(t, !users.parse(tab, c.text, next), "%s: refused", c.why)
	}
	testing.expect_value(t, len(tab.users), 5)
	testing.expect(t, users.adm(tab, "glenda"))

	// No none in the file: none is added.
	testing.expect(t, users.parse(tab, "0:adm:adm:\n", next))
	testing.expect_value(t, len(tab.users), 2)
	testing.expect_value(t, tab.users[tab.none].id, users.NONE_ID)
}
