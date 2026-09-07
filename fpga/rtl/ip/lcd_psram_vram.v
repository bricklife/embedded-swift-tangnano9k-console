`default_nettype none

module lcd_psram_vram #(
    parameter ENABLE_DEBUG  = 0,
    parameter ENABLE_SPRITE = 1,
    parameter NUM_SPRITES   = 4,
    parameter MAX_PER_LINE  = 3
) (
    input  wire        clk,
    input  wire        clk_p,
    input  wire        rst_n,
    input  wire        vram_wr_clk,
    input  wire        vram_wr_rst_n,
    input  wire        vram_wr_req,
    output wire        vram_wr_ack,
    input  wire [17:0] vram_wr_addr,
    input  wire [15:0] vram_wr_data,
    input  wire [1:0]  vram_wr_strb,
    output wire [9:0]  vcount,
    output wire        frame_tick,
    input  wire        lcd_enable,
    input  wire [11:0] debug_mode,

    // Sprite CDC from SoC (clk_sys → this clk)
    input  wire        spr_enable,
    input  wire        spr_wr_req,
    output wire        spr_wr_ack,
    input  wire [1:0]  spr_wr_target,
    input  wire [10:0] spr_wr_addr,
    input  wire [31:0] spr_wr_data,
    input  wire [3:0]  spr_wr_strb,
    output wire        spr_overflow_set,

    output wire        lcd_clk,
    output reg         lcd_de,
    output reg         lcd_hsync,
    output reg         lcd_vsync,
    output reg  [4:0]  lcd_r,
    output reg  [5:0]  lcd_g,
    output reg  [4:0]  lcd_b,

    output wire [1:0]  O_psram_ck,
    output wire [1:0]  O_psram_ck_n,
    inout  wire [1:0]  IO_psram_rwds,
    inout  wire [15:0] IO_psram_dq,
    output wire [1:0]  O_psram_reset_n,
    output wire [1:0]  O_psram_cs_n
);

localparam H_VISIBLE = 10'd480;
localparam H_FP      = 10'd50;
localparam H_BP      = 10'd30;
localparam H_TOTAL   = H_VISIBLE + H_FP + H_BP;

localparam V_VISIBLE = 10'd272;
localparam V_FP      = 10'd37;
localparam V_BP      = 10'd12;
localparam V_TOTAL   = V_VISIBLE + V_FP + V_BP;
localparam [9:0] V_FETCH_FIRST = V_BP - 10'd1;

localparam LINE_PAIRS  = 9'd240;
localparam DBG_SCALE = 5; // 2^5 = 32 pixels per sampled PSRAM pixel.

reg [2:0] pix_div;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        pix_div <= 3'd0;
    else
        pix_div <= pix_div + 3'd1;
end

assign lcd_clk = ~pix_div[2];
wire pixel_tick = (pix_div == 3'd5);

wire psram_ready;
reg  psram_read;
reg  psram_write;
reg  psram_rdv;
reg  psram_byte_write;
reg  [21:0] psram_addr;
reg  [15:0] psram_din;
wire [15:0] psram_dout;
wire [15:0] psram_dout2;
wire psram_busy;
wire psram_memvidbusy;
wire unused_memcpubusy;
wire psram_rdcpu_finished;

assign O_psram_reset_n = {2{rst_n}};

psram_controller #(
    .FREQ(72_000_000),
    .LATENCY(3)
) psram_u (
    .clk             (clk),
    .clk_p           (clk_p),
    .resetn          (rst_n),
    .resetn_o        (psram_ready),
    .read            (psram_read),
    .write           (psram_write),
    .addr            (psram_addr),
    .din             (psram_din),
    .byte_write      (psram_byte_write),
    .rdv             (psram_rdv),
    .dout            (psram_dout),
    .dout2           (psram_dout2),
    .busy            (psram_busy),
    .memcpubusy      (unused_memcpubusy),
    .memvidbusy      (psram_memvidbusy),
    .rdcpu_finished  (psram_rdcpu_finished),
    .O_psram_ck      (O_psram_ck),
    .IO_psram_rwds   (IO_psram_rwds),
    .IO_psram_dq     (IO_psram_dq),
    .O_psram_cs_n    (O_psram_cs_n)
);

reg [9:0] h_ctr;
reg [9:0] v_ctr;
reg       frame_live;
reg       display_buf;

wire active = (h_ctr >= H_BP) && (h_ctr < H_BP + H_VISIBLE) &&
              (v_ctr >= V_BP) && (v_ctr < V_BP + V_VISIBLE);
wire h_active = (h_ctr >= H_BP) && (h_ctr < H_BP + H_VISIBLE);
wire [8:0] active_x = h_ctr[8:0] - H_BP[8:0];
wire [8:0] active_y = v_ctr[8:0] - V_BP[8:0];
wire line_fetch_slot = (v_ctr >= V_FETCH_FIRST) &&
                       (v_ctr < V_FETCH_FIRST + V_VISIBLE);
wire [8:0] line_fetch_y = v_ctr[8:0] - V_FETCH_FIRST[8:0];
assign vcount = (v_ctr >= V_BP) ? (v_ctr - V_BP) : (v_ctr + (V_TOTAL - V_BP));

reg        buf0_wre;
reg [8:0]  buf0_ad;
reg [15:0] buf0_di;
wire [15:0] buf0_do;

reg        buf1_wre;
reg [8:0]  buf1_ad;
reg [15:0] buf1_di;
wire [15:0] buf1_do;

wire [8:0] linebuf_rd_addr = h_active ? active_x : 9'd0;
wire [15:0] linebuf_psram_pixel = display_buf ? buf1_do : buf0_do;

// -------- Sprite engine (optional) --------
wire        spr_en_sync;
reg  [2:0]  spr_en_sync_q;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        spr_en_sync_q <= 3'b000;
    else
        spr_en_sync_q <= {spr_en_sync_q[1:0], spr_enable};
end
assign spr_en_sync = spr_en_sync_q[2];

wire        spr_wr_ack_toggle;
reg  [2:0]  spr_ack_sync;
always @(posedge vram_wr_clk or negedge vram_wr_rst_n) begin
    if (!vram_wr_rst_n)
        spr_ack_sync <= 3'b000;
    else
        spr_ack_sync <= {spr_ack_sync[1:0], spr_wr_ack_toggle};
end
// Edge of toggle → level ack pulse for SoC (same as vram)
assign spr_wr_ack = spr_ack_sync[2] ^ spr_ack_sync[1];

wire        spr_overflow_pulse;
reg         spr_ovf_toggle;
reg  [2:0]  spr_ovf_sync;
reg         spr_ovf_sync_d;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        spr_ovf_toggle <= 1'b0;
    else if (spr_overflow_pulse)
        spr_ovf_toggle <= ~spr_ovf_toggle;
end
always @(posedge vram_wr_clk or negedge vram_wr_rst_n) begin
    if (!vram_wr_rst_n) begin
        spr_ovf_sync   <= 3'b000;
        spr_ovf_sync_d <= 1'b0;
    end else begin
        spr_ovf_sync   <= {spr_ovf_sync[1:0], spr_ovf_toggle};
        spr_ovf_sync_d <= spr_ovf_sync[2];
    end
end
assign spr_overflow_set = spr_ovf_sync[2] ^ spr_ovf_sync_d;

// Blank enter (last pixel of last visible line) → 1-bit toggle → clk_sys pulse.
// Same CDC as overflow. FRAME in lcd_ctrl just counts these ticks.
wire blank_enter = pixel_tick && (h_ctr == H_TOTAL - 1'b1) &&
                   (v_ctr == (V_BP + V_VISIBLE - 1'b1));
reg        frame_toggle;
reg [2:0]  frame_sync;
reg        frame_sync_d;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        frame_toggle <= 1'b0;
    else if (blank_enter)
        frame_toggle <= ~frame_toggle;
end
always @(posedge vram_wr_clk or negedge vram_wr_rst_n) begin
    if (!vram_wr_rst_n) begin
        frame_sync   <= 3'b000;
        frame_sync_d <= 1'b0;
    end else begin
        frame_sync   <= {frame_sync[1:0], frame_toggle};
        frame_sync_d <= frame_sync[2];
    end
end
assign frame_tick = frame_sync[2] ^ frame_sync_d;

// Start sprite prep on the last pixel of the previous line so the scan/fetch
// finishes during H-BP of the line being displayed. prep_y is the *next*
// display line (after the impending v_ctr increment at this same pixel_tick).
wire        prep_start = pixel_tick && (h_ctr == H_TOTAL - 10'd1) && frame_live;
wire [9:0]  prep_v_next = (v_ctr == V_TOTAL - 10'd1) ? 10'd0 : (v_ctr + 10'd1);
// Cast to 9 bits after range check (visible y is 0..271).
wire [8:0]  prep_y = (prep_v_next >= V_BP && prep_v_next < (V_BP + V_VISIBLE))
	? (prep_v_next[8:0] - V_BP[8:0])
	: 9'd0;
wire [15:0] spr_out_px;
wire        spr_out_opaque;
wire        spr_strip_ready;
wire        spr_layer_on;

generate
if (ENABLE_SPRITE) begin : gen_sprite
    sprite_engine #(
        .NUM_SPRITES     (NUM_SPRITES),
        .MAX_PER_LINE    (MAX_PER_LINE),
        .NUM_TILES       (64),
        .NUM_PAL_ENTRIES (256),
        .ENABLE_SPRITE   (1)
    ) sprite_u (
        .clk               (clk),
        .rst_n             (rst_n),
        .spr_enable        (spr_en_sync),
        .spr_wr_req        (spr_wr_req),
        .spr_wr_ack_toggle (spr_wr_ack_toggle),
        .spr_wr_target     (spr_wr_target),
        .spr_wr_addr       (spr_wr_addr),
        .spr_wr_data       (spr_wr_data),
        .spr_wr_strb       (spr_wr_strb),
        .overflow_pulse    (spr_overflow_pulse),
        .prep_start        (prep_start),
        .prep_y            (prep_y),
        .pixel_tick        (pixel_tick),
        .active            (active && frame_live && lcd_enable),
        .active_x          (active_x),
        .bg_px             (linebuf_psram_pixel),
        .out_px            (spr_out_px),
        .out_opaque        (spr_out_opaque),
        .strip_ready       (spr_strip_ready),
        .spr_active        (spr_layer_on)
    );
end else begin : gen_no_sprite
    assign spr_wr_ack_toggle  = 1'b0;
    assign spr_overflow_pulse = 1'b0;
    assign spr_out_px         = 16'd0;
    assign spr_out_opaque     = 1'b0;
    assign spr_strip_ready    = 1'b0;
    assign spr_layer_on       = 1'b0;
end
endgenerate

// BG always from undelayed linebuf. Sprite replaces only opaque pixels.
// out_opaque already includes pipelined spr_active — do not AND ready_r
// here (that was a 72 MHz path into lcd_*).
wire [15:0] composed_px = ((ENABLE_SPRITE != 0) && spr_out_opaque)
    ? spr_out_px : linebuf_psram_pixel;

wire debug_enabled = (ENABLE_DEBUG != 0);
reg [4:0] debug_btn_meta;
reg [4:0] debug_btn_sync;
reg [4:0] debug_btn_active;
wire debug_active = debug_enabled && |debug_btn_active[3:0];
wire debug_window = debug_active && active && active_x < 9'd256 && active_y < 9'd256;
wire debug_outer_border = (active_x == 9'd0) || (active_x == 9'd479) ||
                          (active_y == 9'd0) || (active_y == 9'd271);
wire [2:0] debug_disp_x = active_x[DBG_SCALE + 2:DBG_SCALE];
wire [2:0] debug_disp_y = active_y[DBG_SCALE + 2:DBG_SCALE];
wire [5:0] debug_disp_idx = {debug_disp_y, debug_disp_x};
wire debug_grid = (active_x[DBG_SCALE - 1:0] == {DBG_SCALE{1'b0}}) ||
                  (active_y[DBG_SCALE - 1:0] == {DBG_SCALE{1'b0}});
reg [15:0] debug_px [0:63];
wire [15:0] debug_pixel = debug_px[debug_disp_idx];

lcd_linebuf_480x16 linebuf0 (
    .clk (clk),
    .wre (buf0_wre),
    .ad  (buf0_ad),
    .din (buf0_di),
    .dout(buf0_do)
);

lcd_linebuf_480x16 linebuf1 (
    .clk (clk),
    .wre (buf1_wre),
    .ad  (buf1_ad),
    .din (buf1_di),
    .dout(buf1_do)
);

localparam [3:0]
    ST_WAIT_READY = 4'd0,
    ST_FETCH_LINE   = 4'd2,
    ST_STORE0     = 4'd3,
    ST_STORE1     = 4'd4,
    ST_RUN        = 4'd5,
    ST_DBG_READ   = 4'd6,
    ST_DBG_WAIT   = 4'd7,
    ST_WRITE0     = 4'd9,
    ST_WRITE1     = 4'd10;

reg [3:0] state;
reg [8:0]  fetch_pair;
reg [21:0] fetch_base_addr;
reg [21:0] fetch_addr;
reg        fetch_buf;
reg        memvidbusy_d;
reg [15:0] fetch_word0;
reg [15:0] fetch_word1;
reg [8:0]  fetch_y;
reg [8:0]  store_x;
reg        line_fetch_pending;
// Break pix_div/pixel_tick → line_byte_addr → fetch_addr/pair (72 MHz STA).
reg        line_fetch_go;
reg [21:0] line_fetch_addr_hold;
reg [8:0]  line_fetch_y_hold;
reg        psram_cmd_pending;
reg        cpu_wr_req_seen;
reg        cpu_wr_pending;
reg [17:0] cpu_wr_addr;
reg [15:0] cpu_wr_data;
reg [1:0]  cpu_wr_strb;
reg        cpu_wr_ack_toggle;
reg [3:0]  write_return_state;
reg [17:0] write_addr;
reg [15:0] write_data;
reg [1:0]  write_strb;
reg        write_ack_cpu;
reg [5:0]  debug_fetch_idx;
reg [8:0]  debug_fetch_base_x;
reg [8:0]  debug_fetch_base_y;

reg [2:0] cpu_req_sync;
wire cpu_req_seen_psram = cpu_req_sync[2];
wire [8:0] fetch_pair_limit = LINE_PAIRS;

reg [2:0] cpu_ack_sync;
always @(posedge vram_wr_clk or negedge vram_wr_rst_n) begin
    if (!vram_wr_rst_n)
        cpu_ack_sync <= 3'b000;
    else
        cpu_ack_sync <= {cpu_ack_sync[1:0], cpu_wr_ack_toggle};
end
assign vram_wr_ack = cpu_ack_sync[2] ^ cpu_ack_sync[1];

wire memvid_done = memvidbusy_d && !psram_memvidbusy;
function [21:0] line_byte_addr;
    input [8:0] y;
    begin
        // 480 pixels * 2 bytes = 960 bytes = 1024 - 64.
        line_byte_addr = ({13'd0, y} << 10) - ({13'd0, y} << 6);
    end
endfunction

function [21:0] debug_byte_addr;
    input [5:0] idx;
    reg [8:0] dbg_y;
    reg [8:0] dbg_x;
    begin
        dbg_y = debug_fetch_base_y + {6'd0, idx[5:3]};
        dbg_x = debug_fetch_base_x + {6'd0, idx[2:0]};
        debug_byte_addr = line_byte_addr(dbg_y) + {12'd0, dbg_x, 1'b0};
    end
endfunction

function [8:0] debug_selected_base_x;
    input [4:0] btn;
    begin
        if (btn[0])
            debug_selected_base_x = 9'd0;      // BTN0: top-left
        else if (btn[1])
            debug_selected_base_x = 9'd472;    // BTN1: top-right
        else if (btn[2])
            debug_selected_base_x = 9'd0;      // BTN2: bottom-left
        else if (btn[3])
            debug_selected_base_x = 9'd472;    // BTN3: bottom-right
        else
            debug_selected_base_x = 9'd0;
    end
endfunction

function [8:0] debug_selected_base_y;
    input [4:0] btn;
    begin
        if (btn[0])
            debug_selected_base_y = 9'd0;      // BTN0: top-left
        else if (btn[1])
            debug_selected_base_y = 9'd0;      // BTN1: top-right
        else if (btn[2])
            debug_selected_base_y = 9'd264;    // BTN2: bottom-left
        else if (btn[3])
            debug_selected_base_y = 9'd264;    // BTN3: bottom-right
        else
            debug_selected_base_y = 9'd0;
    end
endfunction

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        h_ctr <= 10'd0;
        v_ctr <= 10'd0;
        display_buf <= 1'b0;
        {lcd_de, lcd_hsync, lcd_vsync, lcd_r, lcd_g, lcd_b} <= 20'd0;
    end else if (pixel_tick) begin
        if (h_ctr == H_TOTAL - 1'b1) begin
            h_ctr <= 10'd0;
            v_ctr <= (v_ctr == V_TOTAL - 1'b1) ? 10'd0 : v_ctr + 10'd1;
            if (frame_live && line_fetch_slot)
                display_buf <= ~display_buf;
        end else begin
            h_ctr <= h_ctr + 10'd1;
        end

        lcd_hsync <= (h_ctr >= H_VISIBLE + H_BP) && (h_ctr < H_VISIBLE + H_BP + H_FP);
        lcd_vsync <= (v_ctr >= V_VISIBLE + V_BP) && (v_ctr < V_VISIBLE + V_BP + V_FP);
        lcd_de <= active && frame_live && lcd_enable;
        if (active && frame_live && lcd_enable) begin
            if (debug_active) begin
                if (debug_outer_border) begin
                    lcd_r <= 5'h1f;
                    lcd_g <= 6'h3f;
                    lcd_b <= 5'h1f;
                end else if (debug_window) begin
                    if (debug_grid) begin
                        lcd_r <= 5'h1f;
                        lcd_g <= 6'h3f;
                        lcd_b <= 5'h1f;
                    end else begin
                        lcd_r <= debug_pixel[15:11];
                        lcd_g <= debug_pixel[10:5];
                        lcd_b <= debug_pixel[4:0];
                    end
                end else begin
                    lcd_r <= 5'd0;
                    lcd_g <= 6'd0;
                    lcd_b <= 5'd0;
                end
            end else begin
                // Sprite overlay (if enabled & ready) else BG linebuf
                lcd_r <= composed_px[15:11];
                lcd_g <= composed_px[10:5];
                lcd_b <= composed_px[4:0];
            end
        end else begin
            lcd_r <= 5'd0;
            lcd_g <= 6'd0;
            lcd_b <= 5'd0;
        end
    end
end

always @* begin
    buf0_wre = 1'b0;
    buf0_ad  = (display_buf == 1'b0) ? linebuf_rd_addr : store_x;
    buf0_di  = fetch_word0;
    buf1_wre = 1'b0;
    buf1_ad  = (display_buf == 1'b1) ? linebuf_rd_addr : store_x;
    buf1_di  = fetch_word0;

    if (state == ST_STORE0) begin
        buf0_di = fetch_word0;
        buf1_di = fetch_word0;
    end else if (state == ST_STORE1) begin
        buf0_di = fetch_word1;
        buf1_di = fetch_word1;
    end

    if (state == ST_STORE0 || state == ST_STORE1) begin
        if (fetch_buf == 1'b0) begin
            buf0_wre = 1'b1;
            buf0_ad = store_x;
        end else begin
            buf1_wre = 1'b1;
            buf1_ad = store_x;
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= ST_WAIT_READY;
        psram_read <= 1'b0;
        psram_write <= 1'b0;
        psram_rdv <= 1'b0;
        psram_addr <= 22'd0;
        psram_din <= 16'd0;
        psram_byte_write <= 1'b0;
        fetch_pair <= 9'd0;
        fetch_base_addr <= 22'd0;
        fetch_addr <= 22'd0;
        fetch_buf <= 1'b0;
        frame_live <= 1'b0;
        memvidbusy_d <= 1'b0;
        fetch_word0 <= 16'd0;
        fetch_word1 <= 16'd0;
        fetch_y <= 9'd0;
        store_x <= 9'd0;
        line_fetch_pending <= 1'b0;
        line_fetch_go      <= 1'b0;
        line_fetch_addr_hold <= 22'd0;
        line_fetch_y_hold  <= 9'd0;
        psram_cmd_pending <= 1'b0;
        cpu_req_sync <= 3'b000;
        cpu_wr_req_seen <= 1'b0;
        cpu_wr_pending <= 1'b0;
        cpu_wr_addr <= 18'd0;
        cpu_wr_data <= 16'd0;
        cpu_wr_strb <= 2'b00;
        cpu_wr_ack_toggle <= 1'b0;
        write_return_state <= ST_WAIT_READY;
        write_addr <= 18'd0;
        write_data <= 16'd0;
        write_strb <= 2'b00;
        write_ack_cpu <= 1'b0;
        debug_btn_meta <= 5'd0;
        debug_btn_sync <= 5'd0;
        debug_btn_active <= 5'd0;
        debug_fetch_idx <= 6'd0;
        debug_fetch_base_x <= 9'd0;
        debug_fetch_base_y <= 9'd0;
    end else begin
        psram_read <= 1'b0;
        psram_write <= 1'b0;
        psram_rdv <= 1'b0;
        psram_byte_write <= 1'b0;
        memvidbusy_d <= psram_memvidbusy;
        cpu_req_sync <= {cpu_req_sync[1:0], vram_wr_req};
        if (debug_enabled) begin
            debug_btn_meta <= debug_mode[4:0];
            debug_btn_sync <= debug_btn_meta;
            debug_btn_active <= debug_btn_sync;
        end else begin
            debug_btn_meta <= 5'd0;
            debug_btn_sync <= 5'd0;
            debug_btn_active <= 5'd0;
        end

        if (!cpu_req_seen_psram) begin
            cpu_wr_req_seen <= 1'b0;
        end else if (!cpu_wr_req_seen && !cpu_wr_pending) begin
            cpu_wr_addr <= vram_wr_addr;
            cpu_wr_data <= vram_wr_data;
            cpu_wr_strb <= vram_wr_strb;
            cpu_wr_pending <= |vram_wr_strb;
            cpu_wr_req_seen <= 1'b1;
        end

        if (line_fetch_go) begin
            fetch_base_addr    <= line_fetch_addr_hold;
            fetch_addr         <= line_fetch_addr_hold;
            fetch_buf          <= ~display_buf;
            fetch_y            <= line_fetch_y_hold;
            fetch_pair         <= 9'd0;
            psram_cmd_pending  <= 1'b0;
            line_fetch_go      <= 1'b0;
            state              <= ST_FETCH_LINE;
        end else

        case (state)
            ST_WAIT_READY: begin
                psram_cmd_pending <= 1'b0;
                if (psram_ready)
                    state <= ST_RUN;
            end

            ST_FETCH_LINE: begin
                if (memvid_done) begin
                    psram_cmd_pending <= 1'b0;
                    fetch_word0 <= psram_dout;
                    fetch_word1 <= psram_dout2;
                    store_x <= {fetch_pair, 1'b0};
                    state <= ST_STORE0;
                end else if (cpu_wr_pending && !psram_busy && !psram_cmd_pending && fetch_pair == fetch_pair_limit) begin
                    write_addr <= cpu_wr_addr;
                    write_data <= cpu_wr_data;
                    write_strb <= cpu_wr_strb;
                    write_ack_cpu <= 1'b1;
                    write_return_state <= ST_FETCH_LINE;
                    cpu_wr_pending <= 1'b0;
                    state <= ST_WRITE0;
                end else if (!psram_busy && !psram_cmd_pending && fetch_pair != fetch_pair_limit) begin
                    psram_addr <= fetch_addr;
                    psram_rdv <= 1'b1;
                    psram_cmd_pending <= 1'b1;
                end else if (!psram_busy && !psram_cmd_pending && fetch_pair == fetch_pair_limit) begin
                    state <= ST_RUN;
                end
            end

            ST_WRITE0: begin
                if (write_strb == 2'b11) begin
                    if (psram_cmd_pending && psram_busy) begin
                        psram_cmd_pending <= 1'b0;
                    end else if (!psram_busy && !psram_cmd_pending) begin
                        psram_addr <= {4'd0, write_addr[17:1], 1'b0};
                        psram_din <= write_data;
                        psram_byte_write <= 1'b0;
                        psram_write <= 1'b1;
                        psram_cmd_pending <= 1'b1;
                        write_strb <= 2'b00;
                    end
                end else if (write_strb[0]) begin
                    if (psram_cmd_pending && psram_busy) begin
                        psram_cmd_pending <= 1'b0;
                    end else if (!psram_busy && !psram_cmd_pending) begin
                        psram_addr <= {4'd0, write_addr[17:1], 1'b0};
                        psram_din <= {8'd0, write_data[7:0]};
                        psram_byte_write <= 1'b1;
                        psram_write <= 1'b1;
                        psram_cmd_pending <= 1'b1;
                        write_strb[0] <= 1'b0;
                    end
                end else begin
                    state <= ST_WRITE1;
                end
            end

            ST_WRITE1: begin
                if (write_strb[1]) begin
                    if (psram_cmd_pending && psram_busy) begin
                        psram_cmd_pending <= 1'b0;
                    end else if (!psram_busy && !psram_cmd_pending) begin
                        psram_addr <= {4'd0, write_addr[17:1], 1'b1};
                        psram_din <= {write_data[15:8], 8'd0};
                        psram_byte_write <= 1'b1;
                        psram_write <= 1'b1;
                        psram_cmd_pending <= 1'b1;
                        write_strb[1] <= 1'b0;
                    end
                end else begin
                    if (psram_cmd_pending && psram_busy) begin
                        psram_cmd_pending <= 1'b0;
                    end else if (!psram_busy && !psram_cmd_pending) begin
                        if (write_ack_cpu)
                            cpu_wr_ack_toggle <= ~cpu_wr_ack_toggle;
                        state <= write_return_state;
                    end
                end
            end

            ST_STORE0: begin
                store_x <= store_x + 9'd1;
                state <= ST_STORE1;
            end

            ST_STORE1: begin
                store_x <= store_x + 9'd1;
                fetch_pair <= fetch_pair + 9'd1;
                fetch_addr <= fetch_addr + 22'd4;
                state <= ST_FETCH_LINE;
            end

            ST_DBG_READ: begin
                if (!debug_active) begin
                    psram_cmd_pending <= 1'b0;
                    state <= ST_RUN;
                end else if (psram_cmd_pending && psram_busy) begin
                    psram_cmd_pending <= 1'b0;
                    state <= ST_DBG_WAIT;
                end else if (!psram_busy && !psram_cmd_pending) begin
                    psram_addr <= debug_byte_addr(debug_fetch_idx);
                    psram_read <= 1'b1;
                    psram_cmd_pending <= 1'b1;
                end
            end

            ST_DBG_WAIT: begin
                if (!debug_active) begin
                    psram_cmd_pending <= 1'b0;
                    state <= ST_RUN;
                end else if (psram_rdcpu_finished) begin
                    debug_px[debug_fetch_idx] <= psram_dout;
                    debug_fetch_idx <= debug_fetch_idx + 6'd1;
                    state <= (debug_fetch_idx == 6'd63) ? ST_RUN : ST_DBG_READ;
                end
            end

            ST_RUN: begin
                if (!frame_live && pixel_tick && h_ctr == 10'd0 && v_ctr == 10'd0)
                    frame_live <= 1'b1;

                if (psram_cmd_pending && psram_busy) begin
                    psram_cmd_pending <= 1'b0;
                end else if (cpu_wr_pending && !psram_busy && !psram_cmd_pending && !line_fetch_pending) begin
                    write_addr <= cpu_wr_addr;
                    write_data <= cpu_wr_data;
                    write_strb <= cpu_wr_strb;
                    write_ack_cpu <= 1'b1;
                    write_return_state <= ST_RUN;
                    cpu_wr_pending <= 1'b0;
                    state <= ST_WRITE0;
                end else if (debug_active &&
                    !psram_busy && !psram_cmd_pending && !line_fetch_pending &&
                    v_ctr >= V_BP + V_VISIBLE) begin
                    debug_fetch_idx <= 6'd0;
                    debug_fetch_base_x <= debug_selected_base_x(debug_btn_active);
                    debug_fetch_base_y <= debug_selected_base_y(debug_btn_active);
                    state <= ST_DBG_READ;
                end else if (pixel_tick && h_ctr == 10'd0 && line_fetch_slot && !line_fetch_pending) begin
                    line_fetch_addr_hold <= line_byte_addr(line_fetch_y);
                    line_fetch_y_hold    <= line_fetch_y;
                    line_fetch_pending   <= 1'b1;
                    line_fetch_go        <= 1'b1;
                end

                if (pixel_tick && h_ctr == H_TOTAL - 1'b1)
                    line_fetch_pending <= 1'b0;
            end

            default: state <= ST_WAIT_READY;
        endcase
    end
end

endmodule

module lcd_linebuf_480x16 (
    input  wire        clk,
    input  wire        wre,
    input  wire [8:0]  ad,
    input  wire [15:0] din,
    output wire [15:0] dout
);

wire [15:0] unused_do;
wire gw_gnd = 1'b0;

SP sp_inst (
    .DO({unused_do, dout}),
    .CLK(clk),
    .OCE(1'b1),
    .CE(1'b1),
    .RESET(1'b0),
    .WRE(wre),
    .BLKSEL({gw_gnd, gw_gnd, gw_gnd}),
    .AD({gw_gnd, ad, gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
    .DI({16'd0, din})
);

defparam sp_inst.READ_MODE = 1'b0;
defparam sp_inst.WRITE_MODE = 2'b01;
defparam sp_inst.BIT_WIDTH = 16;
defparam sp_inst.BLK_SEL = 3'b000;
defparam sp_inst.RESET_MODE = "SYNC";

endmodule
