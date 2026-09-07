`default_nettype none

// Scanline sprite engine (psram_clk / 72 MHz).
// 8x8 / 16x16 / 32x32 (size field) / 4bpp / index 0 transparent / lower OAM index wins.
//
// OAM word:
//   y[8:0] | x[9:0]<<9 | tile[5:0]<<19 | pal[3:0]<<25 | en<<29 | size[1:0]<<30
//   size: 00=8x8, 01=16x16, 10=32x32, 11 reserved (treated as 8x8)
// 16x16 uses tiles base..base+3 in 2x2 (row-major):
//   [base+0 | base+1]
//   [base+2 | base+3]
// 32x32 uses tiles base..base+15 in 4x4 (row-major):
//   [base+0  | base+1  | base+2  | base+3 ]
//   [base+4  | base+5  | base+6  | base+7 ]
//   [base+8  | base+9  | base+10 | base+11]
//   [base+12 | base+13 | base+14 | base+15]
//
// Timing architecture (STA at 72 MHz):
//  - prep_start/prep_y registered (break h_ctr combo into FSM).
//  - OAM scan is 2 cycles/sprite: LOAD (sample OAM) then EVAL (hit commit).
//  - On ST_READY entry, hit tables are latched into *display* registers.
//    Compose reads only those stable copies — scan writes never fan into
//    the pixel pipeline in the same timing path.
//  - Compose pipeline:
//      S0 beam latch, S1a/b/c hit, S2 priority, S3 pal BRAM, S4 out
//  LCD samples on pixel_tick (8 clks); pipeline latency << that.

module sprite_engine #(
	parameter NUM_SPRITES     = 4,
	parameter MAX_PER_LINE    = 3,
	parameter NUM_TILES       = 64,
	parameter NUM_PAL_ENTRIES = 256,
	parameter ENABLE_SPRITE   = 1
) (
	input  wire        clk,
	input  wire        rst_n,

	input  wire        spr_enable,
	input  wire        spr_wr_req,
	output reg         spr_wr_ack_toggle,
	input  wire [1:0]  spr_wr_target,
	input  wire [10:0] spr_wr_addr,
	input  wire [31:0] spr_wr_data,
	input  wire [3:0]  spr_wr_strb,

	output reg         overflow_pulse,

	input  wire        prep_start,
	input  wire [8:0]  prep_y,
	input  wire        pixel_tick,
	input  wire        active,
	input  wire [8:0]  active_x,
	input  wire [15:0] bg_px,
	output wire [15:0] out_px,
	output wire        out_opaque,
	output wire        strip_ready,
	output wire        spr_active
);

localparam [1:0]
	TGT_OAM  = 2'b00,
	TGT_TILE = 2'b01,
	TGT_PAL  = 2'b10,
	TGT_CMD  = 2'b11;

localparam integer W_SLOT  = (MAX_PER_LINE <= 1) ? 1 : $clog2(MAX_PER_LINE);
localparam integer W_OAM_I = (NUM_SPRITES <= 1) ? 1 : $clog2(NUM_SPRITES);

// -------------------------------------------------------------------------
// Storage
// -------------------------------------------------------------------------

// Video OAM: same-clock SDPB (psram_clk). Depth padded to 512 so Gowin
// uses BSRAM (16x32 falls into RAM16 / LUT). Enable lives in FFs so CMD
// clear-all is one cycle and does not need a BRAM RMW.
localparam OAM_WORDS = 512;
(* ram_style = "block", syn_ramstyle = "block_ram" *)
reg [31:0] oam [0:OAM_WORDS-1];
reg [NUM_SPRITES-1:0] oam_en;

reg        oam_we;
reg [8:0]  oam_waddr;
reg [31:0] oam_wdata;
reg [8:0]  oam_raddr;
reg [31:0] oam_rdata;

always @(posedge clk) begin
	if (oam_we)
		oam[oam_waddr] <= oam_wdata;
end

always @(posedge clk) begin
	oam_rdata <= oam[oam_raddr];
end

(* ram_style = "block" *)
reg [15:0] pal [0:NUM_PAL_ENTRIES-1];
reg [15:0] pal_q;

localparam TILE_WORDS = (NUM_TILES * 8);

// Single dual-port tile BRAM (separate write/read always = Gowin SDPB-friendly).
// Step3: discrete FF shadow (ts00..ts15) removed — fetch is BRAM-only; demo
// glyphs come from ENABLE_GLYPH_INIT preload (CPU writeTile still flaky alone).
(* ram_style = "block" *)
reg [31:0] tile_mem [0:TILE_WORDS-1];

reg        tile_we;
reg [8:0]  tile_waddr;
reg [31:0] tile_wdata;
reg [8:0]  tile_raddr;
reg [31:0] tile_rdata;

reg        pal_we;
reg [7:0]  pal_waddr;
reg [15:0] pal_wdata;

integer i;

always @(posedge clk) begin
	if (tile_we)
		tile_mem[tile_waddr] <= tile_wdata;
end

always @(posedge clk) begin
	tile_rdata <= tile_mem[tile_raddr];
end

// -------------------------------------------------------------------------
// Write path (CDC)
// -------------------------------------------------------------------------

reg [2:0] wr_req_sync;
wire wr_req_seen = wr_req_sync[2];
reg  wr_req_seen_d;

// 1 = HW preload demo palette. 0 = palette only from CPU writePalette.
localparam ENABLE_PAL_INIT = 0;
// 1 = HW preload tile0/4–7 into BRAM. 0 = tiles only from CPU writeTile.
localparam ENABLE_GLYPH_INIT = 0;

reg [3:0] init_pal_i;
reg [2:0] init_glyph;  // 0=tile0, 1..4 = tiles 4..7
reg [2:0] init_row;
reg       init_phase;  // 0=drive addr/data, 1=we pulse
reg       init_done;

// Tile/OAM/pal write CDC (level req + toggle ack). See sprite-tile-cdc-investigation.md.
//   WR_IDLE     : wait wr_req_stable (3FF + 2 cycles high), latch tgt/addr/data
//   WR_DISPATCH : use holds; tile → TILE_WE, OAM/CMD → OAM_WE (we/idx/clr),
//                 pal apply+ack → WAIT_LOW
//   WR_TILE_WE  : we + ack, then WAIT_LOW
//   WR_OAM_WE   : BRAM write + enable FF / enable-clear + ack, then WAIT_LOW
//   WR_WAIT_LOW : until !wr_req_seen, then IDLE
localparam [2:0]
	WR_IDLE     = 3'd0,
	WR_DISPATCH = 3'd1,
	WR_TILE_WE  = 3'd2,
	WR_OAM_WE   = 3'd3,
	WR_WAIT_LOW = 3'd4;

reg [2:0]  wr_st;
reg [1:0]  wr_tgt_h;
reg [10:0] wr_addr_h;
reg [31:0] wr_data_h;
reg        oam_we_r;
reg        oam_clr_r;
reg [W_OAM_I-1:0] oam_idx_r;

// Stable req: high for ≥2 video cycles after 3FF (multi-bit bus settle).
wire wr_req_stable = wr_req_seen && wr_req_seen_d;

// Demo glyph rows (match GameMain). Includes odd rows.
function automatic [31:0] init_row_data;
	input [2:0] glyph;
	input [2:0] row;
	reg [31:0] mid;
	begin
		case (glyph)
			3'd0: begin // cursor tile0
				case (row)
					3'd0: init_row_data = 32'h2201_0330;
					3'd1: init_row_data = 32'h2211_1330;
					3'd2: init_row_data = 32'h0111_1100;
					3'd3: init_row_data = 32'h1111_1110;
					3'd4: init_row_data = 32'h0111_1100;
					3'd5: init_row_data = 32'h4411_1550;
					3'd6: init_row_data = 32'h4401_0550;
					default: init_row_data = 32'h0000_0000;
				endcase
			end
			default: begin // tiles 4..7 quarters
				case (glyph)
					3'd1: mid = 32'h1222_2221; // green
					3'd2: mid = 32'h1333_3331; // blue
					3'd3: mid = 32'h1555_5551; // red
					default: mid = 32'h1444_4441; // yellow
				endcase
				// row 0 and 7 = black edge; 1..6 = colour mid (odd rows included)
				init_row_data = (row == 3'd0 || row == 3'd7) ? 32'h1111_1111 : mid;
			end
		endcase
	end
endfunction

function automatic [5:0] init_tile_index;
	input [2:0] glyph;
	begin
		case (glyph)
			3'd0: init_tile_index = 6'd0;
			3'd1: init_tile_index = 6'd4;
			3'd2: init_tile_index = 6'd5;
			3'd3: init_tile_index = 6'd6;
			default: init_tile_index = 6'd7;
		endcase
	end
endfunction

always @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		wr_req_sync       <= 3'b000;
		wr_req_seen_d     <= 1'b0;
		spr_wr_ack_toggle <= 1'b0;
		tile_we           <= 1'b0;
		tile_waddr        <= 9'd0;
		tile_wdata        <= 32'd0;
		wr_st             <= WR_IDLE;
		wr_tgt_h          <= 2'b00;
		wr_addr_h         <= 11'd0;
		wr_data_h         <= 32'd0;
		oam_we_r          <= 1'b0;
		oam_clr_r         <= 1'b0;
		oam_idx_r         <= {W_OAM_I{1'b0}};
		oam_we            <= 1'b0;
		oam_waddr         <= 9'd0;
		oam_wdata         <= 32'd0;
		oam_en            <= {NUM_SPRITES{1'b0}};
		pal_we            <= 1'b0;
		pal_waddr         <= 8'd0;
		pal_wdata         <= 16'd0;
		init_pal_i        <= 4'd0;
		init_glyph        <= 3'd0;
		init_row          <= 3'd0;
		init_phase        <= 1'b0;
		init_done         <= 1'b0;
	end else begin
		wr_req_sync   <= {wr_req_sync[1:0], spr_wr_req};
		wr_req_seen_d <= wr_req_seen;
		tile_we       <= 1'b0;
		oam_we        <= 1'b0;
		pal_we        <= 1'b0;

		// --- optional HW glyph / palette init (before accepting CPU CDC) ---
		if (!init_done) begin
			if (ENABLE_PAL_INIT != 0 && init_pal_i <= 4'd8) begin
				pal_we <= 1'b1;
				case (init_pal_i)
					4'd0: begin pal_waddr <= 8'd0;  pal_wdata <= 16'h0000; end
					4'd1: begin pal_waddr <= 8'd1;  pal_wdata <= 16'h0000; end
					4'd2: begin pal_waddr <= 8'd2;  pal_wdata <= 16'h07e0; end
					4'd3: begin pal_waddr <= 8'd3;  pal_wdata <= 16'h001f; end
					4'd4: begin pal_waddr <= 8'd4;  pal_wdata <= 16'hffe0; end
					4'd5: begin pal_waddr <= 8'd5;  pal_wdata <= 16'hf800; end
					4'd6: begin pal_waddr <= 8'd17; pal_wdata <= 16'hf800; end
					4'd7: begin pal_waddr <= 8'd33; pal_wdata <= 16'h07e0; end
					default: begin pal_waddr <= 8'd49; pal_wdata <= 16'h001f; end
				endcase
				if (init_pal_i == 4'd8) begin
					if (ENABLE_GLYPH_INIT == 0)
						init_done <= 1'b1;
					init_pal_i <= init_pal_i + 4'd1;
				end else
					init_pal_i <= init_pal_i + 4'd1;
			end else if (ENABLE_GLYPH_INIT != 0) begin
				if (!init_phase) begin
					tile_waddr <= {init_tile_index(init_glyph), init_row};
					tile_wdata <= init_row_data(init_glyph, init_row);
					init_phase <= 1'b1;
				end else begin
					tile_we    <= 1'b1;
					init_phase <= 1'b0;
					if (init_row == 3'd7) begin
						init_row <= 3'd0;
						if (init_glyph == 3'd4)
							init_done <= 1'b1;
						else
							init_glyph <= init_glyph + 3'd1;
					end else
						init_row <= init_row + 3'd1;
				end
			end else
				init_done <= 1'b1;
		end else begin
			// --- CPU write CDC state machine ---
			case (wr_st)
				WR_IDLE: begin
					// Require req high for 2 video cycles after 3FF so
					// target/addr/data from sys are stable when latched.
					if (wr_req_stable) begin
						wr_tgt_h  <= spr_wr_target;
						wr_addr_h <= spr_wr_addr;
						wr_data_h <= spr_wr_data;
						wr_st     <= WR_DISPATCH;
					end
				end

				WR_DISPATCH: begin
					// Use *held* target/addr/data (stable for ≥1 cycle)
					if (wr_tgt_h == TGT_TILE) begin
						tile_waddr <= wr_addr_h[10:2];
						tile_wdata <= wr_data_h;
						wr_st <= WR_TILE_WE;
					end else if (wr_tgt_h == TGT_OAM || wr_tgt_h == TGT_CMD) begin
						oam_we_r  <= (wr_tgt_h == TGT_OAM)
							&& (wr_addr_h < NUM_SPRITES);
						oam_clr_r <= (wr_tgt_h == TGT_CMD) && wr_data_h[0];
						oam_idx_r <= wr_addr_h[W_OAM_I-1:0];
						wr_st     <= WR_OAM_WE;
					end else begin
						if (wr_tgt_h == TGT_PAL
							&& wr_addr_h < NUM_PAL_ENTRIES) begin
							pal_we    <= 1'b1;
							pal_waddr <= wr_addr_h[7:0];
							pal_wdata <= wr_data_h[15:0];
						end
						spr_wr_ack_toggle <= ~spr_wr_ack_toggle;
						wr_st <= WR_WAIT_LOW;
					end
				end

				WR_TILE_WE: begin
					tile_we           <= 1'b1;
					tile_waddr        <= wr_addr_h[10:2];
					tile_wdata        <= wr_data_h;
					spr_wr_ack_toggle <= ~spr_wr_ack_toggle;
					wr_st             <= WR_WAIT_LOW;
				end

				WR_OAM_WE: begin
					if (oam_clr_r) begin
						oam_en <= {NUM_SPRITES{1'b0}};
					end else if (oam_we_r) begin
						oam_we    <= 1'b1;
						oam_waddr <= {5'd0, oam_idx_r};
						oam_wdata <= wr_data_h;
						oam_en[oam_idx_r] <= wr_data_h[29];
					end
					oam_we_r          <= 1'b0;
					oam_clr_r         <= 1'b0;
					spr_wr_ack_toggle <= ~spr_wr_ack_toggle;
					wr_st             <= WR_WAIT_LOW;
				end

				WR_WAIT_LOW: begin
					if (!wr_req_seen)
						wr_st <= WR_IDLE;
				end

				default: wr_st <= WR_IDLE;
			endcase
		end
	end
end

// -------------------------------------------------------------------------
// Prep FSM
// -------------------------------------------------------------------------

localparam [2:0]
	ST_IDLE    = 3'd0,
	ST_LOAD    = 3'd1, // issue OAM raddr, then sample oam_rdata
	ST_HIT     = 3'd2, // register dy / line_hit (break scan_y → hit_* path)
	ST_EVAL    = 3'd3, // commit hit tables from registered hit flags
	ST_FETCH   = 3'd4,
	ST_PUBLISH = 3'd5, // copy hit_* → d_* (isolates compose timing)
	ST_READY   = 3'd6;

reg        prep_start_r;
reg [8:0]  prep_y_r;

reg [2:0] st;
reg [8:0] scan_y;
reg [7:0] scan_i;
reg [4:0] hit_count;
reg [4:0] fetch_i;
reg [2:0] fetch_wait;
reg [4:0] fetch_hits; // latched hit_count at ST_FETCH entry (cuts 72 MHz CE)
reg [8:0] fetch_addr; // address presented to tile port for current sample
reg [5:0] fetch_tile_r;
reg [1:0] fetch_map_r;
reg [1:0] fetch_sz_r;
reg [2:0] fetch_row_r;
reg [1:0] fetch_part_r;
reg       ready_r;
reg       ovf_r;
reg [1:0] oam_rd_wait;

// Working hit tables (written during scan/fetch)
reg               hit_en      [0:MAX_PER_LINE-1];
reg signed [10:0] hit_sx      [0:MAX_PER_LINE-1];
reg [5:0]         hit_tile    [0:MAX_PER_LINE-1]; // base tile
reg [3:0]         hit_pal     [0:MAX_PER_LINE-1];
reg [2:0]         hit_row     [0:MAX_PER_LINE-1]; // row within 8x8 cell
reg [1:0]         hit_map_row [0:MAX_PER_LINE-1]; // which 8px tile-row (16/32)
reg [1:0]         hit_size    [0:MAX_PER_LINE-1]; // 00=8, 01=16, 10=32
reg [31:0]        hit_strip   [0:MAX_PER_LINE-1]; // col 0
reg [31:0]        hit_strip_r [0:MAX_PER_LINE-1]; // col 1
reg [31:0]        hit_strip_2 [0:MAX_PER_LINE-1]; // col 2 (32x32)
reg [31:0]        hit_strip_3 [0:MAX_PER_LINE-1]; // col 3 (32x32)

// Display copies (latched when line is ready — compose uses only these)
reg               d_en      [0:MAX_PER_LINE-1];
reg signed [10:0] d_sx      [0:MAX_PER_LINE-1];
reg [3:0]         d_pal     [0:MAX_PER_LINE-1];
reg [1:0]         d_size    [0:MAX_PER_LINE-1];
reg [31:0]        d_strip   [0:MAX_PER_LINE-1];
reg [31:0]        d_strip_r [0:MAX_PER_LINE-1];
reg [31:0]        d_strip_2 [0:MAX_PER_LINE-1];
reg [31:0]        d_strip_3 [0:MAX_PER_LINE-1];

// Registered OAM sample
reg        oam_en_r;
reg [8:0]  oam_y_r;
reg signed [10:0] oam_sx_r;
reg [5:0]  oam_tile_r;
reg [3:0]  oam_pal_r;
reg [1:0]  oam_size_r;

// Fetch: column within the current 8px tile-row (0=left … 3=right for 32x32)
reg [1:0]  fetch_part;

assign strip_ready = ready_r;
assign spr_active  = (ENABLE_SPRITE != 0) && spr_enable && ready_r;

wire [7:0]  scan_i_clamped = (scan_i < NUM_SPRITES[7:0]) ? scan_i : 8'd0;
wire [W_OAM_I-1:0] scan_i_oam = scan_i_clamped[W_OAM_I-1:0];

// Combo helpers (sampled into hit_*_r in ST_HIT — not used for FF D-input
// in the same cycle as scan_y changes on a long path).
wire [8:0] dy_u = scan_y - oam_y_r;
wire       oam_is16 = (oam_size_r == 2'b01);
wire       oam_is32 = (oam_size_r == 2'b10);
wire [8:0] spr_h = oam_is32 ? 9'd32 : (oam_is16 ? 9'd16 : 9'd8);
wire       line_hit_c = oam_en_r && (dy_u < spr_h);

// Registered hit evaluation (filled in ST_HIT)
reg        line_hit_r;
reg [2:0]  row_c_r;
reg [1:0]  map_row_c_r;
reg [1:0]  oam_size_hit_r;
reg signed [10:0] oam_sx_hit_r;
reg [5:0]  oam_tile_hit_r;
reg [3:0]  oam_pal_hit_r;

wire [4:0] fetch_i_clamped =
	(fetch_i < MAX_PER_LINE[4:0]) ? fetch_i : 5'd0;

// Tile index from registered fetch fields (not fetch_i combo — STA at 72 MHz):
//   8x8:  base
//   16x16: base + map_row*2 + part
//   32x32: base + map_row*4 + part
wire [5:0] fetch_tile_off =
	(fetch_sz_r == 2'b10) ? ({2'b0, fetch_map_r, 2'b00} + {4'b0, fetch_part_r}) :
	(fetch_sz_r == 2'b01) ? ({4'b0, fetch_map_r[0], 1'b0} + {5'b0, fetch_part_r[0]}) :
	6'd0;
wire [5:0] fetch_tile_num = fetch_tile_r + fetch_tile_off;
wire [8:0] fetch_word_addr = {fetch_tile_num, fetch_row_r};
wire [1:0] fetch_last_part =
	(hit_size[fetch_i_clamped] == 2'b10) ? 2'd3 :
	(hit_size[fetch_i_clamped] == 2'b01) ? 2'd1 : 2'd0;

always @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		prep_start_r   <= 1'b0;
		prep_y_r       <= 9'd0;
		st             <= ST_IDLE;
		scan_y         <= 9'd0;
		scan_i         <= 8'd0;
		hit_count      <= 5'd0;
		fetch_i        <= 5'd0;
		fetch_wait     <= 3'd0;
		fetch_hits     <= 5'd0;
		fetch_addr     <= 9'd0;
		fetch_tile_r   <= 6'd0;
		fetch_map_r    <= 2'd0;
		fetch_sz_r     <= 2'd0;
		fetch_row_r    <= 3'd0;
		fetch_part_r   <= 2'd0;
		fetch_part     <= 2'd0;
		ready_r        <= 1'b0;
		ovf_r          <= 1'b0;
		overflow_pulse <= 1'b0;
		tile_raddr     <= 9'd511;
		oam_raddr      <= 9'd0;
		oam_rd_wait    <= 2'd0;
		oam_en_r       <= 1'b0;
		oam_y_r        <= 9'd0;
		oam_sx_r       <= 11'sd0;
		oam_tile_r     <= 6'd0;
		oam_pal_r      <= 4'd0;
		oam_size_r     <= 2'd0;
		line_hit_r     <= 1'b0;
		row_c_r        <= 3'd0;
		map_row_c_r    <= 2'd0;
		oam_size_hit_r <= 2'd0;
		oam_sx_hit_r   <= 11'sd0;
		oam_tile_hit_r <= 6'd0;
		oam_pal_hit_r  <= 4'd0;
		for (i = 0; i < MAX_PER_LINE; i = i + 1) begin
			hit_en[i]      <= 1'b0;
			hit_sx[i]      <= 11'sd0;
			hit_tile[i]    <= 6'd0;
			hit_pal[i]     <= 4'd0;
			hit_row[i]     <= 3'd0;
			hit_map_row[i] <= 2'd0;
			hit_size[i]    <= 2'd0;
			hit_strip[i]   <= 32'd0;
			hit_strip_r[i] <= 32'd0;
			hit_strip_2[i] <= 32'd0;
			hit_strip_3[i] <= 32'd0;
			d_en[i]        <= 1'b0;
			d_sx[i]        <= 11'sd0;
			d_pal[i]       <= 4'd0;
			d_size[i]      <= 2'd0;
			d_strip[i]     <= 32'd0;
			d_strip_r[i]   <= 32'd0;
			d_strip_2[i]   <= 32'd0;
			d_strip_3[i]   <= 32'd0;
		end
	end else begin
		overflow_pulse <= 1'b0;
		prep_start_r   <= prep_start;
		prep_y_r       <= prep_y;

		if (ENABLE_SPRITE == 0) begin
			ready_r <= 1'b0;
			st <= ST_IDLE;
		end else if (prep_start_r) begin
			// Do NOT clear ready_r / d_*: keep last published strips until
			// ST_PUBLISH swaps them (avoids blanking / flicker in H-BP).
			scan_y     <= prep_y_r;
			scan_i     <= 8'd0;
			hit_count  <= 5'd0;
			fetch_i    <= 5'd0;
			fetch_wait <= 3'd0;
			fetch_addr <= 9'd0;
			fetch_part  <= 2'd0;
			ovf_r       <= 1'b0;
			oam_rd_wait <= 2'd0;
			oam_raddr   <= 9'd0;
			for (i = 0; i < MAX_PER_LINE; i = i + 1) begin
				hit_en[i]      <= 1'b0;
				hit_strip[i]   <= 32'd0;
				hit_strip_r[i] <= 32'd0;
				hit_strip_2[i] <= 32'd0;
				hit_strip_3[i] <= 32'd0;
			end
			st <= ST_LOAD;
		end else case (st)
			ST_IDLE: ;

			// Issue OAM BRAM address, wait one cycle, then sample.
			// Same 2-cycle latency as tile_mem (raddr → rdata registered).
			// Sampling the cycle after raddr reused the previous sprite's
			// x/y/tile (right paddle sat on the left; hoop rings stacked).
			ST_LOAD: begin
				if (oam_rd_wait == 2'd0) begin
					oam_raddr   <= {5'd0, scan_i_oam};
					oam_rd_wait <= 2'd1;
				end else if (oam_rd_wait == 2'd1) begin
					oam_rd_wait <= 2'd2;
				end else begin
					oam_en_r    <= oam_en[scan_i_oam];
					oam_y_r     <= oam_rdata[8:0];
					oam_sx_r    <= {oam_rdata[18], oam_rdata[18:9]};
					oam_tile_r  <= oam_rdata[24:19];
					oam_pal_r   <= oam_rdata[28:25];
					oam_size_r  <= oam_rdata[31:30];
					oam_rd_wait <= 2'd0;
					st          <= ST_HIT;
				end
			end

			// Register line-hit geometry (Fmax: was combo scan_y→hit_strip)
			ST_HIT: begin
				line_hit_r     <= line_hit_c;
				row_c_r        <= dy_u[2:0];
				map_row_c_r    <= dy_u[4:3];
				oam_size_hit_r <= oam_size_r;
				oam_sx_hit_r   <= oam_sx_r;
				oam_tile_hit_r <= oam_tile_r;
				oam_pal_hit_r  <= oam_pal_r;
				st <= ST_EVAL;
			end

			// Commit hit tables from registered flags only
			ST_EVAL: begin
				if (line_hit_r) begin
					if (hit_count < MAX_PER_LINE[4:0]) begin
						hit_en[hit_count]      <= 1'b1;
						hit_sx[hit_count]      <= oam_sx_hit_r;
						hit_tile[hit_count]    <= oam_tile_hit_r;
						hit_pal[hit_count]     <= oam_pal_hit_r;
						hit_row[hit_count]     <= row_c_r;
						hit_map_row[hit_count] <= map_row_c_r;
						hit_size[hit_count]    <= oam_size_hit_r;
						hit_strip[hit_count]   <= 32'd0;
						hit_strip_r[hit_count] <= 32'd0;
						hit_strip_2[hit_count] <= 32'd0;
						hit_strip_3[hit_count] <= 32'd0;
						hit_count              <= hit_count + 5'd1;
					end else if (!ovf_r) begin
						ovf_r <= 1'b1;
						overflow_pulse <= 1'b1;
					end
				end
				if (scan_i + 8'd1 >= NUM_SPRITES[7:0]) begin
					fetch_i    <= 5'd0;
					fetch_part <= 2'd0;
					fetch_wait <= 3'd0;
					// Same-cycle hit_count increment must be visible here.
					fetch_hits <= (line_hit_r && (hit_count < MAX_PER_LINE[4:0]))
						? (hit_count + 5'd1) : hit_count;
					st <= ST_FETCH;
				end else begin
					scan_i <= scan_i + 8'd1;
					st <= ST_LOAD;
				end
			end

			// Fetch one BRAM word. Split so fetch_i mux and tile add
			// are not one 72 MHz path:
			//   0=latch fields, 1=add addr, 2=issue raddr, 3=bram, 4=sample
			ST_FETCH: begin
				if (fetch_hits == 5'd0) begin
					st <= ST_PUBLISH;
				end else if (fetch_wait == 3'd0) begin
					fetch_tile_r <= hit_tile[fetch_i_clamped];
					fetch_map_r  <= hit_map_row[fetch_i_clamped];
					fetch_sz_r   <= hit_size[fetch_i_clamped];
					fetch_row_r  <= hit_row[fetch_i_clamped];
					fetch_part_r <= fetch_part;
					fetch_wait   <= 3'd1;
				end else if (fetch_wait == 3'd1) begin
					fetch_addr <= fetch_word_addr;
					fetch_wait <= 3'd2;
				end else if (fetch_wait == 3'd2) begin
					tile_raddr <= fetch_addr;
					fetch_wait <= 3'd3;
				end else if (fetch_wait == 3'd3) begin
					fetch_wait <= 3'd4;
				end else begin
					// fetch_wait == 4: sample BRAM (1-cycle latency).
					// Zero is a valid fully-transparent row — do not replace it.
					case (fetch_part)
						2'd0: hit_strip[fetch_i_clamped]   <= tile_rdata;
						2'd1: hit_strip_r[fetch_i_clamped] <= tile_rdata;
						2'd2: hit_strip_2[fetch_i_clamped] <= tile_rdata;
						default: hit_strip_3[fetch_i_clamped] <= tile_rdata;
					endcase

					if (fetch_part != fetch_last_part) begin
						fetch_part <= fetch_part + 2'd1;
						fetch_wait <= 3'd0;
					end else if (fetch_i + 5'd1 >= fetch_hits) begin
						// Park read port away from low addresses so CPU tile
						// writes to tile0/1 never collide with a live read.
						tile_raddr <= 9'd511;
						st <= ST_PUBLISH;
					end else begin
						fetch_i    <= fetch_i + 5'd1;
						fetch_part <= 2'd0;
						fetch_wait <= 3'd0;
					end
				end
			end


			ST_PUBLISH: begin
				for (i = 0; i < MAX_PER_LINE; i = i + 1) begin
					if (hit_count > i[4:0]) begin
						d_en[i]      <= hit_en[i];
						d_sx[i]      <= hit_sx[i];
						d_pal[i]     <= hit_pal[i];
						d_size[i]    <= hit_size[i];
						d_strip[i]   <= hit_strip[i];
						d_strip_r[i] <= hit_strip_r[i];
						d_strip_2[i] <= hit_strip_2[i];
						d_strip_3[i] <= hit_strip_3[i];
					end else begin
						d_en[i]      <= 1'b0;
						d_sx[i]      <= 11'sd0;
						d_pal[i]     <= 4'd0;
						d_size[i]    <= 2'd0;
						d_strip[i]   <= 32'd0;
						d_strip_r[i] <= 32'd0;
						d_strip_2[i] <= 32'd0;
						d_strip_3[i] <= 32'd0;
					end
				end
				ready_r <= 1'b1;
				st <= ST_READY;
			end

			ST_READY: ;

			default: st <= ST_IDLE;
		endcase
	end
end

// -------------------------------------------------------------------------
// Compose pipeline — reads only d_* display registers
// -------------------------------------------------------------------------

function automatic [3:0] nibble_of;
	input [31:0] strip;
	input [2:0]  lx;
	begin
		case (lx)
			3'd0: nibble_of = strip[3:0];
			3'd1: nibble_of = strip[7:4];
			3'd2: nibble_of = strip[11:8];
			3'd3: nibble_of = strip[15:12];
			3'd4: nibble_of = strip[19:16];
			3'd5: nibble_of = strip[23:20];
			3'd6: nibble_of = strip[27:24];
			default: nibble_of = strip[31:28];
		endcase
	end
endfunction

// -------------------------------------------------------------------------
// Compose pipeline (Fmax: wide ax>=sx && ax<=x_last was ~22 ns / -1.6 ns slack).
// Break range test: S1a = subtract only; S1b = bit-slice vis + strip mux.
// Latency +1 vs old path → beam X bias +2 (was +1).
// -------------------------------------------------------------------------

// S0
reg               active_s0, spr_act_s0;
reg signed [10:0] ax_s0;
always @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		active_s0  <= 1'b0;
		spr_act_s0 <= 1'b0;
		ax_s0      <= 11'sd0;
	end else begin
		active_s0  <= active;
		spr_act_s0 <= spr_active;
		// Beam bias: +2 after S4 (was +1 when out was combo of S3).
		ax_s0      <= {2'b0, active_x} + 11'sd2;
	end
end

// S1a: lx = ax - sx only (no multi-bit magnitude compare).
// Strips stay in d_* — copying 4×32b×M into this stage blew CLS / Fmax.
reg signed [10:0] lx_s1a   [0:MAX_PER_LINE-1];
reg               en_s1a   [0:MAX_PER_LINE-1];
reg [1:0]         sz_s1a   [0:MAX_PER_LINE-1];
reg [3:0]         pal_s1a  [0:MAX_PER_LINE-1];
reg               active_s1a, spr_act_s1a;

genvar gi;
generate
	for (gi = 0; gi < MAX_PER_LINE; gi = gi + 1) begin : gen_s1a
		always @(posedge clk or negedge rst_n) begin
			if (!rst_n) begin
				lx_s1a[gi]  <= 11'sd0;
				en_s1a[gi]  <= 1'b0;
				sz_s1a[gi]  <= 2'd0;
				pal_s1a[gi] <= 4'd0;
			end else begin
				lx_s1a[gi]  <= ax_s0 - d_sx[gi];
				en_s1a[gi]  <= d_en[gi];
				sz_s1a[gi]  <= d_size[gi];
				pal_s1a[gi] <= d_pal[gi];
			end
		end
	end
endgenerate

always @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		active_s1a  <= 1'b0;
		spr_act_s1a <= 1'b0;
	end else begin
		active_s1a  <= active_s0;
		spr_act_s1a <= spr_act_s0;
	end
end

// S1b: vis via bit tests (lx in 0..7 / 0..15 / 0..31) + strip select
//   8x8:   lx[10:3]==0 → 0..7
//   16x16: lx[10:4]==0 → 0..15
//   32x32: lx[10:5]==0 → 0..31
reg               vis_s1  [0:MAX_PER_LINE-1];
reg [2:0]         lx_s1   [0:MAX_PER_LINE-1];
reg [31:0]        strip_s1[0:MAX_PER_LINE-1];
reg [3:0]         pal_s1  [0:MAX_PER_LINE-1];
reg               active_s1, spr_act_s1;

generate
	for (gi = 0; gi < MAX_PER_LINE; gi = gi + 1) begin : gen_s1b
		wire sz32 = (sz_s1a[gi] == 2'b10);
		wire sz16 = (sz_s1a[gi] == 2'b01);
		wire in_span = sz32 ? (lx_s1a[gi][10:5] == 6'd0)
			: sz16 ? (lx_s1a[gi][10:4] == 7'd0)
			: (lx_s1a[gi][10:3] == 8'd0);
		wire vis = en_s1a[gi] && in_span;
		wire [1:0] col = lx_s1a[gi][4:3];
		wire [31:0] strip_sel = sz32
			? (col == 2'd0 ? d_strip[gi]
				: col == 2'd1 ? d_strip_r[gi]
				: col == 2'd2 ? d_strip_2[gi]
				: d_strip_3[gi])
			: ((sz16 && lx_s1a[gi][3]) ? d_strip_r[gi] : d_strip[gi]);
		always @(posedge clk or negedge rst_n) begin
			if (!rst_n) begin
				vis_s1[gi]   <= 1'b0;
				lx_s1[gi]    <= 3'd0;
				strip_s1[gi] <= 32'd0;
				pal_s1[gi]   <= 4'd0;
			end else begin
				vis_s1[gi]   <= vis;
				lx_s1[gi]    <= lx_s1a[gi][2:0];
				strip_s1[gi] <= strip_sel;
				pal_s1[gi]   <= pal_s1a[gi];
			end
		end
	end
endgenerate

always @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		active_s1  <= 1'b0;
		spr_act_s1 <= 1'b0;
	end else begin
		active_s1  <= active_s1a;
		spr_act_s1 <= spr_act_s1a;
	end
end

// S1c: nibble extract + opaque (was S1b)
reg       hit_op_s1c [0:MAX_PER_LINE-1];
reg [7:0] hit_pe_s1c [0:MAX_PER_LINE-1];
reg       active_s1c, spr_act_s1c;

generate
	for (gi = 0; gi < MAX_PER_LINE; gi = gi + 1) begin : gen_s1c
		wire [3:0] idx = nibble_of(strip_s1[gi], lx_s1[gi]);
		always @(posedge clk or negedge rst_n) begin
			if (!rst_n) begin
				hit_op_s1c[gi] <= 1'b0;
				hit_pe_s1c[gi] <= 8'd0;
			end else begin
				hit_op_s1c[gi] <= vis_s1[gi] && (idx != 4'd0);
				hit_pe_s1c[gi] <= {pal_s1[gi], idx};
			end
		end
	end
endgenerate

always @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		active_s1c  <= 1'b0;
		spr_act_s1c <= 1'b0;
	end else begin
		active_s1c  <= active_s1;
		spr_act_s1c <= spr_act_s1;
	end
end

// S2 priority (combo of S1c regs only — MAX_PER_LINE is tiny)
reg        any_op_c;
reg [7:0]  win_pe_c;
integer j;
always @(*) begin
	any_op_c = 1'b0;
	win_pe_c = 8'd0;
	for (j = MAX_PER_LINE - 1; j >= 0; j = j - 1) begin
		if (hit_op_s1c[j]) begin
			any_op_c = 1'b1;
			win_pe_c = hit_pe_s1c[j];
		end
	end
end

reg        any_op_s2;
reg [7:0]  win_pe_s2;
reg        active_s2, spr_act_s2;
always @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		any_op_s2  <= 1'b0;
		win_pe_s2  <= 8'd0;
		active_s2  <= 1'b0;
		spr_act_s2 <= 1'b0;
	end else begin
		any_op_s2  <= any_op_c;
		win_pe_s2  <= win_pe_c;
		active_s2  <= active_s1c;
		spr_act_s2 <= spr_act_s1c;
	end
end

// S3 pal + opaque
always @(posedge clk) begin
	if (pal_we)
		pal[pal_waddr] <= pal_wdata;
	pal_q <= pal[win_pe_s2];
end

reg any_op_s3, active_s3, spr_act_s3;
always @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		any_op_s3  <= 1'b0;
		active_s3  <= 1'b0;
		spr_act_s3 <= 1'b0;
	end else begin
		any_op_s3  <= any_op_s2;
		active_s3  <= active_s2;
		spr_act_s3 <= spr_act_s2;
	end
end

// S4: hold pal + opaque so ready_r / pal_q do not combo into lcd_*.
// Unset palette entries stay 0 (black). Index 0 in the tile is still
// transparent via out_opaque (nibble==0); black is an opaque colour when
// the nibble is non-zero and the RGB565 slot is 0x0000.
reg [15:0] out_px_r;
reg        out_opaque_r;
always @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		out_px_r      <= 16'd0;
		out_opaque_r  <= 1'b0;
	end else begin
		out_px_r     <= pal_q;
		out_opaque_r <= any_op_s3 && spr_act_s3 && active_s3;
	end
end
assign out_opaque = out_opaque_r;
assign out_px     = out_px_r;

wire _unused = |{pixel_tick, spr_wr_strb, W_SLOT, bg_px,
	fetch_tile_num, fetch_word_addr};

endmodule

`default_nettype wire
