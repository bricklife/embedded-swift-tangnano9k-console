/*****************************************************************************\
|                      Copyright (C) 2021-2022 Luke Wren                      |
|                     SPDX-License-Identifier: Apache-2.0                     |
\*****************************************************************************/

// Example file integrating a Hazard3 processor, processor JTAG + debug
// components, some memory and a UART.

`default_nettype none

module tangnano9k_soc #(
	parameter DTM_TYPE     = "JTAG",  // Can be "JTAG", "ECP5" or "XILINX7"
	parameter SRAM_DEPTH   = 1 << 15, // Default 32 kwords -> 128 kB
	parameter CLK_MHZ      = 12,      // For timer timebase
	parameter PRELOAD_FILE = "",      // Optional hex file to preload SRAM
	// Sprite engine (limits are resource-driven)
	parameter NUM_SPRITES    = 4,
	parameter MAX_PER_LINE   = 3,

	`include "hazard3_config.vh"
) (
	// System clock + reset
	input wire               clk,
	input wire               rst_n,

	// JTAG port to RISC-V JTAG-DTM
	input  wire              tck,
	input  wire              trst_n,
	input  wire              tms,
	input  wire              tdi,
	output wire              tdo,

	// IO
	output wire              uart_tx,
	input  wire              uart_rx,
	output wire              pwm_out,
	input  wire [11:0]       gpio_i,
	output wire [31:0]       gpio_o,
	input  wire [9:0]        lcd_vcount,
	input  wire              lcd_frame_tick = 1'b0,
	output wire              lcd_enable,

	output wire              vram_wr_req,
	input  wire              vram_wr_ack,
	output wire [17:0]       vram_wr_addr,
	output wire [15:0]       vram_wr_data,
	output wire [1:0]        vram_wr_strb,

	// Sprite CDC → video domain (psram_clk)
	output wire              spr_enable,
	output wire              spr_wr_req,
	input  wire              spr_wr_ack,
	output wire [1:0]        spr_wr_target,
	output wire [10:0]       spr_wr_addr,
	output wire [31:0]       spr_wr_data,
	output wire [3:0]        spr_wr_strb,
	input  wire              spr_overflow_set
);

// ----------------------------------------------------------------------------
// Processor debug

wire              dmi_psel;
wire              dmi_penable;
wire              dmi_pwrite;
wire [8:0]        dmi_paddr;
wire [31:0]       dmi_pwdata;
wire [31:0]       dmi_prdata;
wire              dmi_pready;
wire              dmi_pslverr;


// TCK-domain DTM logic can force a hard reset
wire dmihardreset_req;
wire assert_dmi_reset = !rst_n || dmihardreset_req;
wire rst_n_dmi;

reset_sync dmi_reset_sync_u (
	.clk       (clk),
	.rst_n_in  (!assert_dmi_reset),
	.rst_n_out (rst_n_dmi)
);

generate
if (DTM_TYPE == "JTAG") begin

	// Standard RISC-V JTAG-DTM connected to external IOs.
	// JTAG-DTM IDCODE should be a JEP106-compliant ID:
	localparam IDCODE = 32'hdeadbeef;

	hazard3_jtag_dtm #(
		.IDCODE (IDCODE)
	) dtm_u (
		.tck              (tck),
		.trst_n           (trst_n),
		.tms              (tms),
		.tdi              (tdi),
		.tdo              (tdo),

		.dmihardreset_req (dmihardreset_req),

		.clk_dmi          (clk),
		.rst_n_dmi        (rst_n_dmi),

		.dmi_psel         (dmi_psel),
		.dmi_penable      (dmi_penable),
		.dmi_pwrite       (dmi_pwrite),
		.dmi_paddr        (dmi_paddr),
		.dmi_pwdata       (dmi_pwdata),
		.dmi_prdata       (dmi_prdata),
		.dmi_pready       (dmi_pready),
		.dmi_pslverr      (dmi_pslverr)
	);

end else if (DTM_TYPE == "ECP5") begin

	// Attach RISC-V DTM's DTMCS/DMI registers to ECP5 ER1/ER2 registers. This
	// allows the processor to be debugged through the ECP5 chip TAP, using
	// regular upstream OpenOCD.

	// Connects to ECP5 TAP internally by instantiating a JTAGG primitive.
	assign tdo = 1'b0;

	hazard3_ecp5_jtag_dtm dtm_u (
		.dmihardreset_req (dmihardreset_req),

		.clk_dmi          (clk),
		.rst_n_dmi        (rst_n_dmi),

		.dmi_psel         (dmi_psel),
		.dmi_penable      (dmi_penable),
		.dmi_pwrite       (dmi_pwrite),
		.dmi_paddr        (dmi_paddr),
		.dmi_pwdata       (dmi_pwdata),
		.dmi_prdata       (dmi_prdata),
		.dmi_pready       (dmi_pready),
		.dmi_pslverr      (dmi_pslverr)
	);

end else if (DTM_TYPE == "XILINX7") begin

	assign tdo = 1'b0;

	hazard3_xilinx7_jtag_dtm dtm_u (
		.dmihardreset_req (dmihardreset_req),

		.clk_dmi          (clk),
		.rst_n_dmi        (rst_n_dmi),

		.dmi_psel         (dmi_psel),
		.dmi_penable      (dmi_penable),
		.dmi_pwrite       (dmi_pwrite),
		.dmi_paddr        (dmi_paddr),
		.dmi_pwdata       (dmi_pwdata),
		.dmi_prdata       (dmi_prdata),
		.dmi_pready       (dmi_pready),
		.dmi_pslverr      (dmi_pslverr)
	);

end
endgenerate


localparam N_HARTS = 1;
localparam XLEN = 32;

wire                      sys_reset_req;
wire                      sys_reset_done;
wire [N_HARTS-1:0]        hart_reset_req;
wire [N_HARTS-1:0]        hart_reset_done;

wire [N_HARTS-1:0]        hart_req_halt;
wire [N_HARTS-1:0]        hart_req_halt_on_reset;
wire [N_HARTS-1:0]        hart_req_resume;
wire [N_HARTS-1:0]        hart_halted;
wire [N_HARTS-1:0]        hart_running;

wire [N_HARTS*XLEN-1:0]   hart_data0_rdata;
wire [N_HARTS*XLEN-1:0]   hart_data0_wdata;
wire [N_HARTS-1:0]        hart_data0_wen;

wire [N_HARTS*XLEN-1:0]   hart_instr_data;
wire [N_HARTS-1:0]        hart_instr_data_vld;
wire [N_HARTS-1:0]        hart_instr_data_rdy;
wire [N_HARTS-1:0]        hart_instr_caught_exception;
wire [N_HARTS-1:0]        hart_instr_caught_ebreak;

wire [31:0]               sbus_addr;
wire                      sbus_write;
wire [1:0]                sbus_size;
wire                      sbus_vld;
wire                      sbus_rdy;
wire                      sbus_err;
wire [31:0]               sbus_wdata;
wire [31:0]               sbus_rdata;

hazard3_dm #(
	.N_HARTS      (N_HARTS),
	.HAVE_SBA     (0),
	.NEXT_DM_ADDR (0)
) dm (
	.clk                         (clk),
	.rst_n                       (rst_n),

	.dmi_psel                    (dmi_psel),
	.dmi_penable                 (dmi_penable),
	.dmi_pwrite                  (dmi_pwrite),
	.dmi_paddr                   (dmi_paddr),
	.dmi_pwdata                  (dmi_pwdata),
	.dmi_prdata                  (dmi_prdata),
	.dmi_pready                  (dmi_pready),
	.dmi_pslverr                 (dmi_pslverr),

	.sys_reset_req               (sys_reset_req),
	.sys_reset_done              (sys_reset_done),
	.hart_reset_req              (hart_reset_req),
	.hart_reset_done             (hart_reset_done),

	.hart_req_halt               (hart_req_halt),
	.hart_req_halt_on_reset      (hart_req_halt_on_reset),
	.hart_req_resume             (hart_req_resume),
	.hart_halted                 (hart_halted),
	.hart_running                (hart_running),

	.hart_data0_rdata            (hart_data0_rdata),
	.hart_data0_wdata            (hart_data0_wdata),
	.hart_data0_wen              (hart_data0_wen),

	.hart_instr_data             (hart_instr_data),
	.hart_instr_data_vld         (hart_instr_data_vld),
	.hart_instr_data_rdy         (hart_instr_data_rdy),
	.hart_instr_caught_exception (hart_instr_caught_exception),
	.hart_instr_caught_ebreak    (hart_instr_caught_ebreak),

	.sbus_addr                   (sbus_addr),
	.sbus_write                  (sbus_write),
	.sbus_size                   (sbus_size),
	.sbus_vld                    (sbus_vld),
	.sbus_rdy                    (sbus_rdy),
	.sbus_err                    (sbus_err),
	.sbus_wdata                  (sbus_wdata),
	.sbus_rdata                  (sbus_rdata)
);


// Generate resynchronised reset for CPU based on upstream system reset and on
// system/hart reset requests from DM.

wire assert_cpu_reset = !rst_n || sys_reset_req || hart_reset_req[0];
wire rst_n_cpu;

reset_sync cpu_reset_sync (
	.clk       (clk),
	.rst_n_in  (!assert_cpu_reset),
	.rst_n_out (rst_n_cpu)
);

// Still some work to be done on the reset handshake -- this ought to be
// resynchronised to DM's reset domain here, and the DM should wait for a
// rising edge after it has asserted the reset pulse, to make sure the tail
// of the previous "done" is not passed on.
assign sys_reset_done = rst_n_cpu;
assign hart_reset_done = rst_n_cpu;

// ----------------------------------------------------------------------------
// Processor

wire [W_ADDR-1:0] proc_haddr;
wire              proc_hwrite;
wire [1:0]        proc_htrans;
wire [2:0]        proc_hsize;
wire [2:0]        proc_hburst;
wire [3:0]        proc_hprot;
wire              proc_hmastlock;
wire [7:0]        proc_hmaster;
wire              proc_hexcl;
wire              proc_hready;
wire              proc_hresp;
wire              proc_hexokay = 1'b1; // No global monitor
wire [W_DATA-1:0] proc_hwdata;
wire [W_DATA-1:0] proc_hrdata;

wire              pwrup_req;
wire              unblock_out;

wire              uart_irq;
wire              timer_irq;

hazard3_cpu_1port #(
	// These must have the values given here for you to end up with a useful SoC:
	.RESET_VECTOR    (32'h0000_0040),
	.MTVEC_INIT      (32'h0000_0000),
	.CSR_M_MANDATORY (1),
	.CSR_M_TRAP      (1),
	.DEBUG_SUPPORT   (1),
	.NUM_IRQS        (1),
	.RESET_REGFILE   (0),
	// Can be overridden from the defaults in hazard3_config.vh during
	// instantiation of tangnano9k_soc():
	.EXTENSION_A         (EXTENSION_A),
	.EXTENSION_C         (EXTENSION_C),
	.EXTENSION_E         (EXTENSION_E),
	.EXTENSION_M         (EXTENSION_M),
	.EXTENSION_ZBA       (EXTENSION_ZBA),
	.EXTENSION_ZBB       (EXTENSION_ZBB),
	.EXTENSION_ZBC       (EXTENSION_ZBC),
	.EXTENSION_ZBKB      (EXTENSION_ZBKB),
	.EXTENSION_ZBKX      (EXTENSION_ZBKX),
	.EXTENSION_ZBS       (EXTENSION_ZBS),
	.EXTENSION_ZCB       (EXTENSION_ZCB),
	.EXTENSION_ZCLSD     (EXTENSION_ZCLSD),
	.EXTENSION_ZCMP      (EXTENSION_ZCMP),
	.EXTENSION_ZIFENCEI  (EXTENSION_ZIFENCEI),
	.EXTENSION_ZILSD     (EXTENSION_ZILSD),
	.EXTENSION_XH3BEXTM  (EXTENSION_XH3BEXTM),
	.EXTENSION_XH3IRQ    (EXTENSION_XH3IRQ),
	.EXTENSION_XH3PMPM   (EXTENSION_XH3PMPM),
	.EXTENSION_XH3POWER  (EXTENSION_XH3POWER),
	.CSR_COUNTER         (CSR_COUNTER),
	.U_MODE              (U_MODE),
	.PMP_REGIONS         (PMP_REGIONS),
	.PMP_GRAIN           (PMP_GRAIN),
	.PMP_HARDWIRED       (PMP_HARDWIRED),
	.PMP_HARDWIRED_ADDR  (PMP_HARDWIRED_ADDR),
	.PMP_HARDWIRED_CFG   (PMP_HARDWIRED_CFG),
	.MVENDORID_VAL       (MVENDORID_VAL),
	.BREAKPOINT_TRIGGERS (BREAKPOINT_TRIGGERS),
	.IRQ_PRIORITY_BITS   (IRQ_PRIORITY_BITS),
	.REDUCED_BYPASS      (REDUCED_BYPASS),
	.MULDIV_UNROLL       (MULDIV_UNROLL),
	.MUL_FAST            (MUL_FAST),
	.MUL_FASTER          (MUL_FASTER),
	.MULH_FAST           (MULH_FAST),
	.FAST_BRANCHCMP      (FAST_BRANCHCMP),
	.BRANCH_PREDICTOR    (BRANCH_PREDICTOR),
	.MTVEC_WMASK         (MTVEC_WMASK)
) cpu (
	.clk                        (clk),
	.clk_always_on              (clk),
	.rst_n                      (rst_n_cpu),

	.pwrup_req                  (pwrup_req),
	.pwrup_ack                  (pwrup_req),   // Tied back
	.clk_en                     (/* unused */),
	.unblock_out                (unblock_out),
	.unblock_in                 (unblock_out), // Tied back

	.haddr                      (proc_haddr),
	.hwrite                     (proc_hwrite),
	.htrans                     (proc_htrans),
	.hsize                      (proc_hsize),
	.hburst                     (proc_hburst),
	.hprot                      (proc_hprot),
	.hmastlock                  (proc_hmastlock),
	.hmaster                    (proc_hmaster),
	.hexcl                      (proc_hexcl),
	.hready                     (proc_hready),
	.hresp                      (proc_hresp),
	.hexokay                    (proc_hexokay),
	.hwdata                     (proc_hwdata),
	.hrdata                     (proc_hrdata),

	.fence_i_vld                (/* unused */),
	.fence_d_vld                (/* unused */),
	.fence_rdy                  (1'b1),

	.dbg_req_halt               (hart_req_halt),
	.dbg_req_halt_on_reset      (hart_req_halt_on_reset),
	.dbg_req_resume             (hart_req_resume),
	.dbg_halted                 (hart_halted),
	.dbg_running                (hart_running),

	.dbg_data0_rdata            (hart_data0_rdata),
	.dbg_data0_wdata            (hart_data0_wdata),
	.dbg_data0_wen              (hart_data0_wen),

	.dbg_instr_data             (hart_instr_data),
	.dbg_instr_data_vld         (hart_instr_data_vld),
	.dbg_instr_data_rdy         (hart_instr_data_rdy),
	.dbg_instr_caught_exception (hart_instr_caught_exception),
	.dbg_instr_caught_ebreak    (hart_instr_caught_ebreak),

	.dbg_sbus_addr              (sbus_addr),
	.dbg_sbus_write             (sbus_write),
	.dbg_sbus_size              (sbus_size),
	.dbg_sbus_vld               (sbus_vld),
	.dbg_sbus_rdy               (sbus_rdy),
	.dbg_sbus_err               (sbus_err),
	.dbg_sbus_wdata             (sbus_wdata),
	.dbg_sbus_rdata             (sbus_rdata),

	.mhartid_val                (32'd0),
	.eco_version                (4'd0),

	.irq                        (uart_irq),

	.soft_irq                   (1'b0),
	.timer_irq                  (timer_irq)
);


// ----------------------------------------------------------------------------
// Bus fabric

// - SRAM at.......... 0x0000_0000
// - System timer at.. 0x4000_0000
// - LCD ctrl at...... 0x4000_1000
// - Sprite CTRL at... 0x4000_2000  (ENABLE/STAT/INFO)
// - PWM score at..... 0x4000_3000
// - UART at.......... 0x4000_4000
// - GPIO out at...... 0x4000_8000
// - GPIO in at....... 0x4000_c000
// - Sprite mem at.... 0x5000_0000  (PAL +0x0, TILE +0x1000, OAM +0x4000)
// - VRAM write window 0x6000_0000

// AHBL layer

wire               sram0_hready_resp;
wire               sram0_hready;
wire               sram0_hresp;
wire [W_ADDR-1:0]  sram0_haddr;
wire               sram0_hwrite;
wire [1:0]         sram0_htrans;
wire [2:0]         sram0_hsize;
wire [2:0]         sram0_hburst;
wire [3:0]         sram0_hprot;
wire               sram0_hmastlock;
wire [W_DATA-1:0]  sram0_hwdata;
wire [W_DATA-1:0]  sram0_hrdata;

wire               bridge_hready_resp;
wire               bridge_hready;
wire               bridge_hresp;
wire [W_ADDR-1:0]  bridge_haddr;
wire               bridge_hwrite;
wire [1:0]         bridge_htrans;
wire [2:0]         bridge_hsize;
wire [2:0]         bridge_hburst;
wire [3:0]         bridge_hprot;
wire               bridge_hmastlock;
wire [W_DATA-1:0]  bridge_hwdata;
wire [W_DATA-1:0]  bridge_hrdata;

wire               vram_hready_resp;
wire               vram_hready;
wire               vram_hresp;
wire [W_ADDR-1:0]  vram_haddr;
wire               vram_hwrite;
wire [1:0]         vram_htrans;
wire [2:0]         vram_hsize;
wire [2:0]         vram_hburst;
wire [3:0]         vram_hprot;
wire               vram_hmastlock;
wire [W_DATA-1:0]  vram_hwdata;
wire [W_DATA-1:0]  vram_hrdata;

wire               sprmem_hready_resp;
wire               sprmem_hready;
wire               sprmem_hresp;
wire [W_ADDR-1:0]  sprmem_haddr;
wire               sprmem_hwrite;
wire [1:0]         sprmem_htrans;
wire [2:0]         sprmem_hsize;
wire [2:0]         sprmem_hburst;
wire [3:0]         sprmem_hprot;
wire               sprmem_hmastlock;
wire [W_DATA-1:0]  sprmem_hwdata;
wire [W_DATA-1:0]  sprmem_hrdata;

// Port order MSB→LSB: VRAM, sprite-mem, APB bridge, SRAM
ahbl_splitter #(
	.N_PORTS     (4),
	.ADDR_MAP    (128'h60000000_50000000_40000000_00000000),
	.ADDR_MASK   (128'he0000000_f0000000_e0000000_e0000000)
) splitter_u (
	.clk             (clk),
	.rst_n           (rst_n),

	.src_hready_resp (proc_hready   ),
	.src_hready      (proc_hready   ),
	.src_hresp       (proc_hresp    ),
	.src_haddr       (proc_haddr    ),
	.src_hwrite      (proc_hwrite   ),
	.src_htrans      (proc_htrans   ),
	.src_hsize       (proc_hsize    ),
	.src_hburst      (proc_hburst   ),
	.src_hprot       (proc_hprot    ),
	.src_hmastlock   (proc_hmastlock),
	.src_hwdata      (proc_hwdata   ),
	.src_hrdata      (proc_hrdata   ),

	.dst_hready_resp ({vram_hready_resp , sprmem_hready_resp , bridge_hready_resp , sram0_hready_resp}),
	.dst_hready      ({vram_hready      , sprmem_hready      , bridge_hready      , sram0_hready     }),
	.dst_hresp       ({vram_hresp       , sprmem_hresp       , bridge_hresp       , sram0_hresp      }),
	.dst_haddr       ({vram_haddr       , sprmem_haddr       , bridge_haddr       , sram0_haddr      }),
	.dst_hwrite      ({vram_hwrite      , sprmem_hwrite      , bridge_hwrite      , sram0_hwrite     }),
	.dst_htrans      ({vram_htrans      , sprmem_htrans      , bridge_htrans      , sram0_htrans     }),
	.dst_hsize       ({vram_hsize       , sprmem_hsize       , bridge_hsize       , sram0_hsize      }),
	.dst_hburst      ({vram_hburst      , sprmem_hburst      , bridge_hburst      , sram0_hburst     }),
	.dst_hprot       ({vram_hprot       , sprmem_hprot       , bridge_hprot       , sram0_hprot      }),
	.dst_hmastlock   ({vram_hmastlock   , sprmem_hmastlock   , bridge_hmastlock   , sram0_hmastlock  }),
	.dst_hwdata      ({vram_hwdata      , sprmem_hwdata      , bridge_hwdata      , sram0_hwdata     }),
	.dst_hrdata      ({vram_hrdata      , sprmem_hrdata      , bridge_hrdata      , sram0_hrdata     })
);

// APB layer

wire        bridge_psel;
wire        bridge_penable;
wire        bridge_pwrite;
wire [15:0] bridge_paddr;
wire [31:0] bridge_pwdata;
wire [31:0] bridge_prdata;
wire        bridge_pready;
wire        bridge_pslverr;

wire        uart_psel;
wire        uart_penable;
wire        uart_pwrite;
wire [15:0] uart_paddr;
wire [31:0] uart_pwdata;
wire [31:0] uart_prdata;
wire        uart_pready;
wire        uart_pslverr;

wire        timer_psel;
wire        timer_penable;
wire        timer_pwrite;
wire [15:0] timer_paddr;
wire [31:0] timer_pwdata;
wire [31:0] timer_prdata;
wire        timer_pready;
wire        timer_pslverr;

wire        gpio_psel;
wire        gpio_penable;
wire        gpio_pwrite;
wire [15:0] gpio_paddr;
wire [31:0] gpio_pwdata;
wire [31:0] gpio_prdata;
wire        gpio_pready;
wire        gpio_pslverr;
wire        gpio_in_psel;
wire        gpio_in_penable;
wire        gpio_in_pwrite;
wire [15:0] gpio_in_paddr;
wire [31:0] gpio_in_pwdata;
wire [31:0] gpio_in_prdata;
wire        gpio_in_pready;
wire        gpio_in_pslverr;
wire        lcdctrl_psel;
wire        lcdctrl_penable;
wire        lcdctrl_pwrite;
wire [15:0] lcdctrl_paddr;
wire [31:0] lcdctrl_pwdata;
wire [31:0] lcdctrl_prdata;
wire        lcdctrl_pready;
wire        lcdctrl_pslverr;

wire        sprite_psel;
wire        sprite_penable;
wire        sprite_pwrite;
wire [15:0] sprite_paddr;
wire [31:0] sprite_pwdata;
wire [31:0] sprite_prdata;
wire        sprite_pready;
wire        sprite_pslverr;

wire        sound_psel;
wire        sound_penable;
wire        sound_pwrite;
wire [15:0] sound_paddr;
wire [31:0] sound_pwdata;
wire [31:0] sound_prdata;
wire        sound_pready;
wire        sound_pslverr;

ahbl_to_apb apb_bridge_u (
	.clk               (clk),
	.rst_n             (rst_n),

	.ahbls_hready      (bridge_hready),
	.ahbls_hready_resp (bridge_hready_resp),
	.ahbls_hresp       (bridge_hresp),
	.ahbls_haddr       (bridge_haddr),
	.ahbls_hwrite      (bridge_hwrite),
	.ahbls_htrans      (bridge_htrans),
	.ahbls_hsize       (bridge_hsize),
	.ahbls_hburst      (bridge_hburst),
	.ahbls_hprot       (bridge_hprot),
	.ahbls_hmastlock   (bridge_hmastlock),
	.ahbls_hwdata      (bridge_hwdata),
	.ahbls_hrdata      (bridge_hrdata),

	.apbm_paddr        (bridge_paddr),
	.apbm_psel         (bridge_psel),
	.apbm_penable      (bridge_penable),
	.apbm_pwrite       (bridge_pwrite),
	.apbm_pwdata       (bridge_pwdata),
	.apbm_pready       (bridge_pready),
	.apbm_prdata       (bridge_prdata),
	.apbm_pslverr      (bridge_pslverr)
);

// MSB→LSB: gpio_in, gpio_out, uart, sound, sprite, lcdctrl, timer
apb_splitter #(
	.N_SLAVES   (7),
	.ADDR_MAP   (112'hc000_8000_4000_3000_2000_1000_0000),
	.ADDR_MASK  (112'hf000_f000_f000_f000_f000_f000_f000)
) inst_apb_splitter (
	.apbs_paddr   (bridge_paddr),
	.apbs_psel    (bridge_psel),
	.apbs_penable (bridge_penable),
	.apbs_pwrite  (bridge_pwrite),
	.apbs_pwdata  (bridge_pwdata),
	.apbs_pready  (bridge_pready),
	.apbs_prdata  (bridge_prdata),
	.apbs_pslverr (bridge_pslverr),

	.apbm_paddr   ({gpio_in_paddr   , gpio_paddr   , uart_paddr   , sound_paddr   , sprite_paddr   , lcdctrl_paddr   , timer_paddr  }),
	.apbm_psel    ({gpio_in_psel    , gpio_psel    , uart_psel    , sound_psel    , sprite_psel    , lcdctrl_psel    , timer_psel   }),
	.apbm_penable ({gpio_in_penable , gpio_penable , uart_penable , sound_penable , sprite_penable , lcdctrl_penable , timer_penable}),
	.apbm_pwrite  ({gpio_in_pwrite  , gpio_pwrite  , uart_pwrite  , sound_pwrite  , sprite_pwrite  , lcdctrl_pwrite  , timer_pwrite }),
	.apbm_pwdata  ({gpio_in_pwdata  , gpio_pwdata  , uart_pwdata  , sound_pwdata  , sprite_pwdata  , lcdctrl_pwdata  , timer_pwdata }),
	.apbm_pready  ({gpio_in_pready  , gpio_pready  , uart_pready  , sound_pready  , sprite_pready  , lcdctrl_pready  , timer_pready }),
	.apbm_prdata  ({gpio_in_prdata  , gpio_prdata  , uart_prdata  , sound_prdata  , sprite_prdata  , lcdctrl_prdata  , timer_prdata }),
	.apbm_pslverr ({gpio_in_pslverr , gpio_pslverr , uart_pslverr , sound_pslverr , sprite_pslverr , lcdctrl_pslverr , timer_pslverr})
);

// ----------------------------------------------------------------------------
// Memory and peripherals

// No preloaded bootloader -- just use the debugger! (the processor will
// actually enter an infinite crash loop after reset if memory is
// zero-initialised so don't leave the little guy hanging too long)

ahb_sync_sram #(
	.DEPTH        (SRAM_DEPTH),
	.PRELOAD_FILE (PRELOAD_FILE)
) sram0 (
	.clk               (clk),
	.rst_n             (rst_n),

	.ahbls_hready_resp (sram0_hready_resp),
	.ahbls_hready      (sram0_hready),
	.ahbls_hresp       (sram0_hresp),
	.ahbls_haddr       (sram0_haddr),
	.ahbls_hwrite      (sram0_hwrite),
	.ahbls_htrans      (sram0_htrans),
	.ahbls_hsize       (sram0_hsize),
	.ahbls_hburst      (sram0_hburst),
	.ahbls_hprot       (sram0_hprot),
	.ahbls_hmastlock   (sram0_hmastlock),
	.ahbls_hwdata      (sram0_hwdata),
	.ahbls_hrdata      (sram0_hrdata)
);

ahb_vram_writer vram_writer_u (
	.clk               (clk),
	.rst_n             (rst_n),

	.ahbls_hready_resp (vram_hready_resp),
	.ahbls_hready      (vram_hready),
	.ahbls_hresp       (vram_hresp),
	.ahbls_haddr       (vram_haddr),
	.ahbls_hwrite      (vram_hwrite),
	.ahbls_htrans      (vram_htrans),
	.ahbls_hsize       (vram_hsize),
	.ahbls_hburst      (vram_hburst),
	.ahbls_hprot       (vram_hprot),
	.ahbls_hmastlock   (vram_hmastlock),
	.ahbls_hwdata      (vram_hwdata),
	.ahbls_hrdata      (vram_hrdata),

	.vram_wr_req       (vram_wr_req),
	.vram_wr_ack       (vram_wr_ack),
	.vram_wr_addr      (vram_wr_addr),
	.vram_wr_data      (vram_wr_data),
	.vram_wr_strb      (vram_wr_strb)
);

apb_gpio_out #(
	.W_GPIO (32)
) gpio_u (
	.clk          (clk),
	.rst_n        (rst_n),

	.apbs_psel    (gpio_psel),
	.apbs_penable (gpio_penable),
	.apbs_pwrite  (gpio_pwrite),
	.apbs_paddr   (gpio_paddr),
	.apbs_pwdata  (gpio_pwdata),
	.apbs_prdata  (gpio_prdata),
	.apbs_pready  (gpio_pready),
	.apbs_pslverr (gpio_pslverr),

	.gpio_o       (gpio_o)
);

apb_gpio_in #(
	.W_GPIO (12)
) gpio_in_u (
	.clk          (clk),
	.rst_n        (rst_n),

	.apbs_psel    (gpio_in_psel),
	.apbs_penable (gpio_in_penable),
	.apbs_pwrite  (gpio_in_pwrite),
	.apbs_paddr   (gpio_in_paddr),
	.apbs_pwdata  (gpio_in_pwdata),
	.apbs_prdata  (gpio_in_prdata),
	.apbs_pready  (gpio_in_pready),
	.apbs_pslverr (gpio_in_pslverr),

	.gpio_i       (gpio_i)
);

apb_lcd_ctrl lcd_ctrl_u (
	.clk          (clk),
	.rst_n        (rst_n),

	.apbs_psel    (lcdctrl_psel),
	.apbs_penable (lcdctrl_penable),
	.apbs_pwrite  (lcdctrl_pwrite),
	.apbs_paddr   (lcdctrl_paddr),
	.apbs_pwdata  (lcdctrl_pwdata),
	.apbs_prdata  (lcdctrl_prdata),
	.apbs_pready  (lcdctrl_pready),
	.apbs_pslverr (lcdctrl_pslverr),

	.lcd_vcount     (lcd_vcount),
	.lcd_frame_tick (lcd_frame_tick),
	.lcd_enable     (lcd_enable)
);

apb_pwm_score #(
	.CLK_MHZ (CLK_MHZ)
) sound_u (
	.clk          (clk),
	.rst_n        (rst_n),

	.apbs_psel    (sound_psel),
	.apbs_penable (sound_penable),
	.apbs_pwrite  (sound_pwrite),
	.apbs_paddr   (sound_paddr),
	.apbs_pwdata  (sound_pwdata),
	.apbs_prdata  (sound_prdata),
	.apbs_pready  (sound_pready),
	.apbs_pslverr (sound_pslverr),

	.pwm_out      (pwm_out)
);

apb_sprite_ctrl #(
	.NUM_SPRITES  (NUM_SPRITES),
	.MAX_PER_LINE (MAX_PER_LINE)
) sprite_ctrl_u (
	.clk              (clk),
	.rst_n            (rst_n),

	.apbs_psel        (sprite_psel),
	.apbs_penable     (sprite_penable),
	.apbs_pwrite      (sprite_pwrite),
	.apbs_paddr       (sprite_paddr),
	.apbs_pwdata      (sprite_pwdata),
	.apbs_prdata      (sprite_prdata),
	.apbs_pready      (sprite_pready),
	.apbs_pslverr     (sprite_pslverr),

	.spr_enable          (spr_enable),
	.spr_overflow_set    (spr_overflow_set)
);

ahb_sprite_mem #(
	.NUM_SPRITES     (NUM_SPRITES),
	.NUM_TILES       (64),
	.NUM_PAL_ENTRIES (256)
) sprite_mem_u (
	.clk               (clk),
	.rst_n             (rst_n),

	.ahbls_hready_resp  (sprmem_hready_resp),
	.ahbls_hready       (sprmem_hready),
	.ahbls_hresp        (sprmem_hresp),
	.ahbls_haddr        (sprmem_haddr),
	.ahbls_hwrite       (sprmem_hwrite),
	.ahbls_htrans       (sprmem_htrans),
	.ahbls_hsize        (sprmem_hsize),
	.ahbls_hburst       (sprmem_hburst),
	.ahbls_hprot        (sprmem_hprot),
	.ahbls_hmastlock    (sprmem_hmastlock),
	.ahbls_hwdata       (sprmem_hwdata),
	.ahbls_hrdata       (sprmem_hrdata),

	.spr_wr_req        (spr_wr_req),
	.spr_wr_ack        (spr_wr_ack),
	.spr_wr_target     (spr_wr_target),
	.spr_wr_addr       (spr_wr_addr),
	.spr_wr_data       (spr_wr_data),
	.spr_wr_strb       (spr_wr_strb)
);

uart_mini uart_u (
	.clk          (clk),
	.rst_n        (rst_n),

	.apbs_psel    (uart_psel),
	.apbs_penable (uart_penable),
	.apbs_pwrite  (uart_pwrite),
	.apbs_paddr   (uart_paddr),
	.apbs_pwdata  (uart_pwdata),
	.apbs_prdata  (uart_prdata),
	.apbs_pready  (uart_pready),
	.apbs_pslverr (uart_pslverr),

	.rx           (uart_rx),
	.tx           (uart_tx),
	.cts          (1'b0),
	.rts          (/* unused */),
	.irq          (uart_irq),
	.dreq         (/* unused */)
);

// Microsecond timebase for timer

reg [$clog2(CLK_MHZ)-1:0] timer_tick_ctr;
reg                       timer_tick;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		timer_tick_ctr <= {$clog2(CLK_MHZ){1'b0}};
		timer_tick <= 1'b0;
	end else begin
		if (|timer_tick_ctr) begin
			timer_tick_ctr <= timer_tick_ctr - 1'b1;
		end else begin
			timer_tick_ctr <= CLK_MHZ - 1;
		end
		timer_tick <= ~|timer_tick_ctr;
	end
end

hazard3_riscv_timer timer_u (
	.clk       (clk),
	.rst_n     (rst_n),

	.psel      (timer_psel),
	.penable   (timer_penable),
	.pwrite    (timer_pwrite),
	.paddr     (timer_paddr),
	.pwdata    (timer_pwdata),
	.prdata    (timer_prdata),
	.pready    (timer_pready),
	.pslverr   (timer_pslverr),

	.dbg_halt  (&hart_halted),

	.tick      (timer_tick),

	.timer_irq (timer_irq)
);

endmodule
