#!/bin/sh
# Rebuilds tests/host/fs's cross-format fixtures, from the repository's root,
# with upstream VectraOS's C as the oracle:
#
#   UPSTREAM=/path/to/VectraOS tests/host/fs/fixtures/make.sh
#
# UPSTREAM is a checkout of upstream at M5 (1976c1f); CC a clang that takes
# -std=c23 (default: Homebrew's llvm@22). Upstream's code is only compiled
# here, into a scratch directory; none of it enters this tree.
#
# c-lib.vxfs.gz, c-lib.txt: ops.txt (written by gen-ops.py) run by
#   mkfixture.c against upstream's lib/vx-fs: the volume it leaves (4 arenas,
#   two changed branches, snapshots, forks, deadlists, compressed logs,
#   orphans) and what each op returned.
# c-tool.vxfs.gz: upstream's host/vxfs (shim.h pinning its clock to
#   SOURCE_DATE_EPOCH) making a 2 MiB volume as ./build would: mkfs with
#   /adm/users, tree/ put in home, a snapshot, cfg/ put in cfg, a fork, a
#   label made and deleted. tree/ and cfg/ are copied first, with fixed modes
#   and mtimes.
# tool.txt: what upstream's host/vxfs prints for each of TOOL_COMMANDS below
#   on that volume, and its exit status.
#
# And the reverse, checked here as the fixtures are made: tools/vxfs makes
# the same volume from the same copies, which must be c-tool.vxfs byte for
# byte; upstream's host/vxfs must print tool.txt for it too, and verify,
# check and read it.
set -eu

: "${UPSTREAM:?set UPSTREAM to upstream VectraOS at 1976c1f}"
CC=${CC:-/opt/homebrew/opt/llvm@22/bin/clang}
DIR=tests/host/fs/fixtures
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The oracles, and this tree's tool.
"$CC" -std=c23 -O2 -g -Wall -Wextra -include "$DIR/shim.h" -o "$TMP/vxfs-c" "$UPSTREAM/host/vxfs/main.c"
"$CC" -std=c23 -O1 -g -Wall -Wextra -fsanitize=address,undefined \
	-DUPSTREAM_CHECK_C="\"$UPSTREAM/lib/vx-fs/check.c\"" -DUPSTREAM_FILE_C="\"$UPSTREAM/lib/vx-fs/file.c\"" \
	-o "$TMP/mkfixture" "$DIR/mkfixture.c"
./build loc >/dev/null
odin build tools/vxfs -collection:vx=lib -collection:abi=abi -o:speed -out:"$TMP/vxfs-odin"

# The library's volume.
"$TMP/mkfixture" "$DIR/ops.txt" "$TMP/c-lib.vxfs" >"$DIR/c-lib.txt"
gzip -9n <"$TMP/c-lib.vxfs" >"$DIR/c-lib.vxfs.gz"

# The trees, as the tools see them.
cp -R "$DIR/tree" "$DIR/cfg" "$TMP/"
find "$TMP/tree" "$TMP/cfg" -type d -exec chmod 755 {} +
find "$TMP/tree" "$TMP/cfg" -type f -exec chmod 644 {} +
chmod 755 "$TMP/tree/bin/run"
find "$TMP/tree" "$TMP/cfg" -exec touch -h -t 202601010000.00 {} +

export SOURCE_DATE_EPOCH=1767225600 # 2026-01-01T00:00:00Z
make_volume() { # TOOL IMAGE
	"$1" mkfs -u vectra "$2" 2 store cfg home adm
	"$1" put "$2" home "$TMP/tree"
	"$1" snap "$2" home home@fix
	"$1" put "$2" cfg "$TMP/cfg"
	"$1" fork "$2" home@fix work
	"$1" snap "$2" cfg cfg@tmp
	"$1" del "$2" cfg@tmp
}
mkdir "$TMP/c" "$TMP/o"
(cd "$TMP/c" && make_volume "$TMP/vxfs-c" vol)
(cd "$TMP/o" && make_volume "$TMP/vxfs-odin" vol)
cmp "$TMP/c/vol" "$TMP/o/vol" || { echo "make.sh: tools/vxfs's volume differs from upstream's" >&2; exit 1; }
gzip -9n <"$TMP/c/vol" >"$DIR/c-tool.vxfs.gz"

# What upstream's tool says of it; the test runs each command again with
# tools/vxfs. "vol" is the image.
TOOL_COMMANDS='info vol
check vol
ls vol home
ls vol home /docs
ls vol home /docs/a/b
ls vol home@fix
ls vol work
ls vol cfg
ls vol adm
cat vol adm /users
cat vol home /README
cat vol home /empty
cat vol home /inline-511
cat vol home /block-512
cat vol home /big
cat vol home /link
cat vol home /bin/run
cat vol work /docs/a/b/deep.txt
cat vol cfg /net.ndb
ls vol nolabel
cat vol home /nothing
ls vol home /README'
transcript() { # TOOL: each command, its output, its errors, its status
	echo "$TOOL_COMMANDS" | while read -r line; do
		echo "\$ vxfs $line"
		set +e
		# shellcheck disable=SC2086
		"$1" $line >"$TMP/out" 2>"$TMP/err"
		code=$?
		set -e
		cat "$TMP/out"
		printf '\n-- stderr\n'
		cat "$TMP/err"
		echo "-- exit $code"
	done
}
(cd "$TMP/c" && transcript "$TMP/vxfs-c") >"$DIR/tool.txt"
(cd "$TMP/o" && transcript "$TMP/vxfs-c") >"$TMP/o.txt"
cmp "$DIR/tool.txt" "$TMP/o.txt" || { echo "make.sh: upstream's tool reads tools/vxfs's volume differently" >&2; exit 1; }
"$TMP/vxfs-c" verify "$TMP/o/vol" home "$TMP/tree"
"$TMP/vxfs-c" verify "$TMP/o/vol" cfg "$TMP/cfg"
"$TMP/vxfs-odin" verify "$TMP/c/vol" home "$TMP/tree"
echo "make.sh: fixtures made; tools/vxfs's volume is upstream's, byte for byte"
