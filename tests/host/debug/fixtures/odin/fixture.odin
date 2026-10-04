// The Odin program tests/host/debug indexes: fixtures/make.sh builds it as
// ./build builds a program (Odin to LLVM IR, llc --frame-pointer=all, ld.lld
// with the user linker script), so its DWARF is what this tree's programs
// carry: DWARF 4, from LLVM. Procedures that call each other, with
// parameters, locals in a block, globals of struct, array, enum and string
// types, a file-private procedure and a polymorphic one. The tests know its
// line numbers: keep them where they are.
package fixture

import "base:intrinsics"

Point :: struct {
	x:    i32,
	y:    i64,
	name: [8]u8,
}

Colour :: enum u8 {
	Red   = 0,
	Green = 5,
}

origin := Point {
	x    = 1,
	y    = 2,
	name = {'o', 0, 0, 0, 0, 0, 0, 0},
}
hue := Colour.Green
table := [5]i32{10, 20, 30, 40, 50}
greeting := "hello"
marker: int

// The tests look for add on line 35, and for its line 37.
@(private = "file")
add :: #force_no_inline proc "contextless" (a, b: i32) -> i32 {
	sum := a + b
	intrinsics.volatile_store(&marker, 39)
	return sum + i32(hue)
}

twice :: #force_no_inline proc "contextless" (x: $T) -> T {
	return x + x
}

level3 :: #force_no_inline proc "contextless" (c: i32) -> i32 {
	return add(c, intrinsics.volatile_load(&table[0]))
}

level2 :: #force_no_inline proc "contextless" (b: i32, msg: string) -> i32 {
	local := b + 1
	if intrinsics.volatile_load(&marker) >= 0 {
		inner := local * 3
		local = level3(inner) + i32(msg[0])
	}
	return local
}

level1 :: #force_no_inline proc "contextless" (a: i32) -> i32 {
	doubled := twice(a)
	return level2(doubled, greeting) + i32(twice(i64(origin.y)))
}

@(export, link_name = "_start")
start :: proc "c" () -> ! {
	intrinsics.volatile_store(&marker, int(level1(5)) + int(origin.name[0]))
	for {
		intrinsics.volatile_store(&hue, hue)
	}
}
