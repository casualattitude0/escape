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

// solid[y][x] -- true means wall/floor tile, false means air
var solid [H][W]bool

// room[y][x] -- true means this air cell is inside a room (needs background tile)
var room [H][W]bool

// roomID[y][x] -- 0 = outside, 1 = hub, 2 = left room, 3 = right room, 4 = tunnel
var roomID [H][W]int

func init() {
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

// backgroundAtlasForRoom picks background tiles based on room identity
func backgroundAtlasForRoom(x, y, id int) (int, int) {
	switch id {
	case 1: // Hub -- heavy industrial (rows 16-19)
		return (x % 4) + 16, (y % 4) + 16
	case 2: // Left room -- pipes and conduits (rows 8-11)
		return (x % 4) + 8, (y % 4) + 8
	case 3: // Right room -- panels with labels (rows 4-7)
		return (x % 4) + 4, (y % 4) + 4
	case 4: // Tunnels -- dense dark industrial (rows 24-27)
		return (x % 4) + 24, (y % 4) + 24
	default:
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
				ax, ay := backgroundAtlasForRoom(x, y, roomID[y][x])
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
	// ================================================================
	// ARENA LAYOUT: Central hub + 2 side rooms + tunnels with loops
	// ================================================================
	//
	// Layout sketch (not to scale):
	//
	//          upper-left tunnel     upper-right tunnel
	//     +----------+   +-----------------+   +----------+
	//     | LEFT     |===|                 |===| RIGHT    |
	//     | ROOM     |   |   CENTRAL HUB   |   | ROOM     |
	//     | (pipes)  |===|  (platforms)    |===| (panels) |
	//     +----------+   +-----------------+   +----------+
	//          lower-left tunnel     lower-right tunnel
	//
	// Two tunnels per side creates loops: Runner can enter left room
	// from upper tunnel and exit via lower tunnel (or vice versa).

	// --- Central Hub (room 1) ---
	// Large room: x=30..69, y=8..51 (40 wide, 44 tall)
	carveRoom(30, 69, 8, 51, 1)

	// --- Left Side Room (room 2) ---
	// Smaller: x=5..25, y=16..44 (21 wide, 29 tall)
	carveRoom(5, 25, 16, 44, 2)

	// --- Right Side Room (room 3) ---
	// Smaller: x=74..94, y=16..44 (21 wide, 29 tall)
	carveRoom(74, 94, 16, 44, 3)

	// --- Tunnels (room 4) ---
	// Upper-left tunnel: 3 tiles tall (crawl-friendly)
	carveRoom(25, 30, 20, 22, 4)
	// Lower-left tunnel: 3 tiles tall
	carveRoom(25, 30, 40, 42, 4)
	// Upper-right tunnel: 3 tiles tall
	carveRoom(69, 74, 20, 22, 4)
	// Lower-right tunnel: 3 tiles tall
	carveRoom(69, 74, 40, 42, 4)

	// ================================================================
	// HUB PLATFORMS -- lots of vertical chasing opportunities
	// ================================================================
	// Platforms are staggered left-right at different heights so players
	// must jump between them, creating vertical chase routes.

	// Ground floor platforms (near bottom of hub)
	fill(33, 42, 48, 48) // left ground platform
	fill(57, 66, 48, 48) // right ground platform

	// Level 2 platforms
	fill(44, 55, 44, 44) // center platform
	fill(32, 37, 42, 42) // far-left ledge
	fill(62, 67, 42, 42) // far-right ledge

	// Level 3 platforms
	fill(36, 45, 38, 38) // left-center
	fill(54, 63, 38, 38) // right-center

	// Level 4 platforms -- mid-height
	fill(42, 57, 34, 34) // wide center platform
	fill(31, 36, 33, 33) // left wall shelf
	fill(63, 68, 33, 33) // right wall shelf

	// Level 5 platforms
	fill(35, 42, 29, 29) // left
	fill(57, 64, 29, 29) // right

	// Level 6 platforms
	fill(44, 55, 25, 25) // center high
	fill(32, 38, 24, 24) // far-left high
	fill(61, 67, 24, 24) // far-right high

	// Level 7 platforms -- near ceiling
	fill(38, 47, 20, 20) // left upper
	fill(52, 61, 20, 20) // right upper

	// Top platforms
	fill(43, 56, 15, 15) // center crown
	fill(33, 39, 14, 14) // left crown
	fill(60, 66, 14, 14) // right crown

	// Pillars in the hub for sightline breaks (2 wide, 4 tall each)
	fill(39, 40, 45, 48) // left pillar on ground
	fill(59, 60, 45, 48) // right pillar on ground

	// ================================================================
	// LEFT ROOM -- vertical shaft style with climb chain
	// ================================================================
	// Platforms spaced <= 3 tiles vertically for jumpability

	// Ground floor
	fill(7, 14, 41, 41)  // left ground
	fill(17, 23, 41, 41) // right ground

	// Climb chain going up
	fill(13, 20, 37, 37) // step 1
	fill(7, 14, 33, 33)  // step 2
	fill(13, 20, 29, 29) // step 3
	fill(7, 14, 25, 25)  // step 4
	fill(13, 20, 21, 21) // step 5 (near upper tunnel)

	// ================================================================
	// RIGHT ROOM -- wide halls with low obstacles
	// ================================================================
	// Flatter layout, good for sprinting with some cover

	// Low walls / barriers (2 tall for cover)
	fill(79, 80, 39, 40) // barrier 1
	fill(87, 88, 39, 40) // barrier 2

	// Mid-height platform
	fill(77, 84, 34, 34) // left platform
	fill(86, 93, 34, 34) // right platform

	// Upper platforms
	fill(80, 88, 28, 28) // center upper
	fill(76, 80, 23, 23) // left high
	fill(88, 92, 23, 23) // right high

	// Small elevated perch
	fill(83, 86, 20, 20) // center perch near upper tunnel

	// ================================================================
	// OUTPUT
	// ================================================================

	printASCII()

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
