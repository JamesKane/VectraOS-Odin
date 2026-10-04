/* A user program's layout (x86_64): a static, non-PIE ELF at 4 MiB. Each
   segment has one set of permissions (W^X), as the kernel's ELF loader
   insists. The first, read-only, holds the ELF header and program headers
   and the build ID, with a PT_NOTE for it, as lld's default layout does:
   procfs's /proc/N/images finds a program's image by its mapped header,
   and names it by that build ID (upstream docs/05 §3). */
OUTPUT_FORMAT(elf64-x86-64)
ENTRY(_start)

PHDRS {
    rodata PT_LOAD FILEHDR PHDRS FLAGS(4);
    text   PT_LOAD FLAGS(5);
    data   PT_LOAD FLAGS(6);
    note   PT_NOTE FLAGS(4);
}

SECTIONS {
    . = 0x400000 + SIZEOF_HEADERS;
    .note.gnu.build-id : { *(.note.gnu.build-id) } :rodata :note
    .rodata : { *(.rodata .rodata.*) } :rodata

    . = ALIGN(CONSTANT(MAXPAGESIZE));
    .text : { *(.text .text.*) } :text

    . = ALIGN(CONSTANT(MAXPAGESIZE));
    .data : {
        *(.data .data.*)
        *(.got .got.plt)   /* Odin's globals may be reached through the GOT */
    } :data
    .bss : { *(.bss .bss.*) *(COMMON) } :data

    /DISCARD/ : { *(.eh_frame*) *(.note.GNU-stack) *(.comment) }
}
