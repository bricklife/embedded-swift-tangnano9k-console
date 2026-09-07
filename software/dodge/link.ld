/* link.ld -- Swift app for Tang Nano 9K (software SD boot layout)
 *
 * Soft bootloader (sw/sd_boot) occupies low 8 KiB and loads this image at 0x2000.
 *
 *   0x00000000 - 0x00001fff : boot (not part of this binary)
 *   0x00002000 - 0x0000203f : app trap vectors (.vectors)
 *   0x00002040 - 0x00007fff : app code + data (entry = soft boot jump target)
 *
 * Soft boot jumps to 0x2040 after loading PROG.BIN here.
 * Hardware RESET_VECTOR is still 0x40 for the *boot* image only.
 */

MEMORY {
    APP (rwx) : ORIGIN = 0x00002000, LENGTH = 24K
}

SECTIONS {
    /* Trap stub at APP base + 0x00 → VMA 0x2000
     * start.S pads .vectors to 0x40 bytes so .text begins at 0x2040. */
    .vectors : {
        KEEP(*(.vectors))
    } > APP

    /* Entry (_start) at 0x2040 */
    .text : {
        *(.text.startup)
        *(.text*)
    } > APP

    .rodata : {
        *(.rodata*)
    } > APP

    .got : {
        *(.got*)
    } > APP

    .swift_modhash : {
        *(.swift_modhash)
    } > APP

    .data : {
        *(.data*)
    } > APP

    .bss : {
        *(.bss*)
        *(COMMON)
    } > APP

    _end = .;

    ASSERT(. <= 0x00008000, "Swift app exceeds 24 KiB application region (0x2000-0x7fff)")

    .debug 0 : { *(.debug_*) }
    .comment 0 : { *(.comment) }
    .riscv.attributes 0 : { *(.riscv.attributes) }
    .symtab 0 : { *(.symtab) }
    .shstrtab 0 : { *(.shstrtab) }
    .strtab 0 : { *(.strtab) }
}
