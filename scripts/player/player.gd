extends CharacterBody2D

## Networked player body. This is a thin orchestrator: it holds the replicated
## state and calls its components (Movement / Combat / Health / Animator /
## Effects) in a fixed order each physics frame. Only the owning peer runs
## input/physics; position and a bit of state are replicated to everyone else.
##
## Roles: Runner (the monster) collects items and escapes; can slide tunnels and
## melee. Hunter (the researcher) walks only and captures via the mash-off.

@onready var sprite: AnimatedSprite2D = $SpritePivot/AnimatedSprite2D
@onready var carry_sprite: Sprite2D = $CarrySprite
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
var capturable: bool = false     # Runner: currently vulnerable to a grab
var dead: bool = false           # Hunter: killed, waiting to respawn
var fainted: bool = false        # Hunter: dazed after a Runner escaped its grip

# Set at spawn (world.gd); Hunters respawn here.
var spawn_point: Vector2 = Vector2.ZERO

# The GameManager (server-authoritative match/grapple state), found once.
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
	# The Runner shows the key it's ferrying (replicated carry state, every peer).
	carry_sprite.visible = role == Roles.RUNNER and gm != null and gm.carrying()

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return

	health.tick(delta)
	if dead:
		movement.freeze()
		animator.publish(delta)
		return

	# Dazed after a Runner broke our grip: hold still, no moving or grabbing.
	if fainted:
		combat.grappling = false   # drop the grapple pose so the faint anim shows
		movement.freeze()
		animator.publish(delta)
		return

	# Mid-pounce: custom airborne physics (leap toward the Runner, snag on contact).
	if combat.pouncing:
		combat.pounce_step(delta)
		animator.publish(delta)
		return

	# Paused (local pause menu open): hold still but stay replicated.
	if Net.local_input_locked:
		movement.freeze()
		animator.publish(delta)
		return

	movement.update_tunnel(delta)
	var grappling := combat.update_grapple()
	combat.tick_stiff(delta)
	var immobile := grappling or combat.stiff_active() or movement.exit_stun_active()

	movement.tick(delta, not immobile)
	effects.camera_juice(delta)   # lookahead + landing shake: real velocity, owner only

	if role == Roles.RUNNER:
		# Carrying a key is the Runner's main exposed window (GDD 4.1); the tunnel
		# exit and standing still stay as minor windows.
		capturable = (gm != null and gm.carrying()) or movement.exit_stun_active() or movement.is_slow()

	combat.apply_snap(delta)
	combat.handle_input(delta)
	animator.publish(delta)

@rpc("any_peer", "reliable")
func kill() -> void:
	# Called by the server on the hit Hunter's own peer.
	health.kill()

@rpc("any_peer", "reliable")
func faint(duration: float) -> void:
	# Called by the server on a grabbing Hunter's own peer after a Runner escapes.
	health.faint(duration)
