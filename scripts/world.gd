extends Node2D

## Spawns the players once everyone has loaded the world, then hands off to the
## GameManager for the actual match. The host is the Runner; joiners are Hunters.

const PLAYER := preload("res://scenes/player.tscn")

const RUNNER_SPAWN := Vector2(208, 1690)
const HUNTER_SPAWNS := [
	Vector2(1500, 1650),
	Vector2(1650, 1650),
	Vector2(1800, 1650),
	Vector2(1950, 1650),
]

@onready var spawner: MultiplayerSpawner = $MultiplayerSpawner
@onready var players_root: Node = $Players

# ids that have confirmed their world scene is ready (server-side only)
var _ready_peers: Dictionary = {}

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

func _spawn_player(id: int) -> Node:
	var p := PLAYER.instantiate()
	p.name = str(id)
	p.set_multiplayer_authority(id)
	var role: String = Net.players.get(id, "hunter")
	p.role = role
	p.position = _spawn_point(id, role)
	return p

func _spawn_point(id: int, role: String) -> Vector2:
	if role == "runner":
		return RUNNER_SPAWN
	# Deterministic Hunter index from sorted hunter ids.
	var hunters: Array = []
	for pid in Net.players:
		if Net.players[pid] == "hunter":
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
