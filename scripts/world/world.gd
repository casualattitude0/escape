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

# Dev resume (host only; empty unless the dev_resume feature is active and a
# snapshot exists). See DevSnapshot / scripts/net/dev_snapshot.gd.
var _resume: Dictionary = {}
var _active_seed := 0

func _ready() -> void:
	add_child(PauseMenu.new())        # Esc overlay (every peer has its own)
	spawner.spawn_function = _spawn_player
	if multiplayer.is_server():
		if DevSnapshot.enabled():
			_resume = DevSnapshot.load_data()
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
		# Reuse the saved seed on resume so the map is byte-identical; otherwise
		# roll a fresh one (and remember it, so a later restart can resume).
		_active_seed = int(_resume.get("seed", randi())) if not _resume.is_empty() else randi()
		_build_layout.rpc(_active_seed)
		_after_layout()

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
	var base := _spawn_point(id, role)
	var resumed = _resume_point(id, role)
	# Start where the player last was (dev resume); respawn point stays the real spawn.
	p.position = resumed if resumed != null else base
	p.spawn_point = base
	return p

func _spawn_point(id: int, role: String) -> Vector2:
	if role == Roles.RUNNER:
		return RUNNER_SPAWN
	var idx := _hunter_index(id)
	if idx < 0:
		idx = 0
	return HUNTER_SPAWNS[idx % HUNTER_SPAWNS.size()]

# Deterministic Hunter index from sorted hunter ids (matches resume keying).
func _hunter_index(id: int) -> int:
	var hunters: Array = []
	for pid in Net.players:
		if Net.players[pid] == Roles.HUNTER:
			hunters.append(pid)
	hunters.sort()
	return hunters.find(id)

func _on_peer_disconnected(id: int) -> void:
	if not multiplayer.is_server():
		return
	_ready_peers.erase(id)
	var node := players_root.get_node_or_null(str(id))
	if node != null:
		node.queue_free()

# ---- dev resume (host only) -----------------------------------------------

## Position this player should re-enter at on resume, keyed by role (Runner) or
## hunter index (Hunters) so it survives ENet handing out different peer ids.
## Returns null when not resuming or nothing was saved for this slot.
func _resume_point(id: int, role: String) -> Variant:
	if _resume.is_empty():
		return null
	if role == Roles.RUNNER:
		var rp = _resume.get("runner_pos")
		return rp if rp is Vector2 else null
	var arr = _resume.get("hunter_pos", [])
	var idx := _hunter_index(id)
	if idx >= 0 and idx < arr.size() and arr[idx] is Vector2:
		return arr[idx]
	return null

## Runs on the host right after the layout is built. Re-hides already-collected
## items, restores match state, then starts the periodic autosave.
func _after_layout() -> void:
	if not _resume.is_empty():
		for item_name in _resume.get("hidden_items", []):
			var item := items_root.get_node_or_null(str(item_name))
			if item != null:
				item._hide.rpc()
		var gm := get_tree().get_first_node_in_group("game_manager")
		if gm != null:
			gm.restore_state(_resume.get("gm", {}))
	if DevSnapshot.enabled():
		var timer := Timer.new()
		timer.wait_time = 1.5
		timer.timeout.connect(_save_snapshot)
		add_child(timer)
		timer.start()

func _save_snapshot() -> void:
	var gm := get_tree().get_first_node_in_group("game_manager")
	if gm == null:
		return
	var hidden := PackedStringArray()
	for item in items_root.get_children():
		if item.get("_collected"):
			hidden.append(item.name)
	var runner_pos: Variant = null
	var hunter_pos: Array = []
	for c in players_root.get_children():
		var r = c.get("role")
		if r == Roles.RUNNER:
			runner_pos = c.global_position
		elif r == Roles.HUNTER:
			var idx := _hunter_index(c.name.to_int())
			if idx >= 0:
				if idx >= hunter_pos.size():
					hunter_pos.resize(idx + 1)
				hunter_pos[idx] = c.global_position
	DevSnapshot.save({
		"seed": _active_seed,
		"hidden_items": hidden,
		"runner_pos": runner_pos,
		"hunter_pos": hunter_pos,
		"gm": gm.snapshot_state(),
	})
