// The FAT images the suite reads: tests/host/fatfix's, made by mtools.
package fat_test

import "core:os"
import "../fatfix"

FIXTURES :: fatfix.FIXTURES
UNICODE_FILE :: fatfix.UNICODE_FILE
big_byte :: fatfix.big_byte
fixtures :: fatfix.fixtures
load :: fatfix.load

// An image saved for a later check by another implementation (fsck.fat -n),
// as upstream's ./build check runs on what its fat_test wrote.
save :: proc(path: string, data: []u8) {
	_ = os.make_directory_all("out/host")
	_ = os.write_entire_file(path, data)
}
