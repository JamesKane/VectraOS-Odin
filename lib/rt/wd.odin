package rt

// The current directory (upstream's M6 step 6d7a, ADR-0017, its ADR-0039).
//
// One for the process, an absolute and clean path (as vx:ns's clean makes
// them), at most 255 bytes: the spawn message's cwd=, else /. vx:ns resolves
// relative names against it, and vx:procns's chdir changes it; musl's back
// end keeps its working directory here too.

WD_MAX :: 256 // as vx:ns's MAX_PATH

@(private="file")
wd: struct {
	lock: Mutex,
	path: [dynamic; WD_MAX - 1]u8, // empty: /
}

// The current directory, copied into buf: a slice of it, or "" if it needs
// more than len(buf) bytes.
getwd :: proc "contextless" (buf: []u8) -> string {
	mutex_lock(&wd.lock)
	defer mutex_unlock(&wd.lock)
	path := len(wd.path) > 0 ? string(wd.path[:]) : "/"
	if len(path) > len(buf) {
		return ""
	}
	return string(buf[:copy(buf, path)])
}

// Sets the current directory to path, absolute and clean, which the caller
// has found to be a directory (procns.chdir; musl's chdir). False if it is
// not absolute or too long.
@(require_results)
wd_set :: proc "contextless" (path: string) -> bool {
	if len(path) == 0 || path[0] != '/' || len(path) >= WD_MAX {
		return false
	}
	mutex_lock(&wd.lock)
	defer mutex_unlock(&wd.lock)
	clear(&wd.path)
	_ = append(&wd.path, path)
	return true
}
