// cpu_island testbench (CPU_ISLAND, the espgalarr core): fx68k and the island's fast memories on
// one clock, with models of what lies beyond them: the SDRAM behind the program ROM cache, DDR
// behind the 0xe00000 cache (the real xram_e_island / ram_cache / ddr_cdc), and the 60 MHz
// system behind the bridge (a RAM for any other address, with varying latency, and the
// interrupt acknowledge). A level 4 interrupt is raised every IRQ_PERIOD clocks.
//
// The log (stdout) has one line per change of the CPU's bus outputs, with the clock: two island
// versions that run the program in the same clocks give the same log. The program's results
// (written to the work RAM) are dumped at the end.
import system_consts::*;

module island_tb_top #(
    parameter int SDR_LAT = 9,          // clocks from the SDRAM request toggle to the data
    parameter int DDR_LAT = 12,         // clocks from a DDR read to its first beat
    parameter int IRQ_PERIOD = 3001
) (
    input             clk,
    input             reset,
    output reg        done = 0,
    output reg [31:0] cycle = 0
);
    always_ff @(posedge clk) cycle <= cycle + 1;

    // ---- the island
    wire        bridge_req, bridge_rw, sv_fetch;
    wire [22:0] bridge_addr;
    wire  [1:0] bridge_ds_n;
    wire  [2:0] bridge_fc;
    wire [15:0] bridge_dout;
    reg         bridge_ack = 0;
    reg  [15:0] bridge_din = 0;
    wire [26:0] sdr_addr;
    wire        sdr_req;
    reg         sdr_ack = 0;
    reg  [63:0] sdr_data = 0;
    wire [15:0] wram_addr, wram_d, wram_q, xd_d, xd_q, xe_d, xe_q;
    wire        wram_we_u_n, wram_we_l_n, xd_we_u_n, xd_we_l_n;
    wire [14:0] xd_addr;
    wire        xe_rd, xe_wr, xe_we_u, xe_we_l, xe_ready;
    wire [16:1] xe_addr;
    reg   [2:0] ipl_n = 3'b111;

    cpu_island isl(
        .clk_cpu(clk),
        .reset_sys(reset), .run_sys(1'b1), .unthrottled(1'b1), .ss_override_sys(1'b0),
        .ipl_n_sys(ipl_n), .br_n_sys(1'b1), .bgack_n_sys(1'b1),
        .game(GAME_ESPGALARR), .cart_present(1'b0), .cart_base_addr(23'd0), .bg_n(),
        .bridge_req, .bridge_addr, .bridge_ds_n, .bridge_rw, .bridge_fc, .bridge_dout,
        .bridge_ack_sys(bridge_ack), .bridge_din, .sv_fetch,
        .sdr_addr, .sdr_req, .sdr_ack, .sdr_data,
        .wram_addr, .wram_we_u_n, .wram_we_l_n, .wram_d, .wram_q,
        .xd_addr, .xd_we_u_n, .xd_we_l_n, .xd_d, .xd_q,
`ifdef NEW_ISLAND
        .xe_wr,
`endif
        .xe_rd, .xe_we_u, .xe_we_l, .xe_addr, .xe_d, .xe_q, .xe_ready,
        .nvram_wr_t_sys(1'b0), .nvram_waddr(17'd0), .nvram_wdata(8'd0), .nvram_raddr(17'd0),
        .nvram_q_word()
    );

    // ---- work RAM and 0xd00000 RAM (the core's modules; port B idle)
    m68k_ram_dp2 #(.WIDTHAD(16)) wram(
        .clock_a(clk), .we_lds_n_a(wram_we_l_n), .we_uds_n_a(wram_we_u_n), .address_a(wram_addr),
        .data_a(wram_d), .q_a(wram_q),
        .clock_b(clk), .we_lds_n_b(1'b1), .we_uds_n_b(1'b1), .address_b(16'd0), .data_b(16'd0), .q_b()
    );
    m68k_ram_dp2 #(.WIDTHAD(15)) xdram(
        .clock_a(clk), .we_lds_n_a(xd_we_l_n), .we_uds_n_a(xd_we_u_n), .address_a(xd_addr),
        .data_a(xd_d), .q_a(xd_q),
        .clock_b(clk), .we_lds_n_b(1'b1), .we_uds_n_b(1'b1), .address_b(15'd0), .data_b(16'd0), .q_b()
    );

    // ---- 0xe00000 RAM: the core's cache, DDR model behind ddr_cdc
    ddr_if ddr_a();
    ddr_if ddr_b();
    xram_e_island xram_e(
        .clk, .reset_sys(reset),
`ifdef NEW_ISLAND
        .cpu_wr(xe_wr),
`endif
        .cpu_rd(xe_rd), .cpu_we_u(xe_we_u), .cpu_we_l(xe_we_l), .cpu_addr(xe_addr), .cpu_din(xe_d),
        .cpu_q(xe_q), .cpu_ready(xe_ready),
        .ss_req_sys(1'b0), .ss_wr(1'b0), .ss_addr(15'd0), .ss_wdata(32'd0), .ss_ack(), .ss_rdata(),
        .ddr(ddr_a)
    );
    ddr_cdc cdc(.clk_a(clk), .a(ddr_a), .clk_b(clk), .b(ddr_b));

    reg [63:0] ddr_mem[16384];          // 128KB at PROT_SHARE_DDR_BASE
    reg        ddr_busy = 0, ddr_rd = 0;
    reg  [7:0] ddr_cnt;
    reg  [1:0] ddr_beat;
    reg [13:0] ddr_idx;
    assign ddr_b.busy = ddr_busy;
    always_ff @(posedge clk) begin
        ddr_b.rdata_ready <= 0;
        if (~ddr_busy) begin
            if (ddr_b.read) begin
                ddr_busy <= 1; ddr_rd <= 1; ddr_cnt <= DDR_LAT[7:0]; ddr_beat <= 0;
                ddr_idx <= 14'((ddr_b.addr - PROT_SHARE_DDR_BASE) >> 3);
            end else if (ddr_b.write) begin
                for (int i = 0; i < 8; i++)
                    if (ddr_b.byteenable[i])
                        ddr_mem[14'((ddr_b.addr - PROT_SHARE_DDR_BASE) >> 3)][i*8 +: 8] <= ddr_b.wdata[i*8 +: 8];
                ddr_busy <= 1; ddr_rd <= 0; ddr_cnt <= 8'd3;
            end
        end else if (ddr_cnt != 0) begin
            ddr_cnt <= ddr_cnt - 8'd1;
        end else if (ddr_rd) begin
            ddr_b.rdata <= ddr_mem[ddr_idx + 14'(ddr_beat)];
            ddr_b.rdata_ready <= 1;
            ddr_beat <= ddr_beat + 2'd1;
            if (ddr_beat == 2'd3) ddr_busy <= 0;
        end else begin
            ddr_busy <= 0;
        end
    end

    // ---- SDRAM channel 3: the program (64-bit lines, word 0 in bits 15:0)
    reg [63:0] rom[8192];
    initial begin
        for (int i = 0; i < 16384; i++) ddr_mem[i] = { 32'(i * 32'h9e3779b9), 32'(i ^ 32'h5a5a1234) };
        $readmemh("prog.hex", rom);
    end
    reg       sdr_busy = 0;
    reg [7:0] sdr_cnt;
    always_ff @(posedge clk) begin
        if (~sdr_busy) begin
            if (sdr_req != sdr_ack) begin sdr_busy <= 1; sdr_cnt <= SDR_LAT[7:0]; end
        end else if (sdr_cnt != 0) begin
            sdr_cnt <= sdr_cnt - 8'd1;
        end else begin
            sdr_data <= rom[13'((sdr_addr - BIOS_PROG_ROM_SDR_BASE[26:0]) >> 3)];
            sdr_ack  <= sdr_req;
            sdr_busy <= 0;
        end
    end

    // ---- the 60 MHz system behind the bridge: a 4K-word RAM for any other address, varying
    // latency; a write to 0xc0fffe ends the run; interrupt acknowledges end the interrupt
    reg [15:0] io_ram[4096];
    reg        br_busy = 0;
    reg  [3:0] br_cnt;
    reg [15:0] lfsr = 16'hace1;
    always_ff @(posedge clk) begin
        if (cycle % IRQ_PERIOD == IRQ_PERIOD - 1) ipl_n <= 3'b011;      // level 4
        if (~br_busy) begin
            // the latency varies per request (not with the clock it arrives in)
            if (bridge_req != bridge_ack) begin
                br_busy <= 1; br_cnt <= 4'd3 + 4'(lfsr[2:0]);
                lfsr <= { lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10] };
            end
        end else if (br_cnt != 0) begin
            br_cnt <= br_cnt - 4'd1;
        end else begin
            if (&bridge_fc) begin
                bridge_din <= 16'hffff;
                ipl_n <= 3'b111;
            end else if (bridge_rw) begin
                bridge_din <= io_ram[bridge_addr[11:0]];
            end else begin
                if (~bridge_ds_n[1]) io_ram[bridge_addr[11:0]][15:8] <= bridge_dout[15:8];
                if (~bridge_ds_n[0]) io_ram[bridge_addr[11:0]][7:0]  <= bridge_dout[7:0];
                if ({ bridge_addr, 1'b0 } == 24'hc0fffe) done <= 1;
            end
            bridge_ack <= bridge_req;
            br_busy <= 0;
        end
    end

    // ---- the log: the CPU's bus outputs, on every change
    reg [44:0] last = '1;
    wire [44:0] now = { isl.cpu_addr, isl.cpu_as_n, isl.cpu_ds_n, isl.cpu_rw, isl.cpu_fc,
                        (~isl.cpu_rw & ~&isl.cpu_ds_n) ? isl.cpu_data_out : 16'h0 };
    always_ff @(posedge clk) begin
        if (~reset && now != last)
            $display("%0d %06x as%0d ds%0d%0d rw%0d fc%0d d%04x", cycle, { isl.cpu_addr, 1'b0 },
                     isl.cpu_as_n, isl.cpu_ds_n[1], isl.cpu_ds_n[0], isl.cpu_rw, isl.cpu_fc,
                     now[15:0]);
        last <= now;
        if (done) begin
            for (int i = 0; i < 64; i++)
                $display("result %02x %02x%02x", i, wram.ram_h[16'h7f00 + i], wram.ram_l[16'h7f00 + i]);
            $display("end %0d", cycle);
            $finish;
        end
    end
endmodule
