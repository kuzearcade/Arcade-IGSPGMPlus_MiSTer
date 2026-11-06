// spr_tb: Vspr_tb_top LIST.bin A.bin B.bin OUT.bin [frames] [latency]
// LIST.bin: sprite list words, big-endian (main list as at 0x800000; with EXT=1 in the
// environment, words from 1280 on are the extended list at 0xd0c840). A.bin / B.bin: the sprite
// colour / mask ROMs. OUT.bin: the last frame, 224 x 448 little-endian u16 of color_out (bit 11 =
// a sprite pixel, bits 9:0 = palette * 32 + pixel).
#include "Vspr_tb_top.h"
#include "verilated.h"
#include "Vspr_tb_top__Dpi.h"
#include "svdpi.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>

static std::vector<uint8_t> load(const char *p)
{
    FILE *f = fopen(p, "rb");
    if (!f) { perror(p); exit(1); }
    std::vector<uint8_t> v;
    uint8_t buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) v.insert(v.end(), buf, buf + n);
    fclose(f);
    return v;
}

// 64-bit read as sim_sdram.h UpdateChannel64: four halfwords of the 8-byte block, starting at
// the addressed halfword and wrapping
static uint64_t read64(const std::vector<uint8_t> &m, uint32_t addr)
{
    addr &= 0xfffffffe;
    uint32_t base = addr & ~7u, start = (addr >> 1) & 3;
    uint64_t v = 0;
    for (uint32_t beat = 0; beat < 4; beat++) {
        uint32_t w = base + ((start + beat) & 3) * 2;
        uint16_t h = (w + 1 < m.size()) ? (m[w] | (m[w + 1] << 8)) : 0;
        v |= (uint64_t)h << (beat * 16);
    }
    return v;
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    if (argc < 5) { fprintf(stderr, "usage: %s LIST A B OUT [frames] [latency]\n", argv[0]); return 1; }
    auto list = load(argv[1]);
    auto arom = load(argv[2]);
    auto brom = load(argv[3]);
    int frames = argc > 5 ? atoi(argv[5]) : 3;
    int lat = argc > 6 ? atoi(argv[6]) : 12;
    std::vector<uint16_t> words(list.size() / 2);
    for (size_t i = 0; i < words.size(); i++) words[i] = (list[2 * i] << 8) | list[2 * i + 1];
    words.resize(0x10000, 0);
    const bool ext = getenv("EXT") && atoi(getenv("EXT"));
    const int rlat = getenv("RLAT") ? atoi(getenv("RLAT")) : 0;   // random latency 1..RLAT per request
    srand(getenv("SEED") ? atoi(getenv("SEED")) : 1);

    Vspr_tb_top *t = new Vspr_tb_top;
    t->ext_sprites = ext;
    std::vector<uint16_t> frame(224 * 448, 0);
    int bwait = -1, await = -1, frame_no = 0;
    t->reset = 1;
    for (int i = 0; i < 100; i++) { t->clk = 0; t->eval(); t->clk = 1; t->eval(); }
    t->reset = 0;
    uint64_t cyc = 0, bun = 0, bn = 0, aun = 0, an = 0;
    while (frame_no <= frames && cyc < 200000000ull) {
        t->dma_din = words[t->dma_addr];
        uint32_t ea = t->ext_addr;
        t->ext_din = (ea >= 0x6420 && (1280 + ea - 0x6420) < words.size()) ? words[1280 + ea - 0x6420] : 0;
        t->clk = 0; t->eval();
        t->clk = 1; t->eval();
        cyc++;
        if (t->sdr_brom_req != t->sdr_brom_ack) {
            if (bwait < 0) bwait = rlat ? 1 + rand() % rlat : lat;
            else if (--bwait == 0) { if (t->sdr_brom_address & 7) bun++; bn++; t->sdr_brom_data = read64(brom, t->sdr_brom_address); t->sdr_brom_ack = t->sdr_brom_req; bwait = -1; }
        }
        if (t->arom_req != t->arom_ack) {
            if (await < 0) await = rlat ? 1 + rand() % rlat : lat;
            else if (--await == 0) { if (t->arom_address & 7) aun++; an++; t->arom_data = read64(arom, t->arom_address); t->arom_ack = t->arom_req; await = -1; }
        }
        if (t->frame_start) frame_no++;
        if (t->pix_valid && t->pix_x < 448 && t->pix_y < 224) frame[t->pix_y * 448 + t->pix_x] = t->color_out;
    }
    svSetScope(svGetScopeFromName("TOP.spr_tb_top"));
    printf("bad line writes %d\n", get_bad_writes());
    FILE *o = fopen(argv[4], "wb");
    fwrite(frame.data(), 2, frame.size(), o);
    fclose(o);
    printf("frames %d cycles %llu brom reads %llu unaligned %llu arom reads %llu unaligned %llu\n", frame_no, (unsigned long long)cyc, (unsigned long long)bn, (unsigned long long)bun, (unsigned long long)an, (unsigned long long)aun);
    delete t;
    return 0;
}
