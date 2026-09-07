`default_nettype none

module ahb_vram_writer #(
	parameter W_ADDR = 32,
	parameter W_DATA = 32
) (
	input  wire               clk,
	input  wire               rst_n,

	output reg                ahbls_hready_resp,
	input  wire               ahbls_hready,
	output wire               ahbls_hresp,
	input  wire [W_ADDR-1:0]  ahbls_haddr,
	input  wire               ahbls_hwrite,
	input  wire [1:0]         ahbls_htrans,
	input  wire [2:0]         ahbls_hsize,
	input  wire [2:0]         ahbls_hburst,
	input  wire [3:0]         ahbls_hprot,
	input  wire               ahbls_hmastlock,
	input  wire [W_DATA-1:0]  ahbls_hwdata,
	output wire [W_DATA-1:0]  ahbls_hrdata,

	output reg                vram_wr_req,
	input  wire               vram_wr_ack,
	output reg  [17:0]        vram_wr_addr,
	output reg  [15:0]        vram_wr_data,
	output reg  [1:0]         vram_wr_strb
);

localparam VRAM_BYTES = 18'd261120;

reg [17:0] addr_saved;
reg [2:0]  size_saved;
reg        word_write_saved;
reg [17:0] second_addr;
reg [15:0] second_data;
reg [1:0]  second_strb;

localparam [2:0]
	ST_IDLE         = 3'd0,
	ST_CAPTURE_DATA = 3'd1,
	ST_WAIT0        = 3'd2,
	ST_ISSUE1       = 3'd3,
	ST_WAIT1        = 3'd4,
	ST_DONE         = 3'd5;

reg [2:0] state;

wire ahb_write_aphase = ahbls_hready && ahbls_htrans[1] && ahbls_hwrite;
wire [17:0] byte_addr = ahbls_haddr[17:0];
wire addr_in_range = byte_addr < VRAM_BYTES;
wire align_ok = ahbls_hsize[1] ? (byte_addr[1:0] == 2'b00) :
                ahbls_hsize[0] ? (byte_addr[0] == 1'b0) : 1'b1;

assign ahbls_hresp = ahb_write_aphase && !addr_in_range;
assign ahbls_hrdata = {W_DATA{1'b0}};

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		ahbls_hready_resp <= 1'b1;
		vram_wr_req       <= 1'b0;
		vram_wr_addr      <= 18'd0;
		vram_wr_data      <= 16'd0;
		vram_wr_strb      <= 2'b00;
		addr_saved        <= 18'd0;
		size_saved        <= 3'd0;
		word_write_saved  <= 1'b0;
		second_addr       <= 18'd0;
		second_data       <= 16'd0;
		second_strb       <= 2'b00;
		state             <= ST_IDLE;
	end else begin
		case (state)
			ST_IDLE: begin
				ahbls_hready_resp <= 1'b1;
				vram_wr_req <= 1'b0;
				if (ahb_write_aphase && addr_in_range && align_ok) begin
					addr_saved <= byte_addr;
					size_saved <= ahbls_hsize;
					ahbls_hready_resp <= 1'b0;
					state <= ST_CAPTURE_DATA;
				end
			end

			ST_CAPTURE_DATA: begin
				ahbls_hready_resp <= 1'b0;
				if (size_saved[1]) begin
					vram_wr_addr <= {addr_saved[17:2], 2'b00};
					vram_wr_data <= ahbls_hwdata[15:0];
					vram_wr_strb <= 2'b11;
					vram_wr_req  <= 1'b1;
					word_write_saved <= 1'b1;
					second_addr <= {addr_saved[17:2], 2'b00} + 18'd2;
					second_data <= ahbls_hwdata[31:16];
					second_strb <= 2'b11;
				end else if (size_saved[0]) begin
					vram_wr_addr <= {addr_saved[17:1], 1'b0};
					vram_wr_data <= addr_saved[1] ? ahbls_hwdata[31:16] : ahbls_hwdata[15:0];
					vram_wr_strb <= 2'b11;
					vram_wr_req  <= 1'b1;
					word_write_saved <= 1'b0;
				end else begin
					vram_wr_addr <= {addr_saved[17:1], 1'b0};
					case (addr_saved[1:0])
						2'd0: vram_wr_data <= {2{ahbls_hwdata[7:0]}};
						2'd1: vram_wr_data <= {2{ahbls_hwdata[15:8]}};
						2'd2: vram_wr_data <= {2{ahbls_hwdata[23:16]}};
						default: vram_wr_data <= {2{ahbls_hwdata[31:24]}};
					endcase
					vram_wr_strb <= 2'b11;
					vram_wr_req  <= 1'b1;
					word_write_saved <= 1'b0;
				end
				state <= ST_WAIT0;
			end

			ST_WAIT0: begin
				ahbls_hready_resp <= 1'b0;
				if (vram_wr_req && vram_wr_ack) begin
					vram_wr_req <= 1'b0;
					state <= word_write_saved ? ST_ISSUE1 : ST_DONE;
				end
			end

			ST_ISSUE1: begin
				ahbls_hready_resp <= 1'b0;
				vram_wr_addr <= second_addr;
				vram_wr_data <= second_data;
				vram_wr_strb <= second_strb;
				vram_wr_req  <= 1'b1;
				state <= ST_WAIT1;
			end

			ST_WAIT1: begin
				ahbls_hready_resp <= 1'b0;
				if (vram_wr_req && vram_wr_ack) begin
					vram_wr_req <= 1'b0;
					state <= ST_DONE;
				end
			end

			ST_DONE: begin
				ahbls_hready_resp <= 1'b1;
				state <= ST_IDLE;
			end

			default: begin
				ahbls_hready_resp <= 1'b1;
				vram_wr_req <= 1'b0;
				state <= ST_IDLE;
			end
		endcase
	end
end

endmodule
