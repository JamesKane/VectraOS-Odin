package p9

// The tables messages.def and fields.def describe, written out by hand:
// Odin has no X-macros, and these lists are short and change rarely. The
// .def files stay the one truth: tests/host/p9_codec parses both and checks
// these tables against them entry for entry, so an edit to one without the
// other fails ./build check.

// A message's type byte. None is not a message: it is what a zeroed Msg holds.
// Terror (106) does not exist.
Type :: enum u8 {
	None     = 0,
	Tversion = 100,
	Rversion = 101,
	Tauth    = 102,
	Rauth    = 103,
	Tattach  = 104,
	Rattach  = 105,
	Rerror   = 107,
	Tflush   = 108,
	Rflush   = 109,
	Twalk    = 110,
	Rwalk    = 111,
	Topen    = 112,
	Ropen    = 113,
	Tcreate  = 114,
	Rcreate  = 115,
	Tread    = 116,
	Rread    = 117,
	Twrite   = 118,
	Rwrite   = 119,
	Tclunk   = 120,
	Rclunk   = 121,
	Tremove  = 122,
	Rremove  = 123,
	Tstat    = 124,
	Rstat    = 125,
	Twstat   = 126,
	Rwstat   = 127,
}

// The fields 9P2000 messages are made of, in fields.def's order.
Field :: enum u8 {
	Fid,
	Newfid,
	Afid,
	Msize,
	Iounit,
	Perm,
	Count,
	Offset,
	Mode,
	Oldtag,
	Version,
	Uname,
	Aname,
	Ename,
	Name,
	Qid,
	Wnames,
	Wqids,
	Data,
	Stat,
}

// How a field is laid out on the wire.
Field_Kind :: enum u8 {
	U32,
	U64,
	U8,
	U16,
	Str, // len[2], then len bytes
	Qid, // type[1] version[4] path[8]
	Wnames, // nwname[2], then nwname strings
	Wqids, // nwqid[2], then nwqid qids
	Data, // count[4], then count bytes (count is set too)
	Stat, // n[2], then n bytes of stat
}

Field_Info :: struct {
	kind:   Field_Kind,
	member: string, // the Msg member that holds it
}

@(rodata)
FIELDS := [Field]Field_Info {
	.Fid     = {.U32, "fid"},
	.Newfid  = {.U32, "newfid"},
	.Afid    = {.U32, "afid"},
	.Msize   = {.U32, "msize"},
	.Iounit  = {.U32, "iounit"},
	.Perm    = {.U32, "perm"},
	.Count   = {.U32, "count"},
	.Offset  = {.U64, "offset"},
	.Mode    = {.U8, "mode"},
	.Oldtag  = {.U16, "oldtag"},
	.Version = {.Str, "version"},
	.Uname   = {.Str, "uname"},
	.Aname   = {.Str, "aname"},
	.Ename   = {.Str, "ename"},
	.Name    = {.Str, "name"},
	.Qid     = {.Qid, "qid"},
	.Wnames  = {.Wnames, "wname"},
	.Wqids   = {.Wqids, "wqid"},
	.Data    = {.Data, "data"},
	.Stat    = {.Stat, "stat"},
}

// A message type's name and its fields in wire order. An entry with no name
// is a type 9P2000 does not have; a message with no fields (Rflush) still has
// a name.
Message :: struct {
	name:   string,
	fields: []Field,
}

@(rodata)
MESSAGES := [256]Message {
	100 = {"Tversion", {.Msize, .Version}},
	101 = {"Rversion", {.Msize, .Version}},
	102 = {"Tauth", {.Afid, .Uname, .Aname}},
	103 = {"Rauth", {.Qid}},
	104 = {"Tattach", {.Fid, .Afid, .Uname, .Aname}},
	105 = {"Rattach", {.Qid}},
	107 = {"Rerror", {.Ename}},
	108 = {"Tflush", {.Oldtag}},
	109 = {"Rflush", {}},
	110 = {"Twalk", {.Fid, .Newfid, .Wnames}},
	111 = {"Rwalk", {.Wqids}},
	112 = {"Topen", {.Fid, .Mode}},
	113 = {"Ropen", {.Qid, .Iounit}},
	114 = {"Tcreate", {.Fid, .Name, .Perm, .Mode}},
	115 = {"Rcreate", {.Qid, .Iounit}},
	116 = {"Tread", {.Fid, .Offset, .Count}},
	117 = {"Rread", {.Data}},
	118 = {"Twrite", {.Fid, .Offset, .Data}},
	119 = {"Rwrite", {.Count}},
	120 = {"Tclunk", {.Fid}},
	121 = {"Rclunk", {}},
	122 = {"Tremove", {.Fid}},
	123 = {"Rremove", {}},
	124 = {"Tstat", {.Fid}},
	125 = {"Rstat", {.Stat}},
	126 = {"Twstat", {.Fid, .Stat}},
	127 = {"Rwstat", {}},
}

// Whether t is a message 9P2000 has.
known :: proc "contextless" (t: Type) -> bool {
	return len(MESSAGES[u8(t)].name) > 0
}
