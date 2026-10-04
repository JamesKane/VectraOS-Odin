#!/bin/sh
# Rebuilds tests/host/dbg's fixtures, from the repository's root, after
# `./build all` (which compiles dbgdemo.o and the vectra-musl sysroot):
#
#   tests/host/dbg/fixtures/make.sh
#
# dbgdemo-x86_64.elf, dbgdemo-aarch64.elf: tests/user/dbgdemo.c as ./build
# compiles it (debug mode, against musl, with lib/vx-rt/rt.c), linked as a
# C program is (posix_link_cmd), with start.c standing in for musl's back
# end, which a fixture never needs: it is indexed, never run.
#
# The test finds what it needs (functions, call sites, lines) in the fixture
# itself, so a rebuild needs no table updated.
set -eu

LLVM=/opt/homebrew/opt/llvm@22/bin
LLD=/opt/homebrew/opt/lld@22/bin/ld.lld
DIR=tests/host/dbg/fixtures
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for arch in x86_64 aarch64; do
	LIB=out/$arch/debug/vectra-musl/lib
	"$LLVM/clang" --target=$arch-unknown-none-elf -std=c23 -O1 -Wall -Wextra -Werror \
		-ffreestanding -fno-pie -c -o "$TMP/start-$arch.o" "$DIR/start.c"
	"$LLD" -static -nostdlib --build-id=sha1 -z max-page-size=0x1000 -z noexecstack -e _start \
		-o "$DIR/dbgdemo-$arch.elf" "$TMP/start-$arch.o" out/$arch/debug/prog/dbgdemo/dbgdemo.o \
		"$LIB/libc.a" "$LIB/libclang_rt.builtins.a"
done
