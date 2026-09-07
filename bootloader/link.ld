/* Soft SD bootloader (Embedded Swift) — low 8 KiB of SRAM.
 *
 * 0x00000000 - 0x00001fff : boot (this image, max 8 KiB)
 * 0x00002000 - 0x00007fff : application load area (24 KiB)
 *
 * Application images must be linked with ORIGIN = 0x2000 (entry @ 0x2040).
 */

MEMORY {
    BOOT (rwx) : ORIGIN = 0x00000000, LENGTH = 8K
}

SECTIONS {
    .vectors : {
        KEEP(*(.vectors))
    } > BOOT

    .text : {
        *(.text.startup)
        *(.text*)
    } > BOOT

    .rodata : {
        *(.rodata*)
    } > BOOT

    .got : {
        *(.got*)
    } > BOOT

    .swift_modhash : {
        *(.swift_modhash)
    } > BOOT

    .data : {
        *(.data*)
    } > BOOT

    .bss : {
        __bss_start = .;
        *(.bss*)
        *(COMMON)
        __bss_end = .;
    } > BOOT

    /* Stack grows down from end of boot region */
    __stack_top = 0x00002000;
    _end = .;

    ASSERT(. <= 0x00002000, "swift-sd-boot image exceeds 8 KiB boot region")

    .debug 0 : { *(.debug_*) }
    .comment 0 : { *(.comment) }
    .riscv.attributes 0 : { *(.riscv.attributes) }
    .symtab 0 : { *(.symtab) }
    .shstrtab 0 : { *(.shstrtab) }
    .strtab 0 : { *(.strtab) }
}
