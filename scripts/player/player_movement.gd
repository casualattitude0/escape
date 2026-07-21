extends Node
class_name PlayerMovement

## Platformer locomotion for the player body: run/jump, crouch, and the
## Metroid-style tunnel slide with its exit stiffness (出管硬直). Owns the body's
## velocity and collision-shape swap; the orchestrator (player.gd) calls
## update_tunnel() then tick() each physics frame.

@export var speed: float = 220.0
@export var crawl_speed: float = 110.0
@export var slide_speed: float = 330.0
@export var jump_velocity: float = -470.0
@export var acceleration: float = 1800.0
@export var friction: float = 2000.0
@export var slide_friction: float = 650.0

## -- Jump-feel primitives (§階段1) -----------------------------------------
## All purely feel: they change *when/how* an unchanged jump_velocity fires
## and how gravity is shaped, never the ground top speed or capture rules.
@export var coyote_time: float = 0.10       # grace period to jump after leaving a ledge
@export var jump_buffer_time: float = 0.10  # early jump press remembered into the landing
@export var jump_cut_mult: float = 0.45     # release jump early -> cut upward velocity (short hop)
@export var apex_velocity_threshold: float = 40.0  # |velocity.y| below this counts as "at apex"
@export var apex_gravity_mult: float = 0.55        # lighter gravity near the apex (hang time)
@export var apex_air_accel_bonus: float = 1.35      # extra air control while hanging at the apex
@export var fall_gravity_mult: float = 1.5   # heavier gravity once falling (snappier arcs)
@export var air_acceleration: float = 1400.0 # air steering, below ground acceleration by design
@export var air_turn_accel_mult: float = 1.6 # extra kick when reversing direction mid-air

const TUNNEL_EXIT_STUN := 0.5     # frozen recovery after leaving a tunnel

var crouched: bool = false
var sliding: bool = false
var in_tunnel: bool = false
var exit_stun_left: float = 0.0
var last_dir: float = 0.0         # read by the animator for facing

var _coyote_left: float = 0.0        # time remaining where a jump is still allowed after leaving the floor
var _jump_buffer_left: float = 0.0   # time remaining where a queued jump press still counts
var just_jumped: bool = false        # one tick pulse: this tick's tick() launched a jump (for FX)
var just_landed: bool = false        # one tick pulse: this tick's tick() touched down (for FX)
var _was_on_floor: bool = true

@onready var body: CharacterBody2D = get_parent()
@onready var stand_shape: CollisionShape2D = body.get_node("StandCollision")
@onready var slide_shape: CollisionShape2D = body.get_node("SlideCollision")
@onready var head_check: RayCast2D = body.get_node("HeadCheck")

func exit_stun_active() -> bool:
	return exit_stun_left > 0.0

func freeze() -> void:
	body.velocity = Vector2.ZERO

## Track tunnel travel and fire the exit stiffness when we pop out. Called before
## tick() so the orchestrator can factor exit-stun into the movement lock.
func update_tunnel(delta: float) -> void:
	var head_blocked := head_check.is_colliding()
	var was_in_tunnel := in_tunnel
	in_tunnel = crouched and head_blocked
	# Both diving into and popping out of a tunnel are noisy (GDD 4.3).
	if was_in_tunnel != in_tunnel and body.role == Roles.RUNNER and body.gm != null:
		body.gm.emit_sound(body.global_position)
	if was_in_tunnel and not in_tunnel:
		exit_stun_left = TUNNEL_EXIT_STUN
	if exit_stun_left > 0.0:
		exit_stun_left -= delta

func tick(delta: float, can_control: bool) -> void:
	just_jumped = false
	just_landed = false

	var on_floor := body.is_on_floor()
	# Coyote time: refill the grace window on the ground, drain it in the air —
	# this lets a jump land a beat after walking off a ledge.
	if on_floor:
		_coyote_left = coyote_time
	else:
		_coyote_left = maxf(_coyote_left - delta, 0.0)
		_apply_gravity(delta)

	var head_blocked := head_check.is_colliding()

	var dir := 0.0
	var slide_held := false
	var jump_pressed := false
	if can_control:
		dir = Input.get_axis("move_left", "move_right")
		# Only the Runner can slide / crawl through tunnels.
		slide_held = body.role == Roles.RUNNER and Input.is_action_pressed("slide")
		jump_pressed = Input.is_action_just_pressed("jump")
		# Variable jump height: releasing early clips the rise short (short hop).
		if Input.is_action_just_released("jump") and body.velocity.y < 0.0:
			body.velocity.y *= jump_cut_mult

	# Jump buffer: remember an early press so it fires the instant we can jump.
	_jump_buffer_left = jump_buffer_time if jump_pressed else maxf(_jump_buffer_left - delta, 0.0)

	var want_low := (slide_held and on_floor) or (crouched and head_blocked)
	if want_low and not crouched:
		_enter_crouch()
		var s := signf(body.velocity.x)
		if s == 0.0:
			s = dir
		if s != 0.0:
			body.velocity.x = s * slide_speed
			sliding = true
	elif not want_low and crouched:
		_exit_crouch()

	var can_jump := (on_floor or _coyote_left > 0.0) and not head_blocked
	if can_control and can_jump and _jump_buffer_left > 0.0:
		body.velocity.y = jump_velocity
		_coyote_left = 0.0
		_jump_buffer_left = 0.0
		just_jumped = true
		if crouched:
			_exit_crouch()

	_apply_horizontal(dir, delta, not can_control, on_floor)
	body.move_and_slide()
	last_dir = dir

	if body.is_on_floor() and not _was_on_floor:
		just_landed = true
	_was_on_floor = body.is_on_floor()

## Gravity with an apex "hang" softening and an extra-heavy fall for snappier
## arcs (Celeste-style: floaty at the top, decisive on the way down).
func _apply_gravity(delta: float) -> void:
	var g: float = body.get_gravity().y
	var mult := 1.0
	if absf(body.velocity.y) < apex_velocity_threshold:
		mult = apex_gravity_mult
	elif body.velocity.y > 0.0:
		mult = fall_gravity_mult
	body.velocity.y += g * mult * delta

## The animation the body's motion implies (combat/capture states override this
## in the animator). Ground tiers are purely visual — they never change `speed`
## or the capture-relevant velocity.x semantics, just which sprite plays.
func locomotion_anim() -> String:
	if not body.is_on_floor():
		if body.velocity.y < -apex_velocity_threshold:
			return Anim.JUMP
		if body.velocity.y > apex_velocity_threshold:
			return Anim.FALL
		return Anim.JUMP_APEX
	if crouched:
		if sliding or absf(body.velocity.x) > crawl_speed * 0.5:
			return Anim.SLIDE if sliding else Anim.CRAWL
		return Anim.CROUCH
	var ratio := absf(body.velocity.x) / speed
	if ratio < 0.05:
		return Anim.IDLE
	if ratio < 0.45:
		return Anim.WALK
	if ratio < 0.85:
		return Anim.RUN
	return Anim.SPRINT

func _apply_horizontal(dir: float, delta: float, immobile: bool, on_floor: bool) -> void:
	if immobile:
		if exit_stun_left > 0.0:
			# Rolling out of a tunnel: bleed the slide momentum off gently so the
			# tumble carries across the ground in the exit direction, instead of
			# stopping dead and spinning on the spot.
			body.velocity.x = move_toward(body.velocity.x, 0.0, slide_friction * delta)
		else:
			body.velocity.x = move_toward(body.velocity.x, 0.0, friction * 2.0 * delta)
		return
	if crouched:
		if head_check.is_colliding():
			# In a low-ceiling slide space: locked-direction full-speed slide to
			# the exit (too short to stand/walk, so the Runner slides through).
			var s := signf(body.velocity.x)
			if s == 0.0:
				s = dir
			if s != 0.0:
				body.velocity.x = s * slide_speed
				sliding = true
			else:
				body.velocity.x = move_toward(body.velocity.x, 0.0, friction * delta)
		elif sliding:
			body.velocity.x = move_toward(body.velocity.x, 0.0, slide_friction * delta)
			if absf(body.velocity.x) <= crawl_speed:
				sliding = false
		else:
			if dir != 0.0:
				body.velocity.x = move_toward(body.velocity.x, dir * crawl_speed, acceleration * delta)
			else:
				body.velocity.x = move_toward(body.velocity.x, 0.0, friction * delta)
	elif on_floor:
		if dir != 0.0:
			body.velocity.x = move_toward(body.velocity.x, dir * speed, acceleration * delta)
		else:
			body.velocity.x = move_toward(body.velocity.x, 0.0, friction * delta)
	else:
		# Airborne: separate (lower) acceleration than ground for "intentional but
		# weighty" air control, with a reversal kick and an apex float bonus.
		var accel := air_acceleration
		if dir != 0.0 and body.velocity.x != 0.0 and signf(dir) != signf(body.velocity.x):
			accel *= air_turn_accel_mult
		if absf(body.velocity.y) < apex_velocity_threshold:
			accel *= apex_air_accel_bonus
		if dir != 0.0:
			body.velocity.x = move_toward(body.velocity.x, dir * speed, accel * delta)
		else:
			body.velocity.x = move_toward(body.velocity.x, 0.0, friction * delta)

func _enter_crouch() -> void:
	crouched = true
	stand_shape.disabled = true
	slide_shape.disabled = false

func _exit_crouch() -> void:
	if head_check.is_colliding():
		return
	crouched = false
	sliding = false
	stand_shape.disabled = false
	slide_shape.disabled = true
