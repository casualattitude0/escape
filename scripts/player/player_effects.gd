extends Node
class_name PlayerEffects

## Procedural juice on top of the animation system: squash/stretch, one-shot
## dust FX, and camera lookahead/shake. Art guide ART_CHARACTER.md §6 wants
## exaggerated squash-and-stretch and dust on every jump/landing/run beat.
##
## None of this is replicated — `sprite.scale` and spawned dust nodes are purely
## local. Every peer (owner and remote copies alike) drives itself off the
## *replicated* `net_anim`/`net_flip` transitions in render(), which already
## mirror correctly (see PlayerAnimator). Camera juice is the one exception:
## it reads real physics state, so it only ever runs on the owning peer, called
## separately from the physics path.

const DUST_SCENE := preload("res://scenes/fx/dust.tscn")
const FEET_OFFSET := Vector2(0, 20)  # local offset from body origin to ground contact (matches SpritePivot)

## -- Squash & stretch --------------------------------------------------------
@export var jump_stretch: Vector2 = Vector2(0.8, 1.2)   # takeoff: thin and tall
@export var land_squash: Vector2 = Vector2(1.25, 0.75)  # touchdown: wide and flat
@export var squash_omega: float = 24.0                  # spring stiffness (higher = snappier recovery)
@export var land_squash_min_fall_speed: float = 200.0   # below this, landing squash is barely felt
@export var land_squash_max_fall_speed: float = 700.0   # at/above this, landing squash is maxed out
@export var land_squash_remote_mix: float = 0.6         # fixed "medium" strength used on remote copies (no velocity data)

## -- Dust FX ------------------------------------------------------------------
@export var run_dust_interval: float = 0.28   # seconds between footstep puffs at RUN pace
@export var sprint_dust_interval: float = 0.16 # faster puffs at SPRINT pace

## -- Camera juice (authority only) --------------------------------------------
@export var lookahead_x: float = 40.0
@export var lookahead_y: float = 24.0            # extra downward peek while falling fast
@export var lookahead_fall_speed: float = 500.0  # fall speed at which lookahead_y is fully applied
@export var lookahead_smoothing: float = 10.0    # exponential smoothing rate for the offset chase
@export var land_shake_min_fall_speed: float = 350.0
@export var land_shake_max_fall_speed: float = 750.0
@export var land_shake_strength: float = 6.0     # max pixel jitter at max fall speed
@export var land_shake_time: float = 0.15

@onready var body: CharacterBody2D = get_parent()
@onready var pivot: Node2D = body.get_node("SpritePivot")
@onready var sprite: AnimatedSprite2D = pivot.get_node("AnimatedSprite2D")
@onready var camera: Camera2D = body.get_node("Camera2D")

var _scale := Vector2.ONE
var _scale_vel := Vector2.ZERO   # spring velocity, per axis

var _prev_net_anim := ""
var _prev_net_flip := false
var _run_dust_left := 0.0

var _shake_left := 0.0
var _shake_strength := 0.0
var _cam_offset := Vector2.ZERO  # smoothed lookahead, shake is added on top each frame

## Every peer, every frame: squash/stretch spring + FX spawns, all keyed off
## net_anim/net_flip transitions so remote copies reproduce the same beats.
func render(delta: float) -> void:
	_update_squash(delta)
	_update_dust(delta)
	_prev_net_anim = body.net_anim
	_prev_net_flip = body.net_flip

func _update_squash(delta: float) -> void:
	var entered_jump: bool = body.net_anim == Anim.JUMP and _prev_net_anim != Anim.JUMP
	var entered_land: bool = body.net_anim == Anim.LAND and _prev_net_anim != Anim.LAND
	if entered_jump:
		_scale = jump_stretch
		_scale_vel = Vector2.ZERO
	elif entered_land:
		_scale = land_squash.lerp(Vector2.ONE, 1.0 - _land_intensity())
		_scale_vel = Vector2.ZERO
	var sx := _spring(_scale.x, _scale_vel.x, 1.0, delta)
	var sy := _spring(_scale.y, _scale_vel.y, 1.0, delta)
	_scale = Vector2(sx.x, sy.x)
	_scale_vel = Vector2(sx.y, sy.y)
	pivot.scale = _scale

## Critically damped spring step toward `target`. Returns (new_value, new_velocity)
## packed into a Vector2 since GDScript has no by-reference float out-params.
func _spring(current: float, vel: float, target: float, delta: float) -> Vector2:
	var x := current - target
	var e := exp(-squash_omega * delta)
	var new_x := (x + (vel + squash_omega * x) * delta) * e
	var new_vel := (vel - squash_omega * (vel + squash_omega * x) * delta) * e
	return Vector2(new_x + target, new_vel)

## 0..1 landing squash strength. Authority scales by its own real fall speed
## (the only peer with valid physics velocity); remote copies get a fixed
## "medium" feel since velocity isn't replicated.
func _land_intensity() -> float:
	if not body.is_multiplayer_authority():
		return land_squash_remote_mix
	var fall_speed := absf(body.velocity.y)
	return clampf(
		(fall_speed - land_squash_min_fall_speed) / maxf(land_squash_max_fall_speed - land_squash_min_fall_speed, 1.0),
		0.0, 1.0
	)

func _update_dust(delta: float) -> void:
	var anim: String = body.net_anim
	var entered: bool = anim != _prev_net_anim

	if entered and anim == Anim.JUMP:
		_spawn_dust("jump_dust")
	elif entered and anim == Anim.LAND:
		_spawn_dust("landing_dust")
	elif entered and anim == Anim.SLIDE:
		_spawn_dust("slide_dust")
	elif entered and anim == Anim.ROLL:
		_spawn_dust("roll_dust")

	var is_running: bool = anim == Anim.RUN or anim == Anim.SPRINT
	if is_running:
		# Turning around at speed reads as a skid — reuse the run puff as a slide cue.
		if body.net_flip != _prev_net_flip and not entered:
			_spawn_dust("run_dust")
			_run_dust_left = run_dust_interval if anim == Anim.RUN else sprint_dust_interval
		_run_dust_left -= delta
		if _run_dust_left <= 0.0:
			_spawn_dust("run_dust")
			_run_dust_left = run_dust_interval if anim == Anim.RUN else sprint_dust_interval
	else:
		_run_dust_left = 0.0

func _spawn_dust(fx_anim: String) -> void:
	var dust := DUST_SCENE.instantiate()
	var scene := get_tree().current_scene
	if scene == null:
		return
	scene.add_child(dust)
	dust.global_position = pivot.global_position
	dust.flip_h = body.net_flip
	dust.play(fx_anim)

## Authority only: direction lookahead + a landing micro-shake, both reading
## real (unreplicated) physics state. Call from the physics path after
## movement.tick() so `just_landed`/`velocity` are fresh.
func camera_juice(delta: float) -> void:
	if not body.is_multiplayer_authority():
		return

	var target := Vector2.ZERO
	if absf(body.velocity.x) > 1.0:
		target.x = signf(body.velocity.x) * lookahead_x
	if body.velocity.y > 0.0:
		target.y = lookahead_y * clampf(body.velocity.y / lookahead_fall_speed, 0.0, 1.0)
	_cam_offset = _cam_offset.lerp(target, clampf(lookahead_smoothing * delta, 0.0, 1.0))

	if body.movement.just_landed:
		var fall_speed := absf(body.velocity.y)
		if fall_speed >= land_shake_min_fall_speed:
			var t := clampf(
				(fall_speed - land_shake_min_fall_speed) / maxf(land_shake_max_fall_speed - land_shake_min_fall_speed, 1.0),
				0.0, 1.0
			)
			_shake_strength = land_shake_strength * t
			_shake_left = land_shake_time

	var shake_offset := Vector2.ZERO
	if _shake_left > 0.0:
		_shake_left -= delta
		var falloff := clampf(_shake_left / land_shake_time, 0.0, 1.0)
		shake_offset = Vector2(
			randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)
		) * _shake_strength * falloff

	camera.offset = _cam_offset + shake_offset
