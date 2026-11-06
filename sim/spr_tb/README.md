# Sprite engine testbench

`IGS023_Sprite` + `IGS023_BROM_Cache` (ESPGALARR_CORE configuration) with the IGS023's sprite timing,
driven from a sprite list and the A / B ROMs, against an exact port of MAME's renderer.

    make
    obj/Vspr_tb_top LIST.bin A.bin B.bin OUT.bin [frames] [latency]   # EXT=1: extended list at word 1280
    python3 spr_ref.py LIST.bin ZOOM.txt A.bin B.bin REF.npy             # MAME igs023 draw_sprites

LIST.bin: big-endian list words as at 0x800000 (then the extended list from 0xd0c840). OUT.bin:
224 x 448 u16 of color_out (0xfff = no sprite pixel, bits 9:0 = palette * 32 + pixel). RLAT=n
gives each ROM request a random latency of 1..n clocks. The run also counts line-buffer writes
that land on the line being scanned out or erased.

`spr_ref.run(..., core=True)` uses the core's fixed scale patterns instead of the game's zoom
table (to separate pattern differences from rendering errors).

Findings (2026-11-06): with MAME lists of espgalarr (main and extended) and a board savestate's
list, the engine's output equals MAME's except for zoomed sprites, where the core's fixed scale
patterns pick other source columns / lines than the game's zoom table (a pixel's shift, the same
colours); no corruption at any latency.

The MiSTer-only "noise" (espgalarr TODO 15) was vertically flipped sprites of the espgalarr
build's own art: the IGS023 (and this core) draws a y-flipped sprite backwards from the A-ROM
position of its last pixel, read from the two words after the sprite's mask (high word first);
the original ROMs carry that end marker after every sprite, MAME ignores it, and the build's
encoder did not write it. The espgalarr build now writes it (gfx.b_end_marker); the core is
unchanged.
