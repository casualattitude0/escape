#!/usr/bin/env python3
"""Generate scenes/level.tscn — Metroid Dread-style asymmetric map.

Layout (tile grid 100x60, 32px tiles, y down):

  Rooms                       Openings (>=2 each)              Tunnels (0-2 each)
  A SpawnHall  x4..26  y44..54  door->B, shaft->C, T1          T1 (under floor, y56)
  B LowerHall  x30..68 y46..54  door->A, door->D, drop<-F, T1  T1
  C LeftShaft  x18..24 y12..43  open->A, door->E               -
  E TopCorridor x28..60 y8..15  door->C, door->G, drop->F      -
  F CentralHub x40..70 y19..40  drop<-E, shaft->B, T2          T2 (under floor, y42)
  G TopRight   x64..93 y8..14   door->E, shaft->D              -
  D RightShaft x74..93 y19..54  shaft<-G, door->B, T2          T2

  Tunnels are 1 tile high, run BELOW the walking floor, entered by
  sliding/crawling into a sunken pit (2 deep on the F/A sides).

Player metrics: jump rise <= 3 tiles, horizontal gap while rising 3 <= 2 tiles,
stand height ~1.6 tiles (2 clear rows needed above any stand row).
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

# ---- room interiors -------------------------------------------------------
carve(4, 26, 44, 54)    # A SpawnHall
carve(30, 68, 46, 54)   # B LowerHall
carve(18, 24, 12, 43)   # C LeftShaft (opens into A's ceiling)
carve(28, 60, 8, 15)    # E TopCorridor
carve(40, 70, 19, 40)   # F CentralHub
carve(64, 93, 8, 14)    # G TopRight
carve(74, 93, 19, 54)   # D RightShaft

# ---- interior structures (fill) -------------------------------------------
# A: climb chain up to C shaft (stand rows 55 -> 52 -> 49 -> 46)
fill(8, 10, 52, 52)
fill(13, 15, 49, 49)
fill(18, 20, 46, 46)
fill(4, 5, 53, 54)      # corner step by the left wall
fill(22, 23, 54, 54)    # floor bump under the C shaft mouth
fill(10, 12, 44, 44)    # ceiling stalactite
# C: zig-zag shaft platforms, rise 3 per hop, ledge row 19 leads to door
for i, row in enumerate(range(43, 21, -3)):        # 43 40 37 34 31 28 25 22
    x0 = 22 if i % 2 == 0 else 18
    fill(x0, x0 + 2, row, row)
fill(22, 24, 19, 19)                               # exit ledge -> door to E
# C: side pockets carved into the shaft walls (future item nooks)
carve(14, 17, 26, 30)   # left pocket: drop in from the row-28 platform,
                        # jump back out (stand 31 -> 28, rise 3)
carve(25, 27, 36, 39)   # right pocket: hop down from the row-37 platform
# E: raised right floor (stand 14 vs 16) + shelf + details
fill(46, 60, 14, 15)
fill(34, 35, 15, 15)    # floor bump on the lower section
fill(52, 54, 11, 11)    # high shelf above the raised floor (rise 3,
                        # 2 rows of walking clearance beneath)
fill(36, 38, 8, 8)      # ceiling bumps
fill(57, 59, 8, 8)
# B: plateau + floating platform + ceiling stalactites
fill(54, 60, 52, 54)
fill(36, 38, 52, 52)
fill(33, 34, 46, 46)
fill(44, 46, 46, 46)
# F: platforms (floor stand 41; catches the drop from E at x41..43),
#    then a chain climbing to the upper-right corner
fill(46, 49, 38, 38)
fill(41, 44, 35, 35)
fill(46, 49, 32, 32)
# F: left ladder back up to E — ends at a ledge inside the shaft mouth
# (x41..42) so the player can jump up through the hole; x43 stays open
# as the drop channel from E
fill(41, 44, 29, 29)
fill(46, 49, 26, 26)
fill(41, 43, 24, 24)
fill(44, 46, 22, 22)
fill(41, 42, 19, 19)    # climb-out ledge (stand 19 -> jump to E stand 16)
fill(51, 54, 29, 29)
# F: loft partition in the upper-right quarter. Floor at y28, partition
# wall hanging from the ceiling at x60 with a 3-tall doorway (y25..27).
# Inside the loft two platforms climb to nothing fancy; the east end
# jumps straight into H (loft stand 28 -> H floor stand 26, rise 2).
fill(56, 70, 28, 28)    # loft floor (walk row 28, F main air below y29)
fill(60, 60, 19, 24)    # partition wall, doorway open at y25..27
fill(66, 69, 25, 25)    # loft platform (rise 3 from loft floor)
fill(61, 63, 22, 22)    # loft high platform (rise 3, gap 2)
fill(57, 58, 39, 40)    # low pillar on the floor (hop over, rise 2)
fill(53, 55, 19, 19)    # ceiling stalactite
# G: decorative step, raised right end, hanging platform
fill(74, 76, 14, 14)
fill(88, 93, 13, 14)    # raised floor at the right end (rise 2)
fill(78, 80, 12, 12)    # floating platform (rise 3)
fill(67, 69, 8, 8)      # ceiling bump
# D: tunnel block + entry ledge, then zig-zag climb chain
fill(74, 78, 41, 41)    # tunnel ceiling
fill(74, 78, 43, 44)    # tunnel floor block
fill(79, 85, 43, 43)    # entry ledge (slide left into tunnel)
fill(76, 79, 52, 52)
fill(82, 85, 49, 49)
fill(88, 91, 46, 46)
fill(88, 91, 40, 40)
fill(83, 86, 37, 37)
fill(88, 91, 34, 34)
fill(83, 86, 31, 31)
fill(88, 91, 28, 28)
fill(83, 86, 25, 25)
fill(77, 79, 53, 54)    # chunky base under the first platform
fill(80, 82, 19, 19)    # ceiling stalactite

# H: small chamber off F's top-right corner (item room).
# West face opens into F (walk off the x66..69 shelf and drift right in);
# east doorway at y23..25 hops to/from D's top platform (x83..86, stand 25).
fill(74, 79, 19, 19)    # ceiling (joins the x80..82 stalactite)
fill(80, 81, 20, 22)    # east wall, doorway kept open below (y23..25)
carve(71, 79, 20, 25)   # interior, carved through the F|D wall
fill(74, 79, 26, 26)    # floor (x71..73 wall top completes it, stand 26)

# ---- doors / shafts --------------------------------------------------------
carve(27, 29, 51, 54)   # A <-> B door
carve(69, 73, 51, 54)   # B <-> D door
carve(25, 27, 16, 18)   # C <-> E door (via lowered alcove)
carve(28, 31, 16, 18)   # E lowered alcove floor (stand 19, step up to 16)
carve(32, 33, 16, 17)   # half-step out of the alcove (19 -> 18 -> 16)
carve(61, 63, 12, 14)   # E <-> G door (1-tile step down into G)
carve(41, 43, 16, 18)   # E <-> F shaft (two-way: ledge at stand 19 below)
carve(44, 45, 17, 18)   # undercut right of the shaft so the rise-3 jump
                        # from the x44..46 platform doesn't hit the ceiling
carve(47, 49, 41, 45)   # F -> B drop shaft
carve(84, 86, 15, 18)   # G -> D drop shaft

# ---- tunnels (1 tile high, below the walking floor) ------------------------
# T1: A <-> B, runs at y56 under the y55 floor; sunken pits both ends
carve(14, 15, 55, 56)   # pit in A
carve(16, 38, 56, 56)   # tunnel (ceiling y55 stays solid)
carve(39, 40, 55, 56)   # pit in B
# T1b: B internal, runs at y56 under the plateau (slide in, pop out)
carve(50, 51, 55, 55)   # pit left of the plateau
carve(63, 64, 55, 55)   # pit right of the plateau
carve(50, 64, 56, 56)   # tunnel under the plateau
# T2: F <-> D, runs at y42 under F's floor (stand row 41)
carve(66, 67, 41, 42)   # pit in F
carve(68, 78, 42, 42)   # tunnel through F floor, F|D wall, and D block

# ---- ASCII preview ---------------------------------------------------------
for y in range(H):
    print(f"{y:3d} " + "".join("#" if solid[y][x] else "." for x in range(W)))

# ---- tile picking (3x3 blob + thin-platform row 11) ------------------------
def is_solid(x, y):
    return True if not (0 <= x < W and 0 <= y < H) else solid[y][x]

def atlas(x, y):
    up, dn = not is_solid(x, y - 1), not is_solid(x, y + 1)
    lf, rt = not is_solid(x - 1, y), not is_solid(x + 1, y)
    if up and dn:  # one-tile-thick strip -> platform tiles
        return (1 if lf else 3 if rt else 2, 11)
    row = 7 if up else 9 if dn else 8
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

out = os.path.join(os.path.dirname(__file__), "..", "scenes", "levels", "level.tscn")
with open(out, "w") as f:
    f.write('[gd_scene format=4]\n\n')
    f.write('[ext_resource type="TileSet" path="res://scenes/resources/terrain_tileset.tres" id="1_2q6dc"]\n\n')
    f.write('[node name="Terrain" type="TileMapLayer" unique_id=322632070]\n')
    f.write(f'tile_map_data = PackedByteArray("{b64}")\n')
    f.write('tile_set = ExtResource("1_2q6dc")\n')
print(f"wrote {count} terrain tiles -> {os.path.abspath(out)}")
