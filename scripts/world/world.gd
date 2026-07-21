extends Node2D

## Spawns the players once everyone has loaded the world, then hands off to the
## GameManager for the actual match. The host is the Runner; joiners are Hunters.

const PLAYER := preload("res://scenes/actors/player.tscn")
const DEVICE := preload("res://scenes/actors/device.tscn")
const ESCAPE := preload("res://scenes/actors/escape_point.tscn")
const MEDIA := preload("res://scenes/actors/media_item.tscn")

var RUNNER_SPAWN := Vector2.ZERO
var HUNTER_SPAWNS: Array[Vector2] = []

# One way out (GDD 3): it opens only once every device is broken, so there is
# nothing to choose between and no reason for a second.
const ESCAPE_COUNT := 1

@onready var spawner: MultiplayerSpawner = $MultiplayerSpawner
@onready var players_root: Node = $Players
@onready var devices_root: Node2D = $Devices
@onready var escape_root: Node2D = $Escape
@onready var media_root: Node = get_node_or_null("Media")
@onready var terrain: TileMapLayer = $Terrain

# ids that have confirmed their world scene is ready (server-side only)
var _ready_peers: Dictionary = {}
var _layout_built := false

# Dev resume (host only; empty unless the dev_resume feature is active and a
# snapshot exists). See DevSnapshot / scripts/net/dev_snapshot.gd.
var _resume: Dictionary = {}
var _active_seed := 0

func _read_spawns() -> void:
	var rs := get_node_or_null("RunnerSpawn") as Marker2D
	if rs != null:
		RUNNER_SPAWN = _snap_to_floor(rs.position)
	for i in 4:
		var hs := get_node_or_null("HunterSpawn%d" % i) as Marker2D
		if hs != null:
			HUNTER_SPAWNS.append(_snap_to_floor(hs.position))

func _snap_to_floor(pos: Vector2) -> Vector2:
	var tile_pos := terrain.local_to_map(pos)
	var tile_size := terrain.tile_set.tile_size
	for dy in 200:
		var check := Vector2i(tile_pos.x, tile_pos.y + dy)
		if terrain.get_cell_source_id(check) != -1:
			return Vector2(pos.x, check.y * tile_size.y - 36)
	return pos

## World positions of the authored devices: one per painted Device_tiles cluster
## (4-neighbour connected component), placed at the cluster's centroid. Sorted so
## the index each device gets is the same on every peer. Empty when nothing is
## painted, in which case _build_layout uses the procedural scatter instead.
func _authored_device_spots() -> Array:
	var layer := get_node_or_null("Device_tiles") as TileMapLayer
	if layer == null:
		return []
	var cells := layer.get_used_cells()
	if cells.is_empty():
		return []
	var cell_set := {}
	for c in cells:
		cell_set[c] = true
	var seen := {}
	var spots: Array = []
	var neighbours := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for c in cells:
		if seen.has(c):
			continue
		var stack: Array = [c]
		var members: Array = []
		seen[c] = true
		while not stack.is_empty():
			var cur: Vector2i = stack.pop_back()
			members.append(cur)
			for d in neighbours:
				var nb: Vector2i = cur + d
				if cell_set.has(nb) and not seen.has(nb):
					seen[nb] = true
					stack.append(nb)
		var sum := Vector2.ZERO
		for m in members:
			sum += layer.map_to_local(m)
		spots.append(sum / float(members.size()))
	spots.sort_custom(_sort_by_xy)
	return spots

## Deterministic 2D ordering (top-to-bottom, then left-to-right) so authored
## device indices match across peers regardless of get_used_cells iteration order.
func _sort_by_xy(a: Vector2, b: Vector2) -> bool:
	if a.y != b.y:
		return a.y < b.y
	return a.x < b.x

## World positions of the media spawns, one per Marker2D under MediaSpawns. Snapped
## to the floor so a roughly-dragged placeholder still rests on ground (the designer
## tunes X; Y is forgiving). Empty when the container/markers are absent.
func _read_media_spawns() -> Array:
	var spots: Array = []
	var root := get_node_or_null("MediaSpawns")
	if root == null:
		return spots
	for m in root.get_children():
		if m is Marker2D:
			spots.append(_snap_to_floor(m.global_position))
	return spots

func _ready() -> void:
	_read_spawns()
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
		# A snapshot from an older build has a match state this version cannot read
		# (keys and doors, where there are now devices and one exit). Restoring it
		# would quietly produce a nonsense round rather than fail, so drop it.
		if not _resume.is_empty() \
				and int(_resume.get("gm", {}).get("v", 1)) != GameManager.SNAPSHOT_VERSION:
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
## Devices and the escape point are plain scene nodes with matching names on all
## peers, so the rpcs and index lookups resolve identically everywhere.
##
## LevelLayout still calls these "items" and "doors"; it scatters devices first
## and then places the escape point in the room FARTHEST from the Runner's spawn,
## clear of the spawn and of every device — which is what GDD 4.7 asks for, so it
## needs no changes to serve the new model.
@rpc("authority", "call_local", "reliable")
func _build_layout(layout_seed: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = layout_seed

	var layout := LevelLayout.new(terrain)
	var plan := layout.generate(DeviceSystem.DEVICE_COUNT, ESCAPE_COUNT, rng, RUNNER_SPAWN)

	# Devices: prefer the authored Device_tiles clusters (one device per painted
	# cluster); fall back to the procedural scatter when nothing is painted, so
	# the older levels keep working unchanged.
	var authored := _authored_device_spots()
	var device_spots: Array = authored if not authored.is_empty() else plan["items"]
	var escape_spots: Array = plan["doors"]
	for i in device_spots.size():
		var device := DEVICE.instantiate()
		device.name = "Device%d" % i
		device.index = i
		device.position = device_spots[i]
		devices_root.add_child(device)
	for i in escape_spots.size():
		var exit_point := ESCAPE.instantiate()
		exit_point.name = "Escape%d" % i
		exit_point.index = i
		exit_point.position = escape_spots[i]
		escape_root.add_child(exit_point)

	# Media (破壞媒材): one item per authored MediaSpawns marker.
	var media_spots := _read_media_spawns()
	if media_root != null:
		for i in media_spots.size():
			var item := MEDIA.instantiate()
			item.name = "Media%d" % i
			item.index = i
			item.position = media_spots[i]
			media_root.add_child(item)

	# Tell the match state the real (authored, peer-identical) counts.
	var gm := get_tree().get_first_node_in_group("game_manager")
	if gm != null:
		gm.devices.device_count = device_spots.size()
		gm.setup_media(media_spots)

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
	# Position replicates as net_pos (see player.gd) — the spawner captures its
	# spawn-state from the host's copy, so it must carry the spawn spot too, or
	# every remote copy starts at (0,0) until the owner's first sync arrives.
	p.net_pos = p.position
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

## Runs on the host right after the layout is built. Restores match state, then
## starts the periodic autosave.
##
## Devices need no per-node restore: they never move, and their damage lives in
## the GameManager's replicated state, so restore_state below repaints them.
func _after_layout() -> void:
	if not _resume.is_empty():
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

## Capture the live match state (seed, player positions, game state) as a plain
## dictionary. Used for both the dev-resume autosave and the live rejoin
## snapshot. Returns {} if the match isn't ready.
##
## Device damage is not listed here: it lives in gm.snapshot_state() and the
## devices themselves are rebuilt from the seed, at fixed positions.
func _build_snapshot() -> Dictionary:
	var gm := get_tree().get_first_node_in_group("game_manager")
	if gm == null:
		return {}
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
