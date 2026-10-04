package p9

// The tables messages.def and fields.def describe, written out by hand:
// Odin has no X-macros, and these lists are short and change rarely. The
// .def files stay the one truth: tests/host/p9_codec parses both and checks
// these tables against them entry for entry, so an edit to one without the
// other fails ./build check.

// A message's type byte. None is not a message: it is what a zeroed Msg holds.
// Terror (106) does not exist.
Type :: enum u8 {
	None      = 0,
	// 9P2000.L's, unchanged on the wire, for the posix and xattr extensions.
	Tsymlink  = 16,
	Rsymlink  = 17,
	Treadlink = 22,
	Rreadlink = 23,
	Tgetattr  = 24,
	Rgetattr  = 25,
	Tsetattr  = 26,
	Rsetattr  = 27,
	Tfsync    = 50,
	Rfsync    = 51,
	Tlink     = 70,
	Rlink     = 71,
	Trenameat = 74,
	Rrenameat = 75,
	Tlock     = 52,
	Rlock     = 53,
	Tgetlock  = 54,
	Rgetlock  = 55,
	// 9Px's own, for posix: open files shared between connections, and their
	// offsets kept by the server.
	Tshare    = 150,
	Rshare    = 151,
	Tjoin     = 152,
	Rjoin     = 153,
	Tseek     = 154,
	Rseek     = 155,
	Tdesc     = 156,
	Rdesc     = 157,
	// 9Px's map extension: a file's range as a VMO, which comes back in one
	// of the transport's handle slots.
	Tmap      = 158,
	Rmap      = 159,
	// 9Px's dref extension: a read or write whose data is in a VMO of the
	// client's, which comes in one of the transport's handle slots.
	Treadref  = 160,
	Rreadref  = 161,
	Twriteref = 162,
	Rwriteref = 163,
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

// The fields messages are made of, in fields.def's order.
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
	// 9P2000.L's, for the posix and xattr extensions.
	Name2, // a second name: Trenameat's new one, Tsymlink's target, Rreadlink's
	Gid,
	Mask, // Tgetattr's request_mask
	Datasync,
	Attr, // Rgetattr's body, valid[8] first
	Setattr, // Tsetattr's body, valid[4] first
	Locktype, // Tlock's and Tgetlock's: read 0, write 1, unlock 2
	Lockflags, // Tlock's: block 1, reclaim 2
	Start,
	Length, // 0: to the end of the file
	Procid,
	Clientid,
	Status, // Rlock's: success 0, blocked 1, error 2
	// 9Px's own, for posix.
	Holds, // Tshare's: joins to keep the open file for
	Token, // 16 bytes
	Whence, // Tseek's: set 0, current 1, end 2
	Descflags, // Tdesc's: append 1
	// 9Px's map extension.
	Prot, // Tmap's: read 1, write 2, exec 4
	// 9Px's dref extension.
	Roffset, // where in the request's VMO the data is, or goes
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
	Attr, // Rgetattr's: valid[8] qid[13] mode[4] uid[4] gid[4], then 15 u64s
	Setattr, // Tsetattr's: valid[4] mode[4] uid[4] gid[4], then 5 u64s
	Token, // 16 bytes
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
	.Stat      = {.Stat, "stat"},
	.Name2     = {.Str, "name2"},
	.Gid       = {.U32, "gid"},
	.Mask      = {.U64, "mask"},
	.Datasync  = {.U32, "datasync"},
	.Attr      = {.Attr, "attr"},
	.Setattr   = {.Setattr, "setattr"},
	.Locktype  = {.U8, "lock_type"},
	.Lockflags = {.U32, "lock_flags"},
	.Start     = {.U64, "start"},
	.Length    = {.U64, "length"},
	.Procid    = {.U32, "proc_id"},
	.Clientid  = {.Str, "client_id"},
	.Status    = {.U8, "status"},
	.Holds     = {.U32, "holds"},
	.Token     = {.Token, "token"},
	.Whence    = {.U8, "whence"},
	.Descflags = {.U32, "desc_flags"},
	.Prot      = {.U32, "prot"},
	.Roffset   = {.U64, "roffset"},
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
	16 = {"Tsymlink", {.Fid, .Name, .Name2, .Gid}},
	17 = {"Rsymlink", {.Qid}},
	22 = {"Treadlink", {.Fid}},
	23 = {"Rreadlink", {.Name2}},
	24 = {"Tgetattr", {.Fid, .Mask}},
	25 = {"Rgetattr", {.Attr}},
	26 = {"Tsetattr", {.Fid, .Setattr}},
	27 = {"Rsetattr", {}},
	50 = {"Tfsync", {.Fid, .Datasync}},
	51 = {"Rfsync", {}},
	52 = {"Tlock", {.Fid, .Locktype, .Lockflags, .Start, .Length, .Procid, .Clientid}},
	53 = {"Rlock", {.Status}},
	54 = {"Tgetlock", {.Fid, .Locktype, .Start, .Length, .Procid, .Clientid}},
	55 = {"Rgetlock", {.Locktype, .Start, .Length, .Procid, .Clientid}},
	70 = {"Tlink", {.Fid, .Newfid, .Name}}, // dfid, fid, name
	71 = {"Rlink", {}},
	74 = {"Trenameat", {.Fid, .Name, .Newfid, .Name2}}, // olddirfid, oldname, newdirfid, newname
	75 = {"Rrenameat", {}},
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
	150 = {"Tshare", {.Fid, .Holds}},
	151 = {"Rshare", {.Token}},
	152 = {"Tjoin", {.Newfid, .Token}},
	153 = {"Rjoin", {.Qid, .Iounit}},
	154 = {"Tseek", {.Fid, .Offset, .Whence}},
	155 = {"Rseek", {.Offset}},
	156 = {"Tdesc", {.Fid, .Descflags}},
	157 = {"Rdesc", {}},
	158 = {"Tmap", {.Fid, .Offset, .Length, .Prot}},
	159 = {"Rmap", {.Offset, .Length}}, // where in the VMO the range starts, and how much is there
	160 = {"Treadref", {.Fid, .Offset, .Count, .Roffset}},
	161 = {"Rreadref", {.Count}},
	162 = {"Twriteref", {.Fid, .Offset, .Count, .Roffset}},
	163 = {"Rwriteref", {.Count}},
}

// Whether t is a message 9P2000, or 9P2000.L's or 9Px's extensions, have.
known :: proc "contextless" (t: Type) -> bool {
	return len(MESSAGES[u8(t)].name) > 0
}
