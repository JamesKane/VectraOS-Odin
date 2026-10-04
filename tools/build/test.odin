package build

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "vx:ndb"

// A scenario (tests/qemu/NAME.ndb), with upstream's semantics: one scenario=
// record with a timeout in seconds and, optionally, a kernel cmdline=; then
// expect= records, matched in order against serial output lines (line=
// records match a whole line instead of part of one, and prompt= records the
// start of any line since the last thing typed), and fail= records, any of
// which fails the test when a line contains it. "$arch" in a pattern stands
// for the architecture's name. send= and type= records between the expect=
// records are typed into the serial port once every expect= before them has
// matched; send= then presses return. A scenario= record's iso flag boots
// the CD image (image --iso) instead of the disk. After a pass, each host=
// record's file, under the run's directory (share/ is what vx9pserve served,
// u9fs/ what u9fs did), must hold its text= (with or without a final newline).

Expect_Kind :: enum {
	Contains, // expect=: part of a line
	Line, // line=: the whole line
	Prompt, // prompt=: it has started a line since the last thing typed
}

Expect :: struct {
	text:  string,
	kind:  Expect_Kind,
	input: string, // typed once every expect before this one has matched
}

// host=FILE text=...: what the guest was to leave on the host.
Host_Check :: struct {
	file: string, // under the run's directory
	text: string,
}

Scenario :: struct {
	name:    string,
	timeout: f64,
	cmdline: string,
	with:    string, // test programs for bootfs, comma-separated (tests/user/)
	only:    ^Arch, // arch=: run on this architecture only; nil for all
	needs:   string, // a feature this tree's build cannot provide yet
	iso:     bool, // boot the ISO, as a CD, with no disk
	expects: [dynamic]Expect,
	fails:   [dynamic]string,
	hosts:   [dynamic]Host_Check,
}

substitute_arch :: proc(pattern: string, a: ^Arch) -> string {
	s, _ := strings.replace(pattern, "$arch", a.name, 1, context.temp_allocator)
	return s
}

load_scenario :: proc(name: string, a: ^Arch) -> (sc: Scenario, ok: bool) {
	path := fmt.tprintf("tests/qemu/%s.ndb", name)
	f := read_ndb(path) or_return
	sc.name = name
	sc.expects = make([dynamic]Expect, context.temp_allocator)
	sc.fails = make([dynamic]string, context.temp_allocator)
	sc.hosts = make([dynamic]Host_Check, context.temp_allocator)
	pending := "" // input waiting for the next expect
	for rec in f.records {
		switch {
		case ndb.has(rec, "scenario"):
			t, tok := strconv.parse_f64(val(rec, "timeout"))
			if !tok || t <= 0 {
				fmt.eprintfln("%s:%d: timeout=%s is not a number of seconds", path, rec.line, val(rec, "timeout"))
				return sc, false
			}
			sc.timeout = t
			sc.cmdline = val(rec, "cmdline")
			sc.with = val(rec, "with")
			if arch := val(rec, "arch"); arch != "" {
				only, known := arch_by_name(arch)
				if !known {
					fmt.eprintfln("%s:%d: arch=%s is not x86_64 or aarch64", path, rec.line, arch)
					return sc, false
				}
				sc.only = only
			}
			sc.iso = ndb.has(rec, "iso")
			for feature in ([]string{"disk", "volume", "iommu", "bus"}) {
				if ndb.has(rec, feature) {
					sc.needs = feature
				}
			}
		case ndb.has(rec, "host"):
			file := val(rec, "host")
			if file == "" || file[0] == '/' || strings.has_prefix(file, "..") || strings.contains(file, "/..") {
				fmt.eprintfln("%s:%d: host= names a file inside the run directory", path, rec.line)
				return sc, false
			}
			append(&sc.hosts, Host_Check{file, val(rec, "text")})
		case ndb.has(rec, "expect") || ndb.has(rec, "line") || ndb.has(rec, "prompt"):
			e := Expect{input = pending}
			pending = ""
			switch {
			case ndb.has(rec, "line"):
				e.text, e.kind = val(rec, "line"), .Line
			case ndb.has(rec, "prompt"):
				e.text, e.kind = val(rec, "prompt"), .Prompt
			case:
				e.text = val(rec, "expect")
			}
			e.text = substitute_arch(e.text, a)
			append(&sc.expects, e)
		case ndb.has(rec, "fail"):
			append(&sc.fails, substitute_arch(val(rec, "fail"), a))
		case ndb.has(rec, "send"):
			pending = fmt.tprintf("%s%s\r", pending, val(rec, "send"))
		case ndb.has(rec, "type"):
			pending = fmt.tprintf("%s%s", pending, val(rec, "type"))
		case:
			fmt.eprintfln("%s:%d: expected scenario=, expect=, line=, prompt=, fail=, send=, type= or host=", path, rec.line)
			return sc, false
		}
	}
	if sc.timeout <= 0 || len(sc.expects) == 0 {
		fmt.eprintfln("%s: needs scenario= with a timeout, and an expect=", path)
		return sc, false
	}
	return sc, true
}

// Whether the scenario types something that dials addr: what decides which
// host servers it needs.
@(private="file")
dials :: proc(sc: ^Scenario, addr: string) -> bool {
	for e in sc.expects {
		if strings.contains(e.input, addr) {
			return true
		}
	}
	return false
}

run_scenario :: proc(a: ^Arch, mode: Mode, name: string) -> bool {
	sc := load_scenario(name, a) or_return
	label := fmt.tprintf("  TEST  %-16s %-8s", name, a.name)
	if sc.only != nil && sc.only != a {
		fmt.eprintfln("%s skipped (%s only)", label, sc.only.name)
		return true
	}
	if sc.needs != "" {
		fmt.eprintfln("%s skipped (needs %s=, which this tree cannot provide yet)", label, sc.needs)
		return true
	}
	// u9fs at 10.0.2.101!564 only where it can chroot; vx9pserve at
	// 10.0.2.100!5640 is built when a scenario first needs it.
	with_u9fs := false
	if dials(&sc, "10.0.2.101!564") || dials(&sc, "10.0.2.101:564") {
		if why, usable := user_namespaces(); !usable {
			fmt.eprintfln("%s skipped (%s)", label, why)
			return true
		}
		if !build_u9fs() {
			fmt.eprintfln("%s FAILED: %s did not build", label, U9FS)
			return false
		}
		with_u9fs = true
	}
	if (dials(&sc, "10.0.2.100!5640") || dials(&sc, "10.0.2.100:5640")) && !build_vx9pserve() {
		fmt.eprintfln("%s FAILED: it dials 10.0.2.100!5640, and %s did not build", label, VX9PSERVE)
		return false
	}

	file_name, _ := strings.replace_all(name, "/", "-", context.temp_allocator) // m2/shell -> m2-shell
	image, cdrom := image_path(a, mode), ""
	if sc.cmdline != "" || sc.with != "" || sc.iso {
		image = fmt.tprintf("%s/test-%s.img", out_dir(a, mode), file_name)
	}
	if sc.iso {
		cdrom = fmt.tprintf("%s/test-%s.iso", out_dir(a, mode), file_name)
	}
	build_image(a, mode, image, sc.cmdline, sc.with, cdrom) or_return

	// What the run's servers serve, fresh: run-NAME/share for vx9pserve,
	// run-NAME/u9fs for u9fs.
	run_dir := fmt.tprintf("%s/run-%s", out_dir(a, mode), file_name)
	share := fmt.tprintf("%s/share", run_dir)
	fresh_share(share) or_return
	u9fs := ""
	if with_u9fs {
		u9fs = fmt.tprintf("%s/u9fs", run_dir)
		fresh_u9fs_root(u9fs) or_return
	}

	log_path := fmt.tprintf("%s/test-%s.log", out_dir(a, mode), file_name)
	log, lerr := os.create(log_path)
	if lerr != nil {
		fmt.eprintfln("build: cannot write %s", log_path)
		return false
	}
	defer os.close(log)

	out_r, out_w, perr := os.pipe()
	if perr != nil {
		fmt.eprintln("build: pipe failed")
		return false
	}
	defer os.close(out_r)
	keys_r, keys_w, kerr := os.pipe()
	if kerr != nil {
		os.close(out_w)
		fmt.eprintln("build: pipe failed")
		return false
	}
	defer os.close(keys_w)
	cmd := qemu_cmd(a, image, {test = true, share = share, u9fs = u9fs, cdrom = cdrom})
	if verbose {
		print_cmd(cmd, "")
	}
	// The child's ends close once it has them.
	qemu, serr := os.process_start({command = cmd, stdout = out_w, stderr = out_w, stdin = keys_r})
	os.close(out_w)
	os.close(keys_r)
	if serr != nil {
		fmt.eprintfln("build: cannot run %s: %v", cmd[0], serr)
		return false
	}

	why, passed := match_output(&sc, out_r, keys_w, log)
	_ = os.process_kill(qemu)
	_, _ = os.process_wait(qemu)
	if passed {
		why, passed = check_hosts(&sc, run_dir)
	}

	if passed {
		fmt.eprintfln("%s ok", label)
		return true
	}
	fmt.eprintfln("%s FAILED: %s (log: %s)", label, why, log_path)
	return false
}

// What the guest was to leave on the host, in the run's directory.
@(private="file")
check_hosts :: proc(sc: ^Scenario, run_dir: string) -> (why: string, ok: bool) {
	for h in sc.hosts {
		data, err := os.read_entire_file(fmt.tprintf("%s/%s", run_dir, h.file), context.temp_allocator)
		if err != nil {
			return fmt.tprintf("the host's %s cannot be read (%v); it should say %q", h.file, err, h.text), false
		}
		if got := strings.trim_suffix(string(data), "\n"); got != h.text {
			return fmt.tprintf("the host's %s is %q, not %q", h.file, got, h.text), false
		}
	}
	return "", true
}

// Reads QEMU's serial output, typing and matching as the scenario says.
// Returns whether every expect matched, and if not, why not.
@(private="file")
match_output :: proc(sc: ^Scenario, out: ^os.File, keys: ^os.File, log: ^os.File) -> (why: string, ok: bool) {
	start := time.tick_now()
	next, typed := 0, -1 // expects[typed].input has been typed
	line := strings.builder_make(context.temp_allocator)
	// The output since the last thing typed, for prompt=; since_cut means its
	// start is mid-line, as older output was let go.
	SINCE_MAX :: 64 * 1024
	since := make([dynamic]u8, context.temp_allocator)
	since_cut := false
	buf: [4096]u8
	n, pos := 0, 0
	stale := 0 // bytes of buf, from pos, read before the last typing

	for {
		if typed < next && sc.expects[next].input != "" {
			if _, err := os.write(keys, transmute([]u8)sc.expects[next].input); err != nil {
				return "cannot type into QEMU (it has exited?)", false
			}
			typed = next
			clear(&since)
			since_cut = false
			stale = n - pos // read before the typing: no prompt in it answers what was typed
		}
		if pos == n { // all looked at: read more
			left := sc.timeout - time.duration_seconds(time.tick_since(start))
			if left <= 0 {
				return fmt.tprintf("timed out waiting for %q", sc.expects[next].text), false
			}
			has, herr := os.pipe_has_data(out)
			if herr != nil {
				return "QEMU exited", false
			}
			if !has {
				time.sleep(2 * time.Millisecond)
				continue
			}
			got, rerr := os.read(out, buf[:])
			if rerr != nil || got <= 0 {
				return "QEMU exited", false
			}
			n, pos = got, 0
			_, _ = os.write(log, buf[:n])
		}
		advanced := false
		for pos < n {
			c := buf[pos]
			pos += 1
			if c == '\r' {
				continue
			}
			if len(since) == SINCE_MAX { // keep the newer half: a prompt is in recent output
				copy(since[:], since[SINCE_MAX / 2:])
				resize(&since, SINCE_MAX / 2)
				since_cut = true
			}
			if stale > 0 {
				stale -= 1 // seen for expects and failures, but not by a prompt= after the typing
			} else {
				append(&since, c)
			}
			if c != '\n' {
				if strings.builder_len(line) < 4095 {
					strings.write_byte(&line, c)
				}
				continue
			}
			text := strings.to_string(line)
			for f in sc.fails {
				if strings.contains(text, f) {
					return fmt.tprintf("failure line: %s", text), false
				}
			}
			matched := false
			switch e := sc.expects[next]; e.kind {
			case .Contains:
				matched = strings.contains(text, e.text)
			case .Line:
				matched = text == e.text
			case .Prompt: // matched below, against all output since the last typing
			}
			strings.builder_reset(&line)
			if matched {
				next += 1
				if next == len(sc.expects) {
					return "", true
				}
				if sc.expects[next].input != "" && typed < next {
					advanced = true
					break // type it before what follows
				}
			}
		}
		if advanced {
			continue
		}
		// A prompt has no newline after it, and may share its line with other
		// programs' output: it counts if it started any line since the last
		// thing typed.
		if next < len(sc.expects) && sc.expects[next].kind == .Prompt {
			p := sc.expects[next].text
			s := string(since[:])
			if (!since_cut && strings.has_prefix(s, p)) || strings.contains(s, fmt.tprintf("\n%s", p)) {
				clear(&since) // used: the next prompt= needs a prompt after this one
				since_cut = false
				next += 1
				if next == len(sc.expects) {
					return "", true
				}
			}
		}
	}
}
