# Bootloader (Embedded Swift)

Loads **`PROG.BIN`** from the FAT32 root into SRAM at **`0x2000`** and jumps to **`0x2040`**. The image is preloaded into SRAM (`0x0000_0000`, max 8 KiB) at synthesis time.

## Memory map

```
0x0000_0000  boot (this image, max 8 KiB)
0x0000_2000  app load address (max 24 KiB) — PROG.BIN
0x0000_2040  app entry
0x0000_8000  end of SRAM
```

## Soft SPI (FPGA GPIO bit-bang)

| GPIO | Signal |
|------|--------|
| `gpio_o[8]` | SD CS_n |
| `gpio_o[9]` | SD MOSI |
| `gpio_o[10]` | SD SCK |
| `gpio_i[11]` | SD MISO |

## Build

An open-source Swift toolchain with RISC-V support is required (for example `swift-6.3.2-RELEASE.xctoolchain`). The Swift bundled with Xcode cannot compile `riscv32`.

```bash
make -C bootloader
# → bootloader.bin / bootloader.hex
```

The default synthesis preload is this directory (`fpga/Makefile` → `fpga/build/bootloader.hex`).

## UART log

Success: `SD..` → `INI.` → `FAT.` → `PRG OK`

Fallback when SD fails:

1. `ERR xx` (SD/FAT error code)
2. `URX.` — wait for a program from the host over UART
3. Host sends a little-endian uint32 length plus payload (max 24 KiB, placed at `0x2000`)
4. `PRG OK` → jump to `0x2040`

```bash
python3 software/common/uart_prog.py /dev/cu.usbserial-101 \
  software/pong/pong.bin
```
