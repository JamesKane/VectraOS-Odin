package build

import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"

verbose: bool

print_cmd :: proc(cmd: []string, dir: string) {
	if dir != "" {
		fmt.eprintf("(cd %s) ", dir)
	}
	fmt.eprintln(strings.join(cmd, " ", context.temp_allocator))
}

// Runs a command with this process's output. True if it exited with 0.
run :: proc(cmd: []string, dir := "") -> bool {
	p, ok := start(cmd, dir)
	return ok && finish(p, cmd, dir)
}

@(private="file")
start :: proc(cmd: []string, dir: string) -> (os.Process, bool) {
	if verbose {
		print_cmd(cmd, dir)
	}
	p, err := os.process_start({command = cmd, working_dir = dir, stdin = os.stdin, stdout = os.stdout, stderr = os.stderr})
	if err != nil {
		fmt.eprintfln("build: cannot run %s: %v", cmd[0], err)
		return {}, false
	}
	return p, true
}

@(private="file")
finish :: proc(p: os.Process, cmd: []string, dir: string) -> bool {
	state, err := os.process_wait(p)
	if err != nil || !state.exited || state.exit_code != 0 {
		fmt.eprint("build: failed: ")
		print_cmd(cmd, dir)
		return false
	}
	return true
}

// Runs a command and returns its standard output.
run_capture :: proc(cmd: []string, dir := "") -> (string, bool) {
	if verbose {
		print_cmd(cmd, dir)
	}
	state, stdout, stderr, err := os.process_exec({command = cmd, working_dir = dir}, context.temp_allocator)
	if err != nil || !state.exited || state.exit_code != 0 {
		if len(stderr) > 0 {
			fmt.eprint(string(stderr))
		}
		return "", false
	}
	return string(stdout), true
}

JOBS :: 16

// Runs the commands, JOBS at a time. True if every one succeeded.
run_parallel :: proc(cmds: [][]string, dir := "") -> bool {
	Job :: struct {
		p:   os.Process,
		cmd: []string,
	}
	running := make([dynamic]Job, context.temp_allocator)
	ok := true
	for cmd in cmds {
		if len(running) == JOBS {
			ok = finish(running[0].p, running[0].cmd, dir) && ok
			ordered_remove(&running, 0)
		}
		p, started := start(cmd, dir)
		if !started {
			ok = false
			break
		}
		append(&running, Job{p, cmd})
	}
	for j in running {
		ok = finish(j.p, j.cmd, dir) && ok
	}
	return ok
}

// Splits a flags value from an ndb file into words.
words :: proc(s: string) -> []string {
	return strings.fields(s, context.temp_allocator)
}

// A command line built up from pieces.
Cmd :: [dynamic]string

cmd_make :: proc(args: ..string) -> Cmd {
	c := make(Cmd, context.temp_allocator)
	append(&c, ..args)
	return c
}

read_file :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("build: cannot read %s: %v", path, err)
		return "", false
	}
	return string(data), true
}

write_file :: proc(path: string, data: string) -> bool {
	if err := os.write_entire_file(path, transmute([]u8)data); err != nil {
		fmt.eprintfln("build: cannot write %s: %v", path, err)
		return false
	}
	return true
}

make_dirs :: proc(path: string) -> bool {
	if err := os.make_directory_all(path); err != nil && err != .Exist {
		fmt.eprintfln("build: cannot make %s: %v", path, err)
		return false
	}
	return true
}

// FNV-1a, chained from h, over a file's text or a name: the cache keys and
// the image's derived GUIDs. Chains start from the offset basis, which is
// also hash.fnv64a's default seed.
FNV_OFFSET :: u64(0xcbf29ce484222325)

fnv :: proc(h: u64, data: string) -> u64 {
	return hash.fnv64a(transmute([]u8)data, h)
}
