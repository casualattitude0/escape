extends Area2D

## A key. The Runner picks it up on contact (only one at a time — the pickup is
## gated by the GameManager). While carried, or once installed into a door, the
## key is hidden and non-interactive. Getting captured while carrying scatters
## the key: the server relocates this node and shows it again (see `place`).
##
## Detection is server-side; the resulting visual state is replicated to every
## peer via the rpcs below so pickups / scatters resolve identically.

var index := 0
var _held := false     # carried or installed -> hidden, not pickable

func _ready() -> void:
	body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node) -> void:
	if not multiplayer.is_server() or _held:
		return
	if body.get("role") != Roles.RUNNER:
		return
	var gm := get_tree().get_first_node_in_group("game_manager")
	if gm != null:
		gm.try_pickup(index)

## Carried or installed: hide and stop detecting. Authority (server) drives it so
## every peer's world (and the Runner's minimap) matches.
@rpc("authority", "call_local", "reliable")
func set_held(held: bool) -> void:
	_held = held
	visible = not held
	monitoring = not held

## Drop the key back into the world at `pos` (scatter after a capture).
@rpc("authority", "call_local", "reliable")
func place(pos: Vector2) -> void:
	position = pos
	_held = false
	visible = true
	monitoring = true
