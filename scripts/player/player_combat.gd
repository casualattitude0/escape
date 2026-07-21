extends Node
class_name PlayerCombat

## Routes the shared "attack" key to the GameManager and owns this player's local
## recovery lockout. All the state that matters (knock count, iframes, stun) lives
## on the server; this component only forwards taps and predicts well enough to
## pick a recovery length and play an animation on the same frame as the press.
##
## Hunter: F is a single knock swing. There is no charge, no grab, no pounce — the
## Hunter's only verb is the knock (GDD 4.6), and it has to walk into range to use
## it. Range and cadence are re-tested on the server; the client's own check only
## decides whether this swing whiffs and eats the longer stiff.
##
## Runner: F kills a Hunter in front of it. Hunters respawn forever, so a kill buys
## seconds and a walk-back, not a removed opponent (GDD 4.6).

const KNOCK_HIT_STIFF := 0.18     # brief hold on a connecting knock
const KNOCK_WHIFF_STIFF := 0.45   # longer recovery when the swing hits nothing

# A kill does not have to out-last PlayerHealth.RESPAWN_TIME (3.0): what actually
# stops the Runner re-killing a Hunter is that the Hunter respawns across the map
# and has to walk back (world.gd HUNTER_SPAWNS). The cooldown is only there to stop
# it deleting a whole group on the spot before they can form a pincer.
const ATTACK_CD := 2.5            # Runner: seconds between kills
# Deliberately close to KnockSystem.KNOCK_RANGE (64): with the bodies' 13px capsule
# radius, two players standing together are ~26px apart, so a short reach turns
# into "the kill never connects" once replication lag is in play. The monster is
# meant to be the stronger duellist (GDD 4.6), so it should not be out-ranged.
const KILL_RANGE := 56.0          # Runner: reach of the kill swing

enum Mode { ATTACK, BREAK }

@onready var body: CharacterBody2D = get_parent()

var _runner_ref: Node
var _stiff_left: float = 0.0      # Hunter: swing/miss recovery — gates re-swings, not movement
var _stagger_left: float = 0.0    # Runner: knocked, riding the shove, no steering
var _attack_cd_left: float = 0.0  # Runner: local mirror of the server's cooldown
var mode: int = Mode.ATTACK       # Runner: default attack; F near device enters break

## True while this player is locked in a swing or its recovery.
func stiff_active() -> bool:
	return _stiff_left > 0.0

## True while a knock's shove is still carrying this player.
func stagger_active() -> bool:
	return _stagger_left > 0.0

## Called on the Runner's own peer when a knock lands (see player.knockback).
func stagger(duration: float) -> void:
	_stagger_left = maxf(_stagger_left, duration)

func tick_stiff(delta: float) -> void:
	if _stiff_left > 0.0:
		_stiff_left -= delta
	if _stagger_left > 0.0:
		_stagger_left -= delta
	if _attack_cd_left > 0.0:
		_attack_cd_left -= delta

## Runner: true while the kill is still recharging (drives the HUD prompt).
func attack_ready() -> bool:
	return _attack_cd_left <= 0.0

func handle_input(_delta: float) -> void:
	var gm: Node = body.gm
	if gm == null:
		return
	if body.role == Roles.HUNTER:
		_hunter_input(gm)
	else:
		_runner_input(gm)

## Runner F key: context-sensitive on whether it is carrying a 破壞媒材 (GDD 4.1).
## Empty-handed: F grabs a medium if standing on one, otherwise swings a kill.
## Carrying: F at a device enters/continues break mode (mashing); it CANNOT kill
## while carrying (GDD 4.6). Any move key exits break mode. All of these are
## re-checked on the server; the client's own tests only skip pointless rpcs.
func _runner_input(gm: Node) -> void:
	if mode == Mode.BREAK:
		var dir := Input.get_axis("move_left", "move_right")
		if dir != 0.0 or Input.is_action_just_pressed("jump"):
			mode = Mode.ATTACK
			return
		if not Input.is_action_just_pressed("attack"):
			return
		# The medium is gone (spent on the break, or dropped): nothing to mash.
		if not gm.runner_carrying():
			mode = Mode.ATTACK
			return
		if not _device_in_range(gm):
			mode = Mode.ATTACK
			return
		if _zone_locked(gm):
			return
		body.animator.sabotage()
		gm.sabotage_press.rpc_id(1)
		return

	if not Input.is_action_just_pressed("attack"):
		return
	if gm.runner_carrying():
		# Hands full: break the device it is standing at; no kill (GDD 4.6).
		if _device_in_range(gm) and not _zone_locked(gm):
			mode = Mode.BREAK
			body.animator.sabotage()
			gm.sabotage_press.rpc_id(1)
		return
	# Empty-handed: grab a medium if one is here, else swing a kill.
	if _media_in_range(gm):
		gm.pickup_press.rpc_id(1)
		return
	if _attack_cd_left > 0.0:
		return
	body.animator.attack()
	_attack_cd_left = ATTACK_CD
	if _find_target_hunter(gm) != null:
		gm.attack_press.rpc_id(1)

## Client-side lockdown check. The server re-checks authoritatively.
func _zone_locked(gm: Node) -> bool:
	return gm.zone_locked_at(body.global_position)

## Is an unbroken device close enough to work on? Prediction only — the server
## re-derives which device (if any) from real overlaps.
func _device_in_range(gm: Node) -> bool:
	for d in gm.devices_root().get_children():
		if gm.device_done(d.index):
			continue
		if body.global_position.distance_to(d.global_position) <= DeviceSystem.DEVICE_RANGE:
			return true
	return false

## Is an available medium close enough to grab? Prediction only — the server
## re-derives it from real overlap. Reads the medium's authoritative resting spot
## rather than the node's rendered position, so it doesn't race the item's render.
func _media_in_range(gm: Node) -> bool:
	var root: Node = gm.media_root()
	if root == null:
		return false
	for m in root.get_children():
		if not gm.media_available(int(m.index)):
			continue
		if body.global_position.distance_to(gm.media_pos(int(m.index))) <= MediaItem.PICKUP_RANGE:
			return true
	return false

## Nearest living Hunter within reach and on the side we are facing. Prediction
## only — the server runs the same test and its answer is the one that counts.
func _find_target_hunter(gm: Node) -> Node2D:
	var facing := -1.0 if body.sprite.flip_h else 1.0
	var best: Node2D = null
	var best_d := INF
	for c in gm.players().get_children():
		if c.get("role") != Roles.HUNTER or c.get("dead"):
			continue
		var to: Vector2 = c.global_position - body.global_position
		if signf(to.x) != facing and absf(to.x) > 4.0:
			continue                 # behind us (the epsilon keeps point-blank working)
		var d := to.length()
		if d <= KILL_RANGE and d < best_d:
			best_d = d
			best = c
	return best

## Hunter F: one knock per press. Play the swing locally right away so the tap
## feels immediate, forward it, and lock into a recovery.
func _hunter_input(gm: Node) -> void:
	if body.dead:
		return
	if body.riding:
		return
	if Input.is_action_just_pressed("report"):
		gm.report_press.rpc_id(1)
		return
	if Input.is_action_just_pressed("elevator"):
		gm.elevator_press.rpc_id(1)
		return
	# Shift at a vertical shaft mouth rides to the other end (Hunter-only; the
	# server validates position). Slide is otherwise unused by the Hunter.
	if Input.is_action_just_pressed("slide"):
		gm.shaft_press.rpc_id(1)
		return
	if _stiff_left > 0.0:
		return
	if not Input.is_action_just_pressed("attack"):
		return
	body.animator.knock()
	gm.hunter_press.rpc_id(1, _render_host_time(gm))
	_stiff_left = KNOCK_HIT_STIFF if _knock_would_hit(gm) else KNOCK_WHIFF_STIFF

## Host-clock timestamp of the Runner state this player is RENDERING right now,
## sent with the knock so the server can rewind its range test to it (lag
## compensation, game_manager.hunter_press). What we render is interp_delay in
## the past of the sample stream, and each sample took ~rtt/2 to reach us — so
## walk back both from our host-aligned clock. On a hosting player everything
## degrades to ~now (offset 0, rtt 0, and a remote runner's real interp delay).
func _render_host_time(gm: Node) -> int:
	var r := _find_runner(gm)
	var delay: float = r.interp.interp_delay_ms if r != null else 0.0
	return int(Time.get_ticks_msec() + Net.stats.host_time_offset
		- delay - Net.stats.rtt(1) * 0.5)

## Server confirmed a kill: start the local cooldown mirror. Driven from the
## server rather than from the press so a rejected swing never costs the Runner.
func start_attack_cd() -> void:
	_attack_cd_left = ATTACK_CD

## Client-side prediction of the server's range test, used only to choose the
## recovery length. The server decides whether the knock actually lands.
func _knock_would_hit(gm: Node) -> bool:
	var r := _find_runner(gm)
	return r != null \
		and body.global_position.distance_to(r.global_position) <= KnockSystem.KNOCK_RANGE

func _find_runner(gm: Node) -> Node2D:
	if _runner_ref != null and is_instance_valid(_runner_ref):
		return _runner_ref
	for c in gm.players().get_children():
		if c.get("role") == Roles.RUNNER:
			_runner_ref = c
			return c
	return null
