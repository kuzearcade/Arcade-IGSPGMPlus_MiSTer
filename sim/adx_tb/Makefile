# adx_stream unit testbench: make (LOOP_RESTORE=0) / make LOOP_RESTORE=1
LOOP_RESTORE ?= 0
OBJ = obj_r$(LOOP_RESTORE)
all: $(OBJ)/Vadx_stream
$(OBJ)/Vadx_stream: ../../rtl/adx_stream.sv tb.cpp
	verilator --cc --exe --build -O3 -Wall -Wno-fatal --Mdir $(OBJ) -GLOOP_RESTORE=$(LOOP_RESTORE) \
	  --top-module adx_stream ../../rtl/adx_stream.sv tb.cpp -o Vadx_stream
