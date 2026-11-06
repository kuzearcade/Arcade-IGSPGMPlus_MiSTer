// Sprite engine testbench: IGS023_Sprite + IGS023_BROM_Cache with the IGS023's own sprite timing
// (igs023.sv: 640 x 264 counters at ce_pixel = ce_50m / 5, hblank hcnt < 192, vblank vcnt < 40,
// list DMA on line 221, frame_reset at vblank start, next_line at each hsync outside vblank).
// The C++ side (tb.cpp) serves the sprite list (work RAM words), the extended list, the B-ROM and
// A-ROM toggle handshakes from files and records color_out per visible pixel.
module spr_tb_top(
    input clk,
    input reset,
    input ext_sprites,

    output [15:0] dma_addr,
    input  [15:0] dma_din,
    output [14:0] ext_addr,
    input  [15:0] ext_din,

    output [23:0] sdr_brom_address,
    output        sdr_brom_req,
    input         sdr_brom_ack,
    input  [63:0] sdr_brom_data,

    output [25:0] arom_address,
    output        arom_req,
    input         arom_ack,
    input  [63:0] arom_data,

    output        pix_valid,
    output [9:0]  pix_x,
    output [8:0]  pix_y,
    output [11:0] color_out,
    output        frame_start
);

// 50 MHz enable from the 60 MHz clock (5 of every 6), as PGM.sv
reg [2:0] div6 = 0;
always_ff @(posedge clk) div6 <= (div6 == 3'd5) ? 3'd0 : div6 + 3'd1;
wire ce_50m = div6 != 3'd5;

reg [4:0] ce_pixel_shift = 5'b00001;
always_ff @(posedge clk) begin
    if (~|ce_pixel_shift) ce_pixel_shift <= 5'b00001;
    else if (ce_50m) ce_pixel_shift <= {ce_pixel_shift[3:0], ce_pixel_shift[4]};
end
wire ce_pixel = ce_50m & ce_pixel_shift[4];

reg [8:0] vcnt = 0;
reg [9:0] hcnt = 0;
always_ff @(posedge clk) if (ce_pixel) begin
    hcnt <= hcnt + 1;
    if (hcnt == 639) begin
        hcnt <= 0;
        vcnt <= (vcnt == 263) ? 9'd0 : vcnt + 1;
    end
end
wire hsync  = (hcnt >= 63 && hcnt < (63 + 63));
wire hblank = hcnt < 192;
wire vblank = vcnt < 40;

reg vblank_prev = 0, hsync_prev = 0;
reg [7:0] line_ctr = 0;
reg dma_start = 0, frame_reset = 0, next_line = 0;
always_ff @(posedge clk) begin
    dma_start <= 0; frame_reset <= 0; next_line <= 0;
    vblank_prev <= vblank; hsync_prev <= hsync;
    if (~vblank & vblank_prev) line_ctr <= 0;
    else if (hsync & ~hsync_prev) begin
        next_line <= ~vblank;
        line_ctr <= line_ctr + 1;
        if (line_ctr == 221) dma_start <= 1;
    end
    if (vblank & ~vblank_prev) frame_reset <= 1;
end
assign frame_start = frame_reset;

// 68k bus for the list DMA: grant at once, bus idle
wire cpu_br_n, cpu_bgack_n;
reg  cpu_bg_n = 1;
always_ff @(posedge clk) cpu_bg_n <= cpu_br_n;

wire [23:0] spr_brom_address;
wire [63:0] spr_brom_data;
wire        spr_brom_req, spr_brom_ack;

IGS023_BROM_Cache brom_cache(
    .clk(clk), .reset(reset),
    .req_address(spr_brom_address), .req(spr_brom_req), .ack(spr_brom_ack), .data(spr_brom_data),
    .sdr_address(sdr_brom_address), .sdr_req(sdr_brom_req), .sdr_ack(sdr_brom_ack), .sdr_data(sdr_brom_data)
);

IGS023_Sprite sprite(
    .clk(clk), .ce_pixel(ce_pixel), .frame_reset(frame_reset), .scan_active(~(vblank | hblank)),
    .next_line(next_line), .reset(reset), .dma_start(dma_start),
    .global_flip_x(1'b0), .global_flip_y(1'b0),
    .color_out(color_out),
    .cpu_br_n(cpu_br_n), .cpu_bgack_n(cpu_bgack_n), .cpu_bg_n(cpu_bg_n), .cpu_as_n(1'b1), .cpu_dtack_n(1'b0),
    .dma_addr(dma_addr), .dma_din(dma_din),
    .ext_sprites(ext_sprites), .ext_addr(ext_addr), .ext_din(ext_din),
    .brom_address(spr_brom_address), .brom_data(spr_brom_data), .brom_req(spr_brom_req), .brom_ack(spr_brom_ack),
    .arom_address(arom_address), .arom_data(arom_data), .arom_req(arom_req), .arom_ack(arom_ack)
);

// monitor: line-buffer writes that land on the line being scanned out or erased (a write that
// passed the writable check before next_line moved the window)
int bad_writes /* verilator public_flat */ = 0;
always_ff @(posedge clk) begin
    if (|sprite.line_buffer.line_wr) begin
        if ((sprite.line_buffer.line_wr_entry.line[4:0]) == (sprite.line_buffer.scan_line[4:0]) ||
            (sprite.line_buffer.line_wr_entry.line[4:0]) == (sprite.line_buffer.erase_line[4:0]))
            bad_writes <= bad_writes + 1;
    end
end
export "DPI-C" function get_bad_writes;
function int get_bad_writes(); return bad_writes; endfunction

assign pix_valid = ce_pixel & ~(vblank | hblank);
assign pix_x = hcnt - 10'd192;
assign pix_y = vcnt - 9'd40;

endmodule
