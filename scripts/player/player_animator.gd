extends Node
class_name PlayerAnimator

## Drives the AnimatedSprite2D and name tag from the body's state. The authority
## picks the animation and publishes it (net_anim/net_flip); remote copies mirror
## those. Also handles role tint, the capturable flash, and the dead dim.

const RUNNER_COL := Color(0.55, 0.9, 0.65)
const HUNTER_COL := Color(1.0, 0.55, 0.55)

@onready var body: CharacterBody2D = get_parent()
@onready var sprite: AnimatedSprite2D = body.get_node("AnimatedSprite2D")
@onready var name_tag: Label = body.get_node("NameTag")

var _shown_role: String = ""

## Every peer, every frame: visuals + (remote) mirror the replicated animation.
func render() -> void:
	_apply_visual()
	if not body.is_multiplayer_authority():
		sprite.flip_h = body.net_flip
		if body.net_anim != "" and sprite.animation != body.net_anim:
			sprite.play(body.net_anim)

## Authority only: choose the animation, play it, and publish for remote copies.
func publish() -> void:
	var dir: float = body.movement.last_dir
	if dir != 0.0 and not body.combat.grappling:
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
	if body.combat.attacking():
		return Anim.ATTACK
	if body.combat.grappling:
		return Anim.STRUGGLE if body.role == Roles.RUNNER else Anim.GRAB
	return body.movement.locomotion_anim()

func _apply_visual() -> void:
	if body.role != _shown_role:
		_shown_role = body.role
		var base := "Runner" if body.role == Roles.RUNNER else "Hunter"
		name_tag.text = base + (" (You)" if body.is_multiplayer_authority() else "")
		name_tag.modulate = RUNNER_COL if body.role == Roles.RUNNER else HUNTER_COL
	if body.role == Roles.RUNNER:
		# Flash yellow while capturable so everyone sees a rescue/finish moment.
		sprite.modulate = Color(1, 1, 0.35) if body.capturable else Color(1, 1, 1)
	else:
		sprite.modulate = Color(0.5, 0.32, 0.32) if body.dead else HUNTER_COL
