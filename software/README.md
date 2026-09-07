# Software (Embedded Swift)

Apps loaded as **`PROG.BIN`** on the SD card. All are linked at `0x0000_2000`.

| Directory | Contents |
|---|---|
| `pong/` | Pong |
| `dodge/` | Dodge |
| `flappy/` | Flappy |
| `sfx/` | Sound-effect demo |
| `common/` | UART program loader (`uart_prog.py`) |

## Build

An open-source Swift toolchain with RISC-V support is required.

```bash
make -C software/pong
cp software/pong/pong.bin /Volumes/<SD>/PROG.BIN
```

The SD card must be **FAT32**, with **`PROG.BIN`** (8.3 short name) in the root. Maximum size is 24 KiB.

If there is no SD card, or load fails, the bootloader waits on UART:

```bash
python3 software/common/uart_prog.py /dev/cu.usbserial-101 software/pong/pong.bin
```
