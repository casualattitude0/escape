#!/usr/bin/env python3
"""Generate scenes/levels/section1.tscn — Metroid Dread-style asymmetric map.

Layout (tile grid 50x30, 64px tiles, y down):

  Rooms                        Openings (>=2 each)              Tunnels (0-2 each)
  A SpawnHall  x2..13  y22..27  door->B, shaft->C, T1          T1 (under floor, y28)
  B LowerHall  x15..34 y23..27  door->A, door->D, drop<-F, T1  T1
  C LeftShaft  x9..12  y6..21   open->A, door->E               -
  E TopCorridor x14..30 y4..7   door->C, door->G, drop->F      -
  F CentralHub x20..35 y10..20  drop<-E, shaft->B, T2          T2 (under floor, y21)
  G TopRight   x32..46 y4..7    door->E, shaft->D              -
  D RightShaft x37..46 y10..27  shaft<-G, door->B, T2          T2

  Tunnels are 1 tile high, run BELOW the walking floor, entered by
  sliding/crawling into a sunken pit (2 deep on the F/A sides).

Player metrics at 64px: jump rise <= 1.5 tiles (~96px), horizontal gap
while rising 1.5 <= 1 tile, stand height ~0.8 tiles (1 clear row needed).
"""
import base64, struct, os

W, H = 50, 30
solid = [[True] * W for _ in range(H)]

def carve(x0, x1, y0, y1):
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            solid[y][x] = False

def fill(x0, x1, y0, y1):
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            solid[y][x] = True

# ---- room interiors -------------------------------------------------------
carve(2, 13, 22, 27)    # A SpawnHall
carve(15, 34, 23, 27)   # B LowerHall
carve(9, 12, 6, 21)     # C LeftShaft (opens into A's ceiling)
carve(14, 30, 4, 7)     # E TopCorridor
carve(20, 35, 10, 20)   # F CentralHub
carve(32, 46, 4, 7)     # G TopRight
carve(37, 46, 10, 27)   # D RightShaft

# ---- interior structures (fill) -------------------------------------------
# A: climb chain up to C shaft
fill(4, 5, 26, 26)
fill(7, 8, 25, 25)
fill(9, 10, 23, 23)
fill(2, 3, 27, 27)      # corner step
fill(11, 12, 27, 27)    # floor bump under C shaft mouth
fill(5, 6, 22, 22)      # ceiling stalactite
# C: zig-zag shaft platforms
for i, row in enumerate(range(21, 11, -2)):
    x0 = 11 if i % 2 == 0 else 9
    fill(x0, x0 + 1, row, row)
fill(11, 12, 10, 10)    # exit ledge -> door to E
# C: side pockets
carve(7, 8, 13, 15)     # left pocket
carve(13, 14, 18, 20)   # right pocket
# E: raised right floor + details
fill(23, 30, 7, 7)
fill(17, 17, 7, 7)      # floor bump
fill(26, 27, 6, 6)      # high shelf
fill(18, 19, 4, 4)      # ceiling bumps
fill(29, 30, 4, 4)
# B: plateau + platform + ceiling details
fill(27, 30, 26, 27)
fill(18, 19, 26, 26)
fill(17, 17, 23, 23)
fill(22, 23, 23, 23)
# F: platforms
fill(23, 25, 19, 19)
fill(21, 22, 18, 18)
fill(23, 25, 16, 16)
# F: left ladder back up to E
fill(21, 22, 15, 15)
fill(23, 25, 13, 13)
fill(21, 22, 12, 12)
fill(22, 23, 11, 11)
fill(21, 21, 10, 10)    # climb-out ledge
fill(26, 27, 15, 15)
# F: loft partition
fill(28, 35, 14, 14)    # loft floor
fill(30, 30, 10, 12)    # partition wall, doorway open at y13
fill(33, 35, 13, 13)    # loft platform
fill(31, 32, 11, 11)    # loft high platform
fill(29, 29, 20, 20)    # low pillar
fill(27, 27, 10, 10)    # ceiling stalactite
# G: decorative step, raised right end, hanging platform
fill(37, 38, 7, 7)
fill(44, 46, 7, 7)      # raised floor at right end
fill(39, 40, 6, 6)      # floating platform
fill(34, 35, 4, 4)      # ceiling bump
# D: tunnel block + entry ledge, then zig-zag climb chain
fill(37, 39, 21, 21)    # tunnel ceiling
fill(37, 39, 22, 22)    # tunnel floor block
fill(40, 43, 22, 22)    # entry ledge
fill(38, 40, 26, 26)
fill(41, 43, 25, 25)
fill(44, 46, 23, 23)
fill(44, 46, 20, 20)
fill(42, 43, 19, 19)
fill(44, 46, 17, 17)
fill(42, 43, 16, 16)
fill(44, 46, 14, 14)
fill(42, 43, 13, 13)
fill(39, 40, 27, 27)    # chunky base
fill(40, 41, 10, 10)    # ceiling stalactite

# H: small chamber off F's top-right corner (item room).
fill(37, 39, 10, 10)    # ceiling
fill(40, 41, 10, 11)    # east wall, doorway open below
carve(36, 39, 10, 13)   # interior
fill(37, 39, 13, 13)    # floor

# ---- doors / shafts --------------------------------------------------------
carve(14, 14, 26, 27)   # A <-> B door
carve(35, 36, 26, 27)   # B <-> D door
carve(13, 14, 8, 9)     # C <-> E door
carve(14, 16, 8, 9)     # E lowered alcove
carve(31, 31, 6, 7)     # E <-> G door
carve(21, 22, 8, 9)     # E <-> F shaft
carve(24, 25, 21, 22)   # F -> B drop shaft
carve(42, 43, 8, 9)     # G -> D drop shaft

# ---- tunnels (1 tile high, below the walking floor) ------------------------
# T1: A <-> B, runs at y28 under the y27 floor; sunken pits both ends
carve(7, 8, 28, 28)     # pit in A
carve(8, 19, 28, 28)    # tunnel
carve(20, 20, 28, 28)   # pit in B
# T1b: B internal
carve(25, 26, 28, 28)   # pit left of plateau
carve(32, 32, 28, 28)   # pit right of plateau
carve(25, 32, 28, 28)   # tunnel under plateau
# T2: F <-> D, runs at y21 under F's floor
carve(33, 34, 21, 21)   # pit in F
carve(34, 39, 21, 21)   # tunnel through F floor, F|D wall, and D block

# ---- ASCII preview ---------------------------------------------------------
for y in range(H):
    print(f"{y:3d} " + "".join("#" if solid[y][x] else "." for x in range(W)))

# ---- tile picking (3x3 blob + thin-platform row 5) ------------------------
def is_solid(x, y):
    return True if not (0 <= x < W and 0 <= y < H) else solid[y][x]

def atlas(x, y):
    up, dn = not is_solid(x, y - 1), not is_solid(x, y + 1)
    lf, rt = not is_solid(x - 1, y), not is_solid(x + 1, y)
    if up and dn:  # one-tile-thick strip -> platform tiles
        return (1 if lf else 3 if rt else 2, 5)
    row = 3 if up else 5 if dn else 4
    col = 1 if lf else 3 if rt else 2
    return (col, row)

# ---- encode & write level.tscn -----------------------------------------------
buf = bytearray(struct.pack("<H", 0))
count = 0
for y in range(H):
    for x in range(W):
        if solid[y][x]:
            ax, ay = atlas(x, y)
            buf += struct.pack("<hhhhhh", x, y, 0, ax, ay, 0)
            count += 1
b64 = base64.b64encode(bytes(buf)).decode()

out = os.path.join(os.path.dirname(__file__), "..", "scenes", "levels", "section1.tscn")
with open(out, "w") as f:
    f.write('[gd_scene format=4]\n\n')
    f.write('[ext_resource type="TileSet" path="res://scenes/resources/terrain_tileset.tres" id="1_2q6dc"]\n\n')
    f.write('[node name="Terrain" type="TileMapLayer" unique_id=322632070]\n')
    f.write(f'tile_map_data = PackedByteArray("{b64}")\n')
    f.write('tile_set = ExtResource("1_2q6dc")\n')
print(f"wrote {count} terrain tiles -> {os.path.abspath(out)}")
