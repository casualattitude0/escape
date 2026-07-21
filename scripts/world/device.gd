extends Area2D

## A facility device the Runner has to break (GDD 4.1).
##
## Unlike the key it replaces, this is not a one-shot pickup — the Runner parks
## next to it and mashes. So the node's job is just to know whether the Runner is
## standing in it; the GameManager asks, rather than the device calling in. That
## keeps the "which device is being mashed" decision on the server, where it can
## be checked, instead of trusting whatever index a client sends.
##
## The device body itself is drawn by the Device_tiles tilemap layer, not here —
## this node renders nothing but a health bar and only reports Runner overlap.

# Health bar: shows REMAINING integrity so both sides can judge how close a
# device is to breaking (GDD 4.1). Full green when intact, empties to red as the
# Runner mashes it down. HP_W is the fill's full pixel width (offsets in the scene).
const HP_W := 44.0
const COL_HP_FULL := Color(0.3, 0.85, 0.4)
const COL_HP_LOW := Color(0.9, 0.25, 0.2)

@onready var _hp_bg: ColorRect = $HpBg
@onready var _hp_fill: ColorRect = $HpFill

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
	# Health bar tracks remaining integrity; hidden once the device is scrap (the
	# tilemap keeps drawing the body — the vanished bar is the "broken" tell).
	var remaining: float = clampf(1.0 - r, 0.0, 1.0)
	var alive: bool = r < 1.0
	_hp_bg.visible = alive
	_hp_fill.visible = alive
	if alive:
		_hp_fill.offset_right = _hp_fill.offset_left + HP_W * remaining
		_hp_fill.color = COL_HP_LOW.lerp(COL_HP_FULL, remaining)
