#pragma once

#include <stdint.h>

/// Execute a single RISC-V `nop` and return.
void nop(void);

/// 512-byte sector buffer (BSS).
uint8_t *sd_sector_ptr(void);
