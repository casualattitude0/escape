extends Area2D

## The escape door. It only lets the Runner out once all key objects are
## collected; until then it stays "locked" (red). Colour is driven by the
## replicated game state so every peer sees the same thing.

@onready var _fill: ColorRect = $Fill

var _gm: Node

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	_gm = get_tree().get_first_node_in_group("game_manager")
	if _gm != null:
		_gm.state_changed.connect(_refresh)
	_refresh()

func _refresh() -> void:
	var open: bool = _gm != null and _gm.items_collected() >= _gm.items_total()
	_fill.color = Color(0.3, 0.85, 0.4, 0.85) if open else Color(0.85, 0.3, 0.3, 0.6)

func _on_body_entered(body: Node) -> void:
	_try(body)

func _on_body_exited(_body: Node) -> void:
	pass

func _try(body: Node) -> void:
	if not multiplayer.is_server():
		return
	if body.get("role") != Roles.RUNNER:
		return
	if _gm != null:
		_gm.try_escape()
