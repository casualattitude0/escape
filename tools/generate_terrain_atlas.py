#!/usr/bin/env python3
"""Generate sprites/Tilesets/White_Terrain_32.png — a 32px autotile atlas
sliced from the hand-drawn White_Game.png sheet.

The level generator (generate_level.py) + terrain_tileset.tres address tiles by
fixed atlas coords: a 3x3 blob at cols 1..3 / rows 7..9 plus a platform row 11.
We only need those cells filled, so the atlas is 4 cols x 12 rows of 32px.

  row 7  (top surface, player walks on)  -> FLOOR patch
  row 8  (interior fill)                 -> WALL patch
  row 9  (underside / ceiling)           -> WALL patch
  row 11 (thin platform)                 -> FLOOR patch

Source regions are picked from White_Game.png as representative texture patches
(not the full illustrated tiles) so they stay legible when boxed down to 32px.
"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from pnglib import read_png, write_png

TILE = 32
SRC = os.path.join(os.path.dirname(__file__), "..", "sprites", "Tilesets", "White_Game.png")
OUT = os.path.join(os.path.dirname(__file__), "..", "sprites", "Tilesets", "White_Terrain_32.png")

# (x, y, w, h) patches in White_Game.png
WALL = (912, 452, 276, 276)   # brick + central hatch wall block
FLOOR = (1300, 846, 288, 244)  # riveted floor panels


def box_downscale(px, w, region, out_size):
    """Area-average a source rect down to out_size x out_size RGBA bytes."""
    sx, sy, sw, sh = region
    out = bytearray(out_size * out_size * 4)
    for oy in range(out_size):
        for ox in range(out_size):
            x0 = sx + ox * sw // out_size
            x1 = sx + (ox + 1) * sw // out_size
            y0 = sy + oy * sh // out_size
            y1 = sy + (oy + 1) * sh // out_size
            if x1 <= x0: x1 = x0 + 1
            if y1 <= y0: y1 = y0 + 1
            r = g = b = a = n = 0
            for yy in range(y0, y1):
                base = (yy * w + x0) * 4
                for xx in range(x1 - x0):
                    o = base + xx * 4
                    r += px[o]; g += px[o + 1]; b += px[o + 2]; a += px[o + 3]; n += 1
            o = (oy * out_size + ox) * 4
            out[o:o + 4] = bytes((r // n, g // n, b // n, a // n))
    return out


def main():
    w, h, px = read_png(SRC)
    wall = box_downscale(px, w, WALL, TILE)
    floor = box_downscale(px, w, FLOOR, TILE)

    cols, rows = 4, 12
    aw, ah = cols * TILE, rows * TILE
    atlas = bytearray(aw * ah * 4)  # transparent

    def place(tile, col, row):
        for yy in range(TILE):
            do = ((row * TILE + yy) * aw + col * TILE) * 4
            so = (yy * TILE) * 4
            atlas[do:do + TILE * 4] = tile[so:so + TILE * 4]

    for col in (1, 2, 3):
        place(floor, col, 7)   # top surface
        place(wall, col, 8)    # interior
        place(wall, col, 9)    # underside
        place(floor, col, 11)  # platform

    write_png(OUT, aw, ah, atlas)
    print(f"wrote {os.path.abspath(OUT)} ({aw}x{ah})")

    # preview: upscale x6 for eyeballing
    if "--preview" in sys.argv:
        scale = 6
        pw, ph = aw * scale, ah * scale
        prev = bytearray(pw * ph * 4)
        for y in range(ph):
            for x in range(pw):
                so = ((y // scale) * aw + x // scale) * 4
                prev[(y * pw + x) * 4:(y * pw + x) * 4 + 4] = atlas[so:so + 4]
        pout = OUT.replace(".png", "_preview.png")
        write_png(pout, pw, ph, prev)
        print("wrote preview", pout)


if __name__ == "__main__":
    main()
