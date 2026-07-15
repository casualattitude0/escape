extends Node
class_name PlayerHealth

## Hunter death + respawn, and the Runner's knock-stun. The `dead` / `stunned`
## flags live on the body (they are replicated); this component owns their timers.
##
## Hunters die and respawn forever; the Runner cannot die at all (GDD 4.6) — the
## worst that happens to it is a stun, which costs it time, not the match.

const RESPAWN_TIME := 3.0

@onready var body: CharacterBody2D = get_parent()

var _dead_left: float = 0.0
var _stun_left: float = 0.0

func tick(delta: float) -> void:
	if body.stunned:
		_stun_left -= delta
		if _stun_left <= 0.0:
			body.stunned = false
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

## Called by the server (via the body's stun() rpc) on the Runner's own peer when
## a third knock lands. Re-stunning extends rather than shortens the window.
func stun(duration: float) -> void:
	body.stunned = true
	_stun_left = maxf(_stun_left, duration)
