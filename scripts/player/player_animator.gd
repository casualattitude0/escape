extends Node
class_name PlayerAnimator

## Drives the AnimatedSprite2D and name tag from the body's state. The authority
## picks the animation and publishes it (net_anim/net_flip); remote copies mirror
## those. Also handles role tint and the dead dim.

const RUNNER_COL := Color(0.55, 0.9, 0.65)
const HUNTER_COL := Color(1.0, 0.55, 0.55)

# Lockout durations mirror the non-looping anim's own frame count/fps so the
# lock releases right as the animation would naturally finish.
const LAND_LOCK_TIME := 2.0 / 16.0      # Land: 2 frames @ 16fps
const RUN_STOP_LOCK_TIME := 3.0 / 14.0  # RunToIdle: 3 frames @ 14fps
const KNOCKBACK_LOCK_TIME := 6.0 / 12.0 # Knockback: 6 frames @ 12fps
const SLAM_LOCK_TIME := 10.0 / 14.0     # GroundSlam: 10 frames @ 14fps
const ATTACK_LOCK_TIME := 6.0 / 16.0   # Attack: 6 frames @ 16fps
const SABOTAGE_LOCK_TIME := 4.0 / 18.0 # Sabotage: 4 frames @ 18fps

# Invulnerability flicker (GDD 6.5 lists this as a missing tell). One full
# on/off cycle per FLICKER_PERIOD; the Runner never fully disappears, or it would
# be unreadable exactly when the Hunters are trying to track it.
const FLICKER_PERIOD := 0.16
const FLICKER_ALPHA := 0.35

const DOT_OFF := Color(0.4, 0.4, 0.4, 1.0)
const DOT_ON := Color(1.0, 0.15, 0.15, 1.0)

@onready var body: CharacterBody2D = get_parent()
@onready var sprite: AnimatedSprite2D = body.get_node("SpritePivot/AnimatedSprite2D")
@onready var name_tag: Label = body.get_node("NameTag")
@onready var knock_dots: Node2D = body.get_node("KnockDots")
@onready var _dots: Array[Label] = [
	body.get_node("KnockDots/Dot0"),
	body.get_node("KnockDots/Dot1"),
	body.get_node("KnockDots/Dot2"),
]

var _shown_role: String = ""
var _prev_knocks := 0            # last seen knock count, to catch a knock landing
var _prev_stunned := false       # last seen stun state, to catch the third knock
var _prev_destroyed := 0         # last seen device count, to catch one breaking
var _hooked := false

var _knockback_lock := 0.0       # counts down while the kick-away tumble plays
var _slam_lock := 0.0            # counts down while the device-broken flourish plays
var _attack_lock := 0.0          # counts down while the Runner's kill swing plays
var _sabotage_lock := 0.0        # counts down while the Runner's sabotage swing plays

var _land_lock_left := 0.0       # counts down while LAND is forced over locomotion
var _run_stop_lock_left := 0.0   # counts down while RUN_STOP is forced over locomotion
var _prev_loco := Anim.IDLE      # last raw locomotion_anim(), to catch the run->idle edge

## Every peer, every frame: visuals + (remote) mirror the replicated animation.
func render() -> void:
	_hook_taps()
	_apply_visual()
	if not body.is_multiplayer_authority():
		sprite.flip_h = body.net_flip
		if body.net_anim != "" and sprite.animation != body.net_anim:
			sprite.play(body.net_anim)

## Authority only: choose the animation, play it, and publish for remote copies.
## `delta` drives the LAND/RUN_STOP lockout timers (they hold their anim for a
## fixed duration regardless of how fast locomotion_anim() changes underneath).
## Force a fixed pose, bypassing locomotion — used while the Runner is inside a
## tunnel/pipe. Drives the local sprite and the replicated net_anim/net_flip
## directly so every peer sees the same held pose.
func force_pose(anim: String, flip: bool) -> void:
	body.net_anim = anim
	body.net_flip = flip
	sprite.flip_h = flip
	if sprite.animation != anim:
		sprite.play(anim)

func publish(delta: float) -> void:
	var dir: float = body.movement.last_dir
	if body.movement.exit_stun_active():
		# The tunnel-exit roll faces the way it travels, so it reads as rolling
		# across the ground rather than tumbling in place.
		if absf(body.velocity.x) > 1.0:
			sprite.flip_h = body.velocity.x < 0.0
	elif body.movement.sliding:
		pass                              # locked facing: don't flip mid-slide
	elif dir != 0.0:
		sprite.flip_h = dir < 0.0

	_land_lock_left = maxf(_land_lock_left - delta, 0.0)
	_run_stop_lock_left = maxf(_run_stop_lock_left - delta, 0.0)
	_knockback_lock = maxf(_knockback_lock - delta, 0.0)
	_slam_lock = maxf(_slam_lock - delta, 0.0)
	_attack_lock = maxf(_attack_lock - delta, 0.0)
	_sabotage_lock = maxf(_sabotage_lock - delta, 0.0)

	var loco: String = body.movement.locomotion_anim()
	if body.movement.just_landed:
		# Landing always wins: cancel any pending run-stop so LAND reads clearly.
		_land_lock_left = LAND_LOCK_TIME
		_run_stop_lock_left = 0.0
	elif (_prev_loco == Anim.RUN or _prev_loco == Anim.SPRINT) and loco == Anim.IDLE:
		# Decelerating straight into idle: play the run-stop tail first.
		_run_stop_lock_left = RUN_STOP_LOCK_TIME
	_prev_loco = loco

	var anim := _pick_anim(loco)
	# Only (re)start on change so non-looping anims play once and hold their last
	# frame instead of restarting every frame.
	if sprite.animation != anim:
		sprite.play(anim)
	body.net_anim = anim
	body.net_flip = sprite.flip_h

func _pick_anim(loco: String) -> String:
	if body.dead:
		return Anim.DIE
	if body.stunned:
		# Only the third knock puts the Runner down: it gets knocked off its feet
		# (KNOCKBACK, once) and then lies there (STUNNED, looping).
		return Anim.KNOCKBACK if _knockback_lock > 0.0 else Anim.STUNNED
	if _slam_lock > 0.0:
		return Anim.SLAM              # Runner: a device just came apart
	if _attack_lock > 0.0:
		return Anim.ATTACK            # Runner: kill swing playing out
	if _sabotage_lock > 0.0:
		return Anim.SABOTAGE          # Runner: sabotage swing playing out
	if body.combat.stiff_active():
		return Anim.KNOCK             # Hunter's knock swing and its miss recovery
	if body.movement.exit_stun_active():
		return Anim.ROLL              # tunnel exit stiffness reads as a tumble-recovery
	if _land_lock_left > 0.0:
		return Anim.LAND
	if _run_stop_lock_left > 0.0:
		return Anim.RUN_STOP
	return loco

func _apply_visual() -> void:
	if body.role != _shown_role:
		_shown_role = body.role
		var base := "Runner" if body.role == Roles.RUNNER else "Hunter"
		name_tag.text = base + (" (You)" if body.is_multiplayer_authority() else "")
		name_tag.modulate = RUNNER_COL if body.role == Roles.RUNNER else HUNTER_COL
	if body.role == Roles.RUNNER:
		sprite.modulate = Color(1, 1, 1, _iframe_alpha())
	else:
		sprite.modulate = Color(0.5, 0.32, 0.32) if body.dead else HUNTER_COL

## Blink the Runner while it cannot be knocked. Both sides need this: the Runner
## learns the shove was not its fault, and the Hunters learn that swinging right
## now is wasted — the iframe is otherwise completely invisible.
##
## Driven off the replicated iframe flag, so every peer flickers together, and
## timed off the wall clock rather than a physics accumulator: this is cosmetic
## only, so it does not need to obey the simulation's clock, and this way it does
## not have to be threaded through render().
func _iframe_alpha() -> float:
	if body.gm == null or not body.gm.runner_iframe():
		return 1.0
	var t := fmod(Time.get_ticks_msec() / 1000.0, FLICKER_PERIOD)
	return FLICKER_ALPHA if t < FLICKER_PERIOD * 0.5 else 1.0

## Restart `anim` from frame 0 and publish it immediately. Replaying from the top
## on every press is what makes a mashed key read as a mash rather than a single
## held pose. Called from PlayerCombat on the frame the key goes down.
func _pulse(anim: String) -> void:
	sprite.play(anim)
	sprite.frame = 0
	body.net_anim = anim
	body.net_flip = sprite.flip_h

## The Hunter's knock swing.
func knock() -> void:
	_pulse(Anim.KNOCK)

## The Runner's kill swing.
func attack() -> void:
	_attack_lock = ATTACK_LOCK_TIME
	_pulse(Anim.ATTACK)

## The Runner's sabotage swing. Restarting from frame 0 on every tap is what makes
## the mash read as a mash rather than one long held pose.
func sabotage() -> void:
	_sabotage_lock = SABOTAGE_LOCK_TIME
	_pulse(Anim.SABOTAGE)

## Connect once to the GameManager so a knock landing replays the Runner's
## reaction. This hangs off the REPLICATED knock count rather than local input, so
## the reaction shows on every peer and on the Runner who did not press anything.
func _hook_taps() -> void:
	if _hooked or body.gm == null:
		return
	_hooked = true
	body.gm.state_changed.connect(_on_state_changed)

func _on_state_changed() -> void:
	if body.gm == null or body.role != Roles.RUNNER:
		return
	var n: int = body.gm.knock_count()
	_prev_knocks = n
	_refresh_dots(n)

	var st: bool = body.gm.runner_stunned()
	if st and not _prev_stunned:
		_knockback_lock = KNOCKBACK_LOCK_TIME
	_prev_stunned = st

	var d: int = body.gm.devices_destroyed()
	if d > _prev_destroyed:
		_slam_lock = SLAM_LOCK_TIME
	_prev_destroyed = d

func _refresh_dots(n: int) -> void:
	knock_dots.visible = (n > 0)
	for i in _dots.size():
		_dots[i].add_theme_color_override("font_color", DOT_ON if i < n else DOT_OFF)
