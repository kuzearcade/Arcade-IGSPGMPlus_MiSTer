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

// Sprite B-ROM (mask) read cache between IGS023_Sprite and SDRAM: 1024 x 64-bit words, direct
// mapped by byte address bits 12:3.  Sprites that draw the same graphics (a screen of bullets)
// read the same mask words, which then come from here in two cycles instead of an SDRAM round
// trip each.  Both sides use the toggle handshake (a request is pending while req != ack); the
// address is taken when the request is seen.  The ROM never changes while the core runs, so
// lines stay valid until reset.
module IGS023_BROM_Cache(
    input clk,
    input reset,

    // sprite engine side
    input      [23:0] req_address,
    input             req,
    output reg        ack,
    output reg [63:0] data,

    // SDRAM side
    output reg [23:0] sdr_address,
    output reg        sdr_req,
    input             sdr_ack,
    input      [63:0] sdr_data
);

typedef enum bit [1:0] { IDLE, LOOKUP, FETCH } state_t;
state_t state = IDLE;

reg [23:0] addr;
reg [1023:0] valid;

wire [9:0]  rd_index = req_address[12:3];
wire [9:0]  index = addr[12:3];
wire [10:0] tag = addr[23:13];

reg         fill_we;
wire [74:0] line_q;

dualport_ram_unreg #(.WIDTH(75), .WIDTHAD(10)) lines (
    .clock_a(clk), .wren_a(fill_we), .address_a(index), .data_a({ tag, sdr_data }), .q_a(),
    .clock_b(clk), .wren_b(1'b0), .address_b(rd_index), .data_b(75'd0), .q_b(line_q)
);

always_ff @(posedge clk) begin
    fill_we <= 0;
    if (reset) begin
        state <= IDLE;
        valid <= '0;
        ack <= req;
        sdr_req <= sdr_ack;
    end else begin
        case (state)
            IDLE: begin
                // the line at rd_index is read this cycle, its q is ready in LOOKUP
                if (req != ack) begin
                    addr <= req_address;
                    state <= LOOKUP;
                end
            end

            LOOKUP: begin
                if (valid[index] && line_q[74:64] == tag) begin
                    data <= line_q[63:0];
                    ack <= req;
                    state <= IDLE;
                end else begin
                    sdr_address <= addr;
                    sdr_req <= ~sdr_req;
                    state <= FETCH;
                end
            end

            FETCH: begin
                if (sdr_req == sdr_ack) begin
                    data <= sdr_data;
                    fill_we <= 1;
                    valid[index] <= 1;
                    ack <= req;
                    state <= IDLE;
                end
            end

            default: state <= IDLE;
        endcase
    end
end

endmodule
