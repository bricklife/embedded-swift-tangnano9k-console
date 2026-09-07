// start.S -- App entry for Tang Nano 9K (software SD boot layout)
//
// Linked at ORIGIN 0x2000 (see link.ld). Soft bootloader jumps here:
//   0x2000 : trap stub (.vectors, padded to 0x40 bytes)
//   0x2040 : _start  (APP_ENTRY in sw/sd_boot)
// Stack remains at top of 32 KiB SRAM (0x8000).

	.section .vectors, "ax"

// ---------------------------------------------------------------------------
// Trap stub at app base + 0x00 (VMA 0x2000). Soft boot leaves mtvec at 0x0
// (boot region) unless the app rewrites it; this is a local safety stub.

	.globl _trap_vector
_trap_vector:
	j _trap_vector

// Pad section size to 0x40 so .text is placed at base+0x40 → 0x2040.
	.org 0x40

// ---------------------------------------------------------------------------
// App entry (_start at 0x2040)

	.section .text.startup, "ax"
	.globl _start
_start:
	// Zero all registers (except x0).
	li  x1,  0
	li  x2,  0
	li  x3,  0
	li  x4,  0
	li  x5,  0
	li  x6,  0
	li  x7,  0
	li  x8,  0
	li  x9,  0
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

	// Stack at top of SRAM (shared with boot region layout).
	li  sp, 0x8000

	call main

1:	j 1b
