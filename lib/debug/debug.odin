// vx:debug, the debugger's symbols and evaluator (upstream 05 §4, §6.2 and
// ADR-0017). An ELF image's DWARF and symbol table become a vxdi index: one
// flat buffer whose every reference is an offset from its start, so it can be
// written to a file and mapped as it is. Queries answer from the index alone;
// the unwinder, the location evaluator and the expression evaluator read the
// program only through a Target's callbacks.
//
//   elf_open       an ELF64 image's sections (elf.odin)
//   image_read     bytes of the program from its image's loaded segments (elf.odin)
//   build_index    the index of an image, built in a caller's arena (build.odin)
//   open           an index, built or read from a file, checked whole (index.odin)
//   func_at, sym_at, line_at, func_named, line_addr, local_named, global_named,
//   type_named, resolve, var_location, str, file   the queries (index.odin)
//   unwind         the call stack, by the frame-pointer chain (unwind.odin)
//   location       where a variable is at a frame (location.odin)
//   begin, eval, format   C expressions at a frame, and values as text (eval.odin)
//
// dbg's use, as upstream's cmd/dbg.c has it: elf_open and build_index once,
// then open; func_at, sym_at and line_at to say where a pc is; func_named and
// line_addr to place a breakpoint (a function's body, a line's first
// statement); unwind from the stopped thread's pc, sp and fp; begin a session
// at the chosen frame, eval each expression and format its value.
//
// The index is built from DWARF 5, as clang emits it, and from DWARF 4, as
// Odin emits it through LLVM (docs/PLAN.md P4: vx-debug reads Odin's own
// DWARF; build.odin says what differs). For an image whose units are all
// DWARF 5 the index is upstream's, byte for byte.
//
// Contextless, and allocates nothing: the builder works in an arena the
// caller gives it. Everything read from an image or an index is hostile input
// (a crash directory, and the binaries it names, may come from anywhere):
// it is read through slices, every length is checked before use, and every
// loop over it is bounded by it.
package debug

import "base:intrinsics"

#assert(ODIN_ENDIAN == .Little) // the index is little-endian, as every machine VectraOS runs on

// The ELF machines VectraOS runs on; an image may name any other.
Machine :: enum u32 {
	None    = 0,
	X86_64  = 62,
	AArch64 = 183,
}

// --- The ELF image (elf.odin) ---

Section :: enum u8 {
	Info,
	Abbrev,
	Line,
	Str,
	Line_Str,
	Str_Offsets,
	Addr,
	Rnglists,
	Loclists,
	Loc, // DWARF 4's location lists
	Ranges, // and range lists
	Symtab,
	Strtab,
}

BUILD_ID_MAX :: 32

Elf :: struct {
	machine:  Machine,
	sec:      [Section][]u8, // empty where the image has none
	build_id: [dynamic; BUILD_ID_MAX]u8,
}

// --- The index (ADR-0017) ---

INDEX_VERSION :: 1
INDEX_MAGIC :: "VXDI"

// An offset into the strings table; 0 is the empty string.
Name :: distinct u32
// A type's number: 0 is void, numbers from 1 are the index's types, and from
// SYNTHETIC up the evaluator's own (eval.odin).
Type_Index :: distinct u32
// A file's number in the files table.
File_Index :: distinct u32

Table_Kind :: enum u8 {
	Funcs,
	Lines,
	Vars,
	Types,
	Members,
	Syms,
	Files,
	Strings,
	Exprs,
}

Table :: struct {
	off, count: u64,
}

// What one entry of each table takes.
@(rodata)
TABLE_ENTRY_SIZE := [Table_Kind]u64 {
	.Funcs   = size_of(Func),
	.Lines   = size_of(Line),
	.Vars    = size_of(Var),
	.Types   = size_of(Type),
	.Members = size_of(Member),
	.Syms    = size_of(Sym),
	.Files   = size_of(Name),
	.Strings = 1,
	.Exprs   = 1,
}

Header :: struct {
	magic:        [4]u8, // INDEX_MAGIC
	version:      u32,
	machine:      Machine,
	build_id_len: u32,
	build_id:     [BUILD_ID_MAX]u8,
	size:         u64, // the whole index, in bytes
	tables:       [Table_Kind]Table,
}
#assert(size_of(Header) == 200)
#assert(offset_of(Header, size) == 48)
#assert(offset_of(Header, tables) == 56)

// Sorted by low.
Func :: struct {
	low, high:      u64,
	body:           u64, // past the prologue: where a breakpoint on it goes
	name:           Name,
	file:           File_Index,
	line:           u32, // its declaration's
	type:           Type_Index, // its return type
	first_var:      u32,
	var_count:      u32,
	frame_base:     u32, // an expression, in exprs
	frame_base_len: u32,
}
#assert(size_of(Func) == 56)

Line_Flag :: enum u32 {
	Stmt         = 0,
	Prologue_End = 1,
	End          = 2, // ends a sequence: no code at its address belongs to it
}
Line_Flags :: bit_set[Line_Flag;u32]

// Sorted by addr; an End row ends a sequence there.
Line :: struct {
	addr:     u64,
	file:     File_Index,
	line:     u32,
	flags:    Line_Flags,
	reserved: u32,
}
#assert(size_of(Line) == 24)

Var_Kind :: enum u32 {
	None   = 0,
	Param  = 1,
	Local  = 2,
	Global = 3,
}

Var_Flag :: enum u32 {
	Loclist = 0, // loc is a list, not an expression
	Const   = 1, // loc is unused; value is the value
}
Var_Flags :: bit_set[Var_Flag;u32]

// loc and loc_len are an expression in exprs; or (Loclist) a list starting at
// loc: {lo: u64, hi: u64, len: u32, bytes}..., ended by 0, 0, 0.
Var :: struct {
	name:       Name,
	type:       Type_Index,
	loc:        u32,
	loc_len:    u32,
	scope_low:  u64, // a local's lexical block; 0, 0 for the whole function
	scope_high: u64,
	kind:       Var_Kind,
	flags:      Var_Flags,
	value:      i64, // Const: DW_AT_const_value
}
#assert(size_of(Var) == 48)

Type_Kind :: enum u32 {
	Void,
	Base,
	Pointer,
	Const,
	Volatile,
	Restrict,
	Atomic,
	Typedef,
	Struct,
	Union,
	Array,
	Enum,
	Func,
}

// A base type's DW_ATE_* encoding.
Encoding :: enum u32 {
	None          = 0,
	Boolean       = 0x02,
	Float         = 0x04,
	Signed        = 0x05,
	Signed_Char   = 0x06,
	Unsigned      = 0x07,
	Unsigned_Char = 0x08,
	Signed_Fixed  = 0x0d,
}

// Type 0 is void.
Type :: struct {
	kind:     Type_Kind,
	name:     Name,
	size:     u64,
	target:   Type_Index, // what it points at, qualifies, names, or holds
	first:    u32, // its members or enumerators (Struct, Union, Enum)
	count:    u32, // how many; an array's elements (0 if unknown)
	encoding: Encoding,
}
#assert(size_of(Type) == 32)

// A member (offset: its byte offset), or an enumerator (offset: its value).
Member :: struct {
	name:   Name,
	type:   Type_Index,
	offset: i64,
}
#assert(size_of(Member) == 16)

// An ELF symbol, sorted by addr.
Sym :: struct {
	addr, size: u64,
	name:       Name,
	func:       b32, // STT_FUNC; else data
}
#assert(size_of(Sym) == 24)

// An index opened by `open`: views of its tables.
Index :: struct {
	header:  ^Header,
	funcs:   []Func,
	lines:   []Line,
	vars:    []Var,
	types:   []Type, // never empty: type 0 is void
	members: []Member,
	syms:    []Sym,
	files:   []Name,
	strings: []u8, // NUL-terminated strings; the last byte is a NUL
	exprs:   []u8,
}

// --- The arena ---

// What the builder takes its memory from, from the front, 8-aligned and
// zeroed. It needs a few times the DWARF's size.
Arena :: struct {
	buf:  []u8,
	used: int,
}

// n zeroed T from a, or false if they do not fit.
@(private, require_results)
arena_alloc :: proc "contextless" (a: ^Arena, $T: typeid, n: u64) -> (s: []T, ok: bool) {
	bytes, overflow := intrinsics.overflow_mul(n, u64(size_of(T)))
	if overflow {
		return nil, false
	}
	// 8-aligned in memory, not only from the buffer's start, so the tables
	// can be used in place. (Upstream aligns from the start, which is the
	// same for the 8-aligned buffers it is given.)
	start := uintptr(raw_data(a.buf))
	at := int((start + uintptr(a.used) + 7) &~ 7 - start)
	if at > len(a.buf) || bytes > u64(len(a.buf) - at) {
		return nil, false
	}
	b := a.buf[at:][:bytes]
	a.used = at + int(bytes)
	for &x in b {
		x = 0
	}
	return ([^]T)(raw_data(b))[:n], true
}

// --- Helpers ---

// T, little-endian, from the start of b (which must hold it).
@(private)
load :: #force_inline proc "contextless" (b: []u8, $T: typeid) -> T {
	return intrinsics.unaligned_load((^T)(raw_data(b[:size_of(T)])))
}

