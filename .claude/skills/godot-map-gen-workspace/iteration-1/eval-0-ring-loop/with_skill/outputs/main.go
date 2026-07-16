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
var room [H][W]bool

// roomID[y][x] — 0 = not a room, 1+ = room identifier
var roomID [H][W]int

func init() {
	// start fully solid
	for y := 0; y < H; y++ {
		for x := 0; x < W; x++ {
			solid[y][x] = true
		}
	}
}

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

// carve sets a rectangle to air and marks it as room interior (for corridors)
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
func boundaryAtlas(x, y int) (int, int) {
	up := !isSolid(x, y-1)
	dn := !isSolid(x, y+1)
	lf := !isSolid(x-1, y)
	rt := !isSolid(x+1, y)

	// one-tile-thick strip -> platform tiles (row 11)
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

// backgroundAtlasForRoom picks tiles based on room identity
func backgroundAtlasForRoom(x, y, id int) (int, int) {
	switch id {
	case 1: // Room A (top-left) — clean metal panels
		return (x % 4), (y % 4)
	case 2: // Room B (top-right) — panels with vents/labels
		return (x % 4) + 4, (y % 4) + 4
	case 3: // Room C (bottom-right) — pipe networks
		return (x % 4) + 8, (y % 4) + 8
	case 4: // Room D (bottom-left) — heavy industrial
		return (x % 4) + 16, (y % 4) + 16
	default: // corridors — clean panels
		return (x % 4), (y % 4)
	}
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
	buf := make([]byte, 2)
	binary.LittleEndian.PutUint16(buf, 0)

	for y := 0; y < H; y++ {
		for x := 0; x < W; x++ {
			if solid[y][x] {
				ax, ay := boundaryAtlas(x, y)
				buf = append(buf, tileRecord(x, y, 0, ax, ay, 0)...)
			} else if room[y][x] {
				id := roomID[y][x]
				ax, ay := backgroundAtlasForRoom(x, y, id)
				buf = append(buf, tileRecord(x, y, 3, ax, ay, 0)...)
			}
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
	// =====================================================================
	// LEVEL 3: Ring Loop — 4 rooms connected A -> B -> C -> D -> A
	//
	// Layout (100x60 grid):
	//
	//   Room A (top-left)  ---[top corridor]---  Room B (top-right)
	//       |                                        |
	//   [left shaft]                            [right shaft]
	//       |                                        |
	//   Room D (bot-left)  ---[bot corridor]---  Room C (bot-right)
	//
	// =====================================================================

	// --- Room A: top-left hall (x:5-35, y:5-22) ---
	carveRoom(5, 35, 5, 22, 1)
	// Platforms inside Room A
	fill(10, 20, 14, 14) // mid-level platform (1-tile thick)
	fill(24, 32, 10, 10) // upper-right platform
	fill(8, 14, 19, 19)  // lower-left platform

	// --- Room B: top-right shaft-style room (x:62-92, y:5-22) ---
	carveRoom(62, 92, 5, 22, 2)
	// Platforms inside Room B — staggered for vertical play
	fill(65, 73, 19, 19) // bottom-left platform
	fill(76, 84, 14, 14) // mid-right platform
	fill(68, 76, 9, 9)   // upper-mid platform
	fill(82, 89, 19, 19) // bottom-right platform

	// --- Room C: bottom-right hub (x:62-92, y:37-54) ---
	carveRoom(62, 92, 37, 54, 3)
	// Platforms inside Room C — open hub with obstacles
	fill(70, 74, 45, 45) // central pillar top
	fill(70, 74, 46, 50) // central pillar body
	fill(64, 69, 48, 48) // left low platform
	fill(80, 90, 43, 43) // right high platform
	fill(64, 72, 41, 41) // left high platform

	// --- Room D: bottom-left hall (x:5-35, y:37-54) ---
	carveRoom(5, 35, 37, 54, 4)
	// Platforms inside Room D
	fill(12, 22, 45, 45) // mid-level platform
	fill(26, 33, 50, 50) // lower-right platform
	fill(7, 15, 41, 41)  // upper-left platform
	fill(20, 28, 49, 49) // mid-lower platform

	// =====================================================================
	// Connections (corridors forming the ring)
	// =====================================================================

	// --- Top corridor: A <-> B (horizontal, y:11-14, x:35-62) ---
	// 4 tiles tall = 2 clear rows of air above floor, traversable
	carve(35, 62, 11, 14)

	// --- Right shaft: B <-> C (vertical, x:76-80, y:22-37) ---
	// 5 tiles wide, connects bottom of B to top of C
	carve(76, 80, 22, 37)
	// Step platforms in shaft so players can climb back up (max 3 tile jump)
	fill(76, 78, 27, 27) // left step
	fill(78, 80, 32, 32) // right step

	// --- Bottom corridor: C <-> D (horizontal, y:44-47, x:35-62) ---
	// 4 tiles tall passage
	carve(35, 62, 44, 47)

	// --- Left shaft: D <-> A (vertical, x:18-22, y:22-37) ---
	// 5 tiles wide, connects bottom of A to top of D
	carve(18, 22, 22, 37)
	// Step platforms in shaft for climbing (max 3 tile jump rise)
	fill(20, 22, 27, 27) // right step
	fill(18, 20, 32, 32) // left step

	// =====================================================================
	// Output
	// =====================================================================

	printASCII()

	outPath := filepath.Join("scenes", "levels", "level3.tscn")

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
