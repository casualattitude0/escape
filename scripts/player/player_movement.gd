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

const CAPTURE_SPEED_MAX := 55.0   # Runner is capturable at/below this speed
const TUNNEL_EXIT_STUN := 0.5     # frozen recovery after leaving a tunnel

var crouched: bool = false
var sliding: bool = false
var in_tunnel: bool = false
var exit_stun_left: float = 0.0
var last_dir: float = 0.0         # read by the animator for facing

@onready var body: CharacterBody2D = get_parent()
@onready var stand_shape: CollisionShape2D = body.get_node("StandCollision")
@onready var slide_shape: CollisionShape2D = body.get_node("SlideCollision")
@onready var head_check: RayCast2D = body.get_node("HeadCheck")

func exit_stun_active() -> bool:
	return exit_stun_left > 0.0

func is_slow() -> bool:
	return absf(body.velocity.x) <= CAPTURE_SPEED_MAX

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
	if not body.is_on_floor():
		body.velocity += body.get_gravity() * delta

	var head_blocked := head_check.is_colliding()

	var dir := 0.0
	var slide_held := false
	if can_control:
		dir = Input.get_axis("move_left", "move_right")
		# Only the Runner can slide / crawl through tunnels.
		slide_held = body.role == Roles.RUNNER and Input.is_action_pressed("slide")

	var want_low := (slide_held and body.is_on_floor()) or (crouched and head_blocked)
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

	if can_control and Input.is_action_just_pressed("jump") \
			and body.is_on_floor() and not head_blocked:
		body.velocity.y = jump_velocity
		if crouched:
			_exit_crouch()

	_apply_horizontal(dir, delta, not can_control)
	body.move_and_slide()
	last_dir = dir

## The animation the body's motion implies (combat/capture states override this
## in the animator).
func locomotion_anim() -> String:
	if not body.is_on_floor():
		return Anim.JUMP if body.velocity.y < 0.0 else Anim.FALL
	if crouched:
		if sliding or absf(body.velocity.x) > crawl_speed * 0.5:
			return Anim.SLIDE if sliding else Anim.CRAWL
		return Anim.CROUCH
	if absf(body.velocity.x) > 10.0:
		return Anim.RUN
	return Anim.IDLE

func _apply_horizontal(dir: float, delta: float, immobile: bool) -> void:
	if immobile:
		body.velocity.x = move_toward(body.velocity.x, 0.0, friction * 2.0 * delta)
		return
	if crouched:
		if head_check.is_colliding():
			# In a tunnel: locked-direction full-speed slide to the exit.
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
	else:
		if dir != 0.0:
			body.velocity.x = move_toward(body.velocity.x, dir * speed, acceleration * delta)
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
