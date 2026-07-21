extends Node
class_name TunnelSystem

## Runner-exclusive horizontal fast-travel: a tunnel bored through a wall. The
## Runner presses the slide action at one mouth and instantly blinks to the far
## mouth on the other side of the wall. This is the horizontal counterpart to the
## Hunter elevator (vertical); the two networks are independent (GDD 4.4/4.5).
##
## Authoring (tile-based): on the level's dedicated "Tunnel" TileMapLayer, paint
## a horizontal run of tiles straight through a wall. Each maximal run of
## same-row contiguous cells is one tunnel; its two mouths are the open cells
## just past the left and right ends. Standing at either mouth and pressing slide
## warps to the other. (The Runner's slide-through low ceilings are a separate
## thing entirely: those are ordinary terrain collision, not this layer.)

const ENTER_X_TILES := 0.6   # horizontal reach into a mouth cell (tile widths)
const ENTER_Y_TILES := 1.0   # vertical tolerance at a mouth (tile heights)
const FOOT_OFFSET := 36.0    # player origin sits this far above its feet (see player.tscn)
const FLOOR_SCAN := 12       # cells searched downward for the floor under a mouth

var _layer: TileMapLayer
var _terrain: TileMapLayer
var _tile: Vector2 = Vector2(32, 32)
var _tunnels: Array = []     # each: {"a": Vector2, "b": Vector2} mouths in world space

## Scan the Tunnel layer into paired mouths. Cheap; run on every peer at load.
func setup(tunnel_layer: TileMapLayer, terrain: TileMapLayer) -> void:
	_layer = tunnel_layer
	_terrain = terrain
	_tunnels.clear()
	if _layer == null or _layer.tile_set == null:
		return
	_tile = Vector2(_layer.tile_set.tile_size)
	_build()

func _build() -> void:
	# Group used cells into maximal horizontal runs (same row, contiguous x).
	var by_row: Dictionary = {}
	for c in _layer.get_used_cells():
		var xs: Array = by_row.get(c.y, [])
		xs.append(c.x)
		by_row[c.y] = xs
	for y in by_row:
		var xs: Array = by_row[y]
		xs.sort()
		var start: int = xs[0]
		var prev: int = xs[0]
		for i in range(1, xs.size()):
			var x: int = xs[i]
			if x > prev + 1:
				_add_run(start, prev, y)
				start = x
			prev = x
		_add_run(start, prev, y)

func _add_run(x0: int, x1: int, y: int) -> void:
	var a := _mouth_pos(Vector2i(x0 - 1, y))
	var b := _mouth_pos(Vector2i(x1 + 1, y))
	var fwd := signf(b.x - a.x)
	_tunnels.append({
		"a": a,
		"b": b,
		# Peek spots one cell into the pipe from each mouth (same height): where
		# the Runner sits while inside. They only move out to the mouth to emerge.
		"a_in": Vector2(a.x + fwd * _tile.x, a.y),
		"b_in": Vector2(b.x - fwd * _tile.x, b.y),
	})

## Where the Runner lands at a mouth cell: the cell center in x, dropped so its
## feet rest on the nearest floor below (same rule as world._snap_to_floor).
func _mouth_pos(cell: Vector2i) -> Vector2:
	var center := _layer.map_to_local(cell)
	if _terrain != null:
		var t := _terrain.local_to_map(center)
		for dy in FLOOR_SCAN:
			var below := Vector2i(t.x, t.y + dy)
			if _terrain.get_cell_source_id(below) != -1:
				return Vector2(center.x, below.y * _tile.y - FOOT_OFFSET)
	return center

## If pos sits at a tunnel mouth, return the mouths and the inside peek-spots for
## both the near end (entry/entry_in) and the opposite one (far/far_in), so the
## caller can hold the Runner inside and emerge them at a mouth. Null otherwise.
func enter_at(pos: Vector2):
	var rx := _tile.x * ENTER_X_TILES
	var ry := _tile.y * ENTER_Y_TILES
	for t in _tunnels:
		var a: Vector2 = t["a"]
		var b: Vector2 = t["b"]
		if absf(pos.x - a.x) <= rx and absf(pos.y - a.y) <= ry:
			return {"entry": a, "far": b, "entry_in": t["a_in"], "far_in": t["b_in"]}
		if absf(pos.x - b.x) <= rx and absf(pos.y - b.y) <= ry:
			return {"entry": b, "far": a, "entry_in": t["b_in"], "far_in": t["a_in"]}
	return null
