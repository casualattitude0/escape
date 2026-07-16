---
name: godot-map-gen
description: Design and generate Godot tilemap levels using Go for this tag/chase multiplayer game. Use whenever the user wants to create a new map, modify level geometry, design rooms, or generate a .tscn tilemap file. Also use when the user discusses map layout, room connectivity, chase paths, roundabout routes, or level design for the game — even if they don't explicitly say "generate" or "tilemap".
---

# Godot Map Generator (Go)

Generate `.tscn` tilemap scenes for this Godot 4.x multiplayer tag game using Go.
The game is an asymmetric multiplayer where a Runner flees from Hunters — map design
directly determines whether chases are fun.

## When to read reference files

- **First time writing or modifying a Go map generator**: read `references/go_encoder.md`
  for the complete Go template including the binary tilemap encoder, atlas tile picker,
  and .tscn writer. Don't reinvent this — copy and adapt.
- **When designing room layouts**: re-read the Tag Map Design Principles below.

## Target format

- **Grid**: 100 wide × 60 tall tiles, each 32×32 px (world = 3200×1920 px)
- **Scene node**: `TileMapLayer` (Godot 4.x), not the legacy `TileMap`
- **Tileset**: referenced via `ext_resource`, never inlined as `sub_resource`
  - Level 1: `res://scenes/resources/terrain_tileset.tres` (id `"1_2q6dc"`, unique_id 322632070)
  - Level 2: `res://scenes/resources/terrain2_tileset.tres` (id `"1_t2lvl"`, unique_id 322632071)
- **Output path**: `scenes/levels/levelN.tscn` — never directly in `scenes/`
- **Binary encoding**: `PackedByteArray` with 2-byte header (uint16 LE = 0) followed by
  12-byte records per tile (6 × int16 LE: x, y, **source_id**, atlas_x, atlas_y, alt_id),
  then base64-encoded

## Two tile layers: Boundary and Background

The tileset contains two atlas sources that serve different roles. Both go into the
same `TileMapLayer` node in one `tile_map_data` blob — the **source_id** field (third
int16 in each record) selects which atlas source a tile comes from.

### Source 0 — Boundary tiles (structural)

Texture: `Terrain (32x32).png` (level 1) / `Terrain2_32.png` (level 2)

Brick/panel wall tiles with physics collision. These form the visible surfaces where
solid meets air. Picked automatically based on neighbor exposure:

| Condition | Atlas (col, row) | Meaning |
|---|---|---|
| exposed above + left | (1, 7) | top-left corner |
| exposed above | (2, 7) | top edge |
| exposed above + right | (3, 7) | top-right corner |
| exposed left | (1, 8) | left edge |
| interior (no exposure) | (2, 8) | center fill |
| exposed right | (3, 8) | right edge |
| exposed below + left | (1, 9) | bottom-left corner |
| exposed below | (2, 9) | bottom edge |
| exposed below + right | (3, 9) | bottom-right corner |
| exposed above AND below + left | (1, 11) | thin platform left-end |
| exposed above AND below | (2, 11) | thin platform middle |
| exposed above AND below + right | (3, 11) | thin platform right-end |

The "exposed above AND below" check takes priority — a one-tile-thick floor uses row 11.

### Source 3 — Background tiles (decorative)

Texture: `Terrain.png` (level 1 only — 64 cols × 32 rows grid of sci-fi panels, pipes,
machinery). No physics collision. These fill the air cells behind the player to give
rooms visual depth instead of a flat color.

The atlas coordinates span (0,0) to (63,31). Tiles show metal panels, pipe networks,
vents, numbered doors ("04", "01"), "SEALED" labels, and industrial detailing. Pick
coords that match the room's mood — plain panels for hallways, pipe-heavy tiles for
shafts and tunnels.

**When to place background tiles:**
- Air cells inside rooms (not the open sky outside the map boundary)
- Behind platforms and in visible gaps where the player can see through
- Not needed for cells that are already filled with solid boundary tiles

**Encoding difference**: same 12-byte record format, but set source_id=3 instead of 0:
```
struct.pack("<hhhhhh", x, y, 3, atlas_x, atlas_y, 0)
//                         ^ source_id = 3
```

## Tag Map Design Principles

These principles come from what makes tag/chase games fun. A bad map makes the
Runner uncatchable or the Hunters unescapable — either extreme kills the game.

### 1. Loops are everything ("roundabout" paths)

Every room must connect to at least two other rooms, forming circuits. A Runner
who reaches a dead end is caught. A Hunter who can only approach from one direction
is dodged trivially. The map's room graph should have **no leaves** — every node
has degree ≥ 2.

Good connectivity patterns:
- **Ring**: A→B→C→D→A (minimum viable loop)
- **Figure-8**: two rings sharing a hub room (the hub becomes a high-tension zone)
- **Ladder**: two parallel paths with cross-links (Runners weave, Hunters split)

### 2. Few rooms, rich interiors

3–7 rooms is the sweet spot. Fewer and chases are too short; more and players
never meet. Each room should have enough internal geometry (platforms, pillars,
pits) that movement within the room is interesting, not just flat running.

Room types that work well for tag:
- **Hall**: wide and flat, fast sprinting, platforms break sightlines
- **Shaft**: vertical, zig-zag climb chains, fast to fall / slow to climb
- **Hub**: large central room, multiple entrances, internal obstacles
- **Tunnel**: 1-tile-high crawl passage, slow but hidden (Runners love these)

### 3. Asymmetric advantage

Connections should favor different traversal skills:
- **Drop shafts**: fast one-way down (Runners escape downward, Hunters can't
  follow upward without climbing)
- **Climb chains**: platforms spaced ≤ 3 tiles vertically (jump rise limit),
  slow to ascend (gives the chaser time to cut around)
- **Crawl tunnels**: 1-tile-high passages below floors, entered via sunken pits.
  Slow movement but invisible on the Hunter minimap

### 4. Player metrics (hard constraints)

These are physics constraints from the game engine — violating them makes
geometry untraversable:
- **Jump rise**: ≤ 3 tiles vertically
- **Horizontal gap while rising 3**: ≤ 2 tiles
- **Standing height**: ~1.6 tiles (need 2 clear rows above any walkable surface)
- **Crawl height**: 1 tile (tunnel passages)

### 5. Spawn placement

The existing game places spawns procedurally using `LevelLayout` / `LevelLayout2`,
which scans for standable floor tiles per room. The map generator doesn't need to
place spawns, but rooms labeled for spawning should have ample flat floor tiles.

## Go program structure

A map generator Go program should follow this pattern:

```
1. Define the grid (100×60 bool array, true = solid)
2. Start with everything solid
3. Carve rooms (set regions to false)
4. Add interior structures (set cells back to true — platforms, pillars, walls)
5. Carve connections (doors, shafts, tunnels between rooms)
6. For each solid cell: pick boundary atlas tile (source 0) based on neighbors
7. For each air cell inside rooms: pick background atlas tile (source 3)
8. Encode ALL tiles to PackedByteArray (header + tile records, base64)
9. Write the .tscn file
```

The reference file `references/go_encoder.md` has a complete, working Go template
for steps 6–8. Focus your design effort on steps 2–5 (the fun part).

## Validating output

After generating a `.tscn`, verify it loads:

```sh
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --quit-after 20
```

Grep stderr for errors, filtering known noise (`d3d12|vulkan|freetype|_ensure_cache`).

## Companion files that may need updating

When creating a genuinely new level (not just regenerating an existing one):
- `scripts/world/level_layoutN.gd` — room definitions for procedural spawns
- `scripts/world/worldN.gd` — world controller, spawn positions
- `scenes/levels/worldN.tscn` — instances the level and adds game systems
