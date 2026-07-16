class_name LevelLayout
extends RefCounted

## Procedural placement of key objects and escape doors, grounded in the actual
## generated map (tools/generate_level.py). It reads the Terrain tilemap, finds
## every genuinely standable floor tile, groups them by room, then scatters
## spawns across distinct rooms with a minimum separation.
##
## Deterministic: seed a RandomNumberGenerator identically on every peer and the
## same layout comes out, so the host only has to share the seed (see world.gd).

const TILE := 64

# Rooms as tile-space rects Rect2i(x, y, w, h), inclusive of the interior. These
# mirror the carve() calls in tools/generate_level.py — they are just regions to
# spread spawns over; the real cells are filtered to actual standable floor.
const ROOMS := {
	"A": Rect2i(2, 22, 12, 6),     # SpawnHall (Runner starts here)
	"B": Rect2i(15, 23, 20, 5),    # LowerHall (Hunters start here)
	"C": Rect2i(9, 6, 4, 16),      # LeftShaft
	"E": Rect2i(14, 4, 17, 4),     # TopCorridor
	"F": Rect2i(20, 10, 16, 11),   # CentralHub
	"G": Rect2i(32, 4, 15, 4),     # TopRight
	"D": Rect2i(37, 10, 10, 18),   # RightShaft
	"H": Rect2i(36, 10, 5, 3),     # item chamber
}
const RUNNER_ROOM := "A"

var _solid: Dictionary = {}            # Vector2i -> true for occupied tiles
var cells_by_room: Dictionary = {}     # room name -> Array[Vector2i] standable

func _init(tilemap: TileMapLayer) -> void:
	for c in tilemap.get_used_cells():
		_solid[c] = true
	for room in ROOMS:
		var r: Rect2i = ROOMS[room]
		var list: Array = []
		for cy in range(r.position.y, r.position.y + r.size.y):
			for cx in range(r.position.x, r.position.x + r.size.x):
				if _is_stand(cx, cy):
					list.append(Vector2i(cx, cy))
		cells_by_room[room] = list

# A tile the player can actually stand on: empty, solid ground directly below,
# and the two rows above clear (the map's standing-clearance rule).
func _is_stand(cx: int, cy: int) -> bool:
	return not _s(cx, cy) and _s(cx, cy + 1) and not _s(cx, cy - 1) and not _s(cx, cy - 2)

func _s(cx: int, cy: int) -> bool:
	return _solid.has(Vector2i(cx, cy))

# World point sitting on the floor surface, centred on the tile.
func floor_world(c: Vector2i) -> Vector2:
	return Vector2((c.x + 0.5) * TILE, (c.y + 1) * TILE)

func _room_center(room: String) -> Vector2:
	var r: Rect2i = ROOMS[room]
	return Vector2((r.position.x + r.size.x * 0.5) * TILE, (r.position.y + r.size.y * 0.5) * TILE)

## Returns {"items": Array[Vector2], "doors": Array[Vector2]} in world space.
## Items avoid the Runner's spawn room to force travel; doors prefer the rooms
## farthest from the Runner so escaping means crossing the facility.
func generate(item_count: int, door_count: int, rng: RandomNumberGenerator, runner_spawn: Vector2) -> Dictionary:
	var chosen: Array = [runner_spawn]   # keep spawns off the Runner's start

	# Rooms that actually have standable tiles, farthest-from-spawn first.
	var rooms: Array = []
	for room in ROOMS:
		if not cells_by_room[room].is_empty():
			rooms.append(room)
	rooms.sort_custom(func(a, b): return _room_center(a).distance_to(runner_spawn) \
			> _room_center(b).distance_to(runner_spawn))

	var item_rooms: Array = rooms.filter(func(r): return r != RUNNER_ROOM)
	if item_rooms.is_empty():
		item_rooms = rooms
	var items: Array = _scatter(item_count, item_rooms, rng, chosen, 7.0 * TILE)
	var doors: Array = _scatter(door_count, rooms, rng, chosen, 8.0 * TILE)
	return {"items": items, "doors": doors}

# Round-robin over rooms, taking a random standable tile from each that clears
# the minimum separation. The requirement relaxes each full cycle so a crowded
# map still yields the requested count.
func _scatter(count: int, room_order: Array, rng: RandomNumberGenerator, chosen: Array, min_sep: float) -> Array:
	var out: Array = []
	if room_order.is_empty():
		return out
	var i := 0
	var guard := 0
	while out.size() < count and guard < 4000:
		guard += 1
		var sep := min_sep * pow(0.7, i / room_order.size())
		var cells: Array = cells_by_room[room_order[i % room_order.size()]]
		i += 1
		if cells.is_empty():
			continue
		for _attempt in 8:
			var p := floor_world(cells[rng.randi() % cells.size()])
			if _clear(p, chosen, sep):
				out.append(p)
				chosen.append(p)
				break
	return out

## A random standable world point at least `min_sep` from every point in `avoid`.
## Server-side scatter target for a captured key (see GameManager); non-random
## result is fine to replicate. Returns null if nothing qualifies.
func random_floor(avoid: Array, min_sep: float) -> Variant:
	var cells: Array = []
	for room in cells_by_room:
		cells.append_array(cells_by_room[room])
	if cells.is_empty():
		return null
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for _attempt in 200:
		var p := floor_world(cells[rng.randi() % cells.size()])
		if _clear(p, avoid, min_sep):
			return p
	return null

func _clear(p: Vector2, others: Array, sep: float) -> bool:
	for o in others:
		if p.distance_to(o) < sep:
			return false
	return true
