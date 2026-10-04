package build

import "core:fmt"
import "core:os"

// ./build: the one build tool. `odin build build -out:build-tool` once; then
// `./build-tool <command>`. Only `abi` exists so far (spike S4); `all`,
// `image`, `qemu`, `test`, `check`, `loc` and `vendor-check` follow in P0.

USAGE :: `usage: build <command>
  abi    generate abi/vx/abi_gen.odin from abi/vx/*.def`

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln(USAGE)
		os.exit(2)
	}
	ok := false
	switch os.args[1] {
	case "abi":
		ok = gen_abi(".")
	case:
		fmt.eprintln(USAGE)
		os.exit(2)
	}
	os.exit(ok ? 0 : 1)
}
