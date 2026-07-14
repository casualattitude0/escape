#!/usr/bin/env python3
"""Generate sprites/Tilesets/Terrain2_32.png — a 32px autotile atlas sliced
from the sci-fi panel sheet sprites/Tilesets/Terrain.png.

Same idea as generate_terrain_atlas.py (the White tileset): the level generator
+ tileset address tiles by fixed atlas coords — a 3x3 blob at cols 1..3 / rows
7..9 plus a platform row 11 — so we only need those cells filled.

  row 7  (top surface, player walks on)  -> FLOOR patch (clean light plate)
  row 8  (interior fill)                 -> WALL patch  (dark mechanical plate)
  row 9  (underside / ceiling)           -> WALL patch
  row 11 (thin platform)                 -> FLOOR patch

Raw 32px slices of the 2048px art sheet look like fragmented line-work, so we
area-average coherent source patches down to 32px instead — legible when tiled.
"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from pnglib import read_png, write_png

TILE = 32
SRC = os.path.join(os.path.dirname(__file__), "..", "sprites", "Tilesets", "Terrain.png")
OUT = os.path.join(os.path.dirname(__file__), "..", "sprites", "Tilesets", "Terrain2_32.png")

# (x, y, w, h) patches in Terrain.png (2048x2048).
FLOOR = (500, 1240, 200, 200)   # riveted light panel with beveled border (mid-left)
WALL = (180, 1670, 220, 220)    # dark mechanical floor plating (lower band)


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


if __name__ == "__main__":
    main()
