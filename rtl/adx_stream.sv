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
//
//  Volume and fades as the PS2's stream manager (ELF 0x12D8B0): a stream plays at game volume
//  220 of 256 (-1 dB); a fade takes 4 off every 60 Hz frame (800 samples) with the CRI volume
//  trunc(-20 log10(256 / v)) dB (gain table below), then stops; a play request while a stream plays fades it out
//  and starts the new track after. gout_l / gout_r carry that gain; out_l / out_r are the raw
//  decode (the bit-exact tests).
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
    input               cmd_fade,       // fade out (55 frames), then stop
    input               pause,

    output reg   [31:0] mem_addr,
    output reg          mem_req,
    input               mem_ack,
    input        [63:0] mem_data,

    output reg signed [15:0] out_l,
    output reg signed [15:0] out_r,
    output reg signed [15:0] gout_l,    // out_l / out_r at the PS2's stream volume (fades)
    output reg signed [15:0] gout_r,
    output              playing,
    output reg          underrun,       // a frame was not fetched in time (sticky until play)
    output reg          looped,         // the loop jump happened (sticky until play)

    // savestates (adx_stream_ddr's ssbus slot): 6 x 64-bit words of state; the frames are not
    // saved (a restored S_PLAY re-fetches the current and the loop start's frames)
    output [383:0]      ss_words,
    input               ss_wr,
    input         [2:0] ss_widx,
    input        [63:0] ss_wdata
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
    S_IDLE, S_DIR, S_HDR0, S_HDR1, S_HDR4, S_HDR5, S_HDR6, S_FIRST, S_LOOPF, S_PLAY, S_RESUME
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

function automatic signed [4:0] nibble(input [7:0] b, input odd);   // high nibble first
    nibble = odd ? $signed({b[3], b[3:0]}) : $signed({b[7], b[7:4]});
endfunction

function automatic signed [15:0] clamp16(input signed [31:0] s);
    clamp16 = (s > 32'sd32767) ? 16'sh7fff : (s < -32'sd32768) ? -16'sh8000 : s[15:0];
endfunction

// decode pipeline registers
reg  [1:0]        dph;
reg               d_jump, d_odd;
reg  [31:0]       d_p;
reg signed [15:0] d_a1, d_a2, d_b1, d_b2;
reg  [12:0]       d_scl, d_scr;      // scale word & 0x1FFF (+1 in stage 3)
reg  [7:0]        d_nbl, d_nbr;
reg signed [31:0] m1l, m2l, mnl, m1r, m2r, mnr;
reg               ss_was_playing;

// PS2 stream volume: v = 4 * fv (fv 55 = 220 = -1 dB). The CRI player's gain, measured on the
// PCSX2 SPU2 input (bit-exact over the stage 1 fade and the boss track's loop): Q12
// k = int(4096 * 10^(dB / 20)) & ~15 with dB = trunc(-20 log10(256 / v)); out = (s * k) >> 12
reg  [5:0] fv;
reg        fading, queued;
reg  [3:0] qtrack;
reg  [9:0] fcnt;
reg        fade_start;                // start the queued track (end of a fade)

function automatic [11:0] fade_gain(input [5:0] k);
    case (k)
    0: fade_gain = 12'd0;
    1: fade_gain = 12'd64;
    2: fade_gain = 12'd128;
    3: fade_gain = 12'd192;
    4: fade_gain = 12'd256;
    5: fade_gain = 12'd320;
    6: fade_gain = 12'd400;
    7: fade_gain = 12'd448;
    8: fade_gain = 12'd512;
    9: fade_gain = 12'd576;
    10: fade_gain = 12'd640;
    11: fade_gain = 12'd720;
    12: fade_gain = 12'd816;
    13, 14: fade_gain = 12'd912;
    15, 16: fade_gain = 12'd1024;
    17, 18: fade_gain = 12'd1152;
    19, 20: fade_gain = 12'd1280;
    21, 22: fade_gain = 12'd1440;
    23, 24, 25: fade_gain = 12'd1616;
    26, 27, 28: fade_gain = 12'd1824;
    29, 30, 31, 32: fade_gain = 12'd2048;
    33, 34, 35: fade_gain = 12'd2288;
    36, 37, 38, 39, 40: fade_gain = 12'd2576;
    41, 42, 43, 44, 45: fade_gain = 12'd2896;
    46, 47, 48, 49, 50: fade_gain = 12'd3248;
    default: fade_gain = 12'd3648;
    endcase
endfunction

reg [11:0] gain;
always_ff @(posedge clk) begin
    logic signed [28:0] gl, gr;
    gain <= fade_gain(fv);
    gl = out_l * $signed({1'b0, gain});
    gr = out_r * $signed({1'b0, gain});
    gout_l <= gl[27:12];
    gout_r <= gr[27:12];
end

assign ss_words = {
    {h1_l, h2_l, h1_r, h2_r},                                                   // 5
    {sv1_l, sv2_l, sv1_r, sv2_r},                                               // 4
    {loop_end, 5'd0, cur_f},                                                    // 3
    {n_samples, loop_start},                                                    // 2
    {trk_base, data_start},                                                     // 1
    {2'd0, fcnt, qtrack, queued, fading, fv, (st == S_PLAY || st == S_RESUME) ? 4'd1 : 4'd0, has_loop, saved, looped, underrun, pos}  // 0
};


always_ff @(posedge clk) begin
    if (reset) begin
        st <= S_IDLE;
        mem_req <= 0;
        fbusy <= 0;
        out_l <= 0;
        out_r <= 0;
        underrun <= 0;
        looped <= 0;
        dph <= 2'd0;
        fv <= 6'd55;
        fading <= 0;
        queued <= 0;
        fade_start <= 0;
    end else begin
        fade_start <= 0;
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
            // then prefetch the frame after cur (S_PLAY issues it when it is needed)
            nxt_f <= cur_f + 27'd1;
            faddr <= data_start + 32'd36 * {5'd0, cur_f + 27'd1};
            mem_addr <= (data_start + 32'd36 * {5'd0, cur_f + 27'd1}) & ~32'd7;
            fcount <= 0;
            st <= S_PLAY;
        end
        S_RESUME: begin
            // after a savestate restore: fetch the current frame, then the loop start's (S_LOOPF)
            if (!fbusy && !nxt_ok && !mem_req) begin
                mem_req <= 1;
                fbusy <= 1;
            end
            if (nxt_ok) begin
                cur <= nxt;
                nxt_ok <= 0;
                to_lpf <= 1;
                faddr <= data_start + 32'd36 * {5'd0, loop_start[31:5]};
                mem_addr <= (data_start + 32'd36 * {5'd0, loop_start[31:5]}) & ~32'd7;
                fcount <= 0;
                mem_req <= has_loop;
                fbusy <= has_loop;
                st <= S_LOOPF;
            end
        end
        S_PLAY: begin
            if (!fbusy && !nxt_ok && !mem_req && need_nxt) begin
                mem_req <= 1;
                fbusy <= 1;
            end
            // decode pipeline, one stereo sample per tick (1250 clocks apart on the core):
            // 1 the jump, 2 the bytes / history / frame swap, 3 the products, 4 sum and clamp
            case (dph)
            2'd0: if (tick && !pause) begin
                if (fading) begin
                    fcnt <= (fcnt == 10'd799) ? 10'd0 : fcnt + 10'd1;
                    if (fcnt == 10'd799) begin
                        fv <= fv - 6'd1;
                        if (fv == 6'd1) fade_start <= 1;      // the end of the fade (below)
                    end
                end
                d_jump <= (pos == end_pos);
                d_p <= (pos == end_pos) ? loop_start : pos;
                dph <= 2'd1;
            end
            2'd1: begin
                logic [26:0] f;
                f = d_p[31:5];
                if (d_jump && !has_loop) begin
                    // end of a track without a loop
                    out_l <= 0;
                    out_r <= 0;
                    st <= S_IDLE;
                    dph <= 2'd0;
                end else if (!d_jump && f != cur_f && !(nxt_ok && nxt_f == f)) begin
                    underrun <= 1;                    // hold the output, try again next tick
                    dph <= 2'd0;
                end else begin
                    logic [287:0] fr;
                    logic signed [15:0] a1, a2, b1, b2;
                    logic [4:0] i;
                    logic [7:0] hl, hr;
                    fr = d_jump ? lpf : (f != cur_f) ? nxt : cur;
                    i = d_p[4:0];
                    a1 = h1_l; a2 = h2_l; b1 = h1_r; b2 = h2_r;
                    if (d_jump) begin
                        looped <= 1;
                        if (LOOP_RESTORE) begin a1 = sv1_l; a2 = sv2_l; b1 = sv1_r; b2 = sv2_r; end
                    end
                    if (has_loop && d_p == loop_start && !saved) begin
                        sv1_l <= a1; sv2_l <= a2; sv1_r <= b1; sv2_r <= b2;
                        saved <= 1;
                    end
                    d_a1 <= a1; d_a2 <= a2; d_b1 <= b1; d_b2 <= b2;
                    hl = fbyte(fr, 0);
                    hr = fbyte(fr, 18);
                    d_scl <= {hl[4:0], fbyte(fr, 1)};
                    d_scr <= {hr[4:0], fbyte(fr, 19)};
                    d_nbl <= fbyte(fr, 2 + int'(i[4:1]));
                    d_nbr <= fbyte(fr, 20 + int'(i[4:1]));
                    d_odd <= i[0];
                    pos <= d_p + 32'd1;
                    if (d_jump || f != cur_f) begin
                        // move to the prefetched (or loop start's) frame; fetch the one after it
                        cur <= fr;
                        cur_f <= f;
                        nxt_ok <= 0;
                        nxt_f <= f + 27'd1;
                        faddr <= data_start + 32'd36 * {5'd0, f + 27'd1};
                        mem_addr <= (data_start + 32'd36 * {5'd0, f + 27'd1}) & ~32'd7;
                        fcount <= 0;
                    end
                    dph <= 2'd2;
                end
            end
            2'd2: begin
                m1l <= 32'(C1) * 32'(d_a1);
                m2l <= 32'(C2) * 32'(d_a2);
                mnl <= 32'(nibble(d_nbl, d_odd)) * 32'($signed({2'b00, d_scl}) + 15'sd1);
                m1r <= 32'(C1) * 32'(d_b1);
                m2r <= 32'(C2) * 32'(d_b2);
                mnr <= 32'(nibble(d_nbr, d_odd)) * 32'($signed({2'b00, d_scr}) + 15'sd1);
                dph <= 2'd3;
            end
            2'd3: begin
                logic signed [15:0] sl, sr;
                sl = clamp16(((m1l + m2l) >>> 12) + mnl);
                sr = clamp16(((m1r + m2r) >>> 12) + mnr);
                out_l <= sl;
                out_r <= sr;
                h1_l <= sl; h2_l <= d_a1;
                h1_r <= sr; h2_r <= d_b1;
                dph <= 2'd0;
            end
            endcase
        end
        default: st <= S_IDLE;
        endcase

        if (cmd_stop) begin
            st <= S_IDLE;
            dph <= 2'd0;
            mem_req <= 0;
            fbusy <= 0;
            out_l <= 0;
            out_r <= 0;
            fading <= 0;
            queued <= 0;
        end
        if (cmd_fade && st != S_IDLE && !fading) begin
            fading <= 1;
            fcnt <= 0;
        end
        // a play request while a stream plays: fade it out, then the new track (the PS2's)
        if (cmd_play && st != S_IDLE) begin
            queued <= 1;
            qtrack <= cmd_track;
            if (!fading) begin
                fading <= 1;
                fcnt <= 0;
            end
        end
        if ((cmd_play && st == S_IDLE) || fade_start) begin
            // the fade has ended (fv 0): the queued track, else silence
            dph <= 2'd0;
            fading <= 0;
            queued <= 0;
            fv <= 6'd55;
            out_l <= 0;
            out_r <= 0;
            if (fade_start && !queued) begin
                st <= S_IDLE;
                mem_req <= 0;
                fbusy <= 0;
            end else begin
                mem_addr <= BASE + 32'd8 + {25'd0, fade_start ? qtrack : cmd_track, 3'd0};
                mem_req <= 1;
                fbusy <= 0;
                underrun <= 0;
                looped <= 0;
                st <= S_DIR;
            end
        end

        if (ss_wr) begin
            case (ss_widx)
            3'd0: begin
                pos <= ss_wdata[31:0];
                underrun <= ss_wdata[32];
                looped <= ss_wdata[33];
                saved <= ss_wdata[34];
                has_loop <= ss_wdata[35];
                // a playing stream resumes after the last word (5): its frames are fetched again
                ss_was_playing <= ss_wdata[36];
                fv <= ss_wdata[45:40];
                fading <= ss_wdata[46];
                queued <= ss_wdata[47];
                qtrack <= ss_wdata[51:48];
                fcnt <= ss_wdata[61:52];
                st <= S_IDLE;
                mem_req <= 0;
                fbusy <= 0;
                nxt_ok <= 0;
                to_lpf <= 0;
                dph <= 2'd0;
            end
            3'd1: begin trk_base <= ss_wdata[63:32]; data_start <= ss_wdata[31:0]; end
            3'd2: begin n_samples <= ss_wdata[63:32]; loop_start <= ss_wdata[31:0]; end
            3'd3: begin
                loop_end <= ss_wdata[63:32];
                cur_f <= ss_wdata[26:0];
                // S_RESUME fetches frame cur_f into nxt
                nxt_f <= ss_wdata[26:0];
                faddr <= data_start + 32'd36 * {5'd0, ss_wdata[26:0]};
                mem_addr <= (data_start + 32'd36 * {5'd0, ss_wdata[26:0]}) & ~32'd7;
                fcount <= 0;
            end
            3'd4: begin sv1_l <= ss_wdata[63:48]; sv2_l <= ss_wdata[47:32]; sv1_r <= ss_wdata[31:16]; sv2_r <= ss_wdata[15:0]; end
            3'd5: begin
                h1_l <= ss_wdata[63:48]; h2_l <= ss_wdata[47:32]; h1_r <= ss_wdata[31:16]; h2_r <= ss_wdata[15:0];
                st <= ss_was_playing ? S_RESUME : S_IDLE;
            end
            default: ;
            endcase
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
    parameter bit LOOP_END_INCL = 0,
    parameter int SS_IDX = -1
)(
    input               clk,
    input               reset,
    input               tick,
    input               cmd_play,
    input         [3:0] cmd_track,
    input               cmd_stop,
    input               cmd_fade,
    input               pause,
    ddr_if.to_host      ddr,
    output signed [15:0] out_l,
    output signed [15:0] out_r,
    output signed [15:0] gout_l,
    output signed [15:0] gout_r,
    output              playing,
    output              underrun,
    output              looped,

    // savestates: the stream's 6 state words + one word of the caller's (the port registers)
    ssbus_if.slave      ssbus,
    input        [63:0] ss_ext_in,
    output reg   [63:0] ss_ext_out,
    output reg          ss_ext_load
);

wire [383:0] ss_words;
reg          ss_wr;
reg    [2:0] ss_widx;
reg   [63:0] ss_wdata;

always_ff @(posedge clk) begin
    ssbus.setup(SS_IDX, 7, 3);           // 7 x 64-bit words
    ss_wr <= 0;
    ss_ext_load <= 0;
    if (ssbus.access(SS_IDX)) begin
        if (ssbus.write) begin
            if (ssbus.addr == 6) begin
                ss_ext_out <= ssbus.data;
                ss_ext_load <= 1;
            end else begin
                ss_wr <= 1;
                ss_widx <= ssbus.addr[2:0];
                ss_wdata <= ssbus.data;
            end
            ssbus.write_ack(SS_IDX);
        end else if (ssbus.read) begin
            ssbus.read_response(SS_IDX, ssbus.addr == 6 ? ss_ext_in : ss_words[64 * ssbus.addr[2:0] +: 64]);
        end
    end
end

wire [31:0] mem_addr;
wire        mem_req, mem_ack;
wire [63:0] mem_data;

adx_stream #(.BASE(BASE), .LOOP_RESTORE(LOOP_RESTORE), .LOOP_END_INCL(LOOP_END_INCL)) stream(
    .clk, .reset, .tick, .cmd_play, .cmd_track, .cmd_stop, .cmd_fade, .pause,
    .mem_addr, .mem_req, .mem_ack, .mem_data,
    .out_l, .out_r, .gout_l, .gout_r, .playing, .underrun, .looped,
    .ss_words, .ss_wr, .ss_widx, .ss_wdata);

adx_ddr_port port(.clk, .reset, .mem_addr, .mem_req, .mem_ack, .mem_data, .ddr);

endmodule
