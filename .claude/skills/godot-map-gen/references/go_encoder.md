# Go Tilemap Encoder Reference

Complete, working Go code for encoding a tile grid into a Godot `.tscn` file.
Supports both **boundary tiles** (source 0, structural walls with collision) and
**background tiles** (source 3, decorative room backdrops without collision).

## Full template

```go
package main

import (
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
)

const (
	W = 100 // grid width in tiles
	H = 60  // grid height in tiles
)

// solid[y][x] — true means wall/floor tile, false means air
var solid [H][W]bool

// room[y][x] — true means this air cell is inside a room (needs background tile)
// as opposed to outside the map boundary (stays empty)
var room [H][W]bool

func init() {
	// start fully solid, no rooms
	for y := 0; y < H; y++ {
		for x := 0; x < W; x++ {
			solid[y][x] = true
		}
	}
}

// carve sets a rectangle to air and marks it as room interior
func carve(x0, x1, y0, y1 int) {
	for y := y0; y <= y1; y++ {
		for x := x0; x <= x1; x++ {
			solid[y][x] = false
			room[y][x] = true
		}
	}
}

// fill sets a rectangle to solid (for platforms, walls inside rooms)
func fill(x0, x1, y0, y1 int) {
	for y := y0; y <= y1; y++ {
		for x := x0; x <= x1; x++ {
			solid[y][x] = true
		}
	}
}

// isSolid checks a cell, treating out-of-bounds as solid
func isSolid(x, y int) bool {
	if x < 0 || x >= W || y < 0 || y >= H {
		return true
	}
	return solid[y][x]
}

// boundaryAtlas picks the correct boundary tile (source 0) atlas coordinates
// based on neighbor exposure
func boundaryAtlas(x, y int) (int, int) {
	up := !isSolid(x, y-1)
	dn := !isSolid(x, y+1)
	lf := !isSolid(x-1, y)
	rt := !isSolid(x+1, y)

	// one-tile-thick strip → platform tiles (row 11)
	if up && dn {
		col := 2
		if lf {
			col = 1
		} else if rt {
			col = 3
		}
		return col, 11
	}

	row := 8 // interior
	if up {
		row = 7 // top edge
	} else if dn {
		row = 9 // bottom edge
	}

	col := 2 // interior
	if lf {
		col = 1 // left edge
	} else if rt {
		col = 3 // right edge
	}

	return col, row
}

// backgroundAtlas picks a background tile (source 3) atlas coordinate.
// The background atlas is a 64×32 grid of sci-fi panel/pipe tiles.
// Customize this to vary the look per room or zone.
func backgroundAtlas(x, y int) (int, int) {
	// Simple tiling pattern — pick a region from the atlas.
	// Rows 0-3: clean metal panels (good for hallways)
	// Rows 4-7: panels with detail (numbered doors, vents)
	// Rows 8-15: pipe networks (good for shafts, tunnels)
	// Rows 16-31: heavy industrial (good for hubs, deep rooms)
	//
	// Default: tile with a repeating 4x4 block from the clean panel region
	ax := (x % 4) + 0  // columns 0-3
	ay := (y % 4) + 0  // rows 0-3
	return ax, ay
}

// tileRecord encodes a single tile as a 12-byte record
func tileRecord(x, y, sourceID, atlasX, atlasY, altID int) []byte {
	rec := make([]byte, 12)
	binary.LittleEndian.PutUint16(rec[0:2], uint16(int16(x)))
	binary.LittleEndian.PutUint16(rec[2:4], uint16(int16(y)))
	binary.LittleEndian.PutUint16(rec[4:6], uint16(int16(sourceID)))
	binary.LittleEndian.PutUint16(rec[6:8], uint16(int16(atlasX)))
	binary.LittleEndian.PutUint16(rec[8:10], uint16(int16(atlasY)))
	binary.LittleEndian.PutUint16(rec[10:12], uint16(int16(altID)))
	return rec
}

// encodeTileMapData produces the PackedByteArray content (before base64)
func encodeTileMapData() []byte {
	// header: 2-byte LE uint16 = 0
	buf := make([]byte, 2)
	binary.LittleEndian.PutUint16(buf, 0)

	for y := 0; y < H; y++ {
		for x := 0; x < W; x++ {
			if solid[y][x] {
				// Boundary tile (source 0) — structural wall with collision
				ax, ay := boundaryAtlas(x, y)
				buf = append(buf, tileRecord(x, y, 0, ax, ay, 0)...)
			} else if room[y][x] {
				// Background tile (source 3) — decorative, no collision
				ax, ay := backgroundAtlas(x, y)
				buf = append(buf, tileRecord(x, y, 3, ax, ay, 0)...)
			}
			// else: outside map boundary, no tile placed
		}
	}
	return buf
}

// writeTSCN writes the complete .tscn scene file
func writeTSCN(path string, tilesetPath string, tilesetID string, uniqueID int) error {
	data := encodeTileMapData()
	b64 := base64.StdEncoding.EncodeToString(data)

	content := fmt.Sprintf(`[gd_scene format=4]

[ext_resource type="TileSet" path="%s" id="%s"]

[node name="Terrain" type="TileMapLayer" unique_id=%d]
tile_map_data = PackedByteArray("%s")
tile_set = ExtResource("%s")
`, tilesetPath, tilesetID, uniqueID, b64, tilesetID)

	return os.WriteFile(path, []byte(content), 0644)
}

// printASCII prints an ASCII preview of the map
// # = solid boundary, . = room air (background), ' ' = outside
func printASCII() {
	for y := 0; y < H; y++ {
		fmt.Printf("%3d ", y)
		for x := 0; x < W; x++ {
			if solid[y][x] {
				fmt.Print("#")
			} else if room[y][x] {
				fmt.Print(".")
			} else {
				fmt.Print(" ")
			}
		}
		fmt.Println()
	}
}

func main() {
	// ---- DESIGN YOUR MAP HERE ----

	// Example: carve rooms (marks cells as air + room interior)
	// carve(x0, x1, y0, y1)

	// Example: add interior platforms
	// fill(x0, x1, y0, y1)

	// Example: carve connections
	// carve(x0, x1, y0, y1)

	// ---- END MAP DESIGN ----

	printASCII()

	// Resolve output path relative to this tool's location
	outPath := filepath.Join("scenes", "levels", "level.tscn")

	err := writeTSCN(
		outPath,
		"res://scenes/resources/terrain_tileset.tres",
		"1_2q6dc",
		322632070,
	)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("wrote tilemap -> %s\n", outPath)
}
```

## Tileset reference values

| Level | Tileset path | ext_resource ID | unique_id |
|---|---|---|---|
| 1 | `res://scenes/resources/terrain_tileset.tres` | `1_2q6dc` | 322632070 |
| 2 | `res://scenes/resources/terrain2_tileset.tres` | `1_t2lvl` | 322632071 |

## Atlas source IDs

| Source ID | Texture | Role | Physics |
|---|---|---|---|
| 0 | `Terrain (32x32).png` / `Terrain2_32.png` | Boundary — wall/floor surfaces | Yes (collision layer 1) |
| 3 | `Terrain.png` | Background — decorative room fill | No |

Source 3 is only defined in `terrain_tileset.tres` (level 1). Level 2's tileset
(`terrain2_tileset.tres`) currently has only source 0.

## Background atlas regions (source 3, Terrain.png)

The 64×32 tile grid is organized roughly as:

| Atlas rows | Visual style | Good for |
|---|---|---|
| 0–3 | Clean metal panels, bolted plates | Hallways, corridors |
| 4–7 | Panels with labels ("04", "01"), vents | Labeled rooms, doors |
| 8–11 | Pipe junctions, conduits | Shafts, tunnels, mechanical areas |
| 12–15 | Mixed panels + pipes | Transitional areas |
| 16–23 | Heavy pipe networks, industrial | Deep rooms, hubs |
| 24–31 | Dense pipes, dark industrial | Basements, hidden areas |

Use different atlas regions per room to give each area visual identity. For example,
the hub room might use rows 16–23 (heavy industrial), while hallways use rows 0–3
(clean panels).

## Per-room background styling

To vary backgrounds by room, track which room each air cell belongs to:

```go
// roomID[y][x] — 0 = not a room, 1+ = room identifier
var roomID [H][W]int

// carveRoom sets a rectangle to air and assigns a room ID
func carveRoom(x0, x1, y0, y1, id int) {
	for y := y0; y <= y1; y++ {
		for x := x0; x <= x1; x++ {
			solid[y][x] = false
			room[y][x] = true
			roomID[y][x] = id
		}
	}
}

// backgroundAtlasForRoom picks tiles based on room identity
func backgroundAtlasForRoom(x, y, id int) (int, int) {
	switch id {
	case 1: // Hallway — clean panels
		return (x % 4), (y % 4)
	case 2: // Shaft — pipes
		return (x % 4) + 8, (y % 4) + 8
	case 3: // Hub — heavy industrial
		return (x % 4) + 16, (y % 4) + 16
	default:
		return (x % 4), (y % 4)
	}
}
```

## Mirroring a map

To create a horizontally mirrored variant (like level2 mirrors level1):

```go
func mirror() {
	var mirroredSolid [H][W]bool
	var mirroredRoom [H][W]bool
	for y := 0; y < H; y++ {
		for x := 0; x < W; x++ {
			mirroredSolid[y][x] = solid[y][W-1-x]
			mirroredRoom[y][x] = room[y][W-1-x]
		}
	}
	solid = mirroredSolid
	room = mirroredRoom
}
```

Call `mirror()` after all carve/fill operations and before atlas picking.

## Room connectivity verification

To verify that the map has no dead-end rooms (every room connects to ≥ 2 others),
flood-fill from each room and check reachability. Here's a simple BFS:

```go
type Point struct{ X, Y int }

func floodFill(startX, startY int) map[Point]bool {
	visited := map[Point]bool{}
	queue := []Point{{startX, startY}}
	visited[queue[0]] = true

	for len(queue) > 0 {
		p := queue[0]
		queue = queue[1:]
		for _, d := range [][2]int{{0, -1}, {0, 1}, {-1, 0}, {1, 0}} {
			nx, ny := p.X+d[0], p.Y+d[1]
			np := Point{nx, ny}
			if nx >= 0 && nx < W && ny >= 0 && ny < H && !solid[ny][nx] && !visited[np] {
				visited[np] = true
				queue = append(queue, np)
			}
		}
	}
	return visited
}
```

Use this to confirm all air cells are reachable from each other (single connected
component). If any room is isolated, add a connection.
