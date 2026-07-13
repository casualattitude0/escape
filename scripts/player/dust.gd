extends AnimatedSprite2D

## One-shot dust puff. Effects spawns one of these per FX event (jump, landing,
## run, slide, roll), calls play(anim_name), and the node frees itself the
## instant the animation finishes. Purely local/cosmetic — never replicated;
## each peer spawns its own copies off net_anim transitions (see player_effects.gd).

func _ready() -> void:
	animation_finished.connect(queue_free)
