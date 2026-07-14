#!/usr/bin/env python3
"""Generate scenes/level2.tscn — a SECOND map for the game, skinned with the
sci-fi panel tileset (scenes/terrain2_tileset.tres, built from Terrain.png).

The layout is a horizontal mirror of the proven map in generate_level.py. A
mirror preserves every jump distance and every room-to-room opening exactly, so
the new map is guaranteed just as traversable as the original — but spatially it
is a different facility: the Runner now starts bottom-RIGHT, the Hunters
bottom-LEFT, and every shaft / climb chain is reversed. Pair it with
scripts/world/level_layout2.gd (mirrored ROOMS) and scripts/world/world2.gd
(mirrored spawns).

Keep this in sync with generate_level.py: the geometry block below is copied
verbatim, then mirrored as the final step.
"""
import base64, struct, os

W, H = 100, 60
solid = [[True] * W for _ in range(H)]

def carve(x0, x1, y0, y1):
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            solid[y][x] = False

def fill(x0, x1, y0, y1):
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            solid[y][x] = True

# ---- room interiors (copied from generate_level.py) -----------------------
carve(4, 26, 44, 54)    # A SpawnHall
carve(30, 68, 46, 54)   # B LowerHall
carve(18, 24, 12, 43)   # C LeftShaft
carve(28, 60, 8, 15)    # E TopCorridor
carve(40, 70, 19, 40)   # F CentralHub
carve(64, 93, 8, 14)    # G TopRight
carve(74, 93, 19, 54)   # D RightShaft

# ---- interior structures --------------------------------------------------
fill(8, 10, 52, 52)
fill(13, 15, 49, 49)
fill(18, 20, 46, 46)
fill(4, 5, 53, 54)
fill(22, 23, 54, 54)
fill(10, 12, 44, 44)
for i, row in enumerate(range(43, 21, -3)):
    x0 = 22 if i % 2 == 0 else 18
    fill(x0, x0 + 2, row, row)
fill(22, 24, 19, 19)
carve(14, 17, 26, 30)
carve(25, 27, 36, 39)
fill(46, 60, 14, 15)
fill(34, 35, 15, 15)
fill(52, 54, 11, 11)
fill(36, 38, 8, 8)
fill(57, 59, 8, 8)
fill(54, 60, 52, 54)
fill(36, 38, 52, 52)
fill(33, 34, 46, 46)
fill(44, 46, 46, 46)
fill(46, 49, 38, 38)
fill(41, 44, 35, 35)
fill(46, 49, 32, 32)
fill(41, 44, 29, 29)
fill(46, 49, 26, 26)
fill(41, 43, 24, 24)
fill(44, 46, 22, 22)
fill(41, 42, 19, 19)
fill(51, 54, 29, 29)
fill(56, 70, 28, 28)
fill(60, 60, 19, 24)
fill(66, 69, 25, 25)
fill(61, 63, 22, 22)
fill(57, 58, 39, 40)
fill(53, 55, 19, 19)
fill(74, 76, 14, 14)
fill(88, 93, 13, 14)
fill(78, 80, 12, 12)
fill(67, 69, 8, 8)
fill(74, 78, 41, 41)
fill(74, 78, 43, 44)
fill(79, 85, 43, 43)
fill(76, 79, 52, 52)
fill(82, 85, 49, 49)
fill(88, 91, 46, 46)
fill(88, 91, 40, 40)
fill(83, 86, 37, 37)
fill(88, 91, 34, 34)
fill(83, 86, 31, 31)
fill(88, 91, 28, 28)
fill(83, 86, 25, 25)
fill(77, 79, 53, 54)
fill(80, 82, 19, 19)
fill(74, 79, 19, 19)
fill(80, 81, 20, 22)
carve(71, 79, 20, 25)
fill(74, 79, 26, 26)

# ---- doors / shafts -------------------------------------------------------
carve(27, 29, 51, 54)
carve(69, 73, 51, 54)
carve(25, 27, 16, 18)
carve(28, 31, 16, 18)
carve(32, 33, 16, 17)
carve(61, 63, 12, 14)
carve(41, 43, 16, 18)
carve(44, 45, 17, 18)
carve(47, 49, 41, 45)
carve(84, 86, 15, 18)

# ---- tunnels --------------------------------------------------------------
carve(14, 15, 55, 56)
carve(16, 38, 56, 56)
carve(39, 40, 55, 56)
carve(50, 51, 55, 55)
carve(63, 64, 55, 55)
carve(50, 64, 56, 56)
carve(66, 67, 41, 42)
carve(68, 78, 42, 42)

# ---- MIRROR horizontally: this is what makes level2 a different facility ---
solid = [[solid[y][W - 1 - x] for x in range(W)] for y in range(H)]

# ---- ASCII preview --------------------------------------------------------
for y in range(H):
    print(f"{y:3d} " + "".join("#" if solid[y][x] else "." for x in range(W)))

# ---- tile picking (3x3 blob + thin-platform row 11) -----------------------
def is_solid(x, y):
    return True if not (0 <= x < W and 0 <= y < H) else solid[y][x]

def atlas(x, y):
    up, dn = not is_solid(x, y - 1), not is_solid(x, y + 1)
    lf, rt = not is_solid(x - 1, y), not is_solid(x + 1, y)
    if up and dn:
        return (1 if lf else 3 if rt else 2, 11)
    row = 7 if up else 9 if dn else 8
    col = 1 if lf else 3 if rt else 2
    return (col, row)

# ---- encode & write level2.tscn -------------------------------------------
buf = bytearray(struct.pack("<H", 0))
count = 0
for y in range(H):
    for x in range(W):
        if solid[y][x]:
            ax, ay = atlas(x, y)
            buf += struct.pack("<hhhhhh", x, y, 0, ax, ay, 0)
            count += 1
b64 = base64.b64encode(bytes(buf)).decode()

out = os.path.join(os.path.dirname(__file__), "..", "scenes", "levels", "level2.tscn")
with open(out, "w") as f:
    f.write('[gd_scene format=4]\n\n')
    f.write('[ext_resource type="TileSet" path="res://scenes/resources/terrain2_tileset.tres" id="1_t2lvl"]\n\n')
    f.write('[node name="Terrain" type="TileMapLayer" unique_id=322632071]\n')
    f.write(f'tile_map_data = PackedByteArray("{b64}")\n')
    f.write('tile_set = ExtResource("1_t2lvl")\n')
print(f"wrote {count} terrain tiles -> {os.path.abspath(out)}")
