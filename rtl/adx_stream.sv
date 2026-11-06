//============================================================================
//  CRI ADX stream player (espgalarr lossless BGM)
//
//  Plays one track of the BGM blob loaded at BASE (MRA <rom index="2">): "EBGM", track count,
//  then (offset, size) big-endian per track, each track an ADX stream (encoding 3, 4-bit,
//  18-byte frames, 2 channels, 48 kHz, header version 4).  One stereo sample per `tick`
//  (48 kHz), decoded with the PS2's arithmetic (CRI ADXB, ELF 0x27CD3C):
//      s = clamp16(((C1 * h1 + C2 * h2) >>> 12) + nibble * scale),  scale = (word & 0x1FFF) + 1
//  The track loops from its loop end to its loop start as its header says. LOOP_RESTORE = 1 (the
//  PS2's: PCSX2 run at the boss track's seam, decoder entry state 0x2ECE88 at ELF 0x27D294) restores
//  the predictor history saved at the loop start; 0 carries it on. LOOP_END_INCL = 1 also plays
//  the header's loop end sample (every track has samples = loop end + 1; not yet checked on the PS2).
//
//  Memory: 64-bit reads, byte address mem_addr (8-aligned), mem_req held until mem_ack (one
//  cycle, mem_data valid); byte i of a word is mem_data[8*i +: 8] (DDR3 as the HPS writes it).
//  Reference: espgalarr/ps2/adx.py decode_exact().
//============================================================================

module adx_stream #(
    parameter bit [31:0] BASE = 32'h3400_0000,
    parameter int C1 = 7400,             // cutoff 500 Hz at 48 kHz (EE RAM 0x2ECE90)
    parameter int C2 = -3342,
    parameter bit LOOP_RESTORE = 1,
    parameter bit LOOP_END_INCL = 0
)(
    input               clk,
    input               reset,

    input               tick,           // one output sample (48 kHz)
    input               cmd_play,       // start cmd_track from its beginning
    input         [3:0] cmd_track,
    input               cmd_stop,
    input               pause,

    output reg   [31:0] mem_addr,
    output reg          mem_req,
    input               mem_ack,
    input        [63:0] mem_data,

    output reg signed [15:0] out_l,
    output reg signed [15:0] out_r,
    output              playing,
    output reg          underrun,       // a frame was not fetched in time (sticky until play)
    output reg          looped          // the loop jump happened (sticky until play)
);

// ---- track parameters ----------------------------------------------------------------------
reg [31:0] trk_base, data_start, n_samples, loop_start, loop_end;
reg        has_loop;
wire [31:0] end_pos = has_loop ? loop_end + 32'(LOOP_END_INCL) : n_samples;

// ---- frames: current (decoding) and next (prefetched), 36 bytes each (L 0..17, R 18..35) ----
reg [287:0] cur, nxt;
reg [287:0] lpf;                 // the loop start's frame, fetched once at the track start (the jump
                                 // never waits: the frame holding the loop end may be used for 1 sample)
reg  [26:0] cur_f;               // frame number of cur
reg  [26:0] nxt_f;               // frame number being / been fetched into nxt (cur_f + 1)
reg         nxt_ok;              // nxt holds frame nxt_f
reg         to_lpf;              // the fetch in flight fills lpf
reg  [31:0] pos;                 // next sample to decode

function automatic [7:0] fbyte(input [287:0] f, input int i);
    fbyte = f[8*i +: 8];
endfunction

// cur is the last frame before the end (no loop) or before the jump (from lpf): nothing to fetch
wire need_nxt = !(n_samples <= {cur_f + 27'd1, 5'd0} && !has_loop) &&
                !(has_loop && end_pos <= {cur_f + 27'd1, 5'd0});

// ---- fetch engine: 6 words from the 8-aligned address below a frame (36 bytes at any offset) -
reg  [383:0] fbuf;
reg    [2:0] fcount;
reg   [31:0] faddr;               // byte address of the frame being fetched
reg          fbusy;

// ---- main state ------------------------------------------------------------------------------
typedef enum logic [3:0] {
    S_IDLE, S_DIR, S_HDR0, S_HDR1, S_HDR4, S_HDR5, S_HDR6, S_FIRST, S_LOOPF, S_PLAY
} state_t;
state_t st;
assign playing = (st == S_PLAY);

function automatic [31:0] be32(input [63:0] w, input int b);   // big-endian long at byte b
    be32 = {w[8*b +: 8], w[8*(b+1) +: 8], w[8*(b+2) +: 8], w[8*(b+3) +: 8]};
endfunction

// ---- decode ----------------------------------------------------------------------------------
reg signed [15:0] h1_l, h2_l, h1_r, h2_r;
reg signed [15:0] sv1_l, sv2_l, sv1_r, sv2_r;   // history saved at the loop start
reg               saved;

function automatic signed [15:0] adx_sample(input [7:0] s_hi, input [7:0] s_lo, input [7:0] b,
                                            input odd, input signed [15:0] h1,
                                            input signed [15:0] h2);
    logic signed [4:0]  nib;
    logic signed [14:0] scale;
    logic signed [31:0] p;
    logic signed [31:0] s;
    nib   = odd ? $signed({b[3], b[3:0]}) : $signed({b[7], b[7:4]});
    scale = $signed({2'b00, s_hi[4:0], s_lo}) + 15'sd1;
    p     = (32'(C1) * 32'(h1) + 32'(C2) * 32'(h2)) >>> 12;
    s     = p + 32'(nib) * 32'(scale);
    adx_sample = (s > 32'sd32767) ? 16'sh7fff : (s < -32'sd32768) ? -16'sh8000 : s[15:0];
endfunction


always_ff @(posedge clk) begin
    if (reset) begin
        st <= S_IDLE;
        mem_req <= 0;
        fbusy <= 0;
        out_l <= 0;
        out_r <= 0;
        underrun <= 0;
        looped <= 0;
    end else begin
        // ---- fetch engine (frames) ----
        if (fbusy && mem_ack) begin
            fbuf <= {mem_data, fbuf[383:64]};
            fcount <= fcount + 3'd1;
            mem_addr <= mem_addr + 32'd8;
            if (fcount == 3'd5) begin
                mem_req <= 0;
                fbusy <= 0;
                if (to_lpf)
                    lpf <= 288'({mem_data, fbuf[383:64]} >> (8 * faddr[2:0]));
                else begin
                    nxt <= 288'({mem_data, fbuf[383:64]} >> (8 * faddr[2:0]));
                    nxt_ok <= 1;
                end
                to_lpf <= 0;
            end
        end

        case (st)
        S_IDLE: ;
        S_DIR: if (mem_ack) begin
            trk_base <= BASE + be32(mem_data, 0);
            mem_addr <= BASE + be32(mem_data, 0);
            st <= S_HDR0;
        end
        S_HDR0: if (mem_ack) begin
            // 80 00 <copyright offset> 03 12 04 02: encoding 3, 18-byte frames, 4 bits, 2 channels
            if (mem_data[15:0] != 16'h0080 || mem_data[63:32] != 32'h0204_1203) begin
                mem_req <= 0;
                st <= S_IDLE;
            end else begin
                data_start <= trk_base + {16'd0, mem_data[23:16], mem_data[31:24]} + 32'd4;
                mem_addr <= trk_base + 32'h08;
                st <= S_HDR1;
            end
        end
        S_HDR1: if (mem_ack) begin
            n_samples <= be32(mem_data, 4);
            mem_addr <= trk_base + 32'h20;
            st <= S_HDR4;
        end
        S_HDR4: if (mem_ack) begin
            has_loop <= be32(mem_data, 4) != 0;
            mem_addr <= trk_base + 32'h28;
            st <= S_HDR5;
        end
        S_HDR5: if (mem_ack) begin
            loop_start <= be32(mem_data, 0);
            mem_addr <= trk_base + 32'h30;
            st <= S_HDR6;
        end
        S_HDR6: if (mem_ack) begin
            loop_end <= be32(mem_data, 0);
            mem_req <= 0;
            // fetch frame 0 into nxt
            faddr <= data_start;
            mem_addr <= {data_start[31:3], 3'd0};
            fcount <= 0;
            nxt_f <= 0;
            nxt_ok <= 0;
            to_lpf <= 0;
            st <= S_FIRST;
        end
        S_FIRST: begin
            if (!fbusy && !nxt_ok && !mem_req) begin
                mem_req <= 1;
                fbusy <= 1;
            end
            if (nxt_ok) begin
                cur <= nxt;
                cur_f <= 0;
                pos <= 0;
                h1_l <= 0; h2_l <= 0; h1_r <= 0; h2_r <= 0;
                saved <= 0;
                nxt_ok <= 0;
                // fetch the loop start's frame into lpf
                to_lpf <= 1;
                faddr <= data_start + 32'd36 * {5'd0, loop_start[31:5]};
                mem_addr <= (data_start + 32'd36 * {5'd0, loop_start[31:5]}) & ~32'd7;
                fcount <= 0;
                mem_req <= has_loop;
                fbusy <= has_loop;
                st <= S_LOOPF;
            end
        end
        S_LOOPF: if (!fbusy) begin
            // then prefetch frame 1 (S_PLAY issues it when it is needed)
            nxt_f <= 27'd1;
            faddr <= data_start + 32'd36;
            mem_addr <= (data_start + 32'd36) & ~32'd7;
            fcount <= 0;
            st <= S_PLAY;
        end
        S_PLAY: begin
            if (!fbusy && !nxt_ok && !mem_req && need_nxt) begin
                mem_req <= 1;
                fbusy <= 1;
            end
            if (tick && !pause) begin
                logic [31:0] p;
                logic [26:0] f;
                logic jump;
                jump = (pos == end_pos);
                p = jump ? loop_start : pos;
                f = p[31:5];
                if (jump && !has_loop) begin
                    // end of a track without a loop
                    out_l <= 0;
                    out_r <= 0;
                    st <= S_IDLE;
                end else if (!jump && f != cur_f && !(nxt_ok && nxt_f == f)) begin
                    underrun <= 1;                    // hold the output, try again next tick
                end else begin
                    logic [287:0] fr;
                    logic signed [15:0] a1, a2, b1, b2, sl, sr;
                    logic [4:0] i;
                    fr = jump ? lpf : (f != cur_f) ? nxt : cur;
                    i = p[4:0];
                    a1 = h1_l; a2 = h2_l; b1 = h1_r; b2 = h2_r;
                    if (jump) begin
                        looped <= 1;
                        if (LOOP_RESTORE) begin a1 = sv1_l; a2 = sv2_l; b1 = sv1_r; b2 = sv2_r; end
                    end
                    if (has_loop && p == loop_start && !saved) begin
                        sv1_l <= a1; sv2_l <= a2; sv1_r <= b1; sv2_r <= b2;
                        saved <= 1;
                    end
                    sl = adx_sample(fbyte(fr, 0),  fbyte(fr, 1),  fbyte(fr, 2 + int'(i[4:1])),  i[0], a1, a2);
                    sr = adx_sample(fbyte(fr, 18), fbyte(fr, 19), fbyte(fr, 20 + int'(i[4:1])), i[0], b1, b2);
                    out_l <= sl;
                    out_r <= sr;
                    h1_l <= sl; h2_l <= a1;
                    h1_r <= sr; h2_r <= b1;
                    pos <= p + 32'd1;
                    if (jump || f != cur_f) begin
                        // move to the prefetched (or loop start's) frame; fetch the one after it
                        cur <= fr;
                        cur_f <= f;
                        nxt_ok <= 0;
                        nxt_f <= f + 27'd1;
                        faddr <= data_start + 32'd36 * {5'd0, f + 27'd1};
                        mem_addr <= (data_start + 32'd36 * {5'd0, f + 27'd1}) & ~32'd7;
                        fcount <= 0;
                    end
                end
            end
        end
        default: st <= S_IDLE;
        endcase

        if (cmd_stop) begin
            st <= S_IDLE;
            mem_req <= 0;
            fbusy <= 0;
            out_l <= 0;
            out_r <= 0;
        end
        if (cmd_play) begin
            mem_addr <= BASE + 32'd8 + {25'd0, cmd_track, 3'd0};
            mem_req <= 1;
            fbusy <= 0;
            underrun <= 0;
            looped <= 0;
            out_l <= 0;
            out_r <= 0;
            st <= S_DIR;
        end
    end
end

endmodule

// adx_stream's read port on a ddr_if client (single-beat reads, `acquire` held for each read)
module adx_ddr_port(
    input               clk,
    input               reset,

    input        [31:0] mem_addr,
    input               mem_req,
    output reg          mem_ack,
    output reg   [63:0] mem_data,

    ddr_if.to_host      ddr
);

assign ddr.burstcnt = 8'd1;
assign ddr.byteenable = 8'hff;
assign ddr.write = 0;
assign ddr.wdata = 64'd0;

reg [1:0] st;   // 0 idle, 1 issue, 2 wait, 3 done (mem_req drops or moves on)

always_ff @(posedge clk) begin
    mem_ack <= 0;
    if (reset) begin
        st <= 0;
        ddr.acquire <= 0;
        ddr.read <= 0;
    end else case (st)
    0: if (mem_req && !mem_ack) begin
        ddr.acquire <= 1;
        st <= 1;
    end
    1: if (!ddr.busy) begin
        ddr.addr <= {mem_addr[31:3], 3'd0};
        ddr.read <= 1;
        st <= 2;
    end
    2: if (!ddr.busy) begin
        ddr.read <= 0;
        if (ddr.rdata_ready) begin
            mem_data <= ddr.rdata;
            mem_ack <= 1;
            ddr.acquire <= 0;
            st <= 0;
        end
    end
    default: st <= 0;
    endcase
end

endmodule

// adx_stream on a ddr_if (what the core instantiates; also the DDR testbench's top)
module adx_stream_ddr #(
    parameter bit [31:0] BASE = 32'h3400_0000,
    parameter bit LOOP_RESTORE = 1,
    parameter bit LOOP_END_INCL = 0
)(
    input               clk,
    input               reset,
    input               tick,
    input               cmd_play,
    input         [3:0] cmd_track,
    input               cmd_stop,
    input               pause,
    ddr_if.to_host      ddr,
    output signed [15:0] out_l,
    output signed [15:0] out_r,
    output              playing,
    output              underrun,
    output              looped
);

wire [31:0] mem_addr;
wire        mem_req, mem_ack;
wire [63:0] mem_data;

adx_stream #(.BASE(BASE), .LOOP_RESTORE(LOOP_RESTORE), .LOOP_END_INCL(LOOP_END_INCL)) stream(
    .clk, .reset, .tick, .cmd_play, .cmd_track, .cmd_stop, .pause,
    .mem_addr, .mem_req, .mem_ack, .mem_data,
    .out_l, .out_r, .playing, .underrun, .looped);

adx_ddr_port port(.clk, .reset, .mem_addr, .mem_req, .mem_ack, .mem_data, .ddr);

endmodule
