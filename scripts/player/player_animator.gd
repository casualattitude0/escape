extends Node
class_name PlayerAnimator

## Drives the AnimatedSprite2D and name tag from the body's state. The authority
## picks the animation and publishes it (net_anim/net_flip); remote copies mirror
## those. Also handles role tint and the dead dim.

const RUNNER_COL := Color(0.55, 0.9, 0.65)
const HUNTER_COL := Color(1.0, 0.55, 0.55)

@onready var body: CharacterBody2D = get_parent()
@onready var sprite: AnimatedSprite2D = body.get_node("AnimatedSprite2D")
@onready var name_tag: Label = body.get_node("NameTag")

var _shown_role: String = ""
var _prev_cap := 0.0             # last seen bar values, to detect a fresh mash tap
var _prev_esc := 0.0
var _hooked := false

## Every peer, every frame: visuals + (remote) mirror the replicated animation.
func render() -> void:
	_hook_taps()
	_apply_visual()
	if not body.is_multiplayer_authority():
		sprite.flip_h = body.net_flip
		if body.net_anim != "" and sprite.animation != body.net_anim:
			sprite.play(body.net_anim)

## Authority only: choose the animation, play it, and publish for remote copies.
func publish() -> void:
	var dir: float = body.movement.last_dir
	if body.combat.grappling:
		_face_opponent()                 # tug-of-war: orient toward the other fighter
	elif body.movement.sliding:
		pass                              # locked facing: don't flip mid-slide
	elif dir != 0.0:
		sprite.flip_h = dir < 0.0
	var anim := _pick_anim()
	# Only (re)start on change so non-looping anims play once and hold their last
	# frame instead of restarting every frame.
	if sprite.animation != anim:
		sprite.play(anim)
	body.net_anim = anim
	body.net_flip = sprite.flip_h

func _pick_anim() -> String:
	if body.dead:
		return Anim.DIE
	if body.combat.grappling:
		# The mash-off reads as a tug-of-war: the Runner heaves away (pull), the
		# Hunter shoves in (push).
		return Anim.PULL if body.role == Roles.RUNNER else Anim.PUSH
	return body.movement.locomotion_anim()

## Point the sprite at the other fighter for the mash-off. The push sprite faces
## right by default and the pull sprite faces left, so the two roles flip on
## opposite conditions to end up facing each other.
func _face_opponent() -> void:
	var other := _grapple_opponent()
	if other == null:
		return
	var to_right := other.global_position.x > body.global_position.x
	if body.role == Roles.RUNNER:
		sprite.flip_h = to_right          # pull: default faces left -> flip to face a Hunter on the right
	else:
		sprite.flip_h = not to_right      # push: default faces right -> flip to face a Runner on the left

func _grapple_opponent() -> Node2D:
	if body.gm == null:
		return null
	var want := Roles.HUNTER if body.role == Roles.RUNNER else Roles.RUNNER
	var best: Node2D = null
	var best_d := INF
	for c in body.gm.players().get_children():
		if c.get("role") != want or c.get("dead"):
			continue
		var d: float = body.global_position.distance_to(c.global_position)
		if d < best_d:
			best_d = d
			best = c
	return best

func _apply_visual() -> void:
	if body.role != _shown_role:
		_shown_role = body.role
		var base := "Runner" if body.role == Roles.RUNNER else "Hunter"
		name_tag.text = base + (" (You)" if body.is_multiplayer_authority() else "")
		name_tag.modulate = RUNNER_COL if body.role == Roles.RUNNER else HUNTER_COL
	if body.role == Roles.RUNNER:
		sprite.modulate = Color(1, 1, 1)
	else:
		sprite.modulate = Color(0.5, 0.32, 0.32) if body.dead else HUNTER_COL

## Immediate feedback for a mash tap on the LOCAL player: replay the push/pull
## from the top so each key press lands a fresh, visible heave. Called from
## PlayerCombat the moment the mash key is pressed.
func pulse() -> void:
	if _grappling():
		sprite.play(sprite.animation)
		sprite.frame = 0

## True when this player is shown locked in the mash-off. The push/pull anim is
## the reliable, peer-agnostic tell, so this works the same on the owner and on
## remote copies.
func _grappling() -> bool:
	return sprite.animation == Anim.PUSH or sprite.animation == Anim.PULL

## Connect once to the GameManager so an opponent's tap (a bump in the replicated
## capture/escape bars) replays this player's heave too — so both fighters react.
func _hook_taps() -> void:
	if _hooked or body.gm == null:
		return
	_hooked = true
	body.gm.state_changed.connect(_on_state_changed)

func _on_state_changed() -> void:
	if body.gm == null:
		return
	var cap: float = body.gm.capture_ratio()
	var esc: float = body.gm.escape_ratio()
	if cap > _prev_cap + 0.0001 or esc > _prev_esc + 0.0001:
		pulse()
	_prev_cap = cap
	_prev_esc = esc
