extends Area2D

## A facility device the Runner has to break (GDD 4.1).
##
## Unlike the key it replaces, this is not a one-shot pickup — the Runner parks
## next to it and mashes. So the node's job is just to know whether the Runner is
## standing in it; the GameManager asks, rather than the device calling in. That
## keeps the "which device is being mashed" decision on the server, where it can
## be checked, instead of trusting whatever index a client sends.
##
## Colour comes from the replicated sabotage progress, so every peer sees the same
## damage without the server having to push per-device rpcs.

const COL_INTACT := Color(0.95, 0.3, 0.25)     # unbroken: reads as "break me"
const COL_DAMAGED := Color(0.95, 0.7, 0.2)     # part-way through
const COL_BROKEN := Color(0.25, 0.28, 0.32)    # done: inert scrap

@onready var _fill: ColorRect = $Fill

var index := 0

var _gm: Node
var _runner_inside := false

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	_gm = get_tree().get_first_node_in_group("game_manager")
	if _gm != null:
		_gm.state_changed.connect(_refresh)
	_refresh()

## True when the Runner is standing close enough to work on this device. Server
## truth: the overlap comes from real physics, not from an index a client claimed.
func runner_in_range() -> bool:
	return _runner_inside and not _destroyed()

func _on_body_entered(body: Node) -> void:
	if body.get("role") == Roles.RUNNER:
		_runner_inside = true

func _on_body_exited(body: Node) -> void:
	if body.get("role") == Roles.RUNNER:
		_runner_inside = false

func _destroyed() -> bool:
	return _gm != null and _gm.device_done(index)

func _refresh() -> void:
	var r: float = _gm.device_ratio(index) if _gm != null else 0.0
	if r >= 1.0:
		_fill.color = COL_BROKEN
	elif r > 0.0:
		_fill.color = COL_INTACT.lerp(COL_DAMAGED, r)
	else:
		_fill.color = COL_INTACT
	# A broken device stays put as scrap rather than vanishing: it is a landmark,
	# and both sides should be able to read the score from across the room.
	modulate.a = 0.55 if r >= 1.0 else 1.0
