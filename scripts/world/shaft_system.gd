extends Node
class_name ShaftSystem

## Hunter-only vertical fast-travel: a shaft bored through a floor. The Hunter
## presses slide at a mouth and rides to the other end — server-driven and
## elevator-like, so they do NOT dwell inside (that hide-and-peek behaviour is
## the Runner's horizontal tunnel). This is the vertical counterpart; the ride
## itself runs through the shared ElevatorSystem ride lifecycle.
##
## Authoring (tile-based): on the level's shaft layer, paint a vertical run of
## tiles straight through a floor. Each maximal run of same-column contiguous
## cells is one shaft; its two mouths are the open cells just past the top and
## bottom ends. Standing at either mouth and pressing slide rides to the other.

const ENTER_X_TILES := 1.0        # horizontal alignment tolerance with the column (tile widths)
const ENTER_Y_MARGIN_TILES := 0.9 # vertical slack beyond the floor at each end (tile heights)
const FOOT_OFFSET := 36.0    # player origin sits this far above its feet (see player.tscn)
const FLOOR_SCAN := 12       # cells searched downward for the floor under a mouth

var _layer: TileMapLayer
var _terrain: TileMapLayer
var _tile: Vector2 = Vector2(32, 32)
var _shafts: Array = []      # each shaft's column, end mouths (ride targets), and end tiles

## Scan the shaft layer into paired mouths. Cheap; run on every peer at load.
func setup(shaft_layer: TileMapLayer, terrain: TileMapLayer) -> void:
	_layer = shaft_layer
	_terrain = terrain
	_shafts.clear()
	if _layer == null or _layer.tile_set == null:
		return
	_tile = Vector2(_layer.tile_set.tile_size)
	_build()

func _build() -> void:
	# Group used cells into maximal vertical runs (same column, contiguous y).
	var by_col: Dictionary = {}
	for c in _layer.get_used_cells():
		var ys: Array = by_col.get(c.x, [])
		ys.append(c.y)
		by_col[c.x] = ys
	for x in by_col:
		var ys: Array = by_col[x]
		ys.sort()
		var start: int = ys[0]
		var prev: int = ys[0]
		for i in range(1, ys.size()):
			var y: int = ys[i]
			if y > prev + 1:
				_add_run(x, start, prev)
				start = y
			prev = y
		_add_run(x, start, prev)

func _add_run(x: int, y0: int, y1: int) -> void:
	var col_x := _layer.map_to_local(Vector2i(x, y0)).x
	_shafts.append({
		"col_x": col_x,                                    # column center (world x)
		# Top end = standing on top of the shaft's top tile. Do NOT floor-scan
		# down here: a shaft with no terrain in its column would scan straight
		# through to the bottom floor, collapsing both ends onto one point.
		"top_mouth": Vector2(col_x, y0 * _tile.y - FOOT_OFFSET),
		"bot_mouth": _mouth_pos(Vector2i(x, y1 + 1)),      # floor below the shaft
		"top_tile": _layer.map_to_local(Vector2i(x, y0)),  # end tile centers (on-tile hint)
		"bot_tile": _layer.map_to_local(Vector2i(x, y1)),
	})

## Standing position at a mouth cell: the cell center in x, dropped so the
## Hunter's feet rest on the nearest floor below (same rule as world._snap_to_floor).
func _mouth_pos(cell: Vector2i) -> Vector2:
	var center := _layer.map_to_local(cell)
	if _terrain != null:
		var t := _terrain.local_to_map(center)
		for dy in FLOOR_SCAN:
			var below := Vector2i(t.x, t.y + dy)
			if _terrain.get_cell_source_id(below) != -1:
				return Vector2(center.x, below.y * _tile.y - FOOT_OFFSET)
	return center

## The shaft the Hunter at pos can use, plus which end they're at. A shaft is a
## column-aligned vertical band from the floor above to the floor below, so
## standing anywhere under (or over) the shaft column counts — robust to the gap
## between the shaft's end tile and the floor the Hunter actually stands on.
## Returns {"s": shaft, "from_bottom": bool}, or an empty dict if not at a shaft.
func _find(pos: Vector2) -> Dictionary:
	var rx := _tile.x * ENTER_X_TILES
	var m := _tile.y * ENTER_Y_MARGIN_TILES
	for s in _shafts:
		if absf(pos.x - s["col_x"]) > rx:
			continue
		if pos.y < s["top_mouth"].y - m or pos.y > s["bot_mouth"].y + m:
			continue
		var mid: float = (s["top_tile"].y + s["bot_tile"].y) * 0.5
		return {"s": s, "from_bottom": pos.y >= mid}
	return {}

## If pos is at a shaft, the far end to ride to; else null.
func mouth_at(pos: Vector2):
	var f := _find(pos)
	if f.is_empty():
		return null
	var s: Dictionary = f["s"]
	return s["top_mouth"] if f["from_bottom"] else s["bot_mouth"]

## If pos is at a shaft, the center of the nearest end tile (for the on-tile
## hint); else null.
func hint_pos(pos: Vector2):
	var f := _find(pos)
	if f.is_empty():
		return null
	var s: Dictionary = f["s"]
	return s["bot_tile"] if f["from_bottom"] else s["top_tile"]
