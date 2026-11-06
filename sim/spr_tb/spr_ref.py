"""spr_ref.py LIST.bin ZOOM.txt A.bin B.bin OUT.npy: MAME's igs023 sprite renderer (igs023_video.cpp
draw_sprites / draw_sprite_new_basic / draw_sprite_new_zoomed), ported exactly. LIST.bin = the
sprite list words (big-endian, 5 per entry, as at 0x800000 then the extended list, terminated
by a zero size word); ZOOM.txt = 32 hex words of the zoom table. Output: 224x448 int16 array of
palette * 32 + pixel, -1 where no sprite pixel is drawn."""
import sys, struct
import numpy as np

CORE_PATTERN = [
    0xAAAAAAAA, 0xA8AAAAAA, 0xA8AAA8AA, 0xA8A8A8AA, 0xA8A8A8A8, 0x88A8A8A8, 0x88A888A8, 0x888888A8,
    0x88888888, 0x80888888, 0x80888088, 0x80808088, 0x80808080, 0x80008080, 0x80008000, 0x00008000,
    0x00000000, 0x00010000, 0x00010001, 0x01010001, 0x01010101, 0x01110101, 0x01110111, 0x11110111,
    0x11111111, 0x11511111, 0x11511151, 0x51511151, 0x51515151, 0x51555151, 0x51555155, 0x55555155]

def rev32(v):
    return int(f'{v:032b}'[::-1], 2)

def run(words, zoom, adata, bdata, core=False):
    W, H = 448, 224
    dest = np.full((H, W), -1, np.int32)
    destpri = np.zeros((H, W), np.uint8)
    sprites = []
    for i in range(0, len(words) - 4, 5):
        s0, s1, s2, s3, s4 = words[i:i + 5]
        if (s4 & 0x7fff) == 0:
            break
        xgrow = bool(s0 & 0x8000); xzom = (s0 & 0x7800) >> 11
        x = (s0 & 0x07ff) - (0x800 if s0 & 0x400 else 0)
        ygrow = bool(s1 & 0x8000); yzom = (s1 & 0x7800) >> 11
        y = (s1 & 0x03ff) - (0x400 if s1 & 0x200 else 0)
        flip = (s2 & 0x6000) >> 13; color = (s2 & 0x1f00) >> 8; pri = (s2 >> 7) & 1
        offs = ((s2 & 0x7f) << 16) | s3
        width = (s4 & 0x7e00) >> 9; height = s4 & 0x1ff
        if core:
            # the core: fixed patterns indexed by {grow, table select}, consumed from bit 0 reversed
            xz_core = rev32(CORE_PATTERN[(16 if xgrow else 0) | xzom])
            yz_core = rev32(CORE_PATTERN[(16 if ygrow else 0) | yzom])
        if xgrow: xzom = 0x10 - xzom
        if ygrow: yzom = 0x10 - yzom
        def zt(z):
            if z >= 0x10: return 0
            if z == 0xf: return 1
            return (zoom[z * 2] << 16) | zoom[z * 2 + 1]
        sprites.append(dict(x=x, y=y, flip=flip, color=color, pri=pri, offs=offs, width=width,
                            height=height, xzoom=xz_core if core else zt(xzom), yzoom=yz_core if core else zt(yzom),
                            xgrow=xgrow, ygrow=ygrow))
    nb = len(bdata); na = len(adata)
    st = {}
    def pix():
        v = (adata[st['ao'] & (na - 1)] >> st['ab']) & 0x1f
        st['ab'] += 5
        if st['ab'] >= 15:
            st['ao'] += 1; st['ab'] = 0
        return v
    def put(xd, yd, v, pri):
        if 0 <= xd < W and 0 <= yd < H:
            if not (destpri[yd, xd] & 1):
                if (not pri) or (not (destpri[yd, xd] & 2)):
                    dest[yd, xd] = v
            destpri[yd, xd] |= 1
    def line(sp, yd, draw, zoomed, realxsize):
        xoffset = 0; xcntdraw = 0
        for xc in range(sp['width']):
            msk = bdata[st['bo'] & (nb - 1)]
            for _ in range(16):
                zb = bool((sp['xzoom'] >> (xoffset & 0x1f)) & 1) if zoomed else False
                xoffset += 1
                if not (msk & 1):
                    v = pix() + sp['color'] * 32
                    if draw:
                        n = (2 if zb else 1) if (sp['xgrow'] or not zb) else 0
                        for _ in range(n):
                            xd = sp['x'] + xcntdraw if not (sp['flip'] & 1) else sp['x'] + realxsize - xcntdraw
                            put(xd, yd, v, sp['pri']); xcntdraw += 1
                else:
                    if sp['xgrow'] or not zb:
                        xcntdraw += 2 if zb else 1
                msk >>= 1
            st['bo'] += 1
    # MAME's get_flipx: flip bit 0? spr2 0x6000>>13: bit0 = 0x2000 = flip X, bit1 = 0x4000 = flip Y
    for sp in reversed(sprites):
        st['bo'] = sp['offs']
        st['ao'] = ((bdata[(st['bo'] + 1) & (nb - 1)] << 16) | bdata[st['bo'] & (nb - 1)]) >> 2
        st['ab'] = 0; st['bo'] += 2
        zoomed = bool(sp['xzoom'] or sp['yzoom'])
        fy = bool(sp['flip'] & 2)
        if not zoomed:
            realysize = sp['height'] - 1; realx = sp['width'] * 16 - 1
            for yc in range(sp['height']):
                yd = sp['y'] + yc if not fy else sp['y'] + realysize - yc
                line(sp, yd, 0 <= yd < H, False, realx)
            continue
        realysize = sum((2 if ((sp['yzoom'] >> (c & 31)) & 1) else 1) for c in range(sp['height'])
                        if sp['ygrow'] or not ((sp['yzoom'] >> (c & 31)) & 1)) - 1
        realx = sum((2 if ((sp['xzoom'] >> (c & 31)) & 1) else 1) for c in range(sp['width'] * 16)
                    if sp['xgrow'] or not ((sp['xzoom'] >> (c & 31)) & 1)) - 1
        ycd = 0
        for yc in range(sp['height']):
            zb = bool((sp['yzoom'] >> (yc & 31)) & 1)
            if zb and sp['ygrow']:
                save = (st['ao'], st['ab'], st['bo'])
                yd = sp['y'] + ycd if not fy else sp['y'] + realysize - ycd
                line(sp, yd, 0 <= yd < H, True, realx); ycd += 1
                st['ao'], st['ab'], st['bo'] = save
                yd = sp['y'] + ycd if not fy else sp['y'] + realysize - ycd
                line(sp, yd, 0 <= yd < H, True, realx); ycd += 1
            elif zb and not sp['ygrow']:
                line(sp, -1, False, True, realx)
            else:
                yd = sp['y'] + ycd if not fy else sp['y'] + realysize - ycd
                line(sp, yd, 0 <= yd < H, True, realx); ycd += 1
    return dest

if __name__ == '__main__':
    raw = open(sys.argv[1], 'rb').read()
    words = list(struct.unpack(f'>{len(raw)//2}H', raw))
    zoom = [int(x, 16) for x in open(sys.argv[2]).read().split()]
    a = np.frombuffer(open(sys.argv[3], 'rb').read(), '<u2').astype(np.int64)
    b = np.frombuffer(open(sys.argv[4], 'rb').read(), '<u2').astype(np.int64)
    np.save(sys.argv[5], run(words, zoom, a, b))
