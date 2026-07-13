extends Node

## Server-authoritative match coordinator and the rpc facade the rest of the
## game talks to. Runs its logic only on the host (peer 1). It owns the winner
## and the replication, and delegates the details to its child systems:
##   * $ItemSystem   — key-object collection
##   * $GrappleSystem — the capture mash-off
## Players, items and the door reach this node via the "game_manager" group and
## call its facade methods / rpcs; they never touch the subsystems directly.

signal state_changed
# Fired on every peer when the Runner makes a noise (GDD 4.3). `heard_near` is
# true for the LOCAL player when it is a Hunter close enough to the noise to get
# a vision-clarity boost; false means the noise instead surfaces as a minimap
# ping. The Runner peer ignores it (no Hunter UI).
signal sound_heard(world_pos: Vector2, heard_near: bool)

var capture_range := 110.0       # how close a Hunter must be to grab / mash
var sound_near_radius := 540.0   # Hunters within this of a noise see clearly;
                                 # farther ones only get a minimap ping

var winner := ""                 # "", Roles.WIN_RUNNER, Roles.WIN_HUNTERS

@onready var items: ItemSystem = $ItemSystem
@onready var grapple: GrappleSystem = $GrappleSystem
@onready var _players: Node = get_node("../Players")

func _ready() -> void:
	add_to_group("game_manager")
	set_physics_process(multiplayer.is_server())

# ---- read facade (HUD / players) ------------------------------------------

func grappling() -> bool:
	return grapple.active

func players() -> Node:
	return _players

func items_collected() -> int:
	return items.collected

func items_total() -> int:
	return items.total

func capture_ratio() -> float:
	return grapple.cap

func escape_ratio() -> float:
	return grapple.esc

# ---- items / escape (called on the server by Item / EscapeDoor) -----------

func collect_item() -> void:
	if not multiplayer.is_server():
		return
	items.collect()
	_broadcast(true)

func try_escape() -> void:
	if not multiplayer.is_server() or winner != "":
		return
	if items.all_collected():
		_set_winner(Roles.WIN_RUNNER)

# ---- sound exposure (GDD 4.3) --------------------------------------------

## Called on the server when the Runner does something noisy (slides a tunnel,
## grabs an item, ...). Splits Hunters into "near" (get a vision-clarity boost)
## and "far" (get a minimap ping), then relays to every peer.
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
		# Start a grapple: only a capturable (slowed / cornered) Runner can be grabbed.
		if grapple.on_cooldown() or not runner.capturable:
			return
		grapple.start()
		_broadcast(true)
	elif grapple.add_capture():
		_set_winner(Roles.WIN_HUNTERS)
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

# ---- per-frame upkeep -----------------------------------------------------

func _physics_process(delta: float) -> void:
	if winner != "":
		return
	grapple.tick_cooldown(delta)
	var runner := _find_runner()
	if runner == null:
		return
	if grapple.active:
		grapple.decay(delta)
		if not _any_hunter_in_range(runner):
			grapple.end(false)
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

func _broadcast(reliable: bool) -> void:
	if reliable:
		_sync_state.rpc(items.collected, grapple.cap, grapple.esc, grapple.active, winner)
	else:
		_sync_state_fast.rpc(items.collected, grapple.cap, grapple.esc, grapple.active)

@rpc("authority", "call_local", "reliable")
func _sync_state(item_count: int, c: float, e: float, g: bool, w: String) -> void:
	items.collected = item_count
	grapple.cap = c
	grapple.esc = e
	grapple.active = g
	winner = w
	state_changed.emit()

@rpc("authority", "call_local", "unreliable")
func _sync_state_fast(item_count: int, c: float, e: float, g: bool) -> void:
	if winner != "":
		return
	items.collected = item_count
	grapple.cap = c
	grapple.esc = e
	grapple.active = g
	state_changed.emit()
