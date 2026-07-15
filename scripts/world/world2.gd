extends Node2D

## World controller for the SECOND map (scenes/level2.tscn — the mirrored,
## Terrain.png-skinned facility). Identical to world.gd except the spawn points
## and the layout helper are mirrored to match level2. See world.gd for the full
## commentary on the spawn / resume / rejoin flow.

const PLAYER := preload("res://scenes/actors/player.tscn")
const ITEM := preload("res://scenes/actors/item.tscn")
const DOOR := preload("res://scenes/actors/escape_door.tscn")

# Horizontal mirror of world.gd's spawns (world x' = 3200 - x): Runner now starts
# bottom-right, Hunters bottom-left, matching level2's flipped rooms.
const RUNNER_SPAWN := Vector2(2992, 1690)
const HUNTER_SPAWNS := [
	Vector2(1700, 1650),
	Vector2(1550, 1650),
	Vector2(1400, 1650),
	Vector2(1250, 1650),
]

# Keys are interchangeable now (GDD 4.1), so they share one colour.
const KEY_COLOR := Color(0.95, 0.82, 0.25)
const DOOR_COUNT := 3

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
		add_to_group("world_host")    # so Net can trigger a rejoin resync
		# Resume source: a live rejoin snapshot (a client reconnected) takes
		# priority, else the dev-resume snapshot from disk.
		if not Net.rejoin_snapshot.is_empty():
			_resume = Net.rejoin_snapshot
			Net.rejoin_snapshot = {}
		elif DevSnapshot.enabled():
			_resume = DevSnapshot.load_data()
		# A snapshot saved against an older version of the map (edited terrain,
		# re-run tools/generate_level.py, etc.) has stale seeds/positions that no
		# longer correspond to real floor — resuming it can drop players outside
		# the level. Discard it and start a fresh round instead.
		if not _resume.is_empty() and _resume.get("terrain_sig") != _terrain_signature():
			_resume = {}
		# A snapshot saved after the match already ended (a winner was decided)
		# has no in-progress round left to continue — resuming it just replays
		# stale positions from when the round finished. Only meant to pick a
		# live/unfinished round back up, so discard it too.
		if not _resume.is_empty() and String(_resume.get("gm", {}).get("winner", "")) != "":
			_resume = {}
		_ready_peers[1] = true
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		_try_spawn_all()
	else:
		_announce_ready.rpc_id(1)

@rpc("any_peer", "reliable")
func _announce_ready() -> void:
	if not multiplayer.is_server():
		return
	var peer := multiplayer.get_remote_sender_id()
	_ready_peers[peer] = true
	# _resume only exists on the host (see _ready()); the custom spawn_function
	# below runs independently on every peer, so without this each remote peer's
	# own _spawn_player() sees an empty _resume and falls back to the plain spawn
	# point — and since that peer is the multiplayer authority for its own player,
	# that wrong position is what actually sticks. Send it before _try_spawn_all()
	# so it lands ahead of the spawn messages on this same reliable channel.
	_receive_resume.rpc_id(peer, _resume)
	_try_spawn_all()

@rpc("authority", "reliable")
func _receive_resume(resume: Dictionary) -> void:
	_resume = resume

func _try_spawn_all() -> void:
	# Wait until every rostered peer has its world ready, so no spawn is missed.
	for id in Net.players:
		if not _ready_peers.has(id):
			return
	if _layout_built:
		return
	# Roster is settled — spawn everyone and share the layout exactly once.
	for id in Net.players:
		if not players_root.has_node(str(id)):
			spawner.spawn(id)
	_layout_built = true
	# Reuse the saved seed on resume so the map is byte-identical; otherwise roll
	# a fresh one (and remember it, so a later restart / rejoin can resume).
	_active_seed = int(_resume.get("seed", randi())) if not _resume.is_empty() else randi()
	_build_layout.rpc(_active_seed)
	_after_layout()

## Called on the host (via Net) when a client (re)joins mid-match. Snapshot the
## live match, then have EVERYONE reload the world together. The reload rebuilds
## the MultiplayerSpawner from scratch on every peer — including the newcomer —
## which sidesteps Godot's fragile mid-session spawn back-fill, and the snapshot
## is restored on the fresh world so the match continues where it left off.
func rejoin_new_peer() -> void:
	if not multiplayer.is_server() or not _layout_built:
		return
	Net.rejoin_snapshot = _build_snapshot()
	Net.reload_all()

## Every peer builds the same layout from the shared seed (see LevelLayout).
## Items and doors are plain scene nodes with matching names on all peers, so
## their pickup / open rpcs resolve identically.
@rpc("authority", "call_local", "reliable")
func _build_layout(layout_seed: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = layout_seed
	# Fixed 3 doors + 3 interchangeable keys (GDD 4.1); complete any one door.
	var item_count := ItemSystem.KEYS_TOTAL

	var layout := LevelLayout2.new(terrain)
	var plan := layout.generate(item_count, DOOR_COUNT, rng, RUNNER_SPAWN)

	var item_spots: Array = plan["items"]
	var door_spots: Array = plan["doors"]
	for i in item_spots.size():
		var item := ITEM.instantiate()
		item.name = "Item%d" % i
		item.index = i
		item.position = item_spots[i]
		item.get_node("Fill").color = KEY_COLOR
		items_root.add_child(item)
	for i in door_spots.size():
		var door := DOOR.instantiate()
		door.name = "Door%d" % i
		door.index = i
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
	# Start where the player last was (dev resume / rejoin); respawn point stays real.
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
## hunter index (Hunters) so it survives the transport handing out different peer ids.
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
		# Re-apply each key's live state: held (carried/installed -> hidden) or its
		# last world position (available or scattered).
		for st in _resume.get("key_states", []):
			var item := items_root.get_node_or_null(str(st.get("name", "")))
			if item == null:
				continue
			if bool(st.get("held", false)):
				item.set_held.rpc(true)
			else:
				item.place.rpc(st.get("pos", item.position))
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
	var snap := _build_snapshot()
	if not snap.is_empty():
		DevSnapshot.save(snap)

## Capture the live match state (seed, taken items, player positions, game state)
## as a plain dictionary. Used for both the dev-resume autosave and the live
## rejoin snapshot. Returns {} if the match isn't ready.
func _build_snapshot() -> Dictionary:
	var gm := get_tree().get_first_node_in_group("game_manager")
	if gm == null:
		return {}
	var key_states: Array = []
	for item in items_root.get_children():
		key_states.append({
			"name": item.name,
			"pos": item.position,
			"held": bool(item.get("_held")),
		})
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
	return {
		"seed": _active_seed,
		"key_states": key_states,
		"runner_pos": runner_pos,
		"hunter_pos": hunter_pos,
		"gm": gm.snapshot_state(),
		"terrain_sig": _terrain_signature(),
	}

## Cheap fingerprint of the baked terrain (cell coords + tile ids), so a
## snapshot can detect it was saved against a since-edited map.
func _terrain_signature() -> int:
	var parts := PackedStringArray()
	for c in terrain.get_used_cells():
		parts.append("%d,%d,%d" % [c.x, c.y, terrain.get_cell_source_id(c)])
	parts.sort()
	return ",".join(parts).hash()
