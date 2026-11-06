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

// The 68k in its own clock domain (CPU_ISLAND, the espgalarr core): fx68k on the 80 MHz CPU
// clock (one phase per clock, 40 MHz), with the memories it uses most on this clock and
// zero-wait: the program ROM cache (SDRAM behind it), the work RAM at 0x800000 and the
// 0xd00000 RAM (their CPU ports; the 60 MHz ports serve the sprite DMA and savestates).
//
// The 0xe00000 RAM's cache (xram_e_island) is on this clock too; only its misses go to DDR.
//
// Every other access crosses to the 60 MHz system as a request (toggle) carrying the bus
// cycle; PGM.sv replays it there as a 68k bus cycle on the existing device logic and returns
// the read data with an acknowledge (toggle).  The CPU waits on DTACK (VPA for an interrupt
// acknowledge) meanwhile.  The payload registers are stable from before each toggle until
// after its acknowledge, so only the toggles are timed across the clocks; the payloads are
// false paths (Arcade-IGSPGM.sdc).  The bridge and ROM handshakes use their first synchroniser
// stage directly: the clocks share a VCO, so the crossing is a timed register-to-register path.
//
// Other games keep 20 MHz: the CPU takes a phase every other clock.
module cpu_island (
    input             clk_cpu,

    // From the 60 MHz system, synchronised here
    input             reset_sys,        // reset | ss_reset
    input             run_sys,          // clocks_enabled (ss_cpu_execute | ~paused)
    input             unthrottled,      // static: GAME_ESPGALARR runs at 40 MHz
    input             ss_override_sys,
    input       [2:0] ipl_n_sys,
    input             br_n_sys,
    input             bgack_n_sys,
    input  game_t     game,             // static
    input             cart_present,     // static
    input      [22:0] cart_base_addr,   // static
    output            bg_n,

    // Slow path to the 60 MHz system
    output reg        bridge_req,       // toggles per request
    output reg [22:0] bridge_addr,
    output reg  [1:0] bridge_ds_n,
    output reg        bridge_rw,
    output reg  [2:0] bridge_fc,
    output reg [15:0] bridge_dout,
    input             bridge_ack_sys,   // toggles back when the cycle is done
    input      [15:0] bridge_din,       // read data, stable once bridge_ack_sys has toggled
    output reg        sv_fetch,         // toggles per supervisor program read from the ROM cache

    // Program ROM in SDRAM (channel 3)
    output reg [26:0] sdr_addr,
    output reg        sdr_req,
    input             sdr_ack,
    input      [63:0] sdr_data,

    // Work RAM 0x800000, CPU port (also serves NVRAM loads and saves)
    output     [15:0] wram_addr,
    output            wram_we_u_n,
    output            wram_we_l_n,
    output     [15:0] wram_d,
    input      [15:0] wram_q,

    // 0xd00000 RAM, CPU port
    output     [14:0] xd_addr,
    output            xd_we_u_n,
    output            xd_we_l_n,
    output     [15:0] xd_d,
    input      [15:0] xd_q,

    // 0xe00000 RAM (xram_e_island: a cache in front of DDR, also on this clock)
    output            xe_rd,
    output            xe_we_u,
    output            xe_we_l,
    output     [16:1] xe_addr,
    output     [15:0] xe_d,
    input      [15:0] xe_q,
    input             xe_ready,

    // NVRAM (the work RAM): writes arrive as a toggle with a held address/byte, reads use
    // the (slowly changing) HPS address; the word read back is held in nvram_q_word.
    input             nvram_wr_t_sys,
    input      [16:0] nvram_waddr,
    input       [7:0] nvram_wdata,
    input      [16:0] nvram_raddr,
    output reg [15:0] nvram_q_word
);

//////////////////////////////////
//// Synchronisers from the 60 MHz system

reg [1:0] reset_s, run_s, ovr_s, br_s, bgack_s, ack_s, nvw_s;
reg [2:0] ipl_s1, ipl_s2;
always_ff @(posedge clk_cpu) begin
    reset_s <= { reset_s[0], reset_sys };
    run_s   <= { run_s[0], run_sys };
    ovr_s   <= { ovr_s[0], ss_override_sys };
    br_s    <= { br_s[0], br_n_sys };
    bgack_s <= { bgack_s[0], bgack_n_sys };
    ack_s   <= { ack_s[0], bridge_ack_sys };
    nvw_s   <= { nvw_s[0], nvram_wr_t_sys };
    ipl_s1  <= ipl_n_sys;
    ipl_s2  <= ipl_s1;
end
wire reset = reset_s[1];

//////////////////////////////////
//// Phases

reg ce_phi1, ce_phi2, phase, half;
always_ff @(posedge clk_cpu) begin
    ce_phi1 <= 0;
    ce_phi2 <= 0;
    half <= ~half;
    if (run_s[1] && (unthrottled || half)) begin
        ce_phi1 <= ~phase;
        ce_phi2 <= phase;
        phase <= ~phase;
    end
end

//////////////////////////////////
//// CPU

wire        cpu_rw, cpu_as_n;
wire [1:0]  cpu_ds_n;
wire [2:0]  cpu_fc;
wire [15:0] cpu_data_out;
wire [22:0] cpu_addr;
wire [23:0] cpu_word_addr = { cpu_addr, 1'b0 };
reg  [15:0] cpu_din_r;
reg         dtack_n_r = 1, vpa_n_r = 1;

fx68k m68000(
    .clk(clk_cpu),
    .HALTn(1),
    .extReset(reset),
    .pwrUp(reset),
    .enPhi1(ce_phi1),
    .enPhi2(ce_phi2),

    .eRWn(cpu_rw), .ASn(cpu_as_n), .LDSn(cpu_ds_n[0]), .UDSn(cpu_ds_n[1]),
    .E(), .VMAn(),

    .FC0(cpu_fc[0]), .FC1(cpu_fc[1]), .FC2(cpu_fc[2]),
    .BGn(bg_n),
    .oRESETn(), .oHALTEDn(),
    .DTACKn(dtack_n_r), .VPAn(vpa_n_r),
    .BERRn(1),
    .BRn(br_s[1]), .BGACKn(bgack_s[1]),
    .IPL0n(ipl_s2[0]), .IPL1n(ipl_s2[1]), .IPL2n(ipl_s2[2]),
    .iEdb(cpu_din_r), .oEdb(cpu_data_out),
    .eab(cpu_addr)
);

//////////////////////////////////
//// Decode (the same decoder as the system side, on the CPU's own address)

logic ROMn, WORKRAMn, XRAM_Dn, XRAM_En, SS_SAVEn, SS_RESETn, SS_VECn;

address_translator address_translator(
    .game,
    .cpu_ds_n,
    .cpu_word_addr,
    .ss_override(ovr_s[1]),
    .WORKRAMn, .ROMn, .IOn(), .IGS023n(), .IGS026_Xn(), .IGS025n(), .IGS022_RAMn(),
    .ARM_SHAREn(), .ARM_LATCHn(), .ARM_NMIn(), .XRAM_Dn, .XRAM_En,
    .SS_SAVEn, .SS_RESETn, .SS_VECn
);

wire iack      = &cpu_fc;
wire ss_region = ~SS_SAVEn | ~SS_RESETn | ~SS_VECn;
wire rom_sel   = ~ROMn & ~ss_region & ~iack;
wire wram_sel  = ~WORKRAMn & ~ss_region & ~iack;
wire xd_sel    = ~XRAM_Dn & ~ss_region & ~iack;
wire xe_sel    = ~XRAM_En & ~ss_region & ~iack;
wire fast      = rom_sel | wram_sel | xd_sel | xe_sel;
wire ds_low    = ~&cpu_ds_n;

//////////////////////////////////
//// Program ROM cache: 2048 x 8-byte lines, direct mapped, looked up every clock so that a hit
//// answers in the clock after AS (zero wait states)

localparam CACHE_WIDTH = 11;
reg  [1:0]  version;
reg  [63:0] cache_data[2**CACHE_WIDTH];
reg  [11:0] cache_tag[2**CACHE_WIDTH];      // { version, address bits 22:13 }
reg  [63:0] cache_line;
reg  [11:0] cached_tag;
reg  [22:0] addr_q;                         // the address cache_line/cached_tag were read for

wire [CACHE_WIDTH-1:0] index   = cpu_addr[CACHE_WIDTH+1:2];
wire [11:0]            tag_of  = { version, addr_q[22:13] };
wire                   rom_hit = (cached_tag == tag_of) && (addr_q == cpu_addr);
wire [15:0] rom_word = addr_q[1:0] == 2'd0 ? cache_line[15:0]  :
                       addr_q[1:0] == 2'd1 ? cache_line[31:16] :
                       addr_q[1:0] == 2'd2 ? cache_line[47:32] : cache_line[63:48];

typedef enum bit [1:0] { RC_IDLE, RC_REQ, RC_WAIT, RC_SETTLE } rc_state_t;
rc_state_t rc_state = RC_IDLE;
reg [1:0]  sdr_ack_s;
reg [CACHE_WIDTH-1:0] fill_index;
reg [11:0] fill_tag;
reg        prev_reset;

always_ff @(posedge clk_cpu) begin
    cache_line <= cache_data[index];
    cached_tag <= cache_tag[index];
    addr_q     <= cpu_addr;
    sdr_ack_s  <= { sdr_ack_s[0], sdr_ack };
    prev_reset <= reset;

    if (reset) begin
        rc_state <= RC_IDLE;
        if (~prev_reset) version <= version + 2'd1;
    end else begin
        case (rc_state)
            RC_IDLE: if (rom_sel && ~cpu_as_n && addr_q == cpu_addr && ~rom_hit) begin
                // the address goes out a clock before the request toggles
                if (cart_present && (cpu_addr >= cart_base_addr))
                    sdr_addr <= CART_PROG_ROM_SDR_BASE[26:0] + { 3'b0, cpu_addr[22:2] - cart_base_addr[22:2], 3'b000 };
                else
                    sdr_addr <= BIOS_PROG_ROM_SDR_BASE[26:0] + { 3'b0, cpu_addr[22:2], 3'b000 };
                fill_index <= index;
                fill_tag   <= tag_of;
                rc_state   <= RC_REQ;
            end
            RC_REQ: begin
                sdr_req  <= ~sdr_req;
                rc_state <= RC_WAIT;
            end
            RC_WAIT: if (sdr_ack_s[0] == sdr_req) begin
                cache_data[fill_index] <= sdr_data;
                cache_tag[fill_index]  <= fill_tag;
                rc_state <= RC_SETTLE;
            end
            RC_SETTLE: rc_state <= RC_IDLE;      // the line is read again before the next look-up
        endcase
    end
end

//////////////////////////////////
//// Work RAM and 0xd00000 RAM ports; the work RAM port serves NVRAM while the CPU is elsewhere

wire cpu_wram = ~cpu_as_n & wram_sel;
reg  nvw_seen, nv_rd_d;
reg  [16:0] nv_rd_addr_d;
wire nv_write = ~cpu_wram & (nvw_s[1] != nvw_seen);

assign wram_addr   = cpu_wram ? cpu_addr[15:0] : nv_write ? nvram_waddr[16:1] : nvram_raddr[16:1];
assign wram_d      = cpu_wram ? cpu_data_out : { nvram_wdata, nvram_wdata };
assign wram_we_u_n = cpu_wram ? (cpu_rw | cpu_ds_n[1]) : ~(nv_write & nvram_waddr[0]);   // odd NVRAM byte = D15:8
assign wram_we_l_n = cpu_wram ? (cpu_rw | cpu_ds_n[0]) : ~(nv_write & ~nvram_waddr[0]);

always_ff @(posedge clk_cpu) begin
    if (nv_write) nvw_seen <= nvw_s[1];
    nv_rd_d      <= ~cpu_wram & ~nv_write;
    nv_rd_addr_d <= nvram_raddr;
    if (nv_rd_d && nv_rd_addr_d == nvram_raddr) nvram_q_word <= wram_q;
end

assign xe_rd     = ~cpu_as_n & xe_sel & cpu_rw;
assign xe_we_u   = ~cpu_as_n & xe_sel & ~cpu_rw & ~cpu_ds_n[1];
assign xe_we_l   = ~cpu_as_n & xe_sel & ~cpu_rw & ~cpu_ds_n[0];
assign xe_addr   = cpu_addr[15:0];
assign xe_d      = cpu_data_out;

assign xd_addr   = cpu_addr[14:0];
assign xd_d      = cpu_data_out;
assign xd_we_u_n = ~(~cpu_as_n & xd_sel) | cpu_rw | cpu_ds_n[1];
assign xd_we_l_n = ~(~cpu_as_n & xd_sel) | cpu_rw | cpu_ds_n[0];

//////////////////////////////////
//// Slow path

reg ds_low_d, as_n_d;
reg pending, done;
reg [15:0] bridge_din_r;

always_ff @(posedge clk_cpu) begin
    ds_low_d <= ds_low & ~cpu_as_n;
    as_n_d   <= cpu_as_n;

    if (reset) begin
        pending <= 0;
        done <= 0;
    end else begin
        // a new data strobe (reads: with AS; writes: two phases later; TAS: once per half)
        if (~cpu_as_n & ds_low & ~ds_low_d & ~fast & ~pending) begin
            bridge_addr <= cpu_addr;
            bridge_ds_n <= cpu_ds_n;
            bridge_rw   <= cpu_rw;
            bridge_fc   <= cpu_fc;
            bridge_dout <= cpu_data_out;
            bridge_req  <= ~bridge_req;
            pending     <= 1;
            done        <= 0;
        end else if (pending & ~done & (ack_s[0] == bridge_req)) begin
            done <= 1;
            bridge_din_r <= bridge_din;
        end else if (pending & done & (cpu_as_n | ~ds_low)) begin
            pending <= 0;
            done    <= 0;
        end
    end

    // a supervisor program read from the ROM cache, for the savestate sequencer
    if (as_n_d & ~cpu_as_n & rom_sel & cpu_rw & (cpu_fc == 3'b110)) sv_fetch <= ~sv_fetch;
end

//////////////////////////////////
//// Read data and DTACK/VPA, registered

always_ff @(posedge clk_cpu) begin
    cpu_din_r <= rom_sel  ? rom_word :
                 wram_sel ? wram_q :
                 xd_sel   ? xd_q :
                 xe_sel   ? xe_q :
                            bridge_din_r;

    dtack_n_r <= ~(~cpu_as_n & ((rom_sel & rom_hit) | wram_sel | xd_sel | (xe_sel & ds_low & xe_ready) | (~fast & ~iack & pending & done)));
    vpa_n_r   <= ~(~cpu_as_n & iack & pending & done);
end

endmodule
