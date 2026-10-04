// lib/p9's hand-written tables against messages.def and fields.def, which
// upstream expands with X-macros. The .def files are the one truth: every row
// must have its entry, in order, with the same number, fields, kind and
// member, and nothing may be in a table that is not in its file.
package p9_codec_test

import "base:runtime"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "core:testing"
import "vx:p9"

MESSAGES_DEF :: #load("../../../lib/p9/messages.def", string)
FIELDS_DEF :: #load("../../../lib/p9/fields.def", string)

// The arguments of each NAME(...) row, comments and spaces stripped.
// Allocates from the temp allocator.
def_rows :: proc(src, macro: string) -> (rows: [dynamic][]string) {
	rows.allocator = context.temp_allocator
	for line in strings.split_lines(src, context.temp_allocator) {
		l := line
		if i := strings.index(l, "//"); i >= 0 {
			l = l[:i]
		}
		l = strings.trim_space(l)
		if !strings.has_prefix(l, macro) || !strings.has_suffix(l, ")") {
			continue
		}
		args := strings.split(l[len(macro):len(l) - 1], ",", context.temp_allocator)
		for &a in args {
			a = strings.trim_space(a)
		}
		append(&rows, args)
	}
	return
}

// "NEWFID" -> "Newfid", "U32" -> "U32": how a .def's upper-case name is
// spelled as an Odin enum member.
odin_case :: proc(s: string) -> string {
	return strings.concatenate({s[:1], strings.to_lower(s[1:], context.temp_allocator)}, context.temp_allocator)
}

// The type a Msg member is on the wire: a distinct type's base (a Fid is a
// u32), a bit_field's backing integer (an Open_Mode is a u8), an enum's (a
// Lock_Type is a u8) or a bit_set's (a Getattr_Mask is a u64).
wire_type :: proc(ti: ^runtime.Type_Info) -> typeid {
	base := reflect.type_info_base(ti)
	#partial switch v in base.variant {
	case runtime.Type_Info_Integer:
		return base.id
	case runtime.Type_Info_Bit_Field:
		return v.backing_type.id
	case runtime.Type_Info_Enum:
		return v.base.id
	case runtime.Type_Info_Bit_Set:
		return v.underlying.id
	}
	return ti.id
}

// The Msg member type each wire kind is held in.
kind_type :: proc(k: p9.Field_Kind) -> typeid {
	switch k {
	case .U32:
		return u32
	case .U64:
		return u64
	case .U8:
		return u8
	case .U16:
		return u16
	case .Str:
		return string
	case .Qid:
		return p9.Qid
	case .Wnames:
		return [p9.MAXWELEM]string
	case .Wqids:
		return [p9.MAXWELEM]p9.Qid
	case .Data, .Stat:
		return []u8
	case .Attr:
		return p9.Attr
	case .Setattr:
		return p9.Setattr
	case .Token:
		return [p9.TOKEN_SIZE]u8
	}
	return nil
}

@(test)
test_fields_def :: proc(t: ^testing.T) {
	rows := def_rows(FIELDS_DEF, "P9_FIELD(")
	testing.expect_value(t, len(rows), len(p9.Field))
	for row, i in rows {
		if !testing.expectf(t, len(row) == 3, "fields.def row %v", row) || i >= len(p9.Field) {
			continue
		}
		f := p9.Field(i)
		info := p9.FIELDS[f]
		testing.expectf(t, reflect.enum_string(f) == odin_case(row[0]), "field %d is %v, fields.def says %s", i, f, row[0])
		testing.expectf(t, reflect.enum_string(info.kind) == odin_case(row[1]), "%v is %v, fields.def says %s", f, info.kind, row[1])
		testing.expectf(t, info.member == row[2], "%v is held in %s, fields.def says %s", f, info.member, row[2])
		member := reflect.struct_field_by_name(p9.Msg, row[2])
		testing.expectf(t, member.type != nil && wire_type(member.type) == kind_type(info.kind), "Msg.%s does not hold a %v", row[2], info.kind)
	}
}

@(test)
test_messages_def :: proc(t: ^testing.T) {
	rows := def_rows(MESSAGES_DEF, "P9_MSG(")
	listed: [256]bool
	for row in rows {
		if !testing.expectf(t, len(row) >= 2, "messages.def row %v", row) {
			continue
		}
		num, ok := strconv.parse_int(row[1], 10)
		if !testing.expectf(t, ok && num >= 0 && num < 256 && !listed[num], "messages.def: bad or repeated number in %v", row) {
			continue
		}
		listed[num] = true
		m := p9.MESSAGES[num]
		testing.expectf(t, m.name == row[0], "MESSAGES[%d] is %q, messages.def says %s", num, m.name, row[0])
		ty, found := reflect.enum_from_name(p9.Type, row[0])
		testing.expectf(t, found && int(ty) == num, "Type.%s is not %d", row[0], num)
		want := row[2:]
		if !testing.expectf(t, len(m.fields) == len(want), "%s has %d fields, messages.def says %d", row[0], len(m.fields), len(want)) {
			continue
		}
		for name, i in want {
			testing.expectf(t, strings.has_prefix(name, "P9F_") && reflect.enum_string(m.fields[i]) == odin_case(name[4:]), "%s field %d is %v, messages.def says %s", row[0], i, m.fields[i], name)
		}
	}
	// Nothing is in the tables that messages.def lacks.
	for num in 0 ..< 256 {
		testing.expectf(t, p9.known(p9.Type(num)) == listed[num], "MESSAGES[%d] and messages.def disagree", num)
	}
	testing.expect_value(t, len(p9.Type), len(rows) + 1) // and None
}
