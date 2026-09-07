`default_nettype none

// Slim APB sprite control: ENABLE / STAT / INFO.
// OAM, palette, and tiles are memory-mapped via ahb_sprite_mem @ 0x5000_0000.
//
// Reg map (byte offset from 0x4000_2000):
//   +0x00 CTRL   R/W  [0] enable
//   +0x04 STAT   R/W  [0] overflow (W1C)
//   +0x08 INFO   R
//
// prdata is combinatorial (same lesson as apb_gpio_out): registered-on-penable
// returned the previous transaction's data when pready=1 in the ACCESS cycle.

module apb_sprite_ctrl #(
	parameter NUM_SPRITES     = 4,
	parameter MAX_PER_LINE    = 3,
	parameter NUM_TILES       = 64,
	parameter NUM_PAL_ENTRIES = 256
) (
	input  wire        clk,
	input  wire        rst_n,

	input  wire        apbs_psel,
	input  wire        apbs_penable,
	input  wire        apbs_pwrite,
	input  wire [15:0] apbs_paddr,
	input  wire [31:0] apbs_pwdata,
	output wire [31:0] apbs_prdata,
	output wire        apbs_pready,
	output wire        apbs_pslverr,

	output wire        spr_enable,
	input  wire        spr_overflow_set
);

assign apbs_pready  = 1'b1;
assign apbs_pslverr = 1'b0;

localparam [1:0]
	REG_CTRL = 2'h0,
	REG_STAT = 2'h1,
	REG_INFO = 2'h2;

reg ctrl_enable;
reg stat_overflow;

assign spr_enable = ctrl_enable;

// INFO: [7:0] N, [15:8] MAX_PER_LINE, [23:16] NUM_TILES,
//       [27:24] BPP=4, [28] COMPOSE_SEQ, [31:29] log2(NUM_PAL_BANKS)=4 → 16
wire [31:0] info_rd = {
	3'd4,
	1'b1,
	4'd4,
	NUM_TILES[7:0],
	MAX_PER_LINE[7:0],
	NUM_SPRITES[7:0]
};

wire [1:0] reg_sel = apbs_paddr[3:2];

reg [31:0] prdata_mux;
always @(*) begin
	case (reg_sel)
		REG_CTRL: prdata_mux = {31'd0, ctrl_enable};
		REG_STAT: prdata_mux = {31'd0, stat_overflow};
		REG_INFO: prdata_mux = info_rd;
		default:  prdata_mux = 32'h0;
	endcase
end
assign apbs_prdata = prdata_mux;

always @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		ctrl_enable   <= 1'b0;
		stat_overflow <= 1'b0;
	end else begin
		if (spr_overflow_set)
			stat_overflow <= 1'b1;

		if (apbs_psel && apbs_penable && apbs_pwrite) begin
			case (reg_sel)
				REG_CTRL: ctrl_enable <= apbs_pwdata[0];
				REG_STAT: begin
					if (apbs_pwdata[0])
						stat_overflow <= 1'b0;
				end
				default: ;
			endcase
		end
	end
end

wire _unused = |{NUM_PAL_ENTRIES, apbs_penable};

endmodule

`default_nettype wire
