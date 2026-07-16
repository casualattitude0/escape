// Figure-8 level generator for Godot 4.x
// Produces scenes/levels/level3.tscn with a TileMapLayer containing a figure-8 layout:
// two loops sharing a central room, 5 rooms total, with crawl tunnels and drop shafts.
//
// Player metrics:
//   - Jump rise <= 3 tiles
//   - 2 clear rows for standing
//
// Tile encoding: PackedByteArray base64 with 2-byte header (uint16 LE = 0)
// followed by 12-byte records: x, y, source_id, atlas_x, atlas_y, alt_id (all int16 LE).
//
// Terrain tiles: source_id=0, atlas coords based on neighbor exposure
//   row 7 = top edge, row 8 = middle/fill, row 9 = bottom edge
//   col 1 = left edge, col 2 = center, col 3 = right edge
//   row 11 = thin platform (1-tile high)
// Background tiles: source_id=3

package main

import (
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
)

const (
	GridW = 100
	GridH = 60
	// Tile size 32px

	// Atlas coords for terrain edges (source_id=0)
	// Top edge row=7, Middle row=8, Bottom row=9
	// Left col=1, Center col=2, Right col=3
	// Thin platform row=11, col=2

	AtlasTopLeft_X     = 1
	AtlasTopLeft_Y     = 7
	AtlasTop_X         = 2
	AtlasTop_Y         = 7
	AtlasTopRight_X    = 3
	AtlasTopRight_Y    = 7
	AtlasLeft_X        = 1
	AtlasLeft_Y        = 8
	AtlasFill_X        = 2
	AtlasFill_Y        = 8
	AtlasRight_X       = 3
	AtlasRight_Y       = 8
	AtlasBotLeft_X     = 1
	AtlasBotLeft_Y     = 9
	AtlasBot_X         = 2
	AtlasBotLeft2_Y    = 9
	AtlasBotRight_X    = 3
	AtlasBotRight_Y    = 9
	AtlasThinPlatform_X = 2
	AtlasThinPlatform_Y = 11

	BgSourceID = 3
	BgAtlasX   = 0
	BgAtlasY   = 0
)

// CellType for our grid
const (
	CellEmpty  = 0
	CellSolid  = 1
	CellBG     = 2 // background fill behind open areas
	CellThinPlatform = 3
)

type TileRecord struct {
	X, Y                     int16
	SourceID, AtlasX, AtlasY int16
	AltID                    int16
}

// Room defines a rectangular region (in tile coords, inclusive)
type Room struct {
	Name         string
	X1, Y1       int // top-left corner
	X2, Y2       int // bottom-right corner
}

func main() {
	grid := [GridH][GridW]int{}

	// Fill everything solid initially
	for y := 0; y < GridH; y++ {
		for x := 0; x < GridW; x++ {
			grid[y][x] = CellSolid
		}
	}

	// =====================================================================
	// Figure-8 layout: 5 rooms, two loops sharing a central room
	//
	//   Room layout (conceptual):
	//
	//      [Room A]----tunnel----[Room B / Center]----tunnel----[Room C]
	//         |                       |                            |
	//      drop shaft              shaft                       drop shaft
	//         |                       |                            |
	//      [Room D]----tunnel----[Room B / Center]----tunnel----[Room E]
	//
	//   But since the center is shared, the figure-8 is:
	//      Room A (top-left) -- Room B (center) -- Room C (top-right)
	//      Room D (bot-left) -- Room B (center) -- Room E (bot-right)
	//
	//   Loop 1: A -> B -> C -> (drop shaft down) -> E -> (tunnel) -> B -> (shaft up) -> A
	//   Loop 2: A -> (drop shaft down) -> D -> (tunnel) -> B -> (tunnel) -> C
	//
	// =====================================================================

	// Room definitions (interior space, will be carved out)
	// All rooms need 2+ clear height for standing
	// Rooms are defined as interior bounds (walls will be the solid cells around them)

	rooms := []Room{
		// Room A: top-left loop room
		{Name: "A", X1: 8, Y1: 10, X2: 28, Y2: 22},
		// Room B: center (shared hub) - taller to accommodate both loops
		{Name: "B", X1: 40, Y1: 18, X2: 60, Y2: 40},
		// Room C: top-right loop room
		{Name: "C", X1: 72, Y1: 10, X2: 92, Y2: 22},
		// Room D: bottom-left loop room
		{Name: "D", X1: 8, Y1: 38, X2: 28, Y2: 50},
		// Room E: bottom-right loop room
		{Name: "E", X1: 72, Y1: 38, X2: 92, Y2: 50},
	}

	// Carve out rooms
	for _, r := range rooms {
		carveRoom(&grid, r)
	}

	// =====================================================================
	// Connections
	// =====================================================================

	// --- Top crawl tunnel: Room A -> Room B (1 tile high, crawl) ---
	// Connect right side of A (x=28) to left side of B (x=40)
	// Crawl tunnel at y=21 (near bottom of A, near top-ish of B)
	crawlY := 21 // floor of crawl is at y=21, passage is y=20 (1 tile high)
	for x := 29; x < 40; x++ {
		grid[crawlY-1][x] = CellEmpty // the crawl space (1 tile high)
		// floor stays solid at crawlY, ceiling stays solid at crawlY-2
	}
	// Add background behind crawl tunnel
	for x := 29; x < 40; x++ {
		grid[crawlY-1][x] = CellEmpty
	}

	// --- Top crawl tunnel: Room B -> Room C ---
	// Connect right side of B (x=60) to left side of C (x=72)
	// Crawl tunnel at y=21
	for x := 61; x < 72; x++ {
		grid[crawlY-1][x] = CellEmpty
	}

	// --- Bottom crawl tunnel: Room D -> Room B ---
	// Connect right side of D (x=28) to left side of B (x=40)
	crawlYBot := 49 // near bottom of D, connects into lower part of B
	for x := 29; x < 40; x++ {
		grid[crawlYBot-1][x] = CellEmpty
	}

	// --- Bottom crawl tunnel: Room B -> Room E ---
	// Connect right side of B (x=60) to left side of E (x=72)
	for x := 61; x < 72; x++ {
		grid[crawlYBot-1][x] = CellEmpty
	}

	// --- Drop shaft: Room A down to Room D (left side) ---
	// Vertical shaft 2 tiles wide (for standing width) from bottom of A to top of D
	shaftX1Left := 14
	shaftX2Left := 15
	for y := 23; y < 38; y++ {
		grid[y][shaftX1Left] = CellEmpty
		grid[y][shaftX2Left] = CellEmpty
	}

	// --- Drop shaft: Room C down to Room E (right side) ---
	shaftX1Right := 80
	shaftX2Right := 81
	for y := 23; y < 38; y++ {
		grid[y][shaftX1Right] = CellEmpty
		grid[y][shaftX2Right] = CellEmpty
	}

	// --- Central vertical shaft in Room B (already open, but add platforms) ---
	// Room B spans y=18 to y=40, add some intermediate platforms
	// Platform at y=28 with a gap for dropping through
	for x := 42; x <= 50; x++ {
		grid[28][x] = CellThinPlatform
	}
	// Leave gap at x=51-54 for dropping
	for x := 55; x <= 58; x++ {
		grid[28][x] = CellThinPlatform
	}

	// Another platform at y=34
	for x := 44; x <= 48; x++ {
		grid[34][x] = CellThinPlatform
	}
	for x := 53; x <= 58; x++ {
		grid[34][x] = CellThinPlatform
	}

	// =====================================================================
	// Add stepped platforms inside rooms for jump accessibility (max 3 tile rise)
	// =====================================================================

	// Room A: platforms for vertical navigation
	// Floor is at y=22, add platform at y=19 (3 tiles up from floor) -- reachable by jump
	for x := 12; x <= 18; x++ {
		grid[19][x] = CellThinPlatform
	}
	// Another platform at y=16 (3 tiles up from y=19)
	for x := 20; x <= 26; x++ {
		grid[16][x] = CellThinPlatform
	}

	// Room C: mirror of A
	for x := 76; x <= 82; x++ {
		grid[19][x] = CellThinPlatform
	}
	for x := 84; x <= 90; x++ {
		grid[16][x] = CellThinPlatform
	}

	// Room D: platforms
	for x := 12; x <= 18; x++ {
		grid[47][x] = CellThinPlatform
	}
	for x := 20; x <= 26; x++ {
		grid[44][x] = CellThinPlatform
	}

	// Room E: platforms
	for x := 76; x <= 82; x++ {
		grid[47][x] = CellThinPlatform
	}
	for x := 84; x <= 90; x++ {
		grid[44][x] = CellThinPlatform
	}

	// =====================================================================
	// Add landing ledges in drop shafts every 3 tiles (jump-height safe)
	// =====================================================================
	// Left shaft: ledges
	for y := 26; y < 38; y += 3 {
		grid[y][shaftX1Left-1] = CellEmpty // widen slightly for landing
		grid[y][shaftX1Left] = CellThinPlatform
		grid[y][shaftX2Left] = CellThinPlatform
		grid[y][shaftX2Left+1] = CellEmpty
	}

	// Right shaft: ledges
	for y := 26; y < 38; y += 3 {
		grid[y][shaftX1Right-1] = CellEmpty
		grid[y][shaftX1Right] = CellThinPlatform
		grid[y][shaftX2Right] = CellThinPlatform
		grid[y][shaftX2Right+1] = CellEmpty
	}

	// =====================================================================
	// Generate tile records
	// =====================================================================
	var tiles []TileRecord

	// First pass: add background tiles behind all empty/platform spaces
	for y := 0; y < GridH; y++ {
		for x := 0; x < GridW; x++ {
			if grid[y][x] == CellEmpty || grid[y][x] == CellThinPlatform {
				tiles = append(tiles, TileRecord{
					X: int16(x), Y: int16(y),
					SourceID: BgSourceID,
					AtlasX:   int16(BgAtlasX),
					AtlasY:   int16(BgAtlasY),
				})
			}
		}
	}

	// Second pass: add terrain tiles for solid cells with proper atlas coords
	for y := 0; y < GridH; y++ {
		for x := 0; x < GridW; x++ {
			if grid[y][x] == CellSolid {
				ax, ay := getTerrainAtlas(grid, x, y)
				tiles = append(tiles, TileRecord{
					X: int16(x), Y: int16(y),
					SourceID: 0,
					AtlasX:   int16(ax),
					AtlasY:   int16(ay),
				})
			} else if grid[y][x] == CellThinPlatform {
				tiles = append(tiles, TileRecord{
					X: int16(x), Y: int16(y),
					SourceID: 0,
					AtlasX:   int16(AtlasThinPlatform_X),
					AtlasY:   int16(AtlasThinPlatform_Y),
				})
			}
		}
	}

	// =====================================================================
	// Encode to PackedByteArray
	// =====================================================================
	buf := make([]byte, 2+len(tiles)*12)
	// 2-byte header: uint16 LE = 0
	binary.LittleEndian.PutUint16(buf[0:2], 0)

	for i, t := range tiles {
		off := 2 + i*12
		binary.LittleEndian.PutUint16(buf[off+0:off+2], uint16(t.X))
		binary.LittleEndian.PutUint16(buf[off+2:off+4], uint16(t.Y))
		binary.LittleEndian.PutUint16(buf[off+4:off+6], uint16(t.SourceID))
		binary.LittleEndian.PutUint16(buf[off+6:off+8], uint16(t.AtlasX))
		binary.LittleEndian.PutUint16(buf[off+8:off+10], uint16(t.AtlasY))
		binary.LittleEndian.PutUint16(buf[off+10:off+12], uint16(t.AltID))
	}

	b64 := base64.StdEncoding.EncodeToString(buf)

	// =====================================================================
	// Write .tscn file
	// =====================================================================
	tscn := fmt.Sprintf(`[gd_scene format=4]

[ext_resource type="TileSet" path="res://scenes/resources/terrain_tileset.tres" id="1_2q6dc"]

[node name="Terrain" type="TileMapLayer" unique_id=322632070]
tile_map_data = PackedByteArray("%s")
`, b64)

	outDir := filepath.Dir(os.Args[0])
	// Default output path
	outPath := "scenes/levels/level3.tscn"
	if len(os.Args) > 1 {
		outPath = os.Args[1]
	}

	// If run from project root, write directly
	if err := os.MkdirAll(filepath.Dir(outPath), 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "mkdir: %v\n", err)
		os.Exit(1)
	}
	_ = outDir

	if err := os.WriteFile(outPath, []byte(tscn), 0o644); err != nil {
		fmt.Fprintf(os.Stderr, "write: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Wrote %s (%d tiles, %d bytes encoded)\n", outPath, len(tiles), len(buf))
}

// carveRoom sets interior cells to empty
func carveRoom(grid *[GridH][GridW]int, r Room) {
	for y := r.Y1; y <= r.Y2; y++ {
		for x := r.X1; x <= r.X2; x++ {
			if x >= 0 && x < GridW && y >= 0 && y < GridH {
				grid[y][x] = CellEmpty
			}
		}
	}
}

// getTerrainAtlas returns the atlas (x, y) for a solid tile based on its neighbors.
// Neighbor exposure determines which edge variant to use.
func getTerrainAtlas(grid [GridH][GridW]int, x, y int) (int, int) {
	isOpen := func(gx, gy int) bool {
		if gx < 0 || gx >= GridW || gy < 0 || gy >= GridH {
			return false // out of bounds = solid
		}
		return grid[gy][gx] != CellSolid
	}

	openAbove := isOpen(x, y-1)
	openBelow := isOpen(x, y+1)
	openLeft := isOpen(x-1, y)
	openRight := isOpen(x+1, y)

	// Determine row based on vertical exposure
	atlasRow := AtlasFill_Y // default: middle fill (row 8)
	if openAbove && openBelow {
		// Both open: treat as thin, but since this is CellSolid we keep fill
		atlasRow = AtlasFill_Y
	} else if openAbove {
		atlasRow = AtlasTop_Y // row 7: top edge
	} else if openBelow {
		atlasRow = AtlasBotLeft2_Y // row 9: bottom edge
	}

	// Determine column based on horizontal exposure
	atlasCol := AtlasFill_X // default: center fill (col 2)
	if openLeft && openRight {
		atlasCol = AtlasFill_X // both sides open, still center
	} else if openLeft {
		atlasCol = AtlasLeft_X // col 1: left edge (exposed on left)
	} else if openRight {
		atlasCol = AtlasRight_X // col 3: right edge (exposed on right)
	}

	// Corner cases
	if openAbove && openLeft {
		atlasCol = AtlasTopLeft_X
		atlasRow = AtlasTopLeft_Y
	}
	if openAbove && openRight {
		atlasCol = AtlasTopRight_X
		atlasRow = AtlasTopRight_Y
	}
	if openBelow && openLeft {
		atlasCol = AtlasBotLeft_X
		atlasRow = AtlasBotLeft2_Y
	}
	if openBelow && openRight {
		atlasCol = AtlasBotRight_X
		atlasRow = AtlasBotRight_Y
	}

	return atlasCol, atlasRow
}
