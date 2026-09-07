// Soft SD bootloader entry (RESET_VECTOR=0x40, MTVEC=0x0)
// Stack at top of boot region (0x2000); app region starts there.

	.section .vectors, "ax"
	.globl _trap_vector
_trap_vector:
	j _trap_vector

	// Pad section size to 0x40 so .text.startup is placed at 0x40.
	.org 0x40

	.section .text.startup, "ax"
	.globl _start
_start:
	/* Zero GPRs */
	li  x1, 0
	li  x2, 0
	li  x3, 0
	li  x4, 0
	li  x5, 0
	li  x6, 0
	li  x7, 0
	li  x8, 0
	li  x9, 0
	li  x10, 0
	li  x11, 0
	li  x12, 0
	li  x13, 0
	li  x14, 0
	li  x15, 0
	li  x16, 0
	li  x17, 0
	li  x18, 0
	li  x19, 0
	li  x20, 0
	li  x21, 0
	li  x22, 0
	li  x23, 0
	li  x24, 0
	li  x25, 0
	li  x26, 0
	li  x27, 0
	li  x28, 0
	li  x29, 0
	li  x30, 0
	li  x31, 0

	/* Stack at top of boot region (app starts at 0x2000) */
	la  sp, __stack_top

	/* Clear .bss */
	la  t0, __bss_start
	la  t1, __bss_end
1:
	bgeu t0, t1, 2f
	sw   zero, 0(t0)
	addi t0, t0, 4
	j    1b
2:
	call main
3:	j 3b
