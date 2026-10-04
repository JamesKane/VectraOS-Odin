package build

import "core:fmt"
import "core:os"
import "core:strings"

// FAT test disks (upstream's M5 step 8b): a scenario's second disk that is
// one FAT volume, no partition table, as many USB sticks are (fat=12, 16 or
// 32 with disk=MIB), made by mtools as upstream's fat_disk makes it; and,
// with fsck, the check after the run that another implementation finds the
// volume the guest wrote sound. Upstream's is fsck.fat -n (dosfstools). On
// macOS it is fsck_msdos -n, which warns of a "long filename entry for
// volume label" on every volume mtools labels: there the disk must have no
// finding a fresh disk made the same way lacks.

when ODIN_OS == .Darwin {
	FSCK_FAT :: []string{"/sbin/fsck_msdos", "-n"}
} else {
	FSCK_FAT :: []string{"/usr/bin/fsck.fat", "-n"}
}

// A FAT12, FAT16 or FAT32 volume of mib MiB at path, labelled VECTRAFAT.
make_fat_disk :: proc(path: string, mib: int, bits: int) -> bool {
	if bits != 12 && bits != 16 && bits != 32 {
		fmt.eprintfln("build: fat=%d: FAT is 12, 16 or 32", bits)
		return false
	}
	_ = os.remove(path)
	c := cmd_make(MFORMAT, "-C", "-i", path, "-v", "VECTRAFAT", "-T", fmt.tprint(mib << 11), "-h", "64", "-s", "32")
	if bits == 32 {
		append(&c, "-F")
	}
	append(&c, "::")
	if !run(c[:]) {
		fmt.eprintfln("build: cannot make the FAT test disk %s", path)
		return false
	}
	return true
}

// What the host's fsck finds wrong with the volume at path, a line each;
// none if it finds it sound. Its progress and summary lines are left out.
@(private="file")
fsck_findings :: proc(path: string) -> (found: []string, ran: bool) {
	c := make([dynamic]string, context.temp_allocator)
	append(&c, ..FSCK_FAT)
	append(&c, path)
	state, stdout, stderr, err := os.process_exec({command = c[:]}, context.temp_allocator)
	if err != nil || !state.exited {
		fmt.eprintfln("build: cannot run %s: %v", FSCK_FAT[0], err)
		return nil, false
	}
	if state.exit_code == 0 {
		return nil, true
	}
	out := fmt.tprintf("%s%s", string(stdout), string(stderr))
	lines := make([dynamic]string, context.temp_allocator)
	for line in strings.split_lines_iterator(&out) {
		summary := strings.has_prefix(line, "Warning: ") && strings.contains(line, " files, ")
		if line != "" && !strings.has_prefix(line, "**") && !summary {
			append(&lines, line)
		}
	}
	if len(lines) == 0 {
		append(&lines, fmt.tprintf("%s exited %d", FSCK_FAT[0], state.exit_code))
	}
	return lines[:], true
}

// Whether the host's fsck finds the FAT volume at path sound: what it
// finds, if anything, written to log. mib and bits are how the disk was
// made (make_fat_disk), for macOS's comparison with a fresh one.
fsck_fat_disk :: proc(path, log: string, mib, bits: int) -> bool {
	found := fsck_findings(path) or_return
	when ODIN_OS == .Darwin {
		fresh := fmt.tprintf("%s.fresh", path)
		make_fat_disk(fresh, mib, bits) or_return
		known := fsck_findings(fresh) or_return
		_ = os.remove(fresh)
		unknown := make([dynamic]string, context.temp_allocator)
		outer: for f in found {
			for k in known {
				if f == k {
					continue outer
				}
			}
			append(&unknown, f)
		}
		found = unknown[:]
	}
	write_file(log, strings.join(found, "\n", context.temp_allocator)) or_return
	return len(found) == 0
}
