// adx_stream testbench: tb BLOB TRACK SAMPLES OUT [TICK_CLOCKS] [SEED]
// Plays TRACK of the BGM blob through rtl/adx_stream.sv with a memory model of random latency
// (BASE 0x34000000) and writes one int16 L/R pair per tick to OUT. Prints underrun / loop flags.
#include "Vadx_stream.h"
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

    Vadx_stream* t = new Vadx_stream;
    auto clk = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
    t->reset = 1; clk(); clk(); t->reset = 0;
    t->cmd_track = track; t->cmd_play = 1; clk(); t->cmd_play = 0;

    int lat = 0; bool busy = false;
    long got = 0, cyc = 0, max_wait = 0;
    std::vector<int16_t> pairs; pairs.reserve(1 << 20);
    while (got < samples) {
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
        t->tick = (cyc % tick_clocks) == 0 && cyc > 0;
        bool was_tick = t->tick && t->playing;   // (decodes the next sample on this edge)
        clk();
        cyc++;
        if (was_tick) {
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
