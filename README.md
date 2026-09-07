# embedded-swift-tangnano9k-console

A RISC-V handheld game console on Tang Nano 9K, programmed in **Embedded Swift**.

A Hazard3 CPU runs on the FPGA. An Embedded Swift soft bootloader is preloaded into SRAM and loads `PROG.BIN` from an SD card. Games and the bootloader are both written in Embedded Swift.

## Layout

```text
fpga/          Tang Nano 9K RTL, constraints, and synthesis (CLI / Gowin EDA)
  third_party/ hazard3 / libfpga (submodules)
bootloader/    Embedded Swift SD bootloader (SRAM preload)
software/      Embedded Swift apps (SD PROG.BIN)
```

| Region | Address | Location |
|---|---|---|
| Bootloader | `0x0000_0000` (8 KiB) | `bootloader/` |
| Application | `0x0000_2000` (24 KiB) | `software/*` → SD root `PROG.BIN` |

## Requirements

| Tool | Use |
|---|---|
| [Gowin EDA](https://www.gowinsemi.com/en/support/download_eda/) | Synthesis and place-and-route (`gw_sh` or GUI) |
| [openFPGALoader](https://github.com/trabucayre/openFPGALoader) | Bitstream programming |
| [Swift 6.3.2 open-source toolchain](https://www.swift.org/install/) (RISC-V) | Bootloader and apps |
| [OpenOCD](https://openocd.org/) | JTAG debug (optional) |

The Swift bundled with Xcode cannot compile `riscv32`.

## Getting started

```bash
git clone <this-repo>
cd embedded-swift-tangnano9k-console
make submodules   # hazard3, libfpga, and Hazard3's fpgascripts (listfiles)

# Bitstream (bootloader hex → synthesis)
make synth

# Program Tang Nano 9K SRAM (lost on power-off)
make run

# Program Flash (persistent)
make flash
```

To synthesize from the Gowin EDA GUI:

```bash
make -C fpga gprj
# Open the generated fpga/fpga_tangnano9k.gprj in Gowin EDA
```

See [`fpga/README.md`](fpga/README.md) for hardware details.

## Apps

```bash
make -C software/pong
make -C software/dodge
make -C software/flappy
make -C software/sfx

cp software/pong/pong.bin /Volumes/<SD>/PROG.BIN
```

The SD card must be **FAT32**, with **`PROG.BIN`** (8.3 short name) in the root. Apps are linked at `0x0000_2000`.

## Acknowledgments

This project is based on [ciniml](https://github.com/ciniml)'s [Hazard3 Gowin port](https://github.com/ciniml/Hazard3/tree/gowin/example_soc/synth_gowin). That work made it possible to bring Hazard3 up on Tang Nano 9K, and this console would not have reached this point without it.

## License

Original work in this repository is Apache-2.0. Third-party components:

- [Hazard3](https://github.com/wren6991/hazard3) — Apache-2.0 (`fpga/third_party/hazard3`)
- [libfpga](https://github.com/Wren6991/libfpga) — WTFPL (`fpga/third_party/libfpga`)
