// Not upstream's: the cross-format test PLAN's P5 gate asks for. Volumes
// upstream's C wrote are mounted, checked and read by vx:fs and tools/vxfs,
// and vx:fs writes what upstream's C writes, byte for byte. The fixtures and
// how they were made are in fixtures/make.sh:
//
// - c-lib.vxfs.gz: fixtures/ops.txt run against upstream's lib/vx-fs (its
//   mkfixture.c). Here the same script runs against vx:fs: every op must
//   return what it returned there (c-lib.txt), the volume left must be those
//   bytes, and the C volume must mount and check clean here, take the
//   reaping of its orphans and a commit, and check clean again.
// - c-tool.vxfs.gz: made by upstream's host/vxfs (mkfs, put, snap, fork,
//   del), which make.sh also checked tools/vxfs makes byte for byte, and
//   upstream's tool reads as its own. Here tools/vxfs runs each command of
//   tool.txt on it and must print what upstream's printed.
package fs_test

import "core:bytes"
import "core:compress/gzip"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import vx "abi:vx"
import "vx:fs"
import vxfs "../../../tools/vxfs"

OPS :: #load("fixtures/ops.txt", string)
C_LIB_TXT :: #load("fixtures/c-lib.txt", string)
C_LIB_GZ :: #load("fixtures/c-lib.vxfs.gz")
C_TOOL_GZ :: #load("fixtures/c-tool.vxfs.gz")
TOOL_TXT :: #load("fixtures/tool.txt", string)

gunzip :: proc(t: ^testing.T, gz: []u8, loc := #caller_location) -> []u8 {
	buf: bytes.Buffer
	if err := gzip.load(gz, &buf); !testing.expectf(t, err == nil, "gunzip: %v", err, loc = loc) {
		bytes.buffer_destroy(&buf)
		return nil
	}
	return buf.buf[:]
}

// --- The op script (fixtures/mkfixture.c has its language) ---

Script :: struct {
	d:    ^Memdev,
	v:    ^fs.Vol,
	now:  i64,
	data: []u8,
	out:  strings.Builder,
}

script_tree :: proc(s: ^Script, branch: string, st: ^vx.Status) -> ^fs.Tree {
	br: ^fs.Branch
	br, st^ = fs.branch_open(s.v, branch)
	return st^ == .Ok ? &br.t : nil
}

// The parent of path and its last name: "" and "/" are the root.
parent_of :: proc(s: ^Script, tr: ^fs.Tree, path: string) -> (dir: fs.File, name: string, st: vx.Status) {
	slash := strings.last_index_byte(path, '/')
	up := slash >= 0 ? path[:slash] : ""
	name = slash >= 0 ? path[slash + 1:] : path
	dir, st = fs.walk_path(s.v, tr, up)
	return
}

num :: proc(s: string, base := 10) -> u64 {
	n, _ := strconv.parse_u64_of_base(s, base)
	return n
}

run_script :: proc(t: ^testing.T, s: ^Script, script: string) {
	v := s.v
	lineno := 0
	rest := script
	for raw in strings.split_lines_iterator(&rest) {
		lineno += 1
		line := raw
		if hash := strings.index_byte(line, '#'); hash >= 0 {
			line = line[:hash]
		}
		w := strings.fields(line, context.temp_allocator)
		if len(w) == 0 {
			continue
		}
		op := w[0]
		st := vx.Status.Err_Invalid
		fmt.sbprintf(&s.out, "%d %s", lineno, op)
		tr: ^fs.Tree
		dir, f, to: fs.File
		name, name2: string
		switch op {
		case "format":
			s.d = memdev_new(num(w[1]))
			st = fs.mkfs(v, dev_of(s.d), mem(), 256, u32(num(w[2])), w[4:], 0o755, 0, 0, s.now)
			v.fs.compress_at = num(w[3])
			for b in w[4:] {
				if st != .Ok {
					break
				}
				script_tree(s, b, &st)
			}
		case "time":
			n, _ := strconv.parse_i64(w[1])
			s.now = n
			st = .Ok
		case "users":
			text := fmt.tprintf("0:adm:adm:%s\n1:none::\n%d:%s:%s:\n", w[1], 1000, w[1], w[1])
			if tr = script_tree(s, "adm", &st); tr != nil {
				if dir, st = fs.root(v, tr); st == .Ok {
					if f, st = fs.create(v, tr, &dir, "users", 0o664, 0, 0, s.now); st == .Ok {
						st = fs.write(v, tr, &f, 0, transmute([]u8)text, s.now, 0)
					}
				}
			}
			if st == .Ok {
				if tr = script_tree(s, "home", &st); tr != nil {
					if dir, st = fs.root(v, tr); st == .Ok {
						st = fs.setattr(v, tr, &dir, {valid = {.Uid, .Gid}, uid = 1000, gid = 1000}, s.now)
					}
				}
			}
		case "mkdir", "create":
			mode := u32(num(w[3], 8)) | (op == "mkdir" ? fs.DMDIR : 0)
			if tr = script_tree(s, w[1], &st); tr != nil {
				if dir, name, st = parent_of(s, tr, w[2]); st == .Ok {
					_, st = fs.create(v, tr, &dir, name, mode, 1000, 1000, s.now)
				}
			}
		case "symlink":
			if tr = script_tree(s, w[1], &st); tr != nil {
				if dir, name, st = parent_of(s, tr, w[2]); st == .Ok {
					_, st = fs.symlink(v, tr, &dir, name, w[3], 1000, 1000, s.now)
				}
			}
		case "write":
			off, n, seed := num(w[3]), num(w[4]), num(w[5])
			for i in 0 ..< n {
				s.data[i] = u8('a' + (i / 3 + seed) % 26)
			}
			if tr = script_tree(s, w[1], &st); tr != nil {
				if f, st = fs.walk_path(v, tr, w[2]); st == .Ok {
					st = fs.write(v, tr, &f, off, s.data[:n], s.now, 1000)
				}
			}
		case "truncate", "chmod":
			a := fs.Attr {
				valid  = op == "truncate" ? {.Size} : {.Mode},
				length = num(w[3]),
				mode   = u32(num(w[3], 8)),
			}
			if tr = script_tree(s, w[1], &st); tr != nil {
				if f, st = fs.walk_path(v, tr, w[2]); st == .Ok {
					st = fs.setattr(v, tr, &f, a, s.now)
				}
			}
		case "remove", "orphan":
			if tr = script_tree(s, w[1], &st); tr != nil {
				if dir, name, st = parent_of(s, tr, w[2]); st == .Ok {
					st = op == "remove" ? fs.remove(v, tr, &dir, name, s.now) : fs.orphan(v, tr, &dir, name, s.now)
				}
			}
		case "rename":
			if tr = script_tree(s, w[1], &st); tr != nil {
				if dir, name, st = parent_of(s, tr, w[2]); st == .Ok {
					if to, name2, st = parent_of(s, tr, w[3]); st == .Ok {
						st = fs.rename(v, tr, &dir, name, &to, name2, s.now, nil, nil)
					}
				}
			}
		case "reapall":
			got: u32
			if tr = script_tree(s, w[1], &st); tr != nil {
				got, st = fs.reap_all(v, tr)
			}
			fmt.sbprintf(&s.out, " %d", got)
		case "commit":
			st = fs.commit(v)
			fmt.sbprintf(&s.out, " %d", v.sb.commit)
		case "snap":
			st = fs.label(v, w[1], w[2], {})
		case "fork":
			if st = fs.label(v, w[1], w[2], {.Mutable}); st == .Ok {
				script_tree(s, w[2], &st)
			}
		case "close":
			br: ^fs.Branch
			if br, st = fs.branch_open(v, w[1]); st == .Ok {
				st = fs.branch_close(br)
			}
		case "del":
			st = fs.unlabel(v, w[1])
		case "rollback":
			br: ^fs.Branch
			if br, st = fs.branch_open(v, w[1]); st == .Ok {
				st = fs.branch_rollback(v, br, w[2])
			}
		case "compress":
			i := int(num(w[1]))
			ok := i < len(v.fs.arenas) && fs.log_compress(&v.fs, &v.fs.arenas[i])
			st = ok ? .Ok : v.fs.err
			if i < len(v.fs.arenas) && st != .Ok {
				v.fs.err = .Ok // a refusal (BAD_STATE), not a failure
			}
		}
		fmt.sbprintf(&s.out, " %d\n", i32(st))
	}
	c: fs.Check
	st := fs.check_volume(v, &c)
	fmt.sbprintf(&s.out, "check %d: %d snapshots, %d labels, %d deadlists; %d used, %d in trees, %d else\n", i32(st), c.snapshots, c.labels, c.dlists, c.used, c.trees, c.other)
}

@(test)
test_xformat_lib :: proc(t: ^testing.T) {
	s := Script{v = new(fs.Vol), data = make([]u8, 1 << 20)}
	defer free(s.v)
	defer delete(s.data)
	s.out = strings.builder_make()
	defer strings.builder_destroy(&s.out)
	run_script(t, &s, OPS)
	if !testing.expect(t, s.d != nil) {
		return
	}
	defer memdev_free(s.d)
	fs.unmount(s.v)
	testing.expect_value(t, strings.to_string(s.out), C_LIB_TXT)

	// The volume vx:fs left is the one upstream's C left.
	image := gunzip(t, C_LIB_GZ)
	defer delete(image)
	testing.expect_value(t, len(image), len(s.d.bytes))
	if len(image) == len(s.d.bytes) {
		for i := 0; i < len(image); i += B {
			if !bytes_eq(image[i:][:B], s.d.bytes[i:][:B]) {
				testing.expectf(t, false, "block %d (at %x) differs from upstream's", i / B, i)
				break
			}
		}
	}

	// Upstream's volume, mounted here: clean, its orphans reaped and committed,
	// and clean again.
	d := new(Memdev)
	defer free(d)
	d.bytes = image
	v := new(fs.Vol)
	defer free(v)
	testing.expect_value(t, fs.mount(v, dev_of(d), mem(), 256), vx.Status.Ok)
	defer fs.unmount(v)
	testing.expect(t, clean(t, v))
	reaped: u32
	for b in ([]string{"home", "cfg"}) {
		br, st := fs.branch_open(v, b)
		testing.expect_value(t, st, vx.Status.Ok)
		n: u32
		n, st = fs.reap_all(v, &br.t)
		testing.expect_value(t, st, vx.Status.Ok)
		reaped += n
	}
	testing.expect(t, reaped > 0) // the script left orphans, as a crash would
	testing.expect_value(t, fs.commit(v), vx.Status.Ok)
	testing.expect(t, clean(t, v))
}

// --- The tool's volume ---

@(test)
test_xformat_tool :: proc(t: ^testing.T) {
	image := gunzip(t, C_TOOL_GZ)
	defer delete(image)
	tmp, terr := os.make_directory_temp("", "vxfs-xformat-*", context.allocator)
	if !testing.expectf(t, terr == nil, "no temporary directory: %v", terr) {
		return
	}
	defer delete(tmp)
	defer os.remove_all(tmp)
	vol := fmt.aprintf("%s/vol", tmp)
	defer delete(vol)
	testing.expect(t, os.write_entire_file(vol, image) == nil)

	// What upstream's host/vxfs printed for each command, tools/vxfs prints.
	got := strings.builder_make()
	defer strings.builder_destroy(&got)
	out, errs := strings.builder_make(), strings.builder_make()
	defer strings.builder_destroy(&out)
	defer strings.builder_destroy(&errs)
	commands := 0
	rest := TOOL_TXT
	for line in strings.split_lines_iterator(&rest) {
		if !strings.has_prefix(line, "$ vxfs ") {
			continue
		}
		cmd := line[len("$ vxfs "):]
		args := strings.fields(cmd, context.temp_allocator)
		for &a in args {
			if a == "vol" {
				a = vol
			}
		}
		strings.builder_reset(&out)
		strings.builder_reset(&errs)
		code := vxfs.run(args, strings.to_writer(&out), strings.to_writer(&errs))
		fmt.sbprintf(&got, "$ vxfs %s\n%s\n-- stderr\n%s-- exit %d\n", cmd, strings.to_string(out), strings.to_string(errs), code)
		commands += 1
	}
	testing.expect_value(t, commands, 22)
	want := TOOL_TXT
	have := strings.to_string(got)
	if have != want {
		// Name the first command whose output differs.
		w, h := want, have
		for {
			wl, wok := strings.split_lines_iterator(&w)
			hl, hok := strings.split_lines_iterator(&h)
			if !wok || !hok || wl != hl {
				testing.expectf(t, false, "tools/vxfs differs from upstream's host/vxfs: %q, upstream's %q", hl, wl)
				break
			}
		}
	}

	// And vx:fs mounts it and checks it clean.
	d := new(Memdev)
	defer free(d)
	d.bytes = image
	v := new(fs.Vol)
	defer free(v)
	testing.expect_value(t, fs.mount(v, dev_of(d), mem(), 256), vx.Status.Ok)
	testing.expect(t, clean(t, v))
	fs.unmount(v)
}
