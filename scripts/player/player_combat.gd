extends Node
class_name PlayerCombat

## Attack + capture-grapple participation, and routing the shared "attack" key to
## the GameManager. The mash-off state itself lives on the server (GrappleSystem);
## this component decides whether this player is a participant, snaps a grabbing
## Hunter onto the Runner, and forwards taps.

const ATTACK_ANIM_TIME := 0.38    # how long the attack animation plays
const GRAB_DISTANCE := 34.0       # gap the Hunter closes to so the grab connects
const GRAB_SNAP := 260.0          # how fast the Hunter slides into grab distance

@onready var body: CharacterBody2D = get_parent()

var attack_left: float = 0.0      # attack animation countdown
var grappling: bool = false       # locked in an active grapple this frame
var _grab_runner: Node2D
var _runner_ref: Node

func tick_timers(delta: float) -> void:
	if attack_left > 0.0:
		attack_left -= delta

func attacking() -> bool:
	return attack_left > 0.0

## Decide grapple participation for this frame. Runner: participating whenever a
## grapple is active. Hunter: participating while a grapple is active and it is in
## range of the Runner. Returns whether this player is locked in the grapple.
func update_grapple() -> bool:
	grappling = false
	_grab_runner = null
	var gm: Node = body.gm
	if gm == null or not gm.grappling():
		return false
	if body.role == Roles.RUNNER:
		grappling = true
		return true
	if body.dead:
		return false
	var r := _find_runner(gm)
	if r != null and body.global_position.distance_to(r.global_position) <= gm.capture_range:
		_grab_runner = r
		grappling = true
	return grappling

## After movement, slide the grabbing Hunter onto the Runner and face it so the
## grab visually connects.
func apply_snap(delta: float) -> void:
	if not grappling or body.role != Roles.HUNTER or _grab_runner == null:
		return
	var dx: float = _grab_runner.global_position.x - body.global_position.x
	var s := signf(dx)
	if s == 0.0:
		s = 1.0
	body.global_position.x = move_toward(
		body.global_position.x, _grab_runner.global_position.x - s * GRAB_DISTANCE, GRAB_SNAP * delta)
	body.sprite.flip_h = dx < 0.0

func handle_input() -> void:
	var gm: Node = body.gm
	if gm == null or not Input.is_action_just_pressed("attack"):
		return
	if body.role == Roles.HUNTER:
		if not body.dead:
			gm.hunter_press.rpc_id(1)     # server: start a grab, or add a capture tap
	else:
		if gm.grappling():
			gm.runner_press.rpc_id(1)     # escape tap
		elif not body.movement.in_tunnel and not body.movement.exit_stun_active():
			attack_left = ATTACK_ANIM_TIME
			gm.runner_press.rpc_id(1)     # melee attack (kills nearby Hunters)

func _find_runner(gm: Node) -> Node2D:
	if _runner_ref != null and is_instance_valid(_runner_ref):
		return _runner_ref
	for c in gm.players().get_children():
		if c.get("role") == Roles.RUNNER:
			_runner_ref = c
			return c
	return null
