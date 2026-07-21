extends CharacterBody2D

## Networked player body. This is a thin orchestrator: it holds the replicated
## state and calls its components (Movement / Combat / Health / Animator /
## Effects) in a fixed order each physics frame. Only the owning peer runs
## input/physics; position and a bit of state are replicated to everyone else.
##
## Roles: Runner (the monster) breaks the facility and escapes; can slide tunnels
## and kill. Hunter (the researcher) walks only and knocks the Runner to stun it.

const PIPE_PEEK_CAM := 120.0  # how far the camera leans outside the current pipe end (peek)
const POP_OUT_SPEED := 200.0  # outward burst when popping out of a tunnel
const POP_UP_SPEED := -260.0  # upward hop on pop -> drives the jump squash + dust on every peer
const STUN_DRAG := 900.0     # how fast a stunned Runner's knockback slide bleeds off
const KNOCK_HOP := -90.0     # small pop on a knock so the kick reads as a hit, not a nudge
const KNOCK_STAGGER := 0.38  # Runner: no steering right after a knock, so the shove lands

@onready var sprite: AnimatedSprite2D = $SpritePivot/AnimatedSprite2D
@onready var camera: Camera2D = $Camera2D
@onready var movement: PlayerMovement = $Movement
@onready var combat: PlayerCombat = $Combat
@onready var health: PlayerHealth = $Health
@onready var animator: PlayerAnimator = $Animator
@onready var effects: PlayerEffects = $Effects

# Replicated state (the MultiplayerSynchronizer references these on this node).
# Position replicates as net_pos (not .position) so the receiving side can
# buffer + interpolate instead of snapping — see net_interp.gd for why.
var net_pos: Vector2:
	set(value):
		net_pos = value
		# Pre-tree writes happen while world._spawn_player builds the node (which
		# also sets .position directly, so placement is covered) — and authority
		# can't even be queried outside the tree.
		if not is_inside_tree() or is_multiplayer_authority():
			return
		interp.push(value)
var role: String = Roles.HUNTER
var net_anim: String = Anim.IDLE
var net_flip: bool = false
var dead: bool = false           # Hunter: killed, waiting to respawn
var stunned: bool = false        # Runner: stunned by a third knock (GDD 4.6)
var riding: bool = false         # Hunter: locked in an elevator ride (GDD 4.5)

# Set at spawn (world.gd); Hunters respawn here.
var spawn_point: Vector2 = Vector2.ZERO

# Elevator ride interpolation (owner only, while riding == true).
var _ride_start_pos: Vector2
var _ride_end_pos: Vector2
var _ride_timer: float = 0.0

# Wall-tunnel travel (owner only, while tunneling == true). Entering whisks the
# Runner straight to the far end; from an end they peek outside (camera leans
# out) and either tap outward to emerge or tap inward to shuttle to the other end.
var tunneling: bool = false
var _tunnel_a: Vector2        # entry mouth (emerge point on the entry side)
var _tunnel_b: Vector2        # far mouth (emerge point on the far side)
var _tunnel_a_in: Vector2     # peek spot just inside the entry end
var _tunnel_b_in: Vector2     # peek spot just inside the far end
var _tunnel_fwd: float = 0.0  # world x-sign pointing from entry toward far
var _tunnel_at_b: bool = true # which end they're currently peeking out of

# The GameManager (server-authoritative match state), found once.
var gm: Node

# Interpolation buffer for this body when it is a REMOTE player (non-authority).
# Public: lag compensation reads interp.interp_delay_ms (player_combat.gd).
var interp := NetInterp.new()

func _ready() -> void:
	camera.enabled = is_multiplayer_authority()
	if is_multiplayer_authority():
		camera.make_current()
		camera.reset_smoothing()
	_apply_sync_rate()
	Net.transport_changed.connect(_apply_sync_rate)
	gm = get_tree().get_first_node_in_group("game_manager")

## Replication rate by transport. The default (interval 0) sends every physics
## tick, which floods the relay and queues packets. LAN / P2P links can afford
## ~33 Hz; the relay path keeps the proven 22 Hz. The receive-side interp delay
## is derived from the same interval so a rate change retunes both ends.
func _apply_sync_rate() -> void:
	var iv := 0.045 if Net.transport_kind() == "RELAY" else 0.03
	$Sync.replication_interval = iv
	$Sync.delta_interval = iv
	interp.set_send_interval(iv)

func _process(delta: float) -> void:
	if not is_multiplayer_authority():
		# Remote body: draw it interp_delay in the past, between known samples.
		var target = interp.sample(float(Time.get_ticks_msec()))
		if target != null:
			global_position = target
	animator.render()
	effects.render(delta)   # squash/stretch + dust: every peer, keyed off net_anim/net_flip

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return
	net_pos = global_position   # publish for remote peers (sampled by $Sync)

	health.tick(delta)
	if dead:
		movement.freeze()
		animator.publish(delta)
		return

	if riding:
		_ride_timer += delta
		var t: float = clampf(_ride_timer / ElevatorSystem.RIDE_TIME, 0.0, 1.0)
		t = t * t * (3.0 - 2.0 * t)
		global_position = _ride_start_pos.lerp(_ride_end_pos, t)
		velocity = Vector2.ZERO
		animator.publish(delta)
		return

	# Inside a wall-tunnel, peeking out one end (the camera leans outside so the
	# Runner can scout before committing). A directional tap decides: outward
	# (away from the pipe) emerges here; inward shuttles instantly to the other
	# end to peek there. Emerging is noisy.
	if tunneling:
		velocity = Vector2.ZERO
		var out_dir := _tunnel_fwd if _tunnel_at_b else -_tunnel_fwd
		var inside: Vector2 = _tunnel_b_in if _tunnel_at_b else _tunnel_a_in
		var mouth: Vector2 = _tunnel_b if _tunnel_at_b else _tunnel_a
		var tap := 0.0
		if not Net.local_input_locked:
			if Input.is_action_just_pressed("move_right"):
				tap = 1.0
			elif Input.is_action_just_pressed("move_left"):
				tap = -1.0
		if tap != 0.0 and tap == out_dir:
			# Push outward from this end -> pop out of the pipe: a burst up-and-out
			# so the Runner is visibly ejected. The upward hop makes the animator
			# enter JUMP, which drives the jump squash + dust puff on every peer.
			global_position = mouth
			velocity = Vector2(out_dir * POP_OUT_SPEED, POP_UP_SPEED)
			net_pos = mouth
			tunneling = false
			sprite.visible = true        # show the character again once out of the pipe
			camera.offset = Vector2.ZERO
			if gm != null:
				gm.emit_sound(mouth)
			animator.publish(delta)
			return
		if tap != 0.0:
			# Push inward -> shuttle to the other end (instant) and peek there.
			_tunnel_at_b = not _tunnel_at_b
			out_dir = _tunnel_fwd if _tunnel_at_b else -_tunnel_fwd
			inside = _tunnel_b_in if _tunnel_at_b else _tunnel_a_in
		# Held inside the pipe, peeking out the current end.
		global_position = inside
		net_pos = inside
		camera.offset = Vector2(out_dir * PIPE_PEEK_CAM, 0.0)
		animator.force_pose(Anim.CROUCH, out_dir < 0.0)
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

	# Enter a wall-tunnel: press slide at a mouth to slip inside and hold there
	# (see the `tunneling` block above for how they leave). Consumes the press so
	# it wins over the crouch/slide the same key starts, and is noisy like other
	# Runner acts (GDD 4.3). Blocked while stiff/exit-stunned.
	if role == Roles.RUNNER and gm != null and Input.is_action_just_pressed("slide") \
			and not combat.stiff_active() and not movement.exit_stun_active():
		var t = gm.tunnel_enter_at(global_position)
		if t != null:
			_tunnel_a = t["entry"]
			_tunnel_b = t["far"]
			_tunnel_a_in = t["entry_in"]
			_tunnel_b_in = t["far_in"]
			_tunnel_fwd = signf(_tunnel_b.x - _tunnel_a.x)
			_tunnel_at_b = true          # whisk them to the far end, held inside, peeking out
			tunneling = true
			sprite.visible = false       # hide the character while it's inside the pipe
			velocity = Vector2.ZERO
			global_position = _tunnel_b_in
			net_pos = global_position
			gm.emit_sound(_tunnel_b_in)  # noisy: they rush through to the far side
			animator.force_pose(Anim.CROUCH, _tunnel_fwd < 0.0)
			return

	movement.update_tunnel(delta)
	combat.tick_stiff(delta)

	if combat.stagger_active():
		velocity.y += get_gravity().y * delta
		velocity.x = move_toward(velocity.x, 0.0, STUN_DRAG * delta)
		move_and_slide()
		animator.publish(delta)
		return

	var immobile := combat.stiff_active() or movement.exit_stun_active()

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

@rpc("any_peer", "call_local", "reliable")
func ride_start(start_pos: Vector2, end_pos: Vector2) -> void:
	if not _from_server():
		return
	riding = true
	_ride_start_pos = start_pos
	_ride_end_pos = end_pos
	_ride_timer = 0.0
	velocity = Vector2.ZERO

@rpc("any_peer", "call_local", "reliable")
func ride_end(final_pos: Vector2) -> void:
	if not _from_server():
		return
	riding = false
	global_position = final_pos
	velocity = Vector2.ZERO
