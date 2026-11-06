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

module IGS026_X #(parameter int SS_IDX = -1)(
    input clk,
    input reset,
    input ss_restore,

    // CPU interface
    input [23:0] cpu_addr,
    input [15:0] cpu_din,
    output logic [15:0] cpu_dout,
    input cpu_lds_n,
    input cpu_uds_n,
    input cpu_rw,
    input cpu_cs_n,


    output logic v3021_cs_n,
    output logic v3021_wr_n,
    output logic v3021_dout,
    input  v3021_din,

    output logic aram_lds_n,
    output logic aram_uds_n,
    output logic [14:0] aram_addr,
    input  logic [15:0] aram_din,
    output logic [15:0] aram_dout,

    output z80_reset_n,
    output logic z80_wait_n,
    output logic z80_busrq_n,
    input z80_busak_n,
    output logic z80_int_n,
    output reg z80_nmi_n,
    input z80_mreq_n,
    input z80_iorq_n,
    input z80_rd_n,
    input z80_wr_n,
    input [15:0] z80_addr,
    input [7:0] z80_din,
    output logic [7:0] z80_dout,

    output logic ics2115_reset_n,
    output logic [1:0] ics2115_addr,
    output logic [7:0] ics2115_dout,
    input [7:0] ics2115_din,
    output logic ics2115_cs_n,
    output logic ics2115_wr_n,
    output logic ics2115_rd_n,
    input logic ics2115_irq,
    input logic ics2115_ready,

    input  [7:0] bgm_status,      // espgalarr: ADX stream player status (Z80 I/O 0x88xx)

    ssbus_if.slave ssbus
);

reg [15:0] latch[8];

localparam int SS_WORD_LATCH1 = 0;
localparam int SS_WORD_LATCH2 = 1;
localparam int SS_WORD_LATCH4 = 2;
localparam int SS_WORD_LATCH5 = 3;
localparam int SS_WORD_LATCH6 = 4;
localparam int SS_WORD_MISC   = 5;
localparam int SS_WORD_COUNT  = 6;

wire io_access_n = cpu_cs_n | cpu_addr[16];
wire ram_access_n = cpu_cs_n | ~cpu_addr[16];

wire z80_io_access_n = z80_iorq_n;
wire z80_ics2115_access = ~z80_io_access_n && ~(|z80_addr[11:8]) && (~z80_rd_n || ~z80_wr_n);

wire [15:0] z80_ctrl = latch[4];
wire [15:0] z80_bus_ctrl = latch[5];
wire z80_bus_requested = z80_bus_ctrl == 16'h45d3;
wire z80_control_reset_n = ~z80_ctrl[0]; // 0x5050 runs, 0xa659 halts/resets the Z80 during uploads
wire z80_bus_disable = z80_bus_requested && (!z80_control_reset_n || !z80_busak_n);
logic ics2115_reset_n_reg;

assign z80_busrq_n = ~z80_bus_requested;
assign z80_reset_n = z80_control_reset_n;
assign ics2115_reset_n = ics2115_reset_n_reg;

always_comb begin
    v3021_dout = cpu_din[0];
    
    cpu_dout = 16'h0;

    v3021_cs_n = 1;
    v3021_wr_n = 1;

    aram_uds_n = 1;
    aram_lds_n = 1;
    aram_addr = z80_bus_disable ? cpu_addr[15:1] : z80_addr[15:1];
    aram_dout = z80_bus_disable ? cpu_din : { z80_din, z80_din };

    z80_wait_n = 1'b1;

    z80_dout = z80_addr[0] ? aram_din[7:0] : aram_din[15:8];

    ics2115_dout = z80_din;
    ics2115_addr = z80_addr[1:0];
    ics2115_cs_n = z80_io_access_n | (|z80_addr[11:8]);
    ics2115_rd_n = ics2115_cs_n | z80_rd_n;
    ics2115_wr_n = ics2115_cs_n | z80_wr_n;

    z80_int_n = ~ics2115_irq;

    if (~io_access_n) begin
        case(cpu_addr[3:0])
            4'h2: cpu_dout = latch[1];
            4'h4: cpu_dout = latch[2];
            4'h6: begin
                v3021_cs_n = 0;
                v3021_wr_n = cpu_rw;
                cpu_dout[0] = v3021_din;
            end
            4'h8: cpu_dout = latch[4];
            4'ha: cpu_dout = latch[5];
            4'hc: cpu_dout = latch[6];
            default: begin
            end
        endcase
    end else if (z80_bus_disable & ~ram_access_n) begin
        cpu_dout = aram_din;
        aram_lds_n = cpu_lds_n | cpu_rw;
        aram_uds_n = cpu_uds_n | cpu_rw;
    end

    if (~z80_bus_disable) begin
        if (~z80_io_access_n) begin
            case(z80_addr[11:8])
                0: z80_dout = ics2115_din;
                1: z80_dout = latch[6][7:0];
                2: z80_dout = latch[1][7:0];
                4: z80_dout = latch[2][7:0];
                8: z80_dout = bgm_status;
            endcase
        end else begin
            aram_lds_n = z80_wr_n | ~z80_addr[0];
            aram_uds_n = z80_wr_n | z80_addr[0];
        end
    end
end

always_ff @(posedge clk) begin
    ssbus.setup(SS_IDX, SS_WORD_COUNT, 2);

    if (reset || ss_restore) begin
        latch[1] <= 16'd0;
        latch[2] <= 16'd0;
        latch[4] <= 16'd0;
        latch[5] <= 16'd0;
        latch[6] <= 16'd0;
        z80_nmi_n <= 1;
        ics2115_reset_n_reg <= ss_restore;
    end else begin
        ics2115_reset_n_reg <= 1'b1;
        if (ssbus.access(SS_IDX)) begin
            if (ssbus.write) begin
                case (ssbus.addr)
                    SS_WORD_LATCH1: latch[1] <= ssbus.data[15:0];
                    SS_WORD_LATCH2: latch[2] <= ssbus.data[15:0];
                    SS_WORD_LATCH4: latch[4] <= ssbus.data[15:0];
                    SS_WORD_LATCH5: latch[5] <= ssbus.data[15:0];
                    SS_WORD_LATCH6: latch[6] <= ssbus.data[15:0];
                    SS_WORD_MISC:   z80_nmi_n <= ssbus.data[0];
                    default: begin end
                endcase
                ssbus.write_ack(SS_IDX);
            end else if (ssbus.read) begin
                case (ssbus.addr)
                    SS_WORD_LATCH1: ssbus.read_response(SS_IDX, {32'd0, 16'd0, latch[1]});
                    SS_WORD_LATCH2: ssbus.read_response(SS_IDX, {32'd0, 16'd0, latch[2]});
                    SS_WORD_LATCH4: ssbus.read_response(SS_IDX, {32'd0, 16'd0, latch[4]});
                    SS_WORD_LATCH5: ssbus.read_response(SS_IDX, {32'd0, 16'd0, latch[5]});
                    SS_WORD_LATCH6: ssbus.read_response(SS_IDX, {32'd0, 16'd0, latch[6]});
                    SS_WORD_MISC:   ssbus.read_response(SS_IDX, {32'd0, 31'd0, z80_nmi_n});
                    default:        ssbus.read_response(SS_IDX, 64'd0);
                endcase
            end
        end

        if (~io_access_n) begin
            if (~cpu_rw & ~cpu_lds_n) begin
                case(cpu_addr[3:0])
                    4'h2: begin
                        latch[1] <= cpu_din;
                        z80_nmi_n <= 0;
                    end
                    4'h4: latch[2] <= cpu_din;
                    4'h8: begin
                        latch[4] <= cpu_din;
                        // MJD-TODO: I don't like this
                        if (cpu_din == 16'h5050)
                            ics2115_reset_n_reg <= 1'b0;
                    end
                    4'ha: latch[5] <= cpu_din;
                    4'hc: latch[6] <= cpu_din;
                    default: begin
                    end
                endcase
            end
        end

        if (~z80_bus_disable) begin
            if (~z80_io_access_n) begin
                if (~z80_wr_n) begin
                    case(z80_addr[11:8])
                        0: begin end
                        1: latch[6][7:0] <= z80_din;
                        2: latch[1][7:0] <= z80_din;
                        4: latch[2][7:0] <= z80_din;
                    endcase
                end
                if (~z80_rd_n && z80_addr[11:8] == 2) z80_nmi_n <= 1;
            end
        end
    end
end
endmodule



