extends Node2D

## Spawns the players once everyone has loaded the world, then hands off to the
## GameManager for the actual match. The host is the Runner; joiners are Hunters.

const PLAYER := preload("res://scenes/player.tscn")
const ITEM := preload("res://scenes/item.tscn")
const DOOR := preload("res://scenes/escape_door.tscn")

const RUNNER_SPAWN := Vector2(208, 1690)
const HUNTER_SPAWNS := [
	Vector2(1500, 1650),
	Vector2(1650, 1650),
	Vector2(1800, 1650),
	Vector2(1950, 1650),
]

# Distinct colours for the x / y / z key objects.
const ITEM_COLORS := [
	Color(0.95, 0.85, 0.25),
	Color(0.3, 0.85, 0.9),
	Color(0.85, 0.4, 0.9),
]

@onready var spawner: MultiplayerSpawner = $MultiplayerSpawner
@onready var players_root: Node = $Players
@onready var items_root: Node2D = $Items
@onready var doors_root: Node2D = $Doors
@onready var terrain: TileMapLayer = $Terrain

# ids that have confirmed their world scene is ready (server-side only)
var _ready_peers: Dictionary = {}
var _layout_built := false

func _ready() -> void:
	spawner.spawn_function = _spawn_player
	if multiplayer.is_server():
		_ready_peers[1] = true
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		_try_spawn_all()
	else:
		_announce_ready.rpc_id(1)

@rpc("any_peer", "reliable")
func _announce_ready() -> void:
	if not multiplayer.is_server():
		return
	_ready_peers[multiplayer.get_remote_sender_id()] = true
	_try_spawn_all()

func _try_spawn_all() -> void:
	# Wait until every rostered peer has its world ready, so no spawn is missed.
	for id in Net.players:
		if not _ready_peers.has(id):
			return
	for id in Net.players:
		if not players_root.has_node(str(id)):
			spawner.spawn(id)
	# Roster is settled — pick and share the item/door layout exactly once.
	if not _layout_built:
		_layout_built = true
		_build_layout.rpc(randi())

## Every peer builds the same layout from the shared seed (see LevelLayout).
## Items and doors are plain scene nodes with matching names on all peers, so
## their pickup / open rpcs resolve identically.
@rpc("authority", "call_local", "reliable")
func _build_layout(layout_seed: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = layout_seed
	var hunters := 0
	for id in Net.players:
		if Net.players[id] == Roles.HUNTER:
			hunters += 1
	var door_count: int = hunters + 1              # GDD 4.1: always one more than Hunters
	var item_count: int = get_tree().get_first_node_in_group("game_manager").items_total()

	var layout := LevelLayout.new(terrain)
	var plan := layout.generate(item_count, door_count, rng, RUNNER_SPAWN)

	var item_spots: Array = plan["items"]
	var door_spots: Array = plan["doors"]
	for i in item_spots.size():
		var item := ITEM.instantiate()
		item.name = "Item%d" % i
		item.position = item_spots[i]
		item.get_node("Fill").color = ITEM_COLORS[i % ITEM_COLORS.size()]
		items_root.add_child(item)
	for i in door_spots.size():
		var door := DOOR.instantiate()
		door.name = "Door%d" % i
		door.position = door_spots[i]
		doors_root.add_child(door)

func _spawn_player(id: int) -> Node:
	var p := PLAYER.instantiate()
	p.name = str(id)
	p.set_multiplayer_authority(id)
	var role: String = Net.players.get(id, Roles.HUNTER)
	p.role = role
	var pos := _spawn_point(id, role)
	p.position = pos
	p.spawn_point = pos
	return p

func _spawn_point(id: int, role: String) -> Vector2:
	if role == Roles.RUNNER:
		return RUNNER_SPAWN
	# Deterministic Hunter index from sorted hunter ids.
	var hunters: Array = []
	for pid in Net.players:
		if Net.players[pid] == Roles.HUNTER:
			hunters.append(pid)
	hunters.sort()
	var idx := hunters.find(id)
	if idx < 0:
		idx = 0
	return HUNTER_SPAWNS[idx % HUNTER_SPAWNS.size()]

func _on_peer_disconnected(id: int) -> void:
	if not multiplayer.is_server():
		return
	_ready_peers.erase(id)
	var node := players_root.get_node_or_null(str(id))
	if node != null:
		node.queue_free()
