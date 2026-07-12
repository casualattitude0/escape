extends CharacterBody2D

## Networked 2D platformer controller with a Metroid-style slide.
## Sliding (press "slide" while moving on the floor) swaps to a short collision
## shape so the player fits through 1-tile-high tunnels. While the head is
## blocked by a ceiling the player stays low and can crawl the rest of the way.
##
## In multiplayer only the owning peer runs the physics/input; position and a
## bit of animation state are replicated to everyone else. `role` is set at
## spawn time to "runner" or "hunter".

@export var speed: float = 220.0
@export var crawl_speed: float = 110.0
@export var slide_speed: float = 330.0
@export var jump_velocity: float = -470.0
@export var acceleration: float = 1800.0
@export var friction: float = 2000.0
@export var slide_friction: float = 650.0

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var stand_shape: CollisionShape2D = $StandCollision
@onready var slide_shape: CollisionShape2D = $SlideCollision
@onready var head_check: RayCast2D = $HeadCheck
@onready var camera: Camera2D = $Camera2D
@onready var name_tag: Label = $NameTag

# Replicated (see the MultiplayerSynchronizer in player.tscn).
var role: String = "hunter"
var net_anim: String = "idle"
var net_flip: bool = false
var stunned: bool = false

var crouched: bool = false
var sliding: bool = false

var _was_capturing: bool = false
var _stun_left: float = 0.0
var _shown_role: String = ""
var _gm: Node

func _ready() -> void:
	camera.enabled = is_multiplayer_authority()
	if is_multiplayer_authority():
		camera.make_current()
	_gm = get_tree().get_first_node_in_group("game_manager")

func _process(_delta: float) -> void:
	_apply_role_visual()
	if not is_multiplayer_authority():
		# Remote copy: mirror the replicated animation.
		sprite.flip_h = net_flip
		if net_anim != "" and sprite.animation != net_anim:
			sprite.play(net_anim)

func _apply_role_visual() -> void:
	# `role` may arrive a frame late over the network, so re-apply on change.
	if role == _shown_role:
		return
	_shown_role = role
	var is_runner := role == "runner"
	# Runner keeps its natural colours; Hunters get a red tint to tell sides apart.
	sprite.modulate = Color(1, 1, 1) if is_runner else Color(1.0, 0.55, 0.55)
	name_tag.text = "Runner" if is_runner else "Hunter"
	name_tag.modulate = Color(0.55, 0.9, 0.65) if is_runner else Color(1.0, 0.55, 0.55)
	if is_multiplayer_authority():
		name_tag.text += "（你）"

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return

	if _stun_left > 0.0:
		_stun_left -= delta
		if _stun_left <= 0.0:
			stunned = false

	if not is_on_floor():
		velocity += get_gravity() * delta

	var dir := 0.0
	var slide_held := false
	if not stunned:
		dir = Input.get_axis("move_left", "move_right")
		# Only the Runner can slide / crawl through tunnels.
		slide_held = role == "runner" and Input.is_action_pressed("slide")
	var head_blocked := head_check.is_colliding()

	# Stay low if the slide button is held on the floor, or if a ceiling is
	# directly overhead (can't stand up yet).
	var want_low := (slide_held and is_on_floor()) or (crouched and head_blocked)

	if want_low and not crouched:
		_enter_crouch()
		var s := signf(velocity.x)
		if s == 0.0:
			s = dir
		if s != 0.0:
			velocity.x = s * slide_speed
			sliding = true
	elif not want_low and crouched:
		_exit_crouch()

	if not stunned and Input.is_action_just_pressed("jump") and is_on_floor() and not head_blocked:
		velocity.y = jump_velocity
		if crouched:
			_exit_crouch()

	_apply_horizontal(dir, delta)
	move_and_slide()
	_animate(dir)
	_handle_role_actions()

func _handle_role_actions() -> void:
	if stunned or _gm == null:
		return
	if role == "hunter":
		var holding := Input.is_action_pressed("capture")
		if holding != _was_capturing:
			_was_capturing = holding
			_gm.set_capturing.rpc_id(1, holding)
	elif role == "runner":
		if Input.is_action_just_pressed("attack"):
			_gm.runner_attack.rpc_id(1)

@rpc("any_peer", "reliable")
func stun(duration: float) -> void:
	# Called by the server on the hit Hunter's own peer.
	stunned = true
	_stun_left = duration
	if _was_capturing:
		_was_capturing = false

func _apply_horizontal(dir: float, delta: float) -> void:
	if crouched:
		if head_check.is_colliding():
			var s := signf(velocity.x)
			if s == 0.0:
				s = dir
			if s != 0.0:
				velocity.x = s * slide_speed
				sliding = true
			else:
				velocity.x = move_toward(velocity.x, 0.0, friction * delta)
		elif sliding:
			velocity.x = move_toward(velocity.x, 0.0, slide_friction * delta)
			if absf(velocity.x) <= crawl_speed:
				sliding = false
		else:
			if dir != 0.0:
				velocity.x = move_toward(velocity.x, dir * crawl_speed, acceleration * delta)
			else:
				velocity.x = move_toward(velocity.x, 0.0, friction * delta)
	else:
		if dir != 0.0:
			velocity.x = move_toward(velocity.x, dir * speed, acceleration * delta)
		else:
			velocity.x = move_toward(velocity.x, 0.0, friction * delta)

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

func _animate(dir: float) -> void:
	if dir != 0.0:
		sprite.flip_h = dir < 0.0

	var anim := "idle"
	if not is_on_floor():
		anim = "jump" if velocity.y < 0.0 else "fall"
	elif crouched:
		if sliding or absf(velocity.x) > crawl_speed * 0.5:
			anim = "slide" if sliding else "crawl"
		else:
			anim = "crouch"
	elif absf(velocity.x) > 10.0:
		anim = "run"
	else:
		anim = "idle"

	sprite.play(anim)
	# Publish for the remote copies.
	net_anim = anim
	net_flip = sprite.flip_h
