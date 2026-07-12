"""Minimal RGBA PNG reader/writer (stdlib only)."""
import zlib, struct


def read_png(path):
    d = open(path, "rb").read()
    assert d[:8] == b"\x89PNG\r\n\x1a\n", path
    pos, w, h, idat, palette, trns, ctype = 8, 0, 0, b"", None, None, None
    while pos < len(d):
        ln, typ = struct.unpack(">I4s", d[pos:pos + 8]); pos += 8
        chunk = d[pos:pos + ln]; pos += ln + 4
        if typ == b"IHDR":
            w, h, bd, ctype = struct.unpack(">IIBB", chunk[:10])
        elif typ == b"IDAT":
            idat += chunk
        elif typ == b"PLTE":
            palette = chunk
        elif typ == b"tRNS":
            trns = chunk
    raw = zlib.decompress(idat)
    ch = {6: 4, 2: 3, 3: 1, 0: 1}[ctype]
    stride = w * ch
    px = bytearray(w * h * 4)
    prev = bytearray(stride)
    pos = 0
    for y in range(h):
        f = raw[pos]; pos += 1
        line = bytearray(raw[pos:pos + stride]); pos += stride
        for i in range(stride):
            a = line[i - ch] if i >= ch else 0
            b = prev[i]
            c = prev[i - ch] if i >= ch else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        prev = line
        for x in range(w):
            if ctype == 6:
                r, g, bl, al = line[x * 4:x * 4 + 4]
            elif ctype == 2:
                r, g, bl = line[x * 3:x * 3 + 3]; al = 255
            else:
                idx = line[x]
                r, g, bl = palette[idx * 3:idx * 3 + 3]
                al = trns[idx] if (trns and idx < len(trns)) else 255
            o = (y * w + x) * 4
            px[o:o + 4] = bytes((r, g, bl, al))
    return w, h, px


def write_png(path, w, h, px):
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + bytes(px[y * w * 4:(y + 1) * w * 4]) for y in range(h))
    open(path, "wb").write(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b""))


def blit(dst, dw, dh, src, sw, sh, sx, sy, w, h, dx, dy):
    """Copy rect (sx,sy,w,h) of src over dst at (dx,dy), alpha-aware."""
    for yy in range(h):
        ty = dy + yy
        if not 0 <= ty < dh: continue
        for xx in range(w):
            tx = dx + xx
            if not 0 <= tx < dw: continue
            so = ((sy + yy) * sw + sx + xx) * 4
            a = src[so + 3]
            if a < 8: continue
            do = (ty * dw + tx) * 4
            if a > 247:
                dst[do:do + 4] = src[so:so + 4]
            else:
                na = a / 255.0
                for k in range(3):
                    dst[do + k] = int(src[so + k] * na + dst[do + k] * (1 - na))
                dst[do + 3] = 255


def bbox(px, w, h, sx, sy, cw, chh):
    """Content bounding box inside rect, or None if empty."""
    x0, y0, x1, y1 = None, None, None, None
    for yy in range(chh):
        for xx in range(cw):
            if px[((sy + yy) * w + sx + xx) * 4 + 3] > 8:
                if x0 is None or xx < x0: x0 = xx
                if x1 is None or xx > x1: x1 = xx
                if y0 is None: y0 = yy
                y1 = yy
    if x0 is None:
        return None
    return x0, y0, x1, y1
