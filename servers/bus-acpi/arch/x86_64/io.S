// io.S (x86_64): port I/O for bus-acpi's AML at the widths ACPI uses (8, 16
// and 32 bits). Only the ports an IoRange from devmgr has given the task
// work; any other faults.

    .text
    .globl bus_acpi_in8
    .type bus_acpi_in8, @function
bus_acpi_in8:              // (port: u16) -> u8
    movw %di, %dx
    inb %dx, %al
    movzbl %al, %eax
    ret

    .globl bus_acpi_in16
    .type bus_acpi_in16, @function
bus_acpi_in16:             // (port: u16) -> u16
    movw %di, %dx
    inw %dx, %ax
    movzwl %ax, %eax
    ret

    .globl bus_acpi_in32
    .type bus_acpi_in32, @function
bus_acpi_in32:             // (port: u16) -> u32
    movw %di, %dx
    inl %dx, %eax
    ret

    .globl bus_acpi_out8
    .type bus_acpi_out8, @function
bus_acpi_out8:             // (port: u16, value: u8)
    movw %di, %dx
    movb %sil, %al
    outb %al, %dx
    ret

    .globl bus_acpi_out16
    .type bus_acpi_out16, @function
bus_acpi_out16:            // (port: u16, value: u16)
    movw %di, %dx
    movw %si, %ax
    outw %ax, %dx
    ret

    .globl bus_acpi_out32
    .type bus_acpi_out32, @function
bus_acpi_out32:            // (port: u16, value: u32)
    movw %di, %dx
    movl %esi, %eax
    outl %eax, %dx
    ret

    .section .note.GNU-stack, "", @progbits
