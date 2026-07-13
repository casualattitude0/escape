extends CharacterBody2D

## Networked player body. This is a thin orchestrator: it holds the replicated
## state and calls its components (Movement / Combat / Health / Animator) in a
## fixed order each physics frame. Only the owning peer runs input/physics;
## position and a bit of state are replicated to everyone else.
##
## Roles: Runner (the monster) collects items and escapes; can slide tunnels and
## melee. Hunter (the researcher) walks only and captures via the mash-off.

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var camera: Camera2D = $Camera2D
@onready var movement: PlayerMovement = $Movement
@onready var combat: PlayerCombat = $Combat
@onready var health: PlayerHealth = $Health
@onready var animator: PlayerAnimator = $Animator

# Replicated state (the MultiplayerSynchronizer references these on this node).
var role: String = Roles.HUNTER
var net_anim: String = Anim.IDLE
var net_flip: bool = false
var capturable: bool = false     # Runner: currently vulnerable to a grab
var dead: bool = false           # Hunter: killed, waiting to respawn

# Set at spawn (world.gd); Hunters respawn here.
var spawn_point: Vector2 = Vector2.ZERO

# The GameManager (server-authoritative match/grapple state), found once.
var gm: Node

func _ready() -> void:
	camera.enabled = is_multiplayer_authority()
	if is_multiplayer_authority():
		camera.make_current()
	gm = get_tree().get_first_node_in_group("game_manager")

func _process(_delta: float) -> void:
	animator.render()

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return

	health.tick(delta)
	if dead:
		movement.freeze()
		animator.publish()
		return

	# Paused (local pause menu open): hold still but stay replicated.
	if Net.local_input_locked:
		movement.freeze()
		animator.publish()
		return

	movement.update_tunnel(delta)
	var grappling := combat.update_grapple()
	var immobile := grappling or movement.exit_stun_active()

	movement.tick(delta, not immobile)

	if role == Roles.RUNNER:
		capturable = movement.exit_stun_active() or movement.is_slow()

	combat.apply_snap(delta)
	combat.handle_input()
	animator.publish()

@rpc("any_peer", "reliable")
func kill() -> void:
	# Called by the server on the hit Hunter's own peer.
	health.kill()
