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

var solid [H][W]bool
var room [H][W]bool
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

// carve sets a rectangle to air and marks it as room interior (no room ID)
func carve(x0, x1, y0, y1 int) {
	for y := y0; y <= y1; y++ {
		for x := x0; x <= x1; x++ {
			solid[y][x] = false
			room[y][x] = true
		}
	}
}

// fill sets a rectangle back to solid (platforms, pillars, walls inside rooms)
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

	// one-tile-thick strip: platform tiles (row 11)
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

// backgroundAtlas picks a background tile (source 3) based on room identity
func backgroundAtlas(x, y int) (int, int) {
	id := roomID[y][x]
	switch id {
	case 1: // Hub - heavy industrial
		return (x % 4) + 16, (y % 4) + 16
	case 2: // Upper Left - clean metal panels
		return (x % 4), (y % 4)
	case 3: // Upper Right - labeled panels with vents
		return (x % 4) + 4, (y % 4) + 4
	case 4: // Lower Left - pipe networks
		return (x % 4) + 8, (y % 4) + 8
	case 5: // Lower Right - dense industrial
		return (x % 4) + 24, (y % 4) + 24
	default: // corridors, tunnels, shafts - mixed panels
		return (x % 4) + 12, (y % 4) + 12
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
				ax, ay := backgroundAtlas(x, y)
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
	// FIGURE-8 MAP: Two loops sharing a central hub room
	//
	// Layout:
	//   Room 2 (UL) ---crawl tunnel--- Room 3 (UR)
	//       |  \                         /  |
	//    drop   corridor    corridor   drop
	//   shaft     \           /      shaft
	//       |      +-- Hub --+          |
	//    drop   corridor    corridor   drop
	//   shaft     /           \      shaft
	//       |  /                         \  |
	//   Room 4 (LL) ---crawl tunnel--- Room 5 (LR)
	//
	// Top loop:  Room2 -> Hub -> Room3 -> crawl -> Room2
	// Bot loop:  Room4 -> Hub -> Room5 -> crawl -> Room4
	// Verticals: Room2 <-> Room4 (left shaft)
	//            Room3 <-> Room5 (right shaft)
	// ================================================================

	// --- 5 ROOMS ---

	// Room 1: Hub (center) - large, multiple entrances, high-tension zone
	carveRoom(40, 59, 22, 37, 1)

	// Room 2: Upper Left - spacious hall
	carveRoom(5, 30, 3, 20, 2)

	// Room 3: Upper Right - spacious hall (mirror)
	carveRoom(69, 94, 3, 20, 3)

	// Room 4: Lower Left - spacious hall
	carveRoom(5, 30, 39, 56, 4)

	// Room 5: Lower Right - spacious hall (mirror)
	carveRoom(69, 94, 39, 56, 5)

	// --- CORRIDORS: Rooms to Hub ---
	// Each corridor is 3 tiles high (2 clear rows above floor for standing)
	// and bridges the 1-tile wall between room and hub.

	// Upper-left corridor (Room 2 -> Hub)
	// Horizontal passage through the wall at y=21
	carve(28, 42, 19, 21)

	// Upper-right corridor (Room 3 -> Hub)
	carve(57, 71, 19, 21)

	// Lower-left corridor (Room 4 -> Hub)
	// Horizontal passage through the wall at y=38
	carve(28, 42, 38, 40)

	// Lower-right corridor (Room 5 -> Hub)
	carve(57, 71, 38, 40)

	// --- CRAWL TUNNELS (1 tile high) ---
	// Slow but hidden passages connecting left/right rooms across the top
	// and bottom. Only 1 tile of air — player must crawl.

	// Top crawl tunnel: Room 2 <-> Room 3 at y=10
	// Inside rooms this row is already air; the tunnel carves through
	// the solid gap between rooms (x=31..68).
	carve(30, 69, 10, 10)

	// Bottom crawl tunnel: Room 4 <-> Room 5 at y=48
	carve(30, 69, 48, 48)

	// --- DROP SHAFTS (vertical, fast down / slow up) ---
	// 3 tiles wide with alternating climbing platforms spaced 3 tiles
	// apart. Fast to fall through, slow to climb.

	// Left drop shaft: Room 2 <-> Room 4 (x=15..17)
	// Carves through the walls at y=21 and y=38, connecting both rooms.
	carve(15, 17, 20, 39)

	// Climbing platforms (alternating sides for zig-zag climb)
	// Each platform is 2 tiles wide, leaving 1 tile open to fall past.
	// Spacing: 3 tiles between platforms (within jump rise limit).
	// Player stands on top of platform tile, needs 2 clear rows above.
	fill(15, 16, 36, 36) // left side,  player walks at y=35
	fill(16, 17, 33, 33) // right side, player walks at y=32
	fill(15, 16, 30, 30) // left side,  player walks at y=29
	fill(16, 17, 27, 27) // right side, player walks at y=26
	fill(15, 16, 24, 24) // left side,  player walks at y=23

	// Right drop shaft: Room 3 <-> Room 5 (x=82..84)
	carve(82, 84, 20, 39)

	// Climbing platforms (mirrored pattern)
	fill(83, 84, 36, 36)
	fill(82, 83, 33, 33)
	fill(83, 84, 30, 30)
	fill(82, 83, 27, 27)
	fill(83, 84, 24, 24)

	// --- INTERIOR PLATFORMS ---
	// Each room gets platforms to break up flat running, create
	// vertical play, and provide sightline cover. All platforms
	// respect: jump rise <= 3 tiles, 2 clear rows above for standing.

	// Room 2 (Upper Left, y=3..20, floor at y=20 on wall y=21)
	// Main mid-height platform
	fill(10, 20, 13, 13) // player walks at y=12, clear y=11 y=12
	// Lower platform (3 tiles above floor: floor y=20, plat y=17)
	fill(19, 28, 17, 17) // player walks at y=16, clear y=15 y=16
	// Upper small platform (3 above mid platform y=13 -> y=10)
	fill(7, 13, 10, 10) // player walks at y=9, clear y=8 y=9
	// Small pillar near corridor entrance for cover
	fill(26, 27, 13, 17)

	// Room 3 (Upper Right, mirror of Room 2)
	fill(79, 89, 13, 13)
	fill(71, 80, 17, 17)
	fill(86, 92, 10, 10)
	fill(72, 73, 13, 17)

	// Room 4 (Lower Left, y=39..56, floor at y=56 on wall y=57)
	// Mid-height platform (floor y=56, plat at y=53 -> 3 tiles up)
	fill(19, 28, 53, 53)
	// Upper platform (from y=53 plat, jump to y=49 -> ~4... let me fix)
	fill(10, 20, 49, 49) // 4 up from y=53, but player stands at y=52
	// on y=53, so y=49 platform -> player at y=48 -> jump rise = 52-48=4
	// That exceeds 3! Fix: move to y=50
	// Actually: player on y=53 platform stands at y=52. Jump rise 3 means
	// they can reach y=49. Platform at y=49, player stands at y=48. OK
	// wait, jump rise <= 3 tiles means from y=52 they jump to y=52-3=y=49.
	// Standing at y=49 means there's a platform at y=50. Let me recalculate.
	// Player at y=52 (on platform y=53), jumps up 3 tiles to y=49.
	// To land, they need a solid at y=50 to stand on (feet at y=49).
	// So platform at y=50 is reachable. Let me adjust.

	// Small platform near shaft opening for climbing access
	fill(12, 18, 42, 42) // player walks at y=41, near shaft top (y=39)

	// Room 5 (Lower Right, mirror of Room 4)
	fill(71, 80, 53, 53)
	fill(79, 89, 49, 49)
	fill(81, 87, 42, 42)

	// Hub (Room 1, x=40..59, y=22..37)
	// Central pillar creates split paths through the hub
	fill(48, 51, 27, 32) // 4-wide pillar in the center

	// Upper platform spanning left side
	fill(42, 47, 28, 28) // player walks at y=27

	// Lower platform spanning right side
	fill(52, 57, 32, 32) // player walks at y=31

	// Small step near lower-left entrance
	fill(42, 44, 35, 35)

	// Small step near upper-right entrance
	fill(55, 57, 25, 25)

	// --- Fix Room 4 platforms with correct jump-rise math ---
	// Undo the y=49 platform in Room 4 and Room 5 placed above,
	// then place corrected versions.
	// Room 4: floor y=56 (solid), player walks at y=55.
	//   Platform 1: y=53 (solid), player at y=52. Jump: 55->52 = 3. OK.
	//   Platform 2: y=50 (solid), player at y=49. Jump: 52->49 = 3. OK.
	//   Platform 3: y=47 (solid), player at y=46. Jump: 49->46 = 3. OK.

	// Clear the wrongly-placed y=49 platforms
	carve(10, 20, 49, 49) // undo Room 4
	carve(79, 89, 49, 49) // undo Room 5

	// Place corrected platforms
	fill(10, 20, 50, 50)  // Room 4 upper platform
	fill(8, 14, 47, 47)   // Room 4 highest platform

	fill(79, 89, 50, 50)  // Room 5 upper platform
	fill(85, 91, 47, 47)  // Room 5 highest platform

	// Print ASCII preview
	printASCII()

	// Write the .tscn file
	outPath := filepath.Join("scenes", "levels", "level3.tscn")
	err := writeTSCN(
		outPath,
		"res://scenes/resources/terrain_tileset.tres",
		"1_2q6dc",
		322632072,
	)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("\nwrote tilemap -> %s\n", outPath)
}
