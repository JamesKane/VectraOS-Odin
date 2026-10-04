#!/bin/sh
# Spike S1 driver: odin -> LLVM IR -> llc (frame pointers) -> ld.lld -> Limine ESP -> QEMU.
# Usage: run.sh x86_64|aarch64 [extra qemu args]. Throwaway; build.odin replaces it.
set -eu
arch=$1; shift
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=$root/out/s1/$arch
LLVM=/opt/homebrew/opt/llvm@22/bin
LLD=/opt/homebrew/opt/lld@22/bin/ld.lld
ODIN=/opt/homebrew/bin/odin
QEMU_SHARE=/opt/homebrew/share/qemu
LIMINE_SHARE=/opt/homebrew/share/limine

case $arch in
x86_64)  target=freestanding_amd64_sysv; extra="-disable-red-zone"; llcx="-code-model=kernel"; efi=BOOTX64.EFI;;
aarch64) target=freestanding_arm64; extra=""; llcx=""; efi=BOOTAA64.EFI;;
*) echo "arch?"; exit 2;;
esac

rm -rf "$out"; mkdir -p "$out/ir" "$out/obj" "$out/esp/EFI/BOOT" "$out/esp/boot/limine" "$out/esp/boot/vx"
"$ODIN" build "$here/kernel" -target:$target -build-mode:llvm-ir -no-crt -default-to-nil-allocator -disable-init-fini \
  -no-rtti -no-thread-local -reloc-mode:static -debug -o:minimal $extra \
  -vet -strict-style -warnings-as-errors -out:"$out/ir"
for ll in "$out"/ir/*.ll; do
  "$LLVM/llc" --frame-pointer=all -O1 -relocation-model=static $llcx -filetype=obj "$ll" -o "$out/obj/$(basename "$ll" .ll).o"
done
for s in "$here"/arch/$arch/*.S; do "$LLVM/clang" --target=$arch-unknown-none-elf -c "$s" -o "$out/obj/$(basename "$s" .S)_S.o"; done
"$LLD" -nostdlib -static -z max-page-size=0x1000 --build-id -T "$here/linker/$arch.ld" -o "$out/kernel.elf" "$out"/obj/*.o

cp "$LIMINE_SHARE/$efi" "$out/esp/EFI/BOOT/"
cp "$here/limine.conf" "$out/esp/boot/limine/"
cp "$out/kernel.elf" "$out/esp/boot/vx/"

case $arch in
x86_64)  q="qemu-system-x86_64 -M q35 -cpu max -drive if=pflash,format=raw,readonly=on,file=$QEMU_SHARE/edk2-x86_64-code.fd";;
aarch64) q="qemu-system-aarch64 -M virt -cpu max -drive if=pflash,format=raw,readonly=on,file=$QEMU_SHARE/edk2-aarch64-code.fd";;
esac
exec $q -m 512 -smp 2 -nographic -no-reboot -drive format=raw,file=fat:rw:"$out/esp" "$@"
