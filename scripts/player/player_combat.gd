extends Node
class_name PlayerCombat

## Attack + capture-grapple participation, and routing the shared "attack" key to
## the GameManager. The mash-off state itself lives on the server (GrappleSystem);
## this component decides whether this player is a participant, snaps a grabbing
## Hunter onto the Runner, and forwards taps.

const GRAB_DISTANCE := 22.0       # half-gap each fighter closes to so bodies read as locked
const GRAB_SNAP := 260.0          # how fast a fighter slides into grab distance
const GRAB_COMMIT := 0.16         # brief lunge hold on a connecting grab (covers replication lag)
const WHIFF_STIFF := 0.55         # recovery lockout after a Hunter's grab hits nothing

# Pounce: hold F to charge a leap toward the Hunter's facing, then release. A quick
# tap (below POUNCE_MIN_CHARGE) stays the point-blank grab; longer holds leap farther.
const POUNCE_MIN_CHARGE := 0.12   # hold shorter than this -> a plain tap grab, no leap
const POUNCE_MAX_CHARGE := 0.5    # charge saturates here
const POUNCE_VX_MIN := 240.0      # launch speed at min charge
const POUNCE_VX_MAX := 430.0      # launch speed at full charge
const POUNCE_VY := -360.0         # upward kick of the leap arc
const POUNCE_LAND_STIFF := 0.5    # recovery lockout after a pounce lands on nothing

@onready var body: CharacterBody2D = get_parent()

var grappling: bool = false       # locked in an active grapple this frame
var pouncing: bool = false        # Hunter: airborne mid-pounce, driven by pounce_step()
var _opponent: Node2D             # the other fighter to snap onto / face this frame
var _runner_ref: Node
var _stiff_left: float = 0.0      # Hunter: committed to the grab lunge / whiff recovery, immobile
var _charge: float = 0.0          # Hunter: how long F has been held this press

## True while a Hunter is locked in a grab lunge or its miss recovery.
func stiff_active() -> bool:
	return _stiff_left > 0.0

func tick_stiff(delta: float) -> void:
	if _stiff_left > 0.0:
		_stiff_left -= delta

## Decide grapple participation for this frame. Runner: participating whenever a
## grapple is active. Hunter: participating while a grapple is active and it is in
## range of the Runner. Returns whether this player is locked in the grapple.
func update_grapple() -> bool:
	grappling = false
	_opponent = null
	var gm: Node = body.gm
	if gm == null or not gm.grappling():
		return false
	if body.role == Roles.RUNNER:
		_opponent = _find_hunter(gm)
		grappling = true
		return true
	if body.dead:
		return false
	var r := _find_runner(gm)
	if r != null and body.global_position.distance_to(r.global_position) <= gm.capture_range:
		_opponent = r
		grappling = true
	return grappling

## After movement, slide this fighter toward its opponent so the two bodies meet
## in the middle and read as locked together (both Hunter and Runner close in).
func apply_snap(delta: float) -> void:
	if not grappling or _opponent == null:
		return
	var dx: float = _opponent.global_position.x - body.global_position.x
	var s := signf(dx)
	if s == 0.0:
		s = 1.0
	body.global_position.x = move_toward(
		body.global_position.x, _opponent.global_position.x - s * GRAB_DISTANCE, GRAB_SNAP * delta)

func handle_input(delta: float) -> void:
	var gm: Node = body.gm
	if gm == null:
		return
	if body.role == Roles.HUNTER:
		_hunter_input(gm, delta)
	elif Input.is_action_just_pressed("attack") and gm.grappling():
		gm.runner_press.rpc_id(1)         # escape tap
		body.animator.pulse()             # instant local strain feedback on the tap

## Hunter F handling. Locked on -> mash taps. Otherwise F charges while held: a
## quick tap is the point-blank grab, a longer hold launches a pounce leap toward
## the Hunter's facing on release.
func _hunter_input(gm: Node, delta: float) -> void:
	if body.dead:
		_charge = 0.0
		return
	if grappling:
		_charge = 0.0
		if Input.is_action_just_pressed("attack"):
			gm.hunter_press.rpc_id(1)     # already locked on: this is a mash tap
			body.animator.pulse()
		return
	if _stiff_left > 0.0:
		_charge = 0.0
		return
	if Input.is_action_pressed("attack"):
		_charge += delta
	if Input.is_action_just_released("attack"):
		if _charge >= POUNCE_MIN_CHARGE and body.is_on_floor():
			_start_pounce(gm)
		else:
			_attempt_grab(gm)             # quick tap = point-blank grab
		_charge = 0.0

## Hunter lunges for a point-blank grab: play the reach immediately, ask the server
## to start the grapple, and lock into a recovery. A connecting grab holds only
## briefly (the grapple takes over); a whiff eats a longer stiff so misses are punished.
func _attempt_grab(gm: Node) -> void:
	body.animator.lunge()
	gm.hunter_press.rpc_id(1)
	_stiff_left = GRAB_COMMIT if _grab_would_hit(gm) else WHIFF_STIFF

## Launch the charged pounce: a facing-ward leap whose speed scales with charge.
func _start_pounce(gm: Node) -> void:
	var power := clampf((_charge - POUNCE_MIN_CHARGE) / (POUNCE_MAX_CHARGE - POUNCE_MIN_CHARGE), 0.0, 1.0)
	var facing := -1.0 if body.sprite.flip_h else 1.0
	body.velocity = Vector2(facing * lerpf(POUNCE_VX_MIN, POUNCE_VX_MAX, power), POUNCE_VY)
	pouncing = true
	body.animator.lunge()                 # arms out, reaching through the arc

## Airborne pounce physics (replaces normal movement while pouncing): fall under
## gravity, and either snag a catchable Runner on contact (starts the grab) or eat
## a landing stiff when the leap comes down on nothing.
func pounce_step(delta: float) -> void:
	body.velocity.y += body.get_gravity().y * delta
	body.move_and_slide()
	if _grab_would_hit(body.gm):
		body.gm.hunter_press.rpc_id(1)    # pounced onto the Runner: server starts the grab
		pouncing = false
		return
	if body.is_on_floor() and body.velocity.y >= 0.0:
		pouncing = false
		_stiff_left = POUNCE_LAND_STIFF   # came down on nothing: recovery window

## Client-side prediction of the server's grab test (range + a capturable Runner),
## used only to decide whether this lunge whiffs and eats the stiff.
func _grab_would_hit(gm: Node) -> bool:
	var r := _find_runner(gm)
	return r != null and r.capturable \
		and body.global_position.distance_to(r.global_position) <= gm.capture_range

func _find_runner(gm: Node) -> Node2D:
	if _runner_ref != null and is_instance_valid(_runner_ref):
		return _runner_ref
	for c in gm.players().get_children():
		if c.get("role") == Roles.RUNNER:
			_runner_ref = c
			return c
	return null

## Nearest living Hunter, for the Runner to lean into during a grapple.
func _find_hunter(gm: Node) -> Node2D:
	var best: Node2D = null
	var best_d := INF
	for c in gm.players().get_children():
		if c.get("role") != Roles.HUNTER or c.get("dead"):
			continue
		var d: float = body.global_position.distance_to(c.global_position)
		if d < best_d:
			best_d = d
			best = c
	return best
