extends Node2D

## Draws the Runner's break-time force field (GDD 4.1) on every peer: a bubble that
## appears while the shield is up and shifts from blue to red as Hunters knock it
## down. Purely cosmetic — the shield state is server-authoritative on the
## GameManager and replicated (shield_up / shield_ratio). Added in code by player.gd
## so no scene wiring is needed; it self-gates to the Runner (only it has a shield).

const RADIUS := 30.0
const COL_STRONG := Color(0.4, 0.8, 1.0, 0.45)   # full shield
const COL_WEAK := Color(1.0, 0.45, 0.35, 0.45)   # nearly broken

var _body: Node
var _gm: Node

func _ready() -> void:
	_body = get_parent()
	_gm = get_tree().get_first_node_in_group("game_manager")
	z_index = 30           # over the character; the device HP bar (z 20/21) still reads
	z_as_relative = false

func _process(_delta: float) -> void:
	var showing: bool = _gm != null and _body != null \
		and _body.get("role") == Roles.RUNNER and _gm.shield_up()
	if showing != visible:
		visible = showing
	if showing:
		queue_redraw()

func _draw() -> void:
	if _gm == null:
		return
	var col := COL_WEAK.lerp(COL_STRONG, _gm.shield_ratio())
	draw_circle(Vector2.ZERO, RADIUS, col)
	draw_arc(Vector2.ZERO, RADIUS, 0.0, TAU, 40, Color(col.r, col.g, col.b, 0.95), 2.5)
