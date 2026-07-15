extends Area2D

## The way out (GDD 3). One per map, and it stays shut until every device is
## broken — so it is not a race to a door, it is the reward for finishing the
## sabotage. Touching it while it is open wins the match for the Runner.
##
## It shows amber the moment the first device falls rather than only turning green
## at the end: the Hunters should be able to see the round slipping away, and the
## Runner should be able to find its exit before it needs it.

const COL_LOCKED := Color(0.85, 0.3, 0.3, 0.6)
const COL_PARTIAL := Color(0.85, 0.7, 0.3, 0.7)
const COL_OPEN := Color(0.3, 0.85, 0.4, 0.85)

@onready var _fill: ColorRect = $Fill

var index := 0

var _gm: Node

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	_gm = get_tree().get_first_node_in_group("game_manager")
	if _gm != null:
		_gm.state_changed.connect(_refresh)
	_refresh()

func _refresh() -> void:
	if _gm == null:
		_fill.color = COL_LOCKED
		return
	if _gm.escape_open():
		_fill.color = COL_OPEN
	elif _gm.devices_destroyed() > 0:
		_fill.color = COL_PARTIAL
	else:
		_fill.color = COL_LOCKED

func _on_body_entered(body: Node) -> void:
	if not multiplayer.is_server():
		return
	if body.get("role") != Roles.RUNNER:
		return
	if _gm != null:
		_gm.try_escape()

## Is the Runner standing in here right now? Needed because the escape can open
## while the Runner is ALREADY inside — it finishes the last device next to the
## exit, or just camps here — and body_entered will never fire again to notice.
func runner_inside() -> bool:
	for b in get_overlapping_bodies():
		if b.get("role") == Roles.RUNNER:
			return true
	return false
