/*****************************************************************************\
|                        Copyright (C) 2021 Luke Wren                         |
|                     SPDX-License-Identifier: Apache-2.0                     |
\*****************************************************************************/

// Simple APB output-only GPIO register.
// A single 32-bit register is mapped at any word-aligned offset in the
// slave's address space; reads return the currently driven value.
//
// prdata is combinatorial so a same-cycle APB ACCESS (pready=1) samples the
// live gpio_o. The previous registered-on-penable path returned stale data,
// which broke software RMW (e.g. soft SD bit-bang SPI on gpio_o[11:8]).

`default_nettype none

module apb_gpio_out #(
	parameter W_GPIO = 32
) (
	input  wire              clk,
	input  wire              rst_n,

	input  wire              apbs_psel,
	input  wire              apbs_penable,
	input  wire              apbs_pwrite,
	input  wire [15:0]       apbs_paddr,
	input  wire [31:0]       apbs_pwdata,
	output wire [31:0]       apbs_prdata,
	output wire              apbs_pready,
	output wire              apbs_pslverr,

	output reg  [W_GPIO-1:0] gpio_o
);

assign apbs_pready  = 1'b1;
assign apbs_pslverr = 1'b0;
assign apbs_prdata  = {{(32 - W_GPIO){1'b0}}, gpio_o};

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n)
		gpio_o <= {W_GPIO{1'b0}};
	else if (apbs_psel && apbs_penable && apbs_pwrite)
		gpio_o <= apbs_pwdata[W_GPIO-1:0];
end

endmodule
