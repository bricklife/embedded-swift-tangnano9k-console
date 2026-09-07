/* Soft bootloader loads this image at 0x2000 (see example_soc/pong/link.ld). */

MEMORY {
    APP (rwx) : ORIGIN = 0x00002000, LENGTH = 24K
}

SECTIONS {
    .vectors : {
        KEEP(*(.vectors))
    } > APP

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
