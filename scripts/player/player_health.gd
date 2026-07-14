extends Node
class_name PlayerHealth

## Hunter death + respawn and the post-escape faint. The `dead` / `fainted` flags
## live on the body (they are replicated); this component owns their timers.

const RESPAWN_TIME := 3.0

@onready var body: CharacterBody2D = get_parent()

var _dead_left: float = 0.0
var _faint_left: float = 0.0

func tick(delta: float) -> void:
	if body.fainted:
		_faint_left -= delta
		if _faint_left <= 0.0:
			body.fainted = false
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

## Called by the server (via the body's faint() rpc) on a grabbing Hunter's own
## peer when the Runner wrenches free. Dead Hunters ignore it.
func faint(duration: float) -> void:
	if body.dead:
		return
	body.fainted = true
	_faint_left = duration
