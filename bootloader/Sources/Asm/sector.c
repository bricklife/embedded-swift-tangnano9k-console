// 512-byte SD sector buffer in BSS (shared by FAT32).
#include <stdint.h>

uint8_t sd_sector_buf[512];

uint8_t *sd_sector_ptr(void) {
  return sd_sector_buf;
}
