// cpu_island testbench driver: reset, then run until the program ends (or MAX clocks).
#include "Visland_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    auto *t = new Visland_tb_top;
    long max = argc > 1 ? atol(argv[1]) : 3000000;
    t->reset = 1; t->clk = 0;
    for (int i = 0; i < 40; i++) { t->clk = !t->clk; t->eval(); }
    t->reset = 0;
    for (long i = 0; i < 2 * max && !Verilated::gotFinish(); i++) { t->clk = !t->clk; t->eval(); }
    if (!Verilated::gotFinish()) { printf("timeout\n"); return 1; }
    delete t;
    return 0;
}
