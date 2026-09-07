# FPGA — Tang Nano 9K (Gowin GW1NR-9C)

RTL, constraints, and synthesis scripts for the Hazard3 SoC with LCD, PSRAM, sprite, and PWM peripherals.

## Synthesis (command line)

```bash
# From the repository root
make synth

# Or
make -C fpga synth
```

If `GW_SH` is not at the default Gowin EDA path:

```bash
make -C fpga synth GW_SH=/path/to/gw_sh
```

Output: `fpga/build/impl/pnr/fpga_tangnano9k.fs`

```bash
make -C fpga run           # program SRAM
make -C fpga flash         # program Flash
make -C fpga clean-synth   # synthesis outputs only
make -C fpga clean         # synthesis + bootloader
```

Synthesis builds `bootloader/` first and embeds it as the SRAM initial image. A checked-in `bootloader.hex` is used when present.

## Synthesis (Gowin EDA GUI)

The GUI uses the same RTL, CST, SDC, and file list as the CLI.

```bash
make -C fpga gprj
```

Open the generated `fpga/fpga_tangnano9k.gprj` in Gowin EDA and run Place & Route. GUI implementation files may appear under `fpga/impl/`.

## Hardware

### JTAG (PMOD0)

| FT232H pin | Signal | FPGA pin |
|---|---|---|
| AD0 (D0) | TCK | 28 |
| AD1 (D1) | TDI | 27 |
| AD2 (D2) | TDO | 26 |
| AD3 (D3) | TMS | 25 |
| GND | GND | GND |

OpenOCD: `fpga/openocd/tangnano9k-ft232h.cfg` (FT2232H: `tangnano9k.cfg`)

Pins 36–39 are the on-board microSD slot. Do not share them with JTAG.

### UART (PMOD1)

| Signal | FPGA pin | USB-UART |
|---|---|---|
| TX (FPGA transmit) | 17 | RX |
| RX (FPGA receive) | 18 | TX |
| GND | GND | GND |

115200 8N1.

### PWM audio

`pwm_out` = pin 30 (LVCMOS33).

## Memory map (software view)

| Address | Size | Use |
|---|---|---|
| `0x0000_0000` | 8 KB | Soft bootloader |
| `0x0000_2000` | 24 KB | Application (SD `PROG.BIN`) |
| `0x4000_0000` | - | Timer (APB) |
| `0x4000_1000` | - | LCD control |
| `0x4000_2000` | - | Sprite CTRL |
| `0x4000_3000` | - | PWM score player |
| `0x4000_4000` | - | UART |
| `0x4000_8000` | - | GPIO output (bit[5:0] → LED) |
| `0x4000_c000` | - | GPIO input |
| `0x5000_0000` | 512 B | OBJ palette |
| `0x5000_1000` | 2 KiB | OBJ tile VRAM |
| `0x5000_4000` | N×4 B | OAM |
| `0x6000_0000` | 261,120 B | RGB565 VRAM write window |

- Reset vector (boot): `0x0000_0040`
- Application entry: `0x0000_2040`
