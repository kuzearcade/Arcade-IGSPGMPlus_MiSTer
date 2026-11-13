//============================================================================
//  Copyright (C) 2026 Martin Donlon
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.
//============================================================================

import system_consts::*;

// CPU_ISLAND: the espgalarr 128KB work RAM at 0xe00000 on the 68k's clock.  One write-back
// ram_cache (512 x 32-byte lines, as the two 256-line caches it replaces) in front of DDR at
// PROT_SHARE_DDR_BASE (the same layout as espgalarr_xram's two 64KB chips), so a hit answers in
// the clock after the island's bus stage sees AS.  Misses go to DDR
// through ddr_cdc; savestate accesses arrive from the 60 MHz side as toggles (xram_e_ss_bridge)
// and take the cache port while the 68k is not using it (the system is paused then).
module xram_e_island (
    input             clk,              // CPU clock
    input             reset_sys,        // registered on the 60 MHz side

    input             cpu_rd,           // AS asserted, read
    input             cpu_wr,           // AS asserted, write (the line is fetched from here on)
    input             cpu_we_u,         // DS asserted, write
    input             cpu_we_l,
    input      [16:1] cpu_addr,
    input      [15:0] cpu_din,
    output     [15:0] cpu_q,
    output            cpu_ready,

    input             ss_req_sys,       // toggles per savestate access
    input             ss_wr,            // payload, held from before the toggle
    input      [14:0] ss_addr,          // 32-bit word
    input      [31:0] ss_wdata,
    output reg        ss_ack,           // toggles back when done
    output reg [31:0] ss_rdata,

    ddr_if.to_host    ddr
);
    reg [1:0] reset_s, ss_s;
    always_ff @(posedge clk) begin
        reset_s <= { reset_s[0], reset_sys };
        ss_s    <= { ss_s[0], ss_req_sys };
    end

    // (the CPU's signals come from cpu_island's bus stage registers.) A savestate access takes
    // the port from the clock after it is seen (ss_pend, registered, so that the selection of
    // the cache's address is not behind a comparison), while the CPU is not using it.
    wire        cpu_on = cpu_rd | cpu_wr;
    reg         ss_pend = 0;
    wire        ss_go  = ss_pend & ~cpu_on;
    wire        hi     = ~cpu_addr[1];       // even halfword = bits 31:16 of the 32-bit word

    wire        rd_req  = ss_go ? ~ss_wr : cpu_rd;
    wire        wr_req  = ss_go ?  ss_wr : cpu_wr;
    wire [31:0] addr    = PROT_SHARE_DDR_BASE + (ss_go ? { 15'd0, ss_addr, 2'b00 } : { 15'd0, cpu_addr[16:2], 2'b00 });
    wire [31:0] wdata   = ss_go ? ss_wdata : { cpu_din, cpu_din };
    wire  [3:0] be      = ss_go ? 4'hf : (hi ? { cpu_we_u, cpu_we_l, 2'b00 } : { 2'b00, cpu_we_u, cpu_we_l });

    wire [31:0] rd_data;
    wire        rd_ready, wr_ready;

    ram_cache #(.LINES(512), .EARLY_LOOKUP(1)) cache (
        .clk, .reset(reset_s[1]),
        .rd_req, .rd_addr(addr), .rd_data, .rd_ready,
        .wr_req, .wr_addr(addr), .wr_data(wdata), .wr_be(be), .wr_ready,
        .ddr
    );

    assign cpu_q     = hi ? rd_data[31:16] : rd_data[15:0];
    assign cpu_ready = ~ss_go & rd_ready & wr_ready;

    // a savestate access completes when the cache reports ready with the request held (it is
    // held for at least the clock in which ready is seen)
    reg ss_busy;
    always_ff @(posedge clk) begin
        ss_pend <= (ss_s[1] != ss_ack);
        if (reset_s[1]) begin
            ss_busy <= 0;
            ss_ack  <= ss_s[1];
            ss_pend <= 0;
        end else if (ss_go) begin
            if (ss_busy & rd_ready & wr_ready) begin
                ss_rdata <= rd_data;
                ss_ack   <= ss_s[1];
                ss_busy  <= 0;
                ss_pend  <= 0;
            end else begin
                ss_busy <= 1;
            end
        end
    end
endmodule

// The savestate side of xram_e_island, on the 60 MHz clock: 32768 x 32-bit words, word
// address bit 14 = chip, as espgalarr_xram.
module xram_e_ss_bridge #(parameter SS_IDX = -1) (
    input             clk,
    input             reset,
    input             ss_paused,
    ssbus_if.slave    ssbus,

    output reg        ss_req,
    output reg        ss_wr,
    output reg [14:0] ss_addr,
    output reg [31:0] ss_wdata,
    input             ss_ack_cpu,
    input      [31:0] ss_rdata
);
    wire ss_sel = ss_paused & (ssbus.select == SS_IDX[7:0]) & ~ssbus.query & (ssbus.read | ssbus.write);
    reg  [1:0] ack_s;

    typedef enum logic [1:0] { SH_IDLE, SH_BUSY, SH_WAIT } sh_t;
    sh_t sh_state;
    always_ff @(posedge clk) begin
        ssbus.setup(SS_IDX, 32'd32768, 2);   // 2x 64KB chips
        ack_s <= { ack_s[0], ss_ack_cpu };
        if (reset) begin
            sh_state <= SH_IDLE;
        end else begin
            case (sh_state)
                SH_IDLE: if (ss_sel) begin
                    ss_wr    <= ssbus.write;
                    ss_addr  <= ssbus.addr[14:0];
                    ss_wdata <= ssbus.data[31:0];
                    ss_req   <= ~ss_req;
                    sh_state <= SH_BUSY;
                end
                SH_BUSY: if (ack_s[1] == ss_req) begin
                    if (ss_wr) ssbus.write_ack(SS_IDX);
                    else       ssbus.read_response(SS_IDX, { 32'd0, ss_rdata });
                    sh_state <= SH_WAIT;
                end
                SH_WAIT: if (~(ssbus.read | ssbus.write)) sh_state <= SH_IDLE;
                default: sh_state <= SH_IDLE;
            endcase
        end
    end
endmodule

// A ddr_if crossing for one master that issues single-beat writes and 4-beat read bursts
// (ram_cache).  The master side (clk_a) accepts a command in the clock it sees read/write with
// busy low, then stays busy until the far side (clk_b) has done it; a read's four beats come
// back as four consecutive rdata_ready clocks.  Command and data payloads are held across each
// toggle (false paths in the sdc); the toggles cross through two-flop synchronisers.
module ddr_cdc (
    input             clk_a,
    ddr_if.from_host  a,
    input             clk_b,
    ddr_if.to_host    b
);
    // side A
    reg        req = 0, busy_a = 0, rd_a, emitting = 0;
    reg  [1:0] ack_s, beat_a;
    reg [31:0] addr_a;
    reg [63:0] wdata_a;
    reg  [7:0] be_a;
    reg [63:0] rbuf [4];
    reg        ack_b = 0;

    assign a.busy  = busy_a;
    assign a.rdata = rbuf[beat_a];
    assign a.rdata_ready = emitting;

    always_ff @(posedge clk_a) begin
        ack_s <= { ack_s[0], ack_b };
        if (~busy_a) begin
            if (a.read | a.write) begin
                rd_a    <= a.read;
                addr_a  <= a.addr;
                wdata_a <= a.wdata;
                be_a    <= a.byteenable;
                req     <= ~req;
                busy_a  <= 1;
            end
        end else if (~emitting & (ack_s[1] == req)) begin
            if (rd_a) begin
                emitting <= 1;
                beat_a   <= 0;
            end else begin
                busy_a <= 0;
            end
        end else if (emitting) begin
            beat_a <= beat_a + 2'd1;
            if (beat_a == 2'd3) begin
                emitting <= 0;
                busy_a   <= 0;
            end
        end
    end

    // side B
    reg  [1:0] req_s;
    reg        seen = 0, active = 0, issued = 0;
    reg  [1:0] beat_b;
    assign b.acquire    = active;
    assign b.addr       = addr_a;
    assign b.wdata      = wdata_a;
    assign b.byteenable = be_a;
    assign b.burstcnt   = rd_a ? 8'd4 : 8'd1;
    assign b.read       = active & ~issued & rd_a;
    assign b.write      = active & ~issued & ~rd_a;

    always_ff @(posedge clk_b) begin
        req_s <= { req_s[0], req };
        if (~active) begin
            if (req_s[1] != seen) begin
                seen   <= req_s[1];
                active <= 1;
                issued <= 0;
                beat_b <= 0;
            end
        end else begin
            if (~issued & ~b.busy) begin
                issued <= 1;
                if (~rd_a) begin
                    active <= 0;
                    ack_b  <= seen;
                end
            end
            if (issued & rd_a & b.rdata_ready) begin
                rbuf[beat_b] <= b.rdata;
                beat_b <= beat_b + 2'd1;
                if (beat_b == 2'd3) begin
                    active <= 0;
                    ack_b  <= seen;
                end
            end
        end
    end
endmodule
