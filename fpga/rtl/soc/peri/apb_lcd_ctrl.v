`default_nettype none

// LCD APB @ 0x4000_1000
//   0x00 VCOUNT  R    [9:0]  video-side scan (visible starts at 0)
//   0x04 ENABLE  R/W  [0]  reset 0 (DE off until software fills VRAM)
//   0x08 FRAME   R    [15:0] increments on lcd_frame_tick (blank enter)
//
// lcd_frame_tick is a 1-cycle pulse on clk (clk_sys), already CDC'd
// from the video domain (toggle in lcd_psram_vram).
module apb_lcd_ctrl (
	input  wire        clk,
	input  wire        rst_n,

	input  wire        apbs_psel,
	input  wire        apbs_penable,
	input  wire        apbs_pwrite,
	input  wire [15:0] apbs_paddr,
	input  wire [31:0] apbs_pwdata,
	output reg  [31:0] apbs_prdata,
	output wire        apbs_pready,
	output wire        apbs_pslverr,

	input  wire [9:0]  lcd_vcount,
	input  wire        lcd_frame_tick,
	output reg         lcd_enable
);

assign apbs_pready  = 1'b1;
assign apbs_pslverr = 1'b0;

reg [15:0] frame_ctr;

always @(posedge clk or negedge rst_n) begin
	if (!rst_n)
		frame_ctr <= 16'd0;
	else if (lcd_frame_tick)
		frame_ctr <= frame_ctr + 16'd1;
end

always @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		// Off until software fills VRAM; otherwise boot shows raw PSRAM.
		lcd_enable  <= 1'b0;
		apbs_prdata <= 32'h0;
	end else if (apbs_psel && apbs_penable) begin
		if (apbs_pwrite) begin
			if (apbs_paddr[3:2] == 2'b01)
				lcd_enable <= apbs_pwdata[0];
		end else begin
			case (apbs_paddr[3:2])
				2'b00: apbs_prdata <= {22'd0, lcd_vcount};
				2'b01: apbs_prdata <= {31'd0, lcd_enable};
				2'b10: apbs_prdata <= {16'd0, frame_ctr};
				default: apbs_prdata <= 32'h0;
			endcase
		end
	end
end

endmodule
