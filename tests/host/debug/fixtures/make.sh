#!/bin/sh
# Rebuilds tests/host/debug's ELF fixtures, from the repository's root:
#
#   tests/host/debug/fixtures/make.sh
#
# c-x86_64.elf, c-aarch64.elf: fixture.c, as upstream builds its host tests
# (clang 22, -O1, frame pointers, not PIE, a build ID), freestanding.
# odin-x86_64.elf, odin-aarch64.elf: odin/, as ./build builds a program (Odin
# to LLVM IR, llc --frame-pointer=all, ld.lld with the user linker script).
#
# The tests know the fixtures' addresses and lines: after rebuilding, check
# what changed (llvm-dwarfdump, llvm-objdump) and update the tests' tables.
set -eu

LLVM=/opt/homebrew/opt/llvm@22/bin
LLD=/opt/homebrew/opt/lld@22/bin/ld.lld
ODIN=/opt/homebrew/bin/odin
DIR=tests/host/debug/fixtures
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for arch in x86_64 aarch64; do
	"$LLVM/clang" --target=$arch-unknown-none-elf -std=c23 -g -O1 -Wall -Wextra -Werror \
		-fno-omit-frame-pointer -ffreestanding -fno-pie -ffile-prefix-map="$(pwd)"=. \
		-c -o "$TMP/c-$arch.o" "$DIR/fixture.c"
	"$LLD" -nostdlib -static -z max-page-size=0x1000 --build-id=sha1 -T lib/rt/linker/$arch.ld \
		-o "$DIR/c-$arch.elf" "$TMP/c-$arch.o"
done

build_odin() { # arch odin-target
	mkdir -p "$TMP/$1/ir"
	"$ODIN" build "$DIR/odin" -target:"$2" -out:"$TMP/$1/ir" \
		-build-mode:llvm-ir -no-crt -default-to-nil-allocator -disable-init-fini \
		-disable-non-constant-globals -no-rtti -no-thread-local -reloc-mode:static -debug \
		-vet -vet-shadowing -strict-style -warnings-as-errors -no-threaded-checker -thread-count:1 \
		-o:minimal
	for ll in "$TMP/$1"/ir/*.ll; do
		"$LLVM/llc" --frame-pointer=all -O1 -relocation-model=static -filetype=obj "$ll" -o "${ll%.ll}.o"
	done
	"$LLD" -nostdlib -static -z max-page-size=0x1000 --build-id -T lib/rt/linker/$1.ld \
		-o "$DIR/odin-$1.elf" "$TMP/$1"/ir/*.o
}
build_odin x86_64 freestanding_amd64_sysv
build_odin aarch64 freestanding_arm64
