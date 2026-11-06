# adx_stream unit testbench: make (LOOP_RESTORE=1, the PS2's) / make LOOP_RESTORE=0 / LOOP_END_INCL=1
LOOP_RESTORE ?= 1
LOOP_END_INCL ?= 0
OBJ = obj_r$(LOOP_RESTORE)i$(LOOP_END_INCL)
all: $(OBJ)/Vadx_stream
$(OBJ)/Vadx_stream: ../../rtl/adx_stream.sv tb.cpp
	verilator --cc --exe --build -O3 -Wall -Wno-fatal --Mdir $(OBJ) -GLOOP_RESTORE=$(LOOP_RESTORE) -GLOOP_END_INCL=$(LOOP_END_INCL) \
	  --top-module adx_stream ../../rtl/adx_stream.sv tb.cpp -o Vadx_stream

# the same through adx_stream_ddr + adx_ddr_port on a ddr_if model
ddr: obj_ddr/Vadx_ddr_tb_top
obj_ddr/Vadx_ddr_tb_top: ../../rtl/adx_stream.sv ../../rtl/ddram.sv adx_ddr_tb_top.sv tb.cpp
	verilator --cc --exe --build -O3 -Wno-fatal -Wno-lint -Wno-style --Mdir obj_ddr -CFLAGS -DDDR_TB \
	  --top-module adx_ddr_tb_top ../../rtl/ddram.sv ../../rtl/adx_stream.sv adx_ddr_tb_top.sv tb.cpp -o Vadx_ddr_tb_top
