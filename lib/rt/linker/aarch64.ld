/* A user program's layout (aarch64): a static, non-PIE ELF at 4 MiB. Each
   segment has one set of permissions (W^X), as the kernel's ELF loader
   insists. */
OUTPUT_FORMAT(elf64-littleaarch64)
ENTRY(_start)

PHDRS {
    text   PT_LOAD FLAGS(5);
    rodata PT_LOAD FLAGS(4);
    data   PT_LOAD FLAGS(6);
}

SECTIONS {
    . = 0x400000;
    .text : { *(.text .text.*) } :text

    . = ALIGN(CONSTANT(MAXPAGESIZE));
    .rodata : { *(.rodata .rodata.*) } :rodata

    . = ALIGN(CONSTANT(MAXPAGESIZE));
    .data : {
        *(.data .data.*)
        *(.got .got.plt)   /* Odin's globals may be reached through the GOT */
    } :data
    .bss : { *(.bss .bss.*) *(COMMON) } :data

    /DISCARD/ : { *(.eh_frame*) *(.note.GNU-stack) *(.comment) }
}
