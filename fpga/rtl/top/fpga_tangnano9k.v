/*****************************************************************************\
|                        Copyright (C) 2021 Luke Wren                         |
|                     SPDX-License-Identifier: Apache-2.0                     |
\*****************************************************************************/

// FPGA toplevel for ../soc/tangnano9k_soc.v on a Tang Nano 9K dev board
// (Gowin GW1NR-9C, 27 MHz oscillator)
//
// JTAG is available on PMOD0:
//   PMOD0 pin 1 (FPGA pin 28) = TCK
//   PMOD0 pin 2 (FPGA pin 26) = TDI
//   PMOD0 pin 3 (FPGA pin 39) = TDO
//   PMOD0 pin 4 (FPGA pin 37) = TMS
//
// UART is available on PMOD1:
//   PMOD1 pin 1 (FPGA pin 17) = TX
//   PMOD1 pin 2 (FPGA pin 18) = RX
//
// On-board microSD (SPI mode, schematic TF_CARD) — software bit-bang only:
//   pin 36 = SD_CLK, 37 = SD_MOSI/CMD, 38 = SD_CS (DAT3), 39 = SD_MISO (DAT0)
//   Driven from GPIO: gpio_o[10]=SCK, [9]=MOSI, [8]=CS_n; gpio_i[11]=MISO
//
// GPIO[5:0] drives the 6 on-board LEDs (active-low, 1.8 V I/O).
//
// Boot: CPU runs from $readmemh preload (soft SD bootloader in bootloader/).
// TANGNANO9K_PRELOAD_FILE is defined by generated build/preload.v (see
// fpga/Makefile), which also builds and copies bootloader.hex.

`default_nettype none

// Fallback so the design elaborates without a firmware image.
`ifndef TANGNANO9K_PRELOAD_FILE
`define TANGNANO9K_PRELOAD_FILE ""
`endif

module fpga_tangnano9k (
	input  wire       clk_osc,   // 27 MHz on-board oscillator

	// Button S2 (active-low: 0 = pressed, used as system reset)
	input  wire       btn,
	input  wire [9:0]  btn_gpio,

	// 6 on-board LEDs (active-low, 1.8 V I/O)
	output wire [5:0] led,

	// JTAG debug port (PMOD0)
	input  wire       tck,
	input  wire       tms,
	input  wire       tdi,
	output wire       tdo,

	// UART (PMOD1)
	output wire       uart_tx,
	input  wire       uart_rx,

	// Piezo / PWM audio (bank 2, 3.3 V — was unused btn_gpio[10])
	output wire       pwm_out,

	// On-board microSD (SPI) — soft bit-bang via GPIO
	output wire       sd_clk,
	output wire       sd_cmd,    // MOSI
	input  wire       sd_dat0,   // MISO
	output wire       sd_dat3,   // CS_n

	// 4.3-inch RGB LCD
	output wire       lcd_clk,
	output wire       lcd_hync,
	output wire       lcd_sync,
	output wire       lcd_den,
	output wire [4:0] lcd_r,
	output wire [5:0] lcd_g,
	output wire [4:0] lcd_b,

	// On-chip PSRAM magic ports. Do not constrain these in the CST.
	output wire [1:0]  O_psram_ck,
	output wire [1:0]  O_psram_ck_n,
	inout  wire [1:0]  IO_psram_rwds,
	inout  wire [15:0] IO_psram_dq,
	output wire [1:0]  O_psram_reset_n,
	output wire [1:0]  O_psram_cs_n
);

localparam integer CLK_MHZ = 15;

wire clk_sys;
wire rst_n_sys;
wire trst_n;

gowin_rpll_27m_15m sys_pll_u (
	.clkin  (clk_osc),
	.clkout (clk_sys)
);

// btn is high when not pressed; pressing it forces rst_n low.
fpga_reset #(
	.SHIFT (3)
) rstgen (
	.clk         (clk_sys),
	.force_rst_n (btn),
	.rst_n       (rst_n_sys)
);

// Synchronise system reset into TCK domain for JTAG TAP reset.
reset_sync trst_sync_u (
	.clk       (tck),
	.rst_n_in  (rst_n_sys),
	.rst_n_out (trst_n)
);

// GPIO[5:0] → LEDs (active-low: GPIO=1 → LED on).
// Soft-SD SPI: gpio_o[8]=CS_n, [9]=MOSI, [10]=SCK; gpio_i[11]=MISO.
wire [31:0] gpio_o;
wire [11:0] gpio_btn_active_high = {sd_dat0, 1'b0, (~btn_gpio[9:0])};

assign sd_clk  = gpio_o[10];
assign sd_cmd  = gpio_o[9];
assign sd_dat3 = gpio_o[8];
assign led     = ~gpio_o[5:0];

wire psram_clk;
wire psram_clk_p;
wire        vram_wr_req;
wire        vram_wr_ack;
wire [17:0] vram_wr_addr;
wire [15:0] vram_wr_data;
wire [1:0]  vram_wr_strb;
wire [9:0]  lcd_vcount;
wire        lcd_frame_tick;
wire        lcd_enable;

// Sprite CDC (clk_sys ↔ psram_clk)
wire        spr_enable;
wire        spr_wr_req;
wire        spr_wr_ack;
wire [1:0]  spr_wr_target;
wire [10:0] spr_wr_addr;
wire [31:0] spr_wr_data;
wire [3:0]  spr_wr_strb;
wire        spr_overflow_set;

wire soc_uart_tx;
assign uart_tx = soc_uart_tx;

gowin_rpll_27m_72m psram_pll_u (
	.clkin  (clk_osc),
	.clkout (psram_clk),
	.clkoutp(psram_clk_p)
);

lcd_psram_vram #(
	.ENABLE_DEBUG  (0),
	.ENABLE_SPRITE (1),
	.NUM_SPRITES   (16),
	.MAX_PER_LINE  (4)
) lcd_psram_vram_u (
	.clk             (psram_clk),
	.clk_p           (psram_clk_p),
	.rst_n           (rst_n_sys),
	.vram_wr_clk     (clk_sys),
	.vram_wr_rst_n   (rst_n_sys),
	.vram_wr_req     (vram_wr_req),
	.vram_wr_ack     (vram_wr_ack),
	.vram_wr_addr    (vram_wr_addr),
	.vram_wr_data    (vram_wr_data),
	.vram_wr_strb    (vram_wr_strb),
	.vcount          (lcd_vcount),
	.frame_tick      (lcd_frame_tick),
	.lcd_enable      (lcd_enable),
	.debug_mode      (12'd0),
	.spr_enable      (spr_enable),
	.spr_wr_req      (spr_wr_req),
	.spr_wr_ack      (spr_wr_ack),
	.spr_wr_target   (spr_wr_target),
	.spr_wr_addr     (spr_wr_addr),
	.spr_wr_data     (spr_wr_data),
	.spr_wr_strb     (spr_wr_strb),
	.spr_overflow_set(spr_overflow_set),
	.lcd_clk         (lcd_clk),
	.lcd_de          (lcd_den),
	.lcd_hsync       (lcd_hync),
	.lcd_vsync       (lcd_sync),
	.lcd_r           (lcd_r),
	.lcd_g           (lcd_g),
	.lcd_b           (lcd_b),
	.O_psram_ck      (O_psram_ck),
	.O_psram_ck_n    (O_psram_ck_n),
	.IO_psram_rwds   (IO_psram_rwds),
	.IO_psram_dq     (IO_psram_dq),
	.O_psram_reset_n (O_psram_reset_n),
	.O_psram_cs_n    (O_psram_cs_n)
);

tangnano9k_soc #(
	.CLK_MHZ             (CLK_MHZ),
	.SRAM_DEPTH          (1 << 13),  // 32 kB
	.PRELOAD_FILE        (`TANGNANO9K_PRELOAD_FILE),
	.NUM_SPRITES         (16),
	.MAX_PER_LINE        (4),
	.EXTENSION_A         (1),
	.EXTENSION_C         (1),
	.EXTENSION_M         (1),
	.EXTENSION_ZBA       (0),
	.EXTENSION_ZBB       (0),
	.EXTENSION_ZBC       (0),
	.EXTENSION_ZBS       (0),
	.EXTENSION_ZBKB      (0),
	.EXTENSION_ZIFENCEI  (0),
	.EXTENSION_XH3BEXTM  (0),
	.EXTENSION_XH3PMPM   (0),
	.EXTENSION_XH3POWER  (0),
	.CSR_COUNTER         (0),
	.U_MODE              (0),
	.PMP_REGIONS         (0),
	.BREAKPOINT_TRIGGERS (0),
	.IRQ_PRIORITY_BITS   (0),
	.REDUCED_BYPASS      (0),
	.MULDIV_UNROLL       (1),
	.MUL_FAST            (0),
	.MUL_FASTER          (0),
	.MULH_FAST           (0),
	.FAST_BRANCHCMP      (1),
	.BRANCH_PREDICTOR    (0)
) soc_u (
	.clk     (clk_sys),
	.rst_n   (rst_n_sys),

	.tck     (tck),
	.trst_n  (trst_n),
	.tms     (tms),
	.tdi     (tdi),
	.tdo     (tdo),

	.uart_tx (soc_uart_tx),
	.uart_rx (uart_rx),
	.pwm_out (pwm_out),
	.gpio_i  (gpio_btn_active_high),
	.gpio_o  (gpio_o),
	.lcd_vcount     (lcd_vcount),
	.lcd_frame_tick (lcd_frame_tick),
	.lcd_enable     (lcd_enable),

	.vram_wr_req  (vram_wr_req),
	.vram_wr_ack  (vram_wr_ack),
	.vram_wr_addr (vram_wr_addr),
	.vram_wr_data (vram_wr_data),
	.vram_wr_strb (vram_wr_strb),

	.spr_enable       (spr_enable),
	.spr_wr_req       (spr_wr_req),
	.spr_wr_ack       (spr_wr_ack),
	.spr_wr_target    (spr_wr_target),
	.spr_wr_addr      (spr_wr_addr),
	.spr_wr_data      (spr_wr_data),
	.spr_wr_strb         (spr_wr_strb),
	.spr_overflow_set    (spr_overflow_set)
);

endmodule

`default_nettype wire
