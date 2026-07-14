class_name LevelLayout2
extends RefCounted

## Spawn placement for the second map (scenes/level2.tscn). Identical logic to
## LevelLayout — it only differs in the ROOMS table, which is the horizontal
## mirror of the base map's rooms (see tools/generate_level2.py). Keeping it a
## separate class avoids threading a rooms parameter through the shared one.

const TILE := 32

# Horizontal mirror of LevelLayout.ROOMS: x' = 100 - (x + w).
const ROOMS := {
	"A": Rect2i(73, 44, 23, 11),   # SpawnHall (Runner starts here) — now bottom-right
	"B": Rect2i(31, 46, 39, 9),    # LowerHall (Hunters start here) — now bottom-left
	"C": Rect2i(75, 12, 7, 32),    # RightShaft (was LeftShaft)
	"E": Rect2i(39, 8, 33, 8),     # TopCorridor
	"F": Rect2i(29, 19, 31, 22),   # CentralHub
	"G": Rect2i(6, 8, 30, 7),      # TopLeft (was TopRight)
	"D": Rect2i(6, 19, 20, 36),    # LeftShaft (was RightShaft)
	"H": Rect2i(20, 20, 9, 6),     # item chamber
}
const RUNNER_ROOM := "A"

var _solid: Dictionary = {}
var cells_by_room: Dictionary = {}

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

func _is_stand(cx: int, cy: int) -> bool:
	return not _s(cx, cy) and _s(cx, cy + 1) and not _s(cx, cy - 1) and not _s(cx, cy - 2)

func _s(cx: int, cy: int) -> bool:
	return _solid.has(Vector2i(cx, cy))

func floor_world(c: Vector2i) -> Vector2:
	return Vector2((c.x + 0.5) * TILE, (c.y + 1) * TILE)

func _room_center(room: String) -> Vector2:
	var r: Rect2i = ROOMS[room]
	return Vector2((r.position.x + r.size.x * 0.5) * TILE, (r.position.y + r.size.y * 0.5) * TILE)

func generate(item_count: int, door_count: int, rng: RandomNumberGenerator, runner_spawn: Vector2) -> Dictionary:
	var chosen: Array = [runner_spawn]

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
