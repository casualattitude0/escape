extends Area2D
class_name MediaItem

## A sabotage medium (破壞媒材, GDD 4.1): the one thing the Runner must carry to a
## device before it can break it. Empty-handed the Runner is nearly uncatchable,
## so being FORCED to ferry a medium is the whole point — transport is the moving
## exposure window the Hunters get to intercept.
##
## Like the device, this node owns no state: whether it is available, riding the
## Runner, dropped at a tunnel mouth, or consumed all lives in the GameManager and
## is replicated, so every peer draws the same thing without per-item rpcs. The
## node just renders that state and reports whether the Runner is standing on it
## (server truth via real overlap, not an index off the wire — see device.gd).

const PICKUP_RANGE := 48.0                       # how close the Runner grabs from
const HOLD_OFFSET := Vector2(0.0, -20.0)         # sits above the Runner while carried

const COL_AVAILABLE := Color(0.35, 0.85, 0.55)   # on the ground, ready to grab
const COL_CARRIED := Color(0.95, 0.95, 0.45)     # riding the Runner

@onready var _fill: ColorRect = $Fill

var index := 0

var _gm: Node
var _runner_inside := false
var _runner_ref: Node2D

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	_gm = get_tree().get_first_node_in_group("game_manager")

## Render position + colour from the replicated carry state. Runs on every peer,
## so a carried medium visibly rides the Runner everywhere (the Runner body and
## carried_index are both replicated); a dropped one sits where it landed.
func _process(_delta: float) -> void:
	if _gm == null:
		return
	if _gm.media_consumed(index):
		visible = false
		return
	visible = true
	if _gm.media_carried_index() == index:
		var r := _runner()
		if r != null:
			global_position = r.global_position + HOLD_OFFSET
		_fill.color = COL_CARRIED
	else:
		global_position = _gm.media_pos(index)
		_fill.color = COL_AVAILABLE

## True when the Runner is standing on this medium AND it can actually be taken
## (not already carried, not consumed). The overlap is real physics, so a client
## cannot claim to grab one from across the map.
func runner_in_range() -> bool:
	return _runner_inside and _gm != null and _gm.media_available(index)

func _on_body_entered(body: Node) -> void:
	if body.get("role") == Roles.RUNNER:
		_runner_inside = true

func _on_body_exited(body: Node) -> void:
	if body.get("role") == Roles.RUNNER:
		_runner_inside = false

func _runner() -> Node2D:
	if _runner_ref != null and is_instance_valid(_runner_ref):
		return _runner_ref
	if _gm == null:
		return null
	for c in _gm.players().get_children():
		if c.get("role") == Roles.RUNNER:
			_runner_ref = c
			return c
	return null
