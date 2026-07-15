extends CharacterBody2D

## Networked player body. This is a thin orchestrator: it holds the replicated
## state and calls its components (Movement / Combat / Health / Animator /
## Effects) in a fixed order each physics frame. Only the owning peer runs
## input/physics; position and a bit of state are replicated to everyone else.
##
## Roles: Runner (the monster) breaks the facility and escapes; can slide tunnels
## and kill. Hunter (the researcher) walks only and knocks the Runner to stun it.

const STUN_DRAG := 900.0     # how fast a stunned Runner's knockback slide bleeds off
const KNOCK_HOP := -90.0     # small pop on a knock so the kick reads as a hit, not a nudge
const KNOCK_STAGGER := 0.22  # Runner: no steering right after a knock, so the shove lands

@onready var sprite: AnimatedSprite2D = $SpritePivot/AnimatedSprite2D
@onready var camera: Camera2D = $Camera2D
@onready var movement: PlayerMovement = $Movement
@onready var combat: PlayerCombat = $Combat
@onready var health: PlayerHealth = $Health
@onready var animator: PlayerAnimator = $Animator
@onready var effects: PlayerEffects = $Effects

# Replicated state (the MultiplayerSynchronizer references these on this node).
var role: String = Roles.HUNTER
var net_anim: String = Anim.IDLE
var net_flip: bool = false
var dead: bool = false           # Hunter: killed, waiting to respawn
var stunned: bool = false        # Runner: stunned by a third knock (GDD 4.6)

# Set at spawn (world.gd); Hunters respawn here.
var spawn_point: Vector2 = Vector2.ZERO

# The GameManager (server-authoritative match state), found once.
var gm: Node

func _ready() -> void:
	camera.enabled = is_multiplayer_authority()
	if is_multiplayer_authority():
		camera.make_current()
	# Throttle replication to ~22Hz instead of once per physics frame. The default
	# (interval 0) sends position every tick, which floods the (high-latency) relay
	# and makes packets queue up; 0.045s is plenty smooth for this game and cuts the
	# outbound packet rate to roughly a third. See net.gd for the relay path.
	$Sync.replication_interval = 0.045
	$Sync.delta_interval = 0.045
	gm = get_tree().get_first_node_in_group("game_manager")

func _process(delta: float) -> void:
	animator.render()
	effects.render(delta)   # squash/stretch + dust: every peer, keyed off net_anim/net_flip

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return

	health.tick(delta)
	if dead:
		movement.freeze()
		animator.publish(delta)
		return

	# Stunned by a third knock: frozen, and the knockback carries us as we fall.
	# Stun beats everything — it is the Hunters' whole payoff for landing three.
	if stunned:
		velocity.y += get_gravity().y * delta
		velocity.x = move_toward(velocity.x, 0.0, STUN_DRAG * delta)
		move_and_slide()
		animator.publish(delta)
		return

	# Paused (local pause menu open): hold still but stay replicated.
	if Net.local_input_locked:
		movement.freeze()
		animator.publish(delta)
		return

	movement.update_tunnel(delta)
	combat.tick_stiff(delta)
	var immobile := combat.stiff_active() or combat.stagger_active() \
		or movement.exit_stun_active()

	movement.tick(delta, not immobile)
	effects.camera_juice(delta)   # lookahead + landing shake: real velocity, owner only

	combat.handle_input(delta)
	animator.publish(delta)

# Server -> owner calls. Two things here are load-bearing and neither is obvious:
#
# 1. They stay "any_peer" and check the sender by hand. The rpc mode "authority"
#    would test against THIS NODE's authority, which is the owning peer (world.gd
#    sets it per player), not the server — so it would reject peer 1 and accept
#    only the victim's own peer. Exactly backwards.
# 2. They are "call_local". The Runner IS the host, so every server -> Runner call
#    (stun / knockback / attack_confirmed) is the host rpc-ing itself, and Godot
#    drops a self-call unless it is declared call_local. Without it the Runner was
#    never stunned and never pushed. See tools/test_rpc_call_local.tscn.

## True when the call came from the server: either it arrived from peer 1, or it
## ran locally on us and we ARE the server (a call_local self-call reports our own
## id; the 0 case only shows up for a direct, non-rpc invocation).
func _from_server() -> bool:
	var s := multiplayer.get_remote_sender_id()
	return s == 1 or ((s == 0 or s == multiplayer.get_unique_id()) and multiplayer.is_server())

@rpc("any_peer", "call_local", "reliable")
func kill() -> void:
	# Called by the server on the hit Hunter's own peer.
	if not _from_server():
		return
	health.kill()

@rpc("any_peer", "call_local", "reliable")
func stun(duration: float) -> void:
	# Called by the server on the Runner's own peer when a third knock lands.
	if not _from_server():
		return
	health.stun(duration)

@rpc("any_peer", "call_local", "reliable")
func attack_confirmed() -> void:
	# Called by the server on the Runner's own peer when a kill actually lands.
	if not _from_server():
		return
	combat.start_attack_cd()

@rpc("any_peer", "call_local", "reliable")
func knockback(vx: float) -> void:
	# Called by the server on the Runner's own peer for every knock that lands:
	# shove it the way the Hunter is facing, off whatever it was breaking.
	if not _from_server():
		return
	velocity.x = vx
	velocity.y = minf(velocity.y, KNOCK_HOP)
	# Brief loss of control so the shove actually reads. Without it the next
	# movement.tick() would steer velocity.x straight back to whatever the Runner
	# is holding and the hit would look like nothing happened.
	combat.stagger(KNOCK_STAGGER)
