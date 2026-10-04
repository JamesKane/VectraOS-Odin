/* The kernel's layout (aarch64). Limine loads it in the top 2 GiB. Each segment
   has one set of permissions, so no mapping is both writable and executable. */
OUTPUT_FORMAT(elf64-littleaarch64)
ENTRY(_start)

PHDRS {
    text   PT_LOAD FLAGS(5);   /* R X */
    rodata PT_LOAD FLAGS(4);   /* R   */
    data   PT_LOAD FLAGS(6);   /* R W */
}

SECTIONS {
    . = 0xffffffff80000000;

    vx_text_start = .;
    .text : { *(.text .text.*) } :text
    vx_text_end = .;

    . = ALIGN(CONSTANT(MAXPAGESIZE));
    vx_rodata_start = .;
    .rodata : {
        *(.rodata .rodata.*)
        KEEP(*(.vx_symbols))   /* last, so its size moves no function (tools/build) */
    } :rodata
    .note.gnu.build-id : { *(.note.gnu.build-id) } :rodata
    vx_rodata_end = .;

    . = ALIGN(CONSTANT(MAXPAGESIZE));
    vx_data_start = .;
    .data : {
        /* Limine looks for its requests between these markers (boot.odin). */
        KEEP(*(.limine_requests_start))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end))
        *(.data .data.*)
        /* Odin's IR leaves symbols preemptible, so some accesses go through
           the GOT, which belongs with the data the kernel maps. */
        *(.got .got.plt)
    } :data
    .bss : { *(.bss .bss.*) *(COMMON) } :data
    vx_data_end = .;

    /* The boot stack, with a guard page below it. The guard page is part of the
       segment Limine loads but is never mapped in the kernel's own page tables
       (paging.odin), so overflowing the stack faults. */
    . = ALIGN(4096) + 4096;
    .boot_stack (NOLOAD) : {
        vx_boot_stack_bottom = .;
        . += 65536;
        vx_boot_stack_top = .;
    } :data

    /DISCARD/ : { *(.eh_frame*) *(.note.GNU-stack) *(.comment) }
}
