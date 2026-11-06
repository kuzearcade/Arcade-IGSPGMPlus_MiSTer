// adx_stream testbench: tb BLOB TRACK SAMPLES OUT [TICK_CLOCKS] [SEED]
// Plays TRACK of the BGM blob through rtl/adx_stream.sv with a memory model of random latency
// (BASE 0x34000000) and writes one int16 L/R pair per tick to OUT. Prints underrun / loop flags.
#ifdef DDR_TB
#include "Vadx_ddr_tb_top.h"
typedef Vadx_ddr_tb_top Top;
#else
#include "Vadx_stream.h"
typedef Vadx_stream Top;
#endif
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>

int main(int argc, char** argv) {
    if (argc < 5) { fprintf(stderr, "usage: tb BLOB TRACK SAMPLES OUT [TICK_CLOCKS] [SEED]\n"); return 2; }
    FILE* f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 1; }
    std::vector<uint8_t> mem;
    { uint8_t buf[1 << 16]; size_t n; while ((n = fread(buf, 1, sizeof buf, f)) > 0) mem.insert(mem.end(), buf, buf + n); }
    fclose(f);
    mem.resize(mem.size() + 64);
    int track = atoi(argv[2]);
    long samples = atol(argv[3]);
    FILE* out = fopen(argv[4], "wb");
    int tick_clocks = argc > 5 ? atoi(argv[5]) : 64;
    srand(argc > 6 ? atoi(argv[6]) : 1);
    const uint32_t BASE = 0x34000000;

    Top* t = new Top;
    auto clk = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
    t->reset = 1; clk(); clk(); t->reset = 0;
    t->cmd_track = track; t->cmd_play = 1; clk(); t->cmd_play = 0;

    int lat = 0; bool busy = false;
    long got = 0, cyc = 0, max_wait = 0;
    std::vector<int16_t> pairs; pairs.reserve(1 << 20);
    while (got < samples) {
#ifdef DDR_TB
        // DDR: busy now and then; a read (taken when not busy) answers after 5..60 clocks
        static int pend = -1; static uint32_t paddr;
        t->ddr_rdata_ready = 0;
        t->ddr_busy = (rand() % 8) == 0;
        if (pend > 0 && --pend == 0) {
            uint32_t a = paddr - BASE; uint64_t w = 0;
            if (a + 8 <= mem.size()) for (int i = 7; i >= 0; i--) w = (w << 8) | mem[a + i];
            t->ddr_rdata = w; t->ddr_rdata_ready = 1; t->ddr_busy = 0; pend = -1;
        }
        if (t->ddr_read && !t->ddr_busy && pend < 0 && !t->ddr_rdata_ready) {
            if (!t->ddr_acquire) { fprintf(stderr, "read without acquire\n"); return 1; }
            if (t->ddr_burstcnt != 1) { fprintf(stderr, "burst %d\n", t->ddr_burstcnt); return 1; }
            paddr = t->ddr_addr; pend = 5 + rand() % 56;
        }
#else
        // memory: ack a held request after a random latency (1..40 clocks; sometimes 300)
        t->mem_ack = 0;
        if (t->mem_req) {
            if (!busy) { busy = true; lat = 1 + rand() % 40; if (rand() % 64 == 0) lat = 300; }
            else if (--lat == 0) {
                uint32_t a = t->mem_addr - BASE;
                uint64_t w = 0;
                if (a + 8 <= mem.size()) for (int i = 7; i >= 0; i--) w = (w << 8) | mem[a + i];
                t->mem_data = w; t->mem_ack = 1; busy = false;
            }
        } else busy = false;
#endif
        t->tick = (cyc % tick_clocks) == 0 && cyc > 0;
        static int rec = -1;                     // the decode pipeline's result: 8 clocks after a playing tick
        if (t->tick && t->playing) rec = 8;
        clk();
        cyc++;
        if (rec > 0 && --rec == 0) {
            pairs.push_back((int16_t)t->out_l); pairs.push_back((int16_t)t->out_r);
            got++;
            if (pairs.size() >= (1 << 20)) { fwrite(pairs.data(), 2, pairs.size(), out); pairs.clear(); }
        }
    }
    fwrite(pairs.data(), 2, pairs.size(), out);
    fclose(out);
    printf("track %d samples %ld underrun %d looped %d playing %d\n", track, got, t->underrun, t->looped, t->playing);
    delete t;
    return 0;
}
