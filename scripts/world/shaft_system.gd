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

const ENTER_X_TILES := 1.0   # horizontal tolerance at a mouth (tile widths)
const ENTER_Y_TILES := 0.7   # vertical reach into a mouth cell (tile heights)
const FOOT_OFFSET := 36.0    # player origin sits this far above its feet (see player.tscn)
const FLOOR_SCAN := 12       # cells searched downward for the floor under a mouth

var _layer: TileMapLayer
var _terrain: TileMapLayer
var _tile: Vector2 = Vector2(32, 32)
var _shafts: Array = []      # each: {"a": Vector2 top mouth, "b": Vector2 bottom mouth}

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
	_shafts.append({
		"a": _mouth_pos(Vector2i(x, y0 - 1)),   # top mouth (open cell above the run)
		"b": _mouth_pos(Vector2i(x, y1 + 1)),   # bottom mouth (open cell below the run)
		# Centers of the end tiles themselves, for placing the on-tile hint.
		"a_tile": _layer.map_to_local(Vector2i(x, y0)),
		"b_tile": _layer.map_to_local(Vector2i(x, y1)),
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

## If pos sits at a shaft mouth, the far mouth to ride to; else null.
func mouth_at(pos: Vector2):
	var rx := _tile.x * ENTER_X_TILES
	var ry := _tile.y * ENTER_Y_TILES
	for s in _shafts:
		var a: Vector2 = s["a"]
		var b: Vector2 = s["b"]
		if absf(pos.x - a.x) <= rx and absf(pos.y - a.y) <= ry:
			return b
		if absf(pos.x - b.x) <= rx and absf(pos.y - b.y) <= ry:
			return a
	return null

## If pos sits at a shaft mouth, the center of the nearest shaft tile (for the
## on-tile hint); else null.
func hint_pos(pos: Vector2):
	var rx := _tile.x * ENTER_X_TILES
	var ry := _tile.y * ENTER_Y_TILES
	for s in _shafts:
		if absf(pos.x - s["a"].x) <= rx and absf(pos.y - s["a"].y) <= ry:
			return s["a_tile"]
		if absf(pos.x - s["b"].x) <= rx and absf(pos.y - s["b"].y) <= ry:
			return s["b_tile"]
	return null
