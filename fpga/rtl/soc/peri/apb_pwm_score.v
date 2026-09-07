`default_nettype none

// Square-wave score player (1 voice, 4 scores × 64 notes, BSRAM).
//
// Base 0x4000_3000
//   +0x00 NOTE  W   [15:8] duration in 8 ms ticks (0 treated as 1)
//                   [7:0]  pitch (0=rest, 1..48 = C3..B6)
//   +0x04 SEL   R/W [1:0]  score 0..3 for NOTE / CLR
//   +0x08 CTRL  W   [1:0]  score, [8] play from start, [9] stop
//   +0x0C CLR   W   any write clears score[SEL] (length → 0)
//   +0x10 LEN   R   [6:0]  notes stored in score[SEL] (0..64)
//
// Duration unit is 8 ms: 1/16 note @ 120 BPM ≈ 16 ticks, quarter ≈ 63,
// whole ≈ 250. Fits in 8 bits. Tick = CLK_MHZ * 8000 sys cycles.

module apb_pwm_score #(
	parameter CLK_MHZ = 15
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

	output reg         pwm_out
);

assign apbs_pready  = 1'b1;
assign apbs_pslverr = 1'b0;

localparam integer TICK_CYCLES = CLK_MHZ * 8000;
localparam integer W_TICK = $clog2(TICK_CYCLES);

localparam [2:0]
	REG_NOTE = 3'd0,
	REG_SEL  = 3'd1,
	REG_CTRL = 3'd2,
	REG_CLR  = 3'd3,
	REG_LEN  = 3'd4;

wire [2:0] reg_sel = apbs_paddr[4:2];
wire       wr = apbs_psel && apbs_penable && apbs_pwrite;

reg [1:0] sel;

// Per-score fill length (0..64). Playback stops at this index.
reg [6:0] wr_len [0:3];

// -------------------------------------------------------------------------
// Score BSRAM: 4 × 64 × 16b = 256 words
// addr = {score[1:0], note[5:0]}
// -------------------------------------------------------------------------

(* ram_style = "block" *)
reg [15:0] score_mem [0:255];
reg        score_we;
reg [7:0]  score_waddr;
reg [15:0] score_wdata;
reg [7:0]  score_raddr;
reg [15:0] score_rdata;

always @(posedge clk) begin
	if (score_we)
		score_mem[score_waddr] <= score_wdata;
	score_rdata <= score_mem[score_raddr];
end

// -------------------------------------------------------------------------
// Player
// -------------------------------------------------------------------------

reg        playing;
reg [1:0]  play_sel;
reg [6:0]  play_idx;
reg [1:0]  fetch_st; // 0=idle, 1=addr issued, 2=sample BRAM
reg [7:0]  cur_note;
reg [7:0]  cur_dur;
reg [W_TICK-1:0] tick_ctr;

reg [17:0] pwm_ctr;
reg [16:0] half_per_r;

// One octave @ 15 MHz (C3..B3). Higher octaves are exact >> 1/2/3.
function automatic [16:0] period_c3;
	input [3:0] deg;
	begin
		case (deg)
			4'd1:  period_c3 = 17'd57334;
			4'd2:  period_c3 = 17'd54116;
			4'd3:  period_c3 = 17'd51078;
			4'd4:  period_c3 = 17'd48212;
			4'd5:  period_c3 = 17'd45506;
			4'd6:  period_c3 = 17'd42952;
			4'd7:  period_c3 = 17'd40541;
			4'd8:  period_c3 = 17'd38266;
			4'd9:  period_c3 = 17'd36118;
			4'd10: period_c3 = 17'd34091;
			4'd11: period_c3 = 17'd32178;
			4'd12: period_c3 = 17'd30372;
			default: period_c3 = 17'd0;
		endcase
	end
endfunction

wire [1:0] octave =
	(cur_note == 8'd0 || cur_note > 8'd48) ? 2'd0 :
	(cur_note <= 8'd12) ? 2'd0 :
	(cur_note <= 8'd24) ? 2'd1 :
	(cur_note <= 8'd36) ? 2'd2 : 2'd3;
wire [7:0] deg8 =
	(cur_note == 8'd0 || cur_note > 8'd48) ? 8'd0 :
	(cur_note <= 8'd12) ? cur_note :
	(cur_note <= 8'd24) ? (cur_note - 8'd12) :
	(cur_note <= 8'd36) ? (cur_note - 8'd24) : (cur_note - 8'd36);
wire [16:0] half_per = period_c3(deg8[3:0]) >> octave;

integer si;

wire [6:0] len_sel = wr_len[sel];

reg [31:0] prdata_mux;
always @(*) begin
	case (reg_sel)
		REG_SEL: prdata_mux = {30'd0, sel};
		REG_LEN: prdata_mux = {25'd0, len_sel};
		default: prdata_mux = 32'h0;
	endcase
end
assign apbs_prdata = prdata_mux;

always @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		sel         <= 2'd0;
		playing     <= 1'b0;
		play_sel    <= 2'd0;
		play_idx    <= 7'd0;
		fetch_st    <= 2'd0;
		cur_note    <= 8'd0;
		cur_dur     <= 8'd0;
		tick_ctr    <= {W_TICK{1'b0}};
		pwm_ctr     <= 18'd0;
		half_per_r  <= 17'd0;
		pwm_out     <= 1'b0;
		score_we    <= 1'b0;
		score_waddr <= 8'd0;
		score_wdata <= 16'd0;
		score_raddr <= 8'd0;
		for (si = 0; si < 4; si = si + 1)
			wr_len[si] <= 7'd0;
	end else begin
		score_we <= 1'b0;

		if (wr) begin
			case (reg_sel)
				REG_NOTE: begin
					if (wr_len[sel] < 7'd64) begin
						score_we    <= 1'b1;
						score_waddr <= {sel, wr_len[sel][5:0]};
						score_wdata <= apbs_pwdata[15:0];
						wr_len[sel] <= wr_len[sel] + 7'd1;
					end
				end
				REG_SEL: sel <= apbs_pwdata[1:0];
				REG_CTRL: begin
					if (apbs_pwdata[9]) begin
						playing  <= 1'b0;
						fetch_st <= 2'd0;
						cur_note <= 8'd0;
						pwm_out  <= 1'b0;
						pwm_ctr  <= 18'd0;
					end else if (apbs_pwdata[8]) begin
						if (wr_len[apbs_pwdata[1:0]] != 7'd0) begin
							playing     <= 1'b1;
							play_sel    <= apbs_pwdata[1:0];
							play_idx    <= 7'd0;
							fetch_st    <= 2'd1;
							cur_note    <= 8'd0;
							tick_ctr    <= {W_TICK{1'b0}};
							pwm_ctr     <= 18'd0;
							pwm_out     <= 1'b0;
							score_raddr <= {apbs_pwdata[1:0], 6'd0};
						end
					end
				end
				REG_CLR: wr_len[sel] <= 7'd0;
				default: ;
			endcase
		end

		if (playing && fetch_st == 2'd1)
			fetch_st <= 2'd2;
		else if (playing && fetch_st == 2'd2) begin
			fetch_st <= 2'd0;
			cur_note <= score_rdata[7:0];
			cur_dur  <= (score_rdata[15:8] == 8'd0) ? 8'd1 : score_rdata[15:8];
			play_idx <= play_idx + 7'd1;
			tick_ctr <= {W_TICK{1'b0}};
			pwm_ctr  <= 18'd0;
		end else if (playing && fetch_st == 2'd0) begin
			if (tick_ctr >= TICK_CYCLES[W_TICK-1:0] - 1'b1) begin
				tick_ctr <= {W_TICK{1'b0}};
				if (cur_dur <= 8'd1) begin
					if (play_idx >= wr_len[play_sel]) begin
						playing  <= 1'b0;
						cur_note <= 8'd0;
						pwm_out  <= 1'b0;
						pwm_ctr  <= 18'd0;
					end else begin
						score_raddr <= {play_sel, play_idx[5:0]};
						fetch_st    <= 2'd1;
						cur_note    <= 8'd0;
					end
				end else
					cur_dur <= cur_dur - 8'd1;
			end else
				tick_ctr <= tick_ctr + 1'b1;
		end

		half_per_r <= half_per;

		// Square PWM uses the registered period (breaks the LUT ROM path).
		if ((wr && (reg_sel == REG_CTRL) && (apbs_pwdata[8] || apbs_pwdata[9]))
			|| !playing || cur_note == 8'd0 || half_per_r == 17'd0)
		begin
			pwm_out <= 1'b0;
			pwm_ctr <= 18'd0;
		end else if (pwm_ctr + 18'd1 >= {1'b0, half_per_r}) begin
			pwm_ctr <= 18'd0;
			pwm_out <= ~pwm_out;
		end else
			pwm_ctr <= pwm_ctr + 18'd1;
	end
end

endmodule

`default_nettype wire
