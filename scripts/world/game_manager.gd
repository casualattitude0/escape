extends Node

## Server-authoritative match coordinator and the rpc facade the rest of the
## game talks to. Runs its logic only on the host (peer 1). It owns the winner,
## the match clock, and the replication, delegating details to its children:
##   * $ItemSystem   — escape progress (carrying + per-door key installs)
##   * $GrappleSystem — the capture mash-off
## Players, keys and doors reach this node via the "game_manager" group and call
## its facade methods / rpcs; they never touch the subsystems directly.
##
## Win conditions (GDD 3 / 4.1):
##   * Runner escapes by installing PER_DOOR keys into ANY one door.
##   * Hunters win by running out the MATCH_TIME clock. Capturing the Runner is
##     NOT a win — it scatters the key the Runner was carrying and buys time.

signal state_changed
# Fired on every peer when the Runner makes a noise (GDD 4.3). `heard_near` is
# true for the LOCAL player when it is a Hunter close enough to the noise to get
# a vision-clarity boost; false means the noise instead surfaces as a minimap
# ping. The Runner peer ignores it (no Hunter UI).
signal sound_heard(world_pos: Vector2, heard_near: bool)

const MATCH_TIME := 90.0          # seconds; Hunters win when it hits 0 (GDD 3)
const CAPTURE_STUN := 0.6         # Runner recovery after a capture / scatter
const SCATTER_MIN_SEP := 6.0 * 32.0   # keep a scattered key clear of doors/Runner

var capture_range := 110.0       # how close a Hunter must be to grab / mash
var sound_near_radius := 540.0   # Hunters within this of a noise see clearly;
                                 # farther ones only get a minimap ping

var winner := ""                 # "", Roles.WIN_RUNNER, Roles.WIN_HUNTERS
var time_left := MATCH_TIME

@onready var items: ItemSystem = $ItemSystem
@onready var grapple: GrappleSystem = $GrappleSystem
@onready var _players: Node = get_node("../Players")
@onready var _items_root: Node = get_node("../Items")
@onready var _doors_root: Node = get_node("../Doors")
@onready var _terrain: TileMapLayer = get_node("../Terrain")

var _carried_index := -1         # which key node the Runner is carrying (-1 = none)
var _sync_accum := 0.0           # cadence for periodic (clock) fast syncs

func _ready() -> void:
	add_to_group("game_manager")
	set_physics_process(multiplayer.is_server())

# ---- read facade (HUD / players / doors) ----------------------------------

func grappling() -> bool:
	return grapple.active

func players() -> Node:
	return _players

func doors() -> Node:
	return _doors_root

func carrying() -> bool:
	return items.carrying

func per_door() -> int:
	return ItemSystem.PER_DOOR

func door_installs(idx: int) -> int:
	return items.door_installs(idx)

func best_progress() -> int:
	return items.best_progress()

func time_ratio() -> float:
	return time_left / MATCH_TIME

func time_seconds() -> int:
	return int(ceil(time_left))

func capture_ratio() -> float:
	return grapple.cap

func escape_ratio() -> float:
	return grapple.esc

# ---- keys / doors (called on the server by Item / EscapeDoor) --------------

## Runner touched key `idx`. Picks it up if hands are free — carrying is the
## Runner's main exposed window (GDD 4.1).
func try_pickup(idx: int) -> void:
	if not multiplayer.is_server() or winner != "":
		return
	if items.carrying or grapple.active:
		return
	items.carrying = true
	_carried_index = idx
	var it: Node = _items_root.get_node_or_null("Item%d" % idx)
	if it != null:
		it.set_held.rpc(true)
	var runner := _find_runner()
	if runner != null:
		emit_sound(runner.global_position)   # grabbing a key is noisy (4.3)
	_broadcast(true)

## Runner touched door `idx` while carrying. Installs the key; the last one wins.
func try_install(idx: int) -> void:
	if not multiplayer.is_server() or winner != "" or not items.carrying:
		return
	var it: Node = _items_root.get_node_or_null("Item%d" % _carried_index)
	if it != null:
		it.set_held.rpc(true)      # consumed: stays hidden
	items.carrying = false
	_carried_index = -1
	var n := items.install(idx)
	var runner := _find_runner()
	if runner != null:
		emit_sound(runner.global_position)
	if n >= ItemSystem.PER_DOOR:
		_set_winner(Roles.WIN_RUNNER)
	else:
		_broadcast(true)

# ---- sound exposure (GDD 4.3) --------------------------------------------

## Called on the server when the Runner does something noisy (slides a tunnel,
## grabs / installs a key, ...). Splits Hunters into "near" (get a vision-clarity
## boost) and "far" (get a minimap ping), then relays to every peer.
func emit_sound(world_pos: Vector2) -> void:
	if not multiplayer.is_server() or winner != "":
		return
	var near_ids: Array = []
	for c in _players.get_children():
		if c.get("role") != Roles.HUNTER or c.dead:
			continue
		if c.global_position.distance_to(world_pos) <= sound_near_radius:
			near_ids.append(c.name.to_int())
	_sound.rpc(world_pos, near_ids)

@rpc("authority", "call_local", "reliable")
func _sound(world_pos: Vector2, near_ids: Array) -> void:
	sound_heard.emit(world_pos, near_ids.has(multiplayer.get_unique_id()))

# ---- mash input (both sides tap "attack") ---------------------------------

@rpc("any_peer", "reliable")
func hunter_press() -> void:
	if not multiplayer.is_server() or winner != "":
		return
	var id := multiplayer.get_remote_sender_id()
	var h: Node2D = _players.get_node_or_null(str(id))
	var runner := _find_runner()
	if h == null or h.dead or runner == null:
		return
	if not _in_range(h, runner):
		return
	if not grapple.active:
		# Start a grapple: only a capturable (carrying / cornered) Runner can be grabbed.
		if grapple.on_cooldown() or not runner.capturable:
			return
		grapple.start()
		_broadcast(true)
	elif grapple.add_capture():
		_on_capture_full()
	else:
		_broadcast(false)

@rpc("any_peer", "call_local", "reliable")
func runner_press() -> void:
	if not multiplayer.is_server() or winner != "":
		return
	if grapple.active:
		if grapple.add_escape():
			_broadcast(true)   # escaped -> grapple ended
		else:
			_broadcast(false)

## Capture bar filled. Not a win (GDD 4.1): scatter the key the Runner was
## carrying to a fresh spot, briefly stun, and reset the mash-off for next time.
func _on_capture_full() -> void:
	var runner := _find_runner()
	if items.carrying and _carried_index >= 0:
		items.carrying = false
		var it: Node = _items_root.get_node_or_null("Item%d" % _carried_index)
		if it != null:
			it.place.rpc(_scatter_spot())
		_carried_index = -1
	grapple.reset()
	if runner != null:
		# Host == Runner, so the recovery stun can be applied directly.
		runner.movement.exit_stun_left = maxf(runner.movement.exit_stun_left, CAPTURE_STUN)
	_broadcast(true)

## A random standable world point clear of the doors and the Runner.
func _scatter_spot() -> Vector2:
	var runner := _find_runner()
	var avoid: Array = []
	if runner != null:
		avoid.append(runner.global_position)
	for d in _doors_root.get_children():
		if d is Node2D:
			avoid.append(d.global_position)
	if _terrain != null:
		var layout := LevelLayout.new(_terrain)
		var spot: Variant = layout.random_floor(avoid, SCATTER_MIN_SEP)
		if spot != null:
			return spot
	return (runner.global_position if runner != null else Vector2.ZERO) + Vector2(0, -8)

# ---- per-frame upkeep -----------------------------------------------------

func _physics_process(delta: float) -> void:
	if winner != "":
		return
	# Match clock: Hunters win if it runs out (GDD 3).
	time_left = maxf(0.0, time_left - delta)
	if time_left <= 0.0:
		_set_winner(Roles.WIN_HUNTERS)
		return
	grapple.tick_cooldown(delta)
	var runner := _find_runner()
	if runner != null and grapple.active:
		grapple.decay(delta)
		if not _any_hunter_in_range(runner):
			grapple.end(false)
		_broadcast(false)
	# Keep the clock (and any drift) in sync a couple times a second.
	_sync_accum += delta
	if _sync_accum >= 0.5:
		_sync_accum = 0.0
		_broadcast(false)

# ---- helpers --------------------------------------------------------------

func _in_range(h: Node2D, runner: Node2D) -> bool:
	return h.global_position.distance_to(runner.global_position) <= capture_range

func _any_hunter_in_range(runner: Node2D) -> bool:
	for c in _players.get_children():
		if c.get("role") == Roles.HUNTER and not c.dead and _in_range(c, runner):
			return true
	return false

func _find_runner() -> Node2D:
	for c in _players.get_children():
		if c.get("role") == Roles.RUNNER:
			return c
	return null

# ---- replication ----------------------------------------------------------

func _set_winner(w: String) -> void:
	winner = w
	grapple.force_end()
	_broadcast(true)
	# The round is over — drop any dev snapshot so the next launch starts fresh.
	if DevSnapshot.enabled():
		DevSnapshot.clear()

# ---- dev resume (server-only match state; see DevSnapshot) -----------------

func snapshot_state() -> Dictionary:
	return {
		"installs": items.installs.duplicate(),
		"carrying": items.carrying,
		"carried_index": _carried_index,
		"time": time_left,
		"winner": winner,
		"cap": grapple.cap,
		"esc": grapple.esc,
		"cap_floor": grapple.cap_floor,
		"active": grapple.active,
	}

func restore_state(d: Dictionary) -> void:
	items.installs = (d.get("installs", {}) as Dictionary).duplicate()
	items.carrying = bool(d.get("carrying", false))
	_carried_index = int(d.get("carried_index", -1))
	time_left = float(d.get("time", MATCH_TIME))
	winner = str(d.get("winner", ""))
	grapple.cap = float(d.get("cap", 0.0))
	grapple.esc = float(d.get("esc", 0.0))
	grapple.cap_floor = float(d.get("cap_floor", 0.0))
	grapple.active = bool(d.get("active", false))
	_broadcast(true)   # push the restored state to every peer's HUD

func _state_dict() -> Dictionary:
	return {
		"installs": items.installs,
		"carrying": items.carrying,
		"time": time_left,
		"cap": grapple.cap,
		"esc": grapple.esc,
		"active": grapple.active,
		"winner": winner,
	}

func _apply_state(d: Dictionary) -> void:
	items.installs = d.get("installs", {})
	items.carrying = bool(d.get("carrying", false))
	time_left = float(d.get("time", MATCH_TIME))
	grapple.cap = float(d.get("cap", 0.0))
	grapple.esc = float(d.get("esc", 0.0))
	grapple.active = bool(d.get("active", false))
	winner = str(d.get("winner", ""))
	state_changed.emit()

func _broadcast(reliable: bool) -> void:
	if reliable:
		_sync_state.rpc(_state_dict())
	else:
		_sync_state_fast.rpc(_state_dict())

@rpc("authority", "call_local", "reliable")
func _sync_state(d: Dictionary) -> void:
	_apply_state(d)

@rpc("authority", "call_local", "unreliable")
func _sync_state_fast(d: Dictionary) -> void:
	if winner != "":
		return
	_apply_state(d)
