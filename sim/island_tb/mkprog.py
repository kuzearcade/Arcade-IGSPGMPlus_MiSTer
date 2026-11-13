"""Assemble the island test program (espgalarr's 68k assembler) into prog.hex: 64-bit SDRAM lines,
word 0 in bits 15:0. Usage: python3 mkprog.py ESPGALARR_REPO OUT_DIR"""
import sys
sys.path.insert(0, sys.argv[1])
from espgalarr.pgm import asm68k

SRC = r"""
    .org 0
    dc.l $80fc00, start, fail, fail, fail
    .org $70
    dc.l irq4
    .org $400
fail:
    move.w  #$dead,$80fe3e.l
    move.w  #1,$c0fffe.l
fhang:
    bra     fhang
irq4:
    movem.l d0/a0,-(a7)
    addq.l  #1,$80fe80.l
    move.w  $a00010.l,d0
    addq.w  #1,d0
    move.w  d0,$a00010.l
    lea     $e0f000,a0
    add.w   d0,(a0)
    movem.l (a7)+,d0/a0
    rte

start:
    dc.w    $46fc,$2000         ; move #$2000,sr
    moveq   #0,d7               ; running checksum
; ---- work RAM: long/word/byte fills and sums
    lea     $800000,a0
    move.l  #$12345678,d0
    move.w  #511,d1
w1: move.l  d0,(a0)+
    rol.l   #3,d0
    add.l   #$01010101,d0
    dbra    d1,w1
    lea     $800000,a0
    move.w  #1023,d1
w2: add.w   (a0)+,d7
    rol.l   #1,d7
    dbra    d1,w2
    lea     $801001,a0
    move.w  #255,d1
w3: move.b  d1,(a0)
    addq.l  #3,a0
    dbra    d1,w3
    lea     $801000,a0
    move.w  #767,d1
w4: add.b   (a0)+,d7
    rol.l   #1,d7
    dbra    d1,w4
    move.l  d7,$80fe00.l
; ---- 0xd00000
    lea     $d00000,a1
    lea     $800000,a0
    move.w  #4095,d1
x1: move.w  (a0)+,(a1)+
    dbra    d1,x1
    lea     $d00003,a1
    move.w  #999,d1
x2: add.b   d1,(a1)
    addq.l  #5,a1
    dbra    d1,x2
    lea     $d00000,a1
    move.w  #2047,d1
x3: add.l   (a1)+,d7
    ror.l   #3,d7
    dbra    d1,x3
    move.l  d7,$80fe04.l
; ---- 0xe00000: strided writes and reads over 64KB (misses, writebacks)
    lea     $e00000,a2
    move.l  #$0badcafe,d0
    move.w  #2047,d1
e1: move.l  d0,(a2)
    move.b  d1,5(a2)
    lea     32(a2),a2
    add.l   #$31415927,d0
    dbra    d1,e1
    lea     $e00002,a2
    move.w  #2047,d1
e2: add.w   (a2),d7
    add.b   5(a2),d7
    rol.l   #5,d7
    lea     32(a2),a2
    dbra    d1,e2
    lea     $e10000,a2
    move.w  #4095,d1
e3: add.l   (a2)+,d7
    eor.w   d1,-2(a2)
    dbra    d1,e3
    move.l  d7,$80fe08.l
; ---- ROM table (32KB: more than the 16KB ROM cache), pc-relative and absolute
    lea     table(pc),a3
    move.w  #8191,d1
r1: add.l   (a3)+,d7
    rol.l   #1,d7
    dbra    d1,r1
    move.l  d7,$80fe0c.l
; ---- the bridge (other addresses): writes, reads, byte lanes, read-modify-write
    lea     $a00100,a4
    move.w  #255,d1
b1: move.w  d1,(a4)+
    move.b  d1,(a4)+
    addq.l  #1,a4
    dbra    d1,b1
    lea     $a00100,a4
    move.w  #255,d1
b2: add.w   (a4)+,d7
    add.b   (a4),d7
    not.w   (a4)
    addq.l  #2,a4
    dbra    d1,b2
    move.l  d7,$80fe10.l
; ---- mixed: movem across regions, tas, copies between regions
    movem.l d0-d7/a0-a6,$800800
    movem.l d0-d7/a0-a6,$d08000
    movem.l d0-d7/a0-a6,$e08000
    movem.l $e08000,d0-d6
    add.l   d0,d7
    add.l   d6,d7
    movem.l $d08000,d0-d6
    add.l   d1,d7
    tas     $800900
    tas     $d08100
    tas     $e08100
    tas     $a00200
    move.b  $800900,d0
    add.b   d0,d7
    move.b  $d08100,d0
    add.b   d0,d7
    move.b  $e08100,d0
    add.b   d0,d7
    move.b  $a00200,d0
    add.b   d0,d7
    lea     $e00000,a0
    lea     $d0c000,a1
    lea     $a00400,a2
    move.w  #511,d1
m1: move.w  (a0)+,(a1)+
    move.w  -2(a1),(a2)
    add.w   (a2),d7
    lea     30(a0),a0
    dbra    d1,m1
    move.l  d7,$80fe14.l
; ---- busy loop across interrupts, then the counts
    move.w  #20000,d1
l1: add.l   d1,d7
    dbra    d1,l1
    move.l  d7,$80fe18.l
    move.l  $80fe80.l,$80fe1c.l
    move.w  $a00010.l,$80fe20.l
    move.w  $e0f000.l,$80fe22.l
    move.w  #1,$c0fffe.l
hang:
    bra     hang
    .align 4
table:
"""
code, syms = asm68k.assemble(SRC, 0)
tbl = bytearray()
x = 0x1234567
for i in range(8192):
    x = (x * 1103515245 + 12345) & 0xFFFFFFFF
    tbl += x.to_bytes(4, "big")
img = bytearray(code) + tbl
img += bytes(-len(img) % 8)
assert len(img) <= 8192 * 8
out = sys.argv[2]
with open(f"{out}/prog.hex", "w") as f:
    for i in range(0, len(img), 8):
        w = [int.from_bytes(img[i + 2 * k:i + 2 * k + 2], "big") for k in range(4)]
        f.write("%016x\n" % (w[0] | w[1] << 16 | w[2] << 32 | w[3] << 48))
print(f"program {len(code)} bytes + table {len(tbl)}")
