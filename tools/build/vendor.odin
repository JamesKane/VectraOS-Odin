package build

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// vendor-check: every vendored tree matches its record in
// third_party/VENDOR.ndb (ADR-0003 upstream; the same rules here).

VENDOR_KEYS := []string{"version", "upstream", "tree.sha256", "license", "adr", "reviewed.by"}
VENDOR_OPTIONAL_KEYS := []string {
	"name",
	"sha256",
	"git.tree",
	"signed.by",
	"port",
	"patches",
	"reviewed.date",
	"reviewed.scope",
	"subset",
}

@(private="file")
sha256_hex :: proc(data: string) -> string {
	return string(hex.encode(hash.hash_string(.SHA256, data, context.temp_allocator), context.temp_allocator))
}

// What this gives, run inside the tree:
//   find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum
tree_sha256 :: proc(dir: string) -> (digest: string, ok: bool) {
	files := tree_files(dir) or_return // sorted: so is each with dir/ cut off
	listing := strings.builder_make(context.temp_allocator)
	for f in files {
		rel := f[len(dir) + 1:]
		for i in 0 ..< len(rel) {
			if rel[i] < 0x20 || rel[i] == 0x7f {
				// sha256sum would have escaped it, and it could forge lines of the listing.
				fmt.eprintfln("build: %s/%s: a control character in a file name", dir, rel)
				return "", false
			}
		}
		data := read_file(f) or_return
		fmt.sbprintf(&listing, "%s  ./%s\n", sha256_hex(data), rel)
	}
	return sha256_hex(strings.to_string(listing)), true
}

cmd_vendor_check :: proc() -> bool {
	path := "third_party/VENDOR.ndb"
	f := read_ndb(path) or_return
	ok := true
	for rec in f.records {
		name := val(rec, "name")
		if name == "" {
			fmt.eprintfln("%s:%d: a record must start with name=", path, rec.line)
			return false
		}
		// Unknown keys fail, as a verifier fails closed: `reviewed.by=A Name`
		// unquoted would otherwise pass as reviewed.by=A plus a flag Name.
		for t in rec.tuples {
			if !slice.contains(VENDOR_KEYS, t.key) && !slice.contains(VENDOR_OPTIONAL_KEYS, t.key) {
				fmt.eprintfln("  VENDOR %s: unknown key %s (line %d); quote values that hold spaces", name, t.key, rec.line)
				ok = false
			}
		}
		for k in VENDOR_KEYS {
			if val(rec, k) == "" {
				fmt.eprintfln("  VENDOR %s: missing %s=", name, k)
				ok = false
			}
		}
		if val(rec, "sha256") == "" && val(rec, "git.tree") == "" {
			fmt.eprintfln("  VENDOR %s: missing sha256= (or git.tree=, for an import with no release)", name)
			ok = false
		}
		for k in ([]string{"adr", "port"}) {
			if v := val(rec, k); v != "" && !os.exists(v) {
				fmt.eprintfln("  VENDOR %s: %s does not exist", name, v)
				ok = false
			}
		}
		dir := fmt.tprintf("third_party/%s", name)
		if !os.is_dir(dir) {
			fmt.eprintfln("  VENDOR %s: %s is missing", name, dir)
			ok = false
			continue
		}
		got, hashed := tree_sha256(dir)
		switch {
		case !hashed:
			ok = false
		case got != val(rec, "tree.sha256"):
			fmt.eprintfln("  VENDOR %s: the tree does not match tree.sha256 (it hashes to %s)", name, got)
			ok = false
		case:
			fmt.eprintfln("  VENDOR %s %s: tree matches", name, val(rec, "version"))
		}
		if val(rec, "reviewed.by") == "pending" {
			fmt.eprintfln("  VENDOR %s: warning: review pending", name)
		}
	}

	// Every directory under third_party/ has a record, and nothing else is
	// there but VENDOR.ndb: no files, links or other entries outside a record.
	entries, err := os.read_directory_by_path("third_party", -1, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("build: cannot read third_party/: %v", err)
		return false
	}
	for e in entries {
		if e.name == "VENDOR.ndb" {
			continue
		}
		if e.type != .Directory {
			fmt.eprintfln("  VENDOR third_party/%s is not a vendored tree (a directory with a record)", e.name)
			ok = false
			continue
		}
		recorded := false
		for rec in f.records {
			recorded = recorded || val(rec, "name") == e.name
		}
		if !recorded {
			fmt.eprintfln("  VENDOR third_party/%s has no record in %s", e.name, path)
			ok = false
		}
	}
	return ok
}
