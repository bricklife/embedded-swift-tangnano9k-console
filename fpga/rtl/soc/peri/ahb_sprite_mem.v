`default_nettype none

// AHB-lite window for GBA-style sprite memory (plan B).
//
// Base 0x5000_0000 (fabric mask selects 0x5xxx_xxxx). Local offsets:
//   +0x0000  Palette   512 B   u16[256] RGB565 — 16 banks × 16 colors
//   +0x1000  Tile VRAM 2048 B  64 × 32 B (4bpp)
//   +0x4000  OAM       N×4 B   packed (see sprite_engine OAM layout)
//
// Palette accepts halfword AND word stores. Compilers often merge two
// consecutive u16 palette writes into one `sw`; rejecting word caused
// missing colours (2nd+ entries) and broken banks.

module ahb_sprite_mem #(
	parameter W_ADDR          = 32,
	parameter W_DATA          = 32,
	parameter NUM_SPRITES     = 4,
	parameter NUM_TILES       = 64,
	parameter NUM_PAL_ENTRIES = 256
) (
	input  wire               clk,
	input  wire               rst_n,

	output reg                ahbls_hready_resp,
	input  wire               ahbls_hready,
	output reg                ahbls_hresp,
	input  wire [W_ADDR-1:0]  ahbls_haddr,
	input  wire               ahbls_hwrite,
	input  wire [1:0]         ahbls_htrans,
	input  wire [2:0]         ahbls_hsize,
	input  wire [2:0]         ahbls_hburst,
	input  wire [3:0]         ahbls_hprot,
	input  wire               ahbls_hmastlock,
	input  wire [W_DATA-1:0]  ahbls_hwdata,
	output reg  [W_DATA-1:0]  ahbls_hrdata,

	output reg                spr_wr_req,
	input  wire               spr_wr_ack,
	output reg  [1:0]         spr_wr_target,
	output reg  [10:0]        spr_wr_addr,
	output reg  [31:0]        spr_wr_data,
	output reg  [3:0]         spr_wr_strb
);

localparam [1:0]
	TGT_OAM  = 2'b00,
	TGT_TILE = 2'b01,
	TGT_PAL  = 2'b10;

localparam [2:0]
	ST_IDLE   = 3'd0,
	ST_DATA   = 3'd1,
	ST_WAIT1  = 3'd2,
	ST_GAP    = 3'd3, // req low between dual pal writes
	ST_WAIT2  = 3'd4,
	ST_GAP2   = 3'd5, // second palette beat
	ST_TGAP   = 3'd6; // tile: multi-cycle req low (tgap_cnt)

localparam [15:0]
	OFF_PAL  = 16'h0000,
	OFF_TILE = 16'h1000,
	OFF_OAM  = 16'h4000;

localparam integer TILE_BYTES = NUM_TILES * 32;
localparam integer OAM_BYTES  = NUM_SPRITES * 4;
localparam integer PAL_BYTES  = NUM_PAL_ENTRIES * 2;

reg [2:0]  state;
reg        is_write;
reg [15:0] addr_lo;
reg [2:0]  size_s;
reg [1:0]  tgt_s;
reg [10:0] waddr_s;
reg [31:0] wdata_s;
reg [15:0] pal_hi_s;
reg        pal_dual; // word palette write needs 2 CDC ops
// After each tile ack: keep req=0 for several sys cycles (video 3FF + stable).
// 2 cycles was not enough under burst (paced we=36/40, four even/row0 lost).
reg [3:0]  tgap_cnt;

reg [31:0] shadow_oam [0:NUM_SPRITES-1];
reg [15:0] last_pal_data;
reg [7:0]  last_pal_idx;
reg [31:0] last_tile_data;

// spr_wr_ack is already a 1-cycle pulse in this clk (toggle edge after 3FF).
// Do not edge-detect again (that stretched one ack into two cycles).
wire spr_wr_ack_pulse = spr_wr_ack;

integer si;

wire ahb_aphase = ahbls_hready && ahbls_htrans[1];
wire [15:0] rel = ahbls_haddr[15:0];

wire in_pal  = (rel >= OFF_PAL)  && (rel < (OFF_PAL  + PAL_BYTES[15:0]));
wire in_tile = (rel >= OFF_TILE) && (rel < (OFF_TILE + TILE_BYTES[15:0]));
wire in_oam  = (rel >= OFF_OAM)  && (rel < (OFF_OAM  + OAM_BYTES[15:0]));
wire decode_ok = in_pal || in_tile || in_oam;

// Palette: halfword (even) or word (word-aligned). Tile/OAM: word preferred.
wire align_ok =
	in_pal  ? (ahbls_hsize[1] ? (rel[1:0] == 2'b00) :
	           ahbls_hsize[0] ? (rel[0] == 1'b0) : 1'b1) :
	in_tile ? (ahbls_hsize[1] ? (rel[1:0] == 2'b00) :
	           ahbls_hsize[0] ? (rel[0] == 1'b0) : 1'b1) :
	in_oam  ? (ahbls_hsize[1] && (rel[1:0] == 2'b00)) :
	1'b0;

wire [7:0] lat_oam_i = (addr_lo - OFF_OAM) >> 2;
wire [7:0] lat_pal_i = (addr_lo - OFF_PAL) >> 1;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		ahbls_hready_resp <= 1'b1;
		ahbls_hresp        <= 1'b0;
		ahbls_hrdata       <= 32'd0;
		spr_wr_req        <= 1'b0;
		spr_wr_target     <= 2'b00;
		spr_wr_addr       <= 11'd0;
		spr_wr_data       <= 32'd0;
		spr_wr_strb       <= 4'hF;
		state             <= ST_IDLE;
		is_write          <= 1'b0;
		addr_lo           <= 16'd0;
		size_s            <= 3'd0;
		tgt_s             <= 2'b00;
		waddr_s           <= 11'd0;
		wdata_s           <= 32'd0;
		pal_hi_s          <= 16'd0;
		pal_dual          <= 1'b0;
		tgap_cnt          <= 4'd0;
		last_tile_data    <= 32'd0;
		last_pal_data     <= 16'd0;
		last_pal_idx      <= 8'd0;
		for (si = 0; si < NUM_SPRITES; si = si + 1)
			shadow_oam[si] <= 32'd0;
	end else begin
		ahbls_hresp   <= 1'b0;

		case (state)
			ST_IDLE: begin
				ahbls_hready_resp <= 1'b1;
				spr_wr_req       <= 1'b0;
				if (ahb_aphase) begin
					addr_lo  <= rel;
					size_s   <= ahbls_hsize;
					is_write <= ahbls_hwrite;
					if (ahbls_hwrite && (!decode_ok || !align_ok)) begin
						ahbls_hresp <= 1'b1;
					end else if (decode_ok && align_ok) begin
						if (in_pal) begin
							tgt_s   <= TGT_PAL;
							waddr_s <= {3'd0, (rel - OFF_PAL) >> 1};
						end else if (in_tile) begin
							tgt_s   <= TGT_TILE;
							waddr_s <= ((rel - OFF_TILE) & 16'h7FFC);
						end else begin
							tgt_s   <= TGT_OAM;
							waddr_s <= {3'd0, (rel - OFF_OAM) >> 2};
						end
						ahbls_hready_resp <= 1'b0;
						state <= ST_DATA;
					end else if (!ahbls_hwrite) begin
						ahbls_hrdata <= 32'd0;
					end
				end
			end

			ST_DATA: begin
				ahbls_hready_resp <= 1'b0;
				if (is_write) begin
					spr_wr_target <= tgt_s;
					spr_wr_strb   <= 4'hF;
					spr_wr_addr   <= waddr_s;
					if (tgt_s == TGT_PAL) begin
						if (size_s[1]) begin
							// Word: lo half → entry waddr, hi half → waddr+1
							spr_wr_data <= {16'd0, ahbls_hwdata[15:0]};
							wdata_s     <= {16'd0, ahbls_hwdata[15:0]};
							pal_hi_s    <= ahbls_hwdata[31:16];
							pal_dual    <= 1'b1;
						end else begin
							spr_wr_data <= {16'd0, addr_lo[1] ? ahbls_hwdata[31:16]
							                                  : ahbls_hwdata[15:0]};
							wdata_s     <= {16'd0, addr_lo[1] ? ahbls_hwdata[31:16]
							                                  : ahbls_hwdata[15:0]};
							pal_dual    <= 1'b0;
						end
					end else begin
						spr_wr_data <= ahbls_hwdata;
						wdata_s     <= ahbls_hwdata;
						pal_dual    <= 1'b0;
					end
					spr_wr_req <= 1'b1;
					state <= ST_WAIT1;
				end else begin
					if (tgt_s == TGT_PAL) begin
						if (lat_pal_i == last_pal_idx)
							ahbls_hrdata <= addr_lo[1]
								? {last_pal_data, 16'd0}
								: {16'd0, last_pal_data};
						else
							ahbls_hrdata <= 32'd0;
					end else if (tgt_s == TGT_OAM) begin
						ahbls_hrdata <= (lat_oam_i < NUM_SPRITES)
							? shadow_oam[lat_oam_i] : 32'd0;
					end else
						ahbls_hrdata <= last_tile_data;
					ahbls_hready_resp <= 1'b1;
					state <= ST_IDLE;
				end
			end

			ST_WAIT1: begin
				ahbls_hready_resp <= 1'b0;
				if (spr_wr_ack_pulse) begin
					spr_wr_req <= 1'b0;
					if (tgt_s == TGT_OAM) begin
						if (waddr_s < NUM_SPRITES)
							shadow_oam[waddr_s[7:0]] <= wdata_s;
						ahbls_hready_resp <= 1'b1;
						state <= ST_IDLE;
					end else if (tgt_s == TGT_PAL) begin
						last_pal_data <= spr_wr_data[15:0];
						last_pal_idx  <= spr_wr_addr[7:0];
						if (pal_dual) begin
							// One cycle gap so video domain sees req falling edge
							state <= ST_GAP;
						end else begin
							ahbls_hready_resp <= 1'b1;
							state <= ST_IDLE;
						end
					end else begin
						// Tile: hold req=0 for several sys cycles (see tgap_cnt).
						// Long multi-µs stalls previously black-screened — keep
						// this short (8 sys ≈ 0.5 µs @ 15 MHz).
						last_tile_data    <= wdata_s;
						spr_wr_req        <= 1'b0;
						ahbls_hready_resp <= 1'b0;
						tgap_cnt          <= 4'd7; // 8 cycles in ST_TGAP total
						state             <= ST_TGAP;
					end
				end
			end

			// Hold req low for 2 cycles so the video-domain 3FF sync sees a
			// falling edge before the second palette beat (word → two entries).
			ST_GAP: begin
				ahbls_hready_resp <= 1'b0;
				spr_wr_req        <= 1'b0;
				state             <= ST_GAP2;
			end

			ST_GAP2: begin
				ahbls_hready_resp <= 1'b0;
				spr_wr_target     <= TGT_PAL;
				spr_wr_addr       <= waddr_s + 11'd1;
				spr_wr_data       <= {16'd0, pal_hi_s};
				spr_wr_strb       <= 4'hF;
				spr_wr_req        <= 1'b1;
				pal_dual          <= 1'b0;
				state             <= ST_WAIT2;
			end

			ST_WAIT2: begin
				ahbls_hready_resp <= 1'b0;
				if (spr_wr_ack_pulse) begin
					spr_wr_req       <= 1'b0;
					last_pal_data    <= pal_hi_s;
					last_pal_idx     <= waddr_s[7:0] + 8'd1;
					ahbls_hready_resp <= 1'b1;
					state            <= ST_IDLE;
				end
			end

			// Multi-cycle req low after each tile beat (hready held low = CPU stall).
			ST_TGAP: begin
				ahbls_hready_resp <= 1'b0;
				spr_wr_req        <= 1'b0;
				if (tgap_cnt != 4'd0)
					tgap_cnt <= tgap_cnt - 4'd1;
				else begin
					ahbls_hready_resp <= 1'b1;
					state             <= ST_IDLE;
				end
			end

			default: state <= ST_IDLE;
		endcase
	end
end

wire _unused = |{ahbls_hburst, ahbls_hprot, ahbls_hmastlock, size_s};

endmodule

`default_nettype wire
