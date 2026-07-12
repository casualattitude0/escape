extends Node
class_name PlayerHealth

## Hunter death + respawn. The `dead` flag lives on the body (it is replicated);
## this component just owns the respawn timer.

const RESPAWN_TIME := 3.0

@onready var body: CharacterBody2D = get_parent()

var _dead_left: float = 0.0

func tick(delta: float) -> void:
	if not body.dead:
		return
	_dead_left -= delta
	if _dead_left <= 0.0:
		body.dead = false
		body.global_position = body.spawn_point

## Called by the server (via the body's kill() rpc) on the hit Hunter's own peer.
func kill() -> void:
	if body.dead:
		return
	body.dead = true
	_dead_left = RESPAWN_TIME
