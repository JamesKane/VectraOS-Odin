/* The spike kernel's layout (aarch64): the top 2 GiB, one permission set per segment. */
OUTPUT_FORMAT(elf64-littleaarch64)
ENTRY(_start)

PHDRS {
    text   PT_LOAD FLAGS(5);
    rodata PT_LOAD FLAGS(4);
    data   PT_LOAD FLAGS(6);
}

SECTIONS {
    . = 0xffffffff80000000;
    .text : { *(.text .text.*) } :text

    . = ALIGN(CONSTANT(MAXPAGESIZE));
    .rodata : { *(.rodata .rodata.*) } :rodata

    . = ALIGN(CONSTANT(MAXPAGESIZE));
    .data : {
        KEEP(*(.limine_requests_start))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end))
        *(.data .data.*)
    } :data
    .bss : { *(.bss .bss.*) *(COMMON) } :data

    . = ALIGN(4096);
    .boot_stack (NOLOAD) : {
        . += 65536;
        vx_boot_stack_top = .;
    } :data

    /DISCARD/ : { *(.eh_frame*) *(.note.GNU-stack) *(.comment) }
}
