// io.S (x86_64): port I/O for drivers, which may use the ports an IoRange
// gives their task (as_map with the IoRange); any other port faults.

    .text
    .globl vx_inb
    .type vx_inb, @function
vx_inb:                    // (port: u16) -> u8
    movw %di, %dx
    inb %dx, %al
    movzbl %al, %eax
    ret

    .globl vx_outb
    .type vx_outb, @function
vx_outb:                   // (port: u16, value: u8)
    movw %di, %dx
    movb %sil, %al
    outb %al, %dx
    ret

    .section .note.GNU-stack, "", @progbits
