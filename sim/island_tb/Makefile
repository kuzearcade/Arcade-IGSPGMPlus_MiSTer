# cpu_island testbench. make ISLAND=<cpu_island.sv> XRAM=<xram_e_island.sv> OBJ=<dir>; then run
# (cd OBJ && ./Visland_tb_top > log.txt) with prog.hex, microrom.mem and nanorom.mem there.
# make ref: the espgalarr branch's island (the 40 MHz core) in obj_ref; make new: the working tree's.
R = ../../rtl
ISLAND ?= $(R)/cpu_island.sv
XRAM ?= $(R)/xram_e_island.sv
RAMCACHE ?= $(R)/ram_cache.sv
OBJ ?= obj_new
ESPGALARR ?= $(HOME)/EspgalArrangePGM
SRC = $(R)/fx68k/hdl/verilator/fx68k.sv $(R)/fx68k/hdl/verilator/fx68kAlu.sv $(R)/fx68k/hdl/verilator/uaddrPla.sv \
      $(R)/system_consts.sv $(R)/address_translator.sv $(R)/ram.sv $(R)/ddram.sv $(RAMCACHE) \
      $(XRAM) $(ISLAND) island_tb_top.sv

$(OBJ)/Visland_tb_top: $(SRC) tb.cpp mkprog.py
	verilator --cc --exe --build -O2 $(VFLAGS) -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN --Mdir $(OBJ) \
	  --top-module island_tb_top $(SRC) tb.cpp -o Visland_tb_top
	python3 mkprog.py $(ESPGALARR) $(OBJ)
	cp ../microrom.mem ../nanorom.mem $(OBJ)/

ref_src/cpu_island.sv ref_src/xram_e_island.sv:
	mkdir -p ref_src
	git show espgalarr:rtl/cpu_island.sv > ref_src/cpu_island.sv
	git show espgalarr:rtl/xram_e_island.sv > ref_src/xram_e_island.sv
	git show espgalarr:rtl/ram_cache.sv > ref_src/ram_cache.sv

ref: ref_src/cpu_island.sv ref_src/xram_e_island.sv
	$(MAKE) ISLAND=ref_src/cpu_island.sv XRAM=ref_src/xram_e_island.sv RAMCACHE=ref_src/ram_cache.sv OBJ=obj_ref obj_ref/Visland_tb_top
new:
	$(MAKE) OBJ=obj_new VFLAGS=+define+NEW_ISLAND=1 obj_new/Visland_tb_top

run: ref new
	cd obj_ref && ./Visland_tb_top 40000000 > log.txt; tail -1 obj_ref/log.txt
	cd obj_new && ./Visland_tb_top 40000000 > log.txt; tail -1 obj_new/log.txt
	cmp obj_ref/log.txt obj_new/log.txt && echo "IDENTICAL"

.PHONY: ref new run
