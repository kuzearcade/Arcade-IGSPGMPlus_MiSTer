// flat-port top for the DDR testbench (Verilator cannot take an interface at the top)
module adx_ddr_tb_top(
    input clk, input reset, input tick, input cmd_play, input [3:0] cmd_track, input cmd_stop,
    input pause,
    output [31:0] ddr_addr, output ddr_read, output ddr_acquire, output [7:0] ddr_burstcnt,
    input [63:0] ddr_rdata, input ddr_busy, input ddr_rdata_ready,
    output signed [15:0] out_l, output signed [15:0] out_r, output playing, output underrun,
    output looped
);
ddr_if ddr();
assign ddr_addr = ddr.addr;
assign ddr_read = ddr.read;
assign ddr_acquire = ddr.acquire;
assign ddr_burstcnt = ddr.burstcnt;
assign ddr.rdata = ddr_rdata;
assign ddr.busy = ddr_busy;
assign ddr.rdata_ready = ddr_rdata_ready;
ssbus_if ssb();
assign ssb.select = 8'hff;
assign ssb.read = 0;
assign ssb.write = 0;
assign ssb.query = 0;
adx_stream_ddr s(.clk, .reset, .tick, .cmd_play, .cmd_track, .cmd_stop, .cmd_fade(1'b0), .pause, .ddr,
                 .out_l, .out_r, .gout_l(), .gout_r(), .playing, .underrun, .looped,
                 .ssbus(ssb), .ss_ext_in(64'd0), .ss_ext_out(), .ss_ext_load());
endmodule
