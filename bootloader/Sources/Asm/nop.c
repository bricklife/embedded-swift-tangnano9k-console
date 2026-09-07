// Single RISC-V nop callable from C / Swift (Asm module).

void nop(void) {
  __asm__ volatile("nop");
}
