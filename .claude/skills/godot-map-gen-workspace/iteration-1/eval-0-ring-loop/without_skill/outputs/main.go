package main

import (
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
)

// Tile record: x, y, source_id, atlas_x, atlas_y, alt_id (all int16 LE).
type tile struct {
	x, y     int16
	srcID    int16
	atlasX   int16
	atlasY   int16
	altID    int16
}

// Atlas coordinates for boundary tiles (source_id 0).
// Rows 7/8/9 = top/middle/bottom; cols 1/2/3 = left/center/right.
// Row 11 = thin horizontal platform.
const (
	srcBoundary   int16 = 0
	srcBackground int16 = 3
)

// Boundary atlas helpers -----------------------------------------------

func topLeft() (int16, int16)     { return 1, 7 }
func topCenter() (int16, int16)   { return 2, 7 }
func topRight() (int16, int16)    { return 3, 7 }
func midLeft() (int16, int16)     { return 1, 8 }
func midCenter() (int16, int16)   { return 2, 8 }
func midRight() (int16, int16)    { return 3, 8 }
func botLeft() (int16, int16)     { return 1, 9 }
func botCenter() (int16, int16)   { return 2, 9 }
func botRight() (int16, int16)    { return 3, 9 }
func thinLeft() (int16, int16)    { return 1, 11 }
func thinCenter() (int16, int16)  { return 2, 11 }
func thinRight() (int16, int16)   { return 3, 11 }

// boundaryAtlas picks the right atlas coord based on a tile's neighbor
// exposure within a filled rectangle. dx/dy are 0-based offsets inside
// the rect; w/h are the rect dimensions.
func boundaryAtlas(dx, dy, w, h int) (int16, int16) {
	top := dy == 0
	bot := dy == h-1
	left := dx == 0
	right := dx == w-1

	switch {
	case top && left:
		return topLeft()
	case top && right:
		return topRight()
	case top:
		return topCenter()
	case bot && left:
		return botLeft()
	case bot && right:
		return botRight()
	case bot:
		return botCenter()
	case left:
		return midLeft()
	case right:
		return midRight()
	default:
		return midCenter()
	}
}

// Room geometry --------------------------------------------------------

// Each room is defined by its bounding box (top-left corner + size) in
// tile coordinates on a 100x60 grid.
type room struct {
	x, y, w, h int
}

// corridor connects two rooms with a horizontal or vertical passage.
type corridor struct {
	x, y, w, h int
}

func main() {
	// ---- Layout: 4 rooms in a ring on a 100×60 grid ----
	//
	//   Room 0 (top-left)  ---- corridor ----  Room 1 (top-right)
	//       |                                       |
	//   corridor                                corridor
	//       |                                       |
	//   Room 3 (bot-left)  ---- corridor ----  Room 2 (bot-right)
	//
	rooms := []room{
		{x: 2, y: 2, w: 30, h: 20},   // Room 0 – top-left
		{x: 55, y: 2, w: 30, h: 20},  // Room 1 – top-right
		{x: 55, y: 35, w: 30, h: 20}, // Room 2 – bot-right
		{x: 2, y: 35, w: 30, h: 20},  // Room 3 – bot-left
	}

	corridors := []corridor{
		{x: 32, y: 8, w: 23, h: 6},  // top horizontal (Room 0 → 1)
		{x: 75, y: 22, w: 6, h: 13}, // right vertical  (Room 1 → 2)
		{x: 32, y: 43, w: 23, h: 6}, // bot horizontal  (Room 3 → 2)
		{x: 8, y: 22, w: 6, h: 13},  // left vertical   (Room 0 → 3)
	}

	// Platforms inside each room (thin horizontal shelves).
	type platform struct {
		x, y, length int
	}
	platforms := []platform{
		// Room 0
		{x: 6, y: 12, length: 8},
		{x: 18, y: 16, length: 10},
		{x: 10, y: 8, length: 6},
		// Room 1
		{x: 59, y: 12, length: 8},
		{x: 70, y: 16, length: 10},
		{x: 63, y: 8, length: 6},
		// Room 2
		{x: 59, y: 45, length: 8},
		{x: 70, y: 49, length: 10},
		{x: 63, y: 41, length: 6},
		// Room 3
		{x: 6, y: 45, length: 8},
		{x: 18, y: 49, length: 10},
		{x: 10, y: 41, length: 6},
	}

	// ---- Build tile list ------------------------------------------------

	// Use a map to deduplicate (later entries win).
	type coord struct{ x, y int16 }
	tileMap := make(map[coord]tile)

	addTile := func(x, y, srcID, ax, ay int16) {
		tileMap[coord{x, y}] = tile{x: x, y: y, srcID: srcID, atlasX: ax, atlasY: ay}
	}

	// Helper: fill a rectangle with boundary walls.
	fillWalls := func(rx, ry, rw, rh int) {
		for dy := 0; dy < rh; dy++ {
			for dx := 0; dx < rw; dx++ {
				ax, ay := boundaryAtlas(dx, dy, rw, rh)
				addTile(int16(rx+dx), int16(ry+dy), srcBoundary, ax, ay)
			}
		}
	}

	// Helper: carve the interior of a rectangle (remove boundary tiles
	// leaving only the 1-tile-thick walls, then fill interior with
	// background tiles).
	carveInterior := func(rx, ry, rw, rh int) {
		for dy := 1; dy < rh-1; dy++ {
			for dx := 1; dx < rw-1; dx++ {
				// Replace boundary tile with background.
				addTile(int16(rx+dx), int16(ry+dy), srcBackground, 0, 0)
			}
		}
	}

	// 1. Draw room walls, then carve interiors.
	for _, r := range rooms {
		fillWalls(r.x, r.y, r.w, r.h)
		carveInterior(r.x, r.y, r.w, r.h)
	}

	// 2. Draw corridor walls, then carve corridor interiors.
	for _, c := range corridors {
		fillWalls(c.x, c.y, c.w, c.h)
		carveInterior(c.x, c.y, c.w, c.h)
	}

	// 3. Place thin platforms inside rooms.
	for _, p := range platforms {
		for i := 0; i < p.length; i++ {
			var ax, ay int16
			switch {
			case i == 0:
				ax, ay = thinLeft()
			case i == p.length-1:
				ax, ay = thinRight()
			default:
				ax, ay = thinCenter()
			}
			addTile(int16(p.x+i), int16(p.y), srcBoundary, ax, ay)
		}
	}

	// ---- Encode PackedByteArray -----------------------------------------

	tiles := make([]tile, 0, len(tileMap))
	for _, t := range tileMap {
		tiles = append(tiles, t)
	}

	// 2-byte header + 12 bytes per tile.
	buf := make([]byte, 2+len(tiles)*12)
	binary.LittleEndian.PutUint16(buf[0:2], 0) // header

	for i, t := range tiles {
		off := 2 + i*12
		binary.LittleEndian.PutUint16(buf[off+0:off+2], uint16(t.x))
		binary.LittleEndian.PutUint16(buf[off+2:off+4], uint16(t.y))
		binary.LittleEndian.PutUint16(buf[off+4:off+6], uint16(t.srcID))
		binary.LittleEndian.PutUint16(buf[off+6:off+8], uint16(t.atlasX))
		binary.LittleEndian.PutUint16(buf[off+8:off+10], uint16(t.atlasY))
		binary.LittleEndian.PutUint16(buf[off+10:off+12], uint16(t.altID))
	}

	b64 := base64.StdEncoding.EncodeToString(buf)

	// ---- Write .tscn ----------------------------------------------------

	tscn := fmt.Sprintf(`[gd_scene format=4]

[ext_resource type="TileSet" path="res://scenes/resources/terrain_tileset.tres" id="1_2q6dc"]

[node name="Terrain" type="TileMapLayer" unique_id=322632070]
tile_map_data = PackedByteArray("%s")
`, b64)

	outPath := filepath.Join("scenes", "levels", "level3.tscn")
	if err := os.MkdirAll(filepath.Dir(outPath), 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "mkdir: %v\n", err)
		os.Exit(1)
	}
	if err := os.WriteFile(outPath, []byte(tscn), 0o644); err != nil {
		fmt.Fprintf(os.Stderr, "write: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Wrote %s (%d tiles, %d bytes base64)\n", outPath, len(tiles), len(b64))
}
