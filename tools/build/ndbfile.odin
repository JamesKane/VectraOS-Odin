package build

import "core:fmt"
import "vx:ndb"

// A whole ndb file's records, read with lib/ndb. Values point into the file's
// text and the scratch space, both from the temp allocator.
Ndb_File :: struct {
	path:    string,
	records: [dynamic]^ndb.Record,
}

read_ndb :: proc(path: string) -> (f: Ndb_File, ok: bool) {
	src := read_file(path) or_return
	f.path = path
	f.records = make([dynamic]^ndb.Record, context.temp_allocator)
	r := ndb.Reader{src = src, scratch = make([]u8, len(src) + 1, context.temp_allocator)}
	for {
		rec := new(ndb.Record, context.temp_allocator)
		switch ndb.next(&r, rec) {
		case .End:
			return f, true
		case .Error:
			fmt.eprintfln("%s:%d: %s", path, r.error_line, r.error)
			return f, false
		case .Record:
			append(&f.records, rec)
		}
	}
}

// The value of key, or "" when the record lacks it.
val :: proc(rec: ^ndb.Record, key: string) -> string {
	v, _ := ndb.get(rec, key)
	return v
}
