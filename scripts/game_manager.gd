extends Node

## Server-authoritative game state. Runs its logic only on the host (peer 1)
## and pushes the results (item count, capture progress, winner) to every
## client so the HUD can display them.

signal state_changed

# Tuning (plain vars so instances/HUD can read them directly).
var items_total := 3
var capture_needed := 4.0        # seconds of read-bar for a lone Hunter
var capture_range := 100.0       # how close a Hunter must be to read
var attack_range := 150.0        # Runner's counter-attack reach
var stun_time := 1.5             # how long a hit Hunter is disabled
var capture_decay := 1.5         # progress lost per second when nobody reads

# Replicated state.
var items_collected := 0
var capture_progress := 0.0
var winner := ""                 # "", "runner", "hunters"

@onready var _players: Node = get_node("../Players")

# hunter_id -> is currently holding the capture button
var _capturing: Dictionary = {}

func _ready() -> void:
	add_to_group("game_manager")
	set_physics_process(multiplayer.is_server())

func capture_ratio() -> float:
	return clampf(capture_progress / capture_needed, 0.0, 1.0)

# ---- items (called on the server by Item) ---------------------------------

func collect_item() -> void:
	if not multiplayer.is_server():
		return
	items_collected += 1
	_broadcast(true)

# ---- Runner reaches an open door (called on the server by EscapeDoor) ------

func try_escape() -> void:
	if not multiplayer.is_server() or winner != "":
		return
	if items_collected >= items_total:
		_set_winner("runner")

# ---- capture read-bar -----------------------------------------------------

@rpc("any_peer", "reliable")
func set_capturing(holding: bool) -> void:
	if not multiplayer.is_server():
		return
	_capturing[multiplayer.get_remote_sender_id()] = holding

@rpc("any_peer", "call_local", "reliable")
func runner_attack() -> void:
	if not multiplayer.is_server() or winner != "":
		return
	var runner := _find_runner()
	if runner == null:
		return
	var landed := false
	for id in _capturing.keys():
		var h: Node2D = _players.get_node_or_null(str(id))
		if h != null and h.global_position.distance_to(runner.global_position) <= attack_range:
			_capturing[id] = false
			h.stun.rpc_id(id, stun_time)
			landed = true
	if landed:
		capture_progress = 0.0
		_broadcast(true)

func _physics_process(delta: float) -> void:
	if winner != "":
		return
	var runner := _find_runner()
	if runner == null:
		return
	var active := 0
	for id in _capturing.keys():
		if not _capturing[id]:
			continue
		var h: Node2D = _players.get_node_or_null(str(id))
		if h != null and not h.stunned \
				and h.global_position.distance_to(runner.global_position) <= capture_range:
			active += 1
	if active > 0:
		# More Hunters reading at once fills the bar faster.
		capture_progress = minf(capture_needed, capture_progress + delta * active)
		if capture_progress >= capture_needed:
			_set_winner("hunters")
			return
	else:
		capture_progress = maxf(0.0, capture_progress - delta * capture_decay)
	_broadcast(false)

# ---- replication ----------------------------------------------------------

func _set_winner(w: String) -> void:
	winner = w
	_broadcast(true)

func _broadcast(reliable: bool) -> void:
	if reliable:
		_sync_state.rpc(items_collected, capture_progress, winner)
	else:
		_sync_state_fast.rpc(items_collected, capture_progress, winner)

@rpc("authority", "call_local", "reliable")
func _sync_state(items: int, cap: float, w: String) -> void:
	items_collected = items
	capture_progress = cap
	winner = w
	state_changed.emit()

@rpc("authority", "call_local", "unreliable")
func _sync_state_fast(items: int, cap: float, w: String) -> void:
	# Never let an unreliable packet undo a decided game.
	if winner != "":
		return
	items_collected = items
	capture_progress = cap
	state_changed.emit()

func _find_runner() -> Node2D:
	for c in _players.get_children():
		if c.get("role") == "runner":
			return c
	return null
