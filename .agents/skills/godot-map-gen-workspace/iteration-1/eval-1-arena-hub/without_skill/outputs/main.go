package main

import (
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"os"
	"strings"
)

const (
	width  = 100
	height = 60
	tileSize = 32

	srcBoundary   = 0
	srcBackground = 3

	// Atlas coords for boundary tile (solid block)
	boundaryAtlasX = 0
	boundaryAtlasY = 0

	// Background tile atlas coords per room style
	bgHubAtlasX   = 1
	bgHubAtlasY   = 0
	bgLeftAtlasX  = 2
	bgLeftAtlasY  = 0
	bgRightAtlasX = 3
	bgRightAtlasY = 0
)

type tile struct {
	x, y     int16
	srcID    int16
	atlasX   int16
	atlasY   int16
	altID    int16
}

func main() {
	tiles := generateArena()
	data := encodeTileMapData(tiles)
	tscn := buildTSCN(data)

	outPath := "arena_hub.tscn"
	if len(os.Args) > 1 {
		outPath = os.Args[1]
	}
	if err := os.WriteFile(outPath, []byte(tscn), 0644); err != nil {
		fmt.Fprintf(os.Stderr, "error writing file: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("Wrote %s (%d tiles)\n", outPath, len(tiles))
}

// generateArena builds the tile list for the arena level.
// Layout (grid coords, 0-indexed):
//
//   Left room:   x=2..22,  y=2..40
//   Hub room:    x=30..70, y=2..55
//   Right room:  x=78..98, y=2..40
//   Left tunnel: x=22..30, y=18..26
//   Right tunnel:x=70..78, y=18..26
//
// Each room gets background fill, walls, and platforms.
func generateArena() []tile {
	grid := make(map[[2]int16]tile)

	// Helper to set a boundary tile
	setBoundary := func(x, y int) {
		key := [2]int16{int16(x), int16(y)}
		grid[key] = tile{int16(x), int16(y), srcBoundary, boundaryAtlasX, boundaryAtlasY, 0}
	}

	// Helper to set a background tile
	setBG := func(x, y, atlasX, atlasY int) {
		key := [2]int16{int16(x), int16(y)}
		if _, exists := grid[key]; !exists {
			grid[key] = tile{int16(x), int16(y), srcBackground, int16(atlasX), int16(atlasY), 0}
		}
	}

	// --- Room definitions ---
	type room struct {
		x1, y1, x2, y2 int
		bgAX, bgAY      int
	}

	hub := room{30, 2, 70, 55, bgHubAtlasX, bgHubAtlasY}
	left := room{2, 2, 22, 40, bgLeftAtlasX, bgLeftAtlasY}
	right := room{78, 2, 98, 40, bgRightAtlasX, bgRightAtlasY}

	// Tunnels
	tunnelLeft := room{22, 18, 30, 26, bgHubAtlasX, bgHubAtlasY}
	tunnelRight := room{70, 18, 78, 26, bgHubAtlasX, bgHubAtlasY}

	rooms := []room{hub, left, right, tunnelLeft, tunnelRight}

	// Fill backgrounds for all rooms
	for _, r := range rooms {
		for x := r.x1; x <= r.x2; x++ {
			for y := r.y1; y <= r.y2; y++ {
				setBG(x, y, r.bgAX, r.bgAY)
			}
		}
	}

	// Build walls for a rectangular room
	buildWalls := func(r room) {
		for x := r.x1; x <= r.x2; x++ {
			setBoundary(x, r.y1) // top
			setBoundary(x, r.y2) // bottom
		}
		for y := r.y1; y <= r.y2; y++ {
			setBoundary(r.x1, y) // left
			setBoundary(r.x2, y) // right
		}
	}

	// Build walls for all rooms
	buildWalls(hub)
	buildWalls(left)
	buildWalls(right)

	// Tunnel walls (top and bottom only, sides are already room walls)
	for x := tunnelLeft.x1; x <= tunnelLeft.x2; x++ {
		setBoundary(x, tunnelLeft.y1)
		setBoundary(x, tunnelLeft.y2)
	}
	for x := tunnelRight.x1; x <= tunnelRight.x2; x++ {
		setBoundary(x, tunnelRight.y1)
		setBoundary(x, tunnelRight.y2)
	}

	// Carve tunnel openings (remove wall segments where tunnels meet rooms)
	// Left tunnel opening into left room (remove right wall of left room in tunnel range)
	for y := tunnelLeft.y1 + 1; y < tunnelLeft.y2; y++ {
		key := [2]int16{int16(left.x2), int16(y)}
		grid[key] = tile{int16(left.x2), int16(y), srcBackground, int16(bgLeftAtlasX), int16(bgLeftAtlasY), 0}
	}
	// Left tunnel opening into hub (remove left wall of hub in tunnel range)
	for y := tunnelLeft.y1 + 1; y < tunnelLeft.y2; y++ {
		key := [2]int16{int16(hub.x1), int16(y)}
		grid[key] = tile{int16(hub.x1), int16(y), srcBackground, int16(bgHubAtlasX), int16(bgHubAtlasY), 0}
	}
	// Right tunnel opening into hub (remove right wall of hub in tunnel range)
	for y := tunnelRight.y1 + 1; y < tunnelRight.y2; y++ {
		key := [2]int16{int16(hub.x2), int16(y)}
		grid[key] = tile{int16(hub.x2), int16(y), srcBackground, int16(bgHubAtlasX), int16(bgHubAtlasY), 0}
	}
	// Right tunnel opening into right room (remove left wall of right room in tunnel range)
	for y := tunnelRight.y1 + 1; y < tunnelRight.y2; y++ {
		key := [2]int16{int16(right.x1), int16(y)}
		grid[key] = tile{int16(right.x1), int16(y), srcBackground, int16(bgRightAtlasX), int16(bgRightAtlasY), 0}
	}

	// --- Hub platforms for vertical chasing ---
	// Multiple staggered platforms at different heights
	hubPlatforms := []struct{ x1, x2, y int }{
		// Ground level platforms
		{33, 40, 50},
		{45, 55, 50},
		{60, 67, 50},

		// Lower-mid platforms
		{35, 42, 44},
		{50, 58, 44},
		{62, 68, 44},

		// Mid platforms (staggered)
		{32, 38, 38},
		{44, 52, 38},
		{56, 65, 38},

		// Upper-mid platforms
		{36, 44, 32},
		{48, 56, 32},
		{60, 68, 32},

		// Upper platforms
		{33, 40, 26},
		{46, 54, 26},
		{58, 66, 26},

		// High platforms
		{38, 46, 20},
		{52, 60, 20},

		// Top platforms
		{34, 42, 14},
		{48, 56, 14},
		{60, 67, 14},

		// Very top
		{40, 50, 8},
		{54, 64, 8},

		// Small stepping stones for varied paths
		{42, 44, 35},
		{53, 55, 41},
		{63, 65, 35},
		{37, 39, 47},
		{57, 59, 47},
		{43, 45, 29},
		{55, 57, 23},
		{35, 37, 17},
		{61, 63, 11},
	}

	for _, p := range hubPlatforms {
		for x := p.x1; x <= p.x2; x++ {
			setBoundary(x, p.y)
		}
	}

	// --- Left room platforms ---
	leftPlatforms := []struct{ x1, x2, y int }{
		{5, 12, 35},
		{14, 20, 35},
		{4, 10, 28},
		{12, 19, 28},
		{6, 14, 21},
		{15, 20, 21},
		{4, 11, 14},
		{13, 20, 14},
		{7, 15, 8},
	}
	for _, p := range leftPlatforms {
		for x := p.x1; x <= p.x2; x++ {
			setBoundary(x, p.y)
		}
	}

	// --- Right room platforms ---
	rightPlatforms := []struct{ x1, x2, y int }{
		{80, 87, 35},
		{89, 96, 35},
		{81, 88, 28},
		{90, 97, 28},
		{80, 86, 21},
		{88, 96, 21},
		{82, 89, 14},
		{91, 97, 14},
		{84, 92, 8},
	}
	for _, p := range rightPlatforms {
		for x := p.x1; x <= p.x2; x++ {
			setBoundary(x, p.y)
		}
	}

	// Convert map to slice
	result := make([]tile, 0, len(grid))
	for _, t := range grid {
		result = append(result, t)
	}
	return result
}

// encodeTileMapData encodes tiles into the Godot PackedByteArray format:
// 2-byte header (uint16 LE = 0), then 12-byte records (6 x int16 LE).
func encodeTileMapData(tiles []tile) string {
	buf := make([]byte, 2+len(tiles)*12)
	// Header: format version 0
	binary.LittleEndian.PutUint16(buf[0:2], 0)

	for i, t := range tiles {
		off := 2 + i*12
		binary.LittleEndian.PutUint16(buf[off+0:off+2], uint16(t.x))
		binary.LittleEndian.PutUint16(buf[off+2:off+4], uint16(t.y))
		binary.LittleEndian.PutUint16(buf[off+4:off+6], uint16(t.srcID))
		binary.LittleEndian.PutUint16(buf[off+6:off+8], uint16(t.atlasX))
		binary.LittleEndian.PutUint16(buf[off+8:off+10], uint16(t.atlasY))
		binary.LittleEndian.PutUint16(buf[off+10:off+12], uint16(t.altID))
	}

	return base64.StdEncoding.EncodeToString(buf)
}

func buildTSCN(tileMapData string) string {
	// Break base64 into 76-char lines for readability
	var dataLines []string
	for i := 0; i < len(tileMapData); i += 76 {
		end := i + 76
		if end > len(tileMapData) {
			end = len(tileMapData)
		}
		dataLines = append(dataLines, tileMapData[i:end])
	}
	wrappedData := strings.Join(dataLines, "\n")

	return fmt.Sprintf(`[gd_scene load_steps=2 format=3 uid="uid://arena_hub_generated"]

[ext_resource type="TileSet" uid="uid://dq2tpm6nvhbyo" path="res://scenes/resources/terrain_tileset.tres" id="1_2q6dc"]

[node name="ArenaHub" type="Node2D"]

[node name="TileMapLayer" type="TileMapLayer" parent="."]
tile_set = ExtResource("1_2q6dc")
tile_map_data = PackedByteArray("%s")
`, wrappedData)
}
