// lib/users, users(6): a table read, its groups and leaders, who
// administers (group 0, not none), the default, and malformed text refused
// with the table left as it was, and a reload merged with every user in its
// place (upstream's M6 step 6d5c). Ported from upstream's
// tests/host/users_test.c.
package users_test

import "core:fmt"
import "core:strings"
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

	// A merge keeps every user in its place (M6 step 6d5c): one added before
	// them goes after; one removed stays, gone; a table too full is refused.
	live := new(users.Table, context.temp_allocator)
	fresh := new(users.Table, context.temp_allocator)
	testing.expect(t, users.parse(fresh, "0:adm:adm:\n1:none::\n100:glenda::\n101:ken::\n", next))
	testing.expect(t, users.merge(live, fresh, next))
	glenda, ken := users.named(live, "glenda"), users.named(live, "ken")
	testing.expect(t, users.parse(fresh, "300:alice::\n0:adm:adm:\n1:none::\n101:ken::\n", next))
	testing.expect(t, users.merge(live, fresh, next))
	testing.expect_value(t, users.named(live, "ken"), ken)
	testing.expect_value(t, live.users[ken].id, 101)
	testing.expect_value(t, live.users[glenda].id, users.GONE_ID) // gone, its place kept
	testing.expect_value(t, len(live.users[glenda].name), 0)
	testing.expect_value(t, users.named(live, "alice"), 4)
	testing.expect_value(t, len(live.users), 5)
	testing.expect_value(t, users.named(live, "glenda"), live.none)
	testing.expect_value(t, users.named(live, ""), live.none) // not the gone place, whose name is empty (Odin's finding)
	many: strings.Builder
	strings.builder_init(&many, context.temp_allocator)
	for i in 0 ..< 126 { // 126 new ones, with the 5 places taken: more than 128
		fmt.sbprintf(&many, "%d:u%d::\n", 1000 + i, i)
	}
	testing.expect(t, users.parse(fresh, strings.to_string(many), next))
	testing.expect(t, !users.merge(live, fresh, next))
	testing.expect_value(t, len(live.users), 5)
}
