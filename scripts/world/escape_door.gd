extends Area2D

## An escape door (GDD 4.1). Each door has PER_DOOR key slots ("marks"). The
## Runner installs a carried key by touching the door; installing the last key
## opens it and the Runner wins. There are 3 doors — completing ANY one wins, so
## keys must be funnelled into the same door. Colour and marks are driven by the
## replicated game state so every peer sees the same progress.

const MARK_ON := Color(0.35, 0.9, 0.45)     # installed slot
const MARK_OFF := Color(0.15, 0.16, 0.2)    # empty slot
const DOOR_LOCKED := Color(0.85, 0.3, 0.3, 0.6)
const DOOR_PARTIAL := Color(0.85, 0.7, 0.3, 0.7)
const DOOR_OPEN := Color(0.3, 0.85, 0.4, 0.85)

@onready var _fill: ColorRect = $Fill

var index := 0
var _gm: Node
var _marks: Array = []

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	_gm = get_tree().get_first_node_in_group("game_manager")
	if _gm != null:
		_gm.state_changed.connect(_refresh)
	_build_marks()
	_refresh()

## One small square per key slot, stacked down the door face.
func _build_marks() -> void:
	var total := _per_door()
	for i in total:
		var m := ColorRect.new()
		m.size = Vector2(12, 12)
		var spacing := 20.0
		var y := -spacing * (total - 1) * 0.5 + spacing * i
		m.position = Vector2(-6, y - 6)
		add_child(m)
		_marks.append(m)

func _per_door() -> int:
	return _gm.per_door() if _gm != null else ItemSystem.PER_DOOR

func _refresh() -> void:
	var installed: int = _gm.door_installs(index) if _gm != null else 0
	var total := _per_door()
	for i in _marks.size():
		_marks[i].color = MARK_ON if i < installed else MARK_OFF
	if installed >= total:
		_fill.color = DOOR_OPEN
	elif installed > 0:
		_fill.color = DOOR_PARTIAL
	else:
		_fill.color = DOOR_LOCKED

func _on_body_entered(body: Node) -> void:
	if not multiplayer.is_server():
		return
	if body.get("role") != Roles.RUNNER:
		return
	if _gm != null:
		_gm.try_install(index)
