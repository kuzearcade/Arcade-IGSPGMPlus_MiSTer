# Sprite engine testbench (IGS023_Sprite + IGS023_BROM_Cache), ESPGALARR_CORE configuration
SRC = ../../rtl/system_consts.sv ../../rtl/ram.sv ../../rtl/igs023_buffer.sv ../../rtl/igs023_brom_cache.sv ../../rtl/igs023_sprite.sv spr_tb_top.sv
all: obj/Vspr_tb_top
obj/Vspr_tb_top: $(SRC) tb.cpp
	verilator --cc --exe --build -O3 -Wno-fatal -Wno-lint -Wno-style +define+ESPGALARR_CORE --Mdir obj --top-module spr_tb_top $(SRC) tb.cpp -o Vspr_tb_top
clean:
	rm -rf obj
