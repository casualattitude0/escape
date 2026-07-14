extends Control

## On-screen guidance for the Runner (GDD 4.1): one chevron per escape door,
## ringing the screen centre and pointing toward that door. A door's arrow hides
## as soon as the door itself is visible on screen, so arrows only ever point at
## exits you can't currently see. Hidden for Hunters and once the match ends.
##
## Arrow colour tracks the door's progress: amber once it has keys in it, red
## while still empty. Fully-completed doors get no arrow (completing one wins).

const RADIUS := 120.0
const HIDE_MARGIN := 28.0                    # hide the arrow once the door is this far inside the edge
const COL_EMPTY := Color(0.9, 0.42, 0.42, 0.9)
const COL_PARTIAL := Color(0.96, 0.83, 0.32, 0.95)

var _gm: Node
var _players: Node
var _doors: Node
var _me := ""
var _is_runner := false

func _ready() -> void:
	_me = str(multiplayer.get_unique_id())
	_is_runner = Net.players.get(multiplayer.get_unique_id(), Roles.HUNTER) == Roles.RUNNER
	_gm = get_tree().get_first_node_in_group("game_manager")
	if _gm != null:
		_players = _gm.players()
		_doors = _gm.doors()
	visible = _is_runner

func _process(_delta: float) -> void:
	if _is_runner:
		queue_redraw()

func _draw() -> void:
	if not _is_runner or _gm == null or _doors == null or _gm.winner != "":
		return
	var xform := get_viewport().get_canvas_transform()   # world -> screen
	var on_screen := Rect2(Vector2.ZERO, size).grow(-HIDE_MARGIN)
	var center := size * 0.5
	var per: int = _gm.per_door()
	for d in _doors.get_children():
		if not (d is Node2D):
			continue
		var node2d := d as Node2D
		var installed: int = _gm.door_installs(d.index)
		if installed >= per:
			continue   # completed door -> no arrow
		var screen_pos := xform * node2d.global_position
		if on_screen.has_point(screen_pos):
			continue   # door itself is visible -> hide its arrow
		var dir := screen_pos - center
		if dir.length() < 1.0:
			continue
		_draw_arrow(center + dir.normalized() * RADIUS, dir.normalized(),
				COL_PARTIAL if installed > 0 else COL_EMPTY)

func _draw_arrow(tip: Vector2, dir: Vector2, col: Color) -> void:
	var perp := Vector2(-dir.y, dir.x)
	draw_colored_polygon(PackedVector2Array([
		tip + dir * 16.0,
		tip - dir * 10.0 + perp * 11.0,
		tip - dir * 10.0 - perp * 11.0,
	]), col)
