/*****************************************************************************\
|                     SPDX-License-Identifier: Apache-2.0                     |
\*****************************************************************************/

// Simple APB input-only GPIO register.
// Reads return current gpio_i value in the low W_GPIO bits.

`default_nettype none

module apb_gpio_in #(
	parameter W_GPIO = 32
) (
	input  wire              clk,
	input  wire              rst_n,

	input  wire              apbs_psel,
	input  wire              apbs_penable,
	input  wire              apbs_pwrite,
	input  wire [15:0]       apbs_paddr,
	input  wire [31:0]       apbs_pwdata,
	output reg  [31:0]       apbs_prdata,
	output reg               apbs_pready,
	output reg               apbs_pslverr,

	input  wire [W_GPIO-1:0] gpio_i
);

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		apbs_prdata  <= 32'h0;
		apbs_pready  <= 1'b0;
		apbs_pslverr <= 1'b0;
	end else begin
		apbs_pready  <= apbs_psel && !apbs_penable;
		apbs_pslverr <= 1'b0;
		if (apbs_psel && !apbs_penable && !apbs_pwrite)
			apbs_prdata <= {{(32-W_GPIO){1'b0}}, gpio_i};
	end
end

endmodule

