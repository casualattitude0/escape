extends Area2D

## A key object (x / y / z). The Runner picks it up on contact. Detection is
## resolved on the server; the pickup is then hidden on every peer.

var _collected := false

func _ready() -> void:
	body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node) -> void:
	if not multiplayer.is_server() or _collected:
		return
	if body.get("role") != "runner":
		return
	_collected = true
	var gm := get_tree().get_first_node_in_group("game_manager")
	if gm != null:
		gm.collect_item()
	_hide.rpc()

@rpc("authority", "call_local", "reliable")
func _hide() -> void:
	_collected = true
	visible = false
	monitoring = false
