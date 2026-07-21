extends Node
class_name GameManager

## Server-authoritative match coordinator and the rpc facade the rest of the
## game talks to. Runs its logic only on the host (peer 1). It owns the winner,
## the match clock, and the replication, delegating details to its children:
##   * $DeviceSystem — sabotage progress (GDD 4.1)
##   * $KnockSystem  — the knock-to-stun state (GDD 4.6)
## Players, devices and the escape point reach this node via the "game_manager"
## group and call its facade methods / rpcs; they never touch the subsystems.
##
## Win conditions (GDD 3):
##   * Runner breaks every device, then reaches the escape point.
##   * Hunters win by running out the MATCH_TIME clock. Stunning the Runner is
##     NOT a win — it burns the Runner's clock and buys the Hunters time. They
##     cannot kill it at all; delay is the whole offence.

signal state_changed
# Fired on every peer when the Runner makes a noise (GDD 4.3). `heard_near` is
# true for the LOCAL player when it is a Hunter close enough to the noise to get
# a vision-clarity boost; false means the noise instead surfaces as a minimap
# ping. The Runner peer ignores it (no Hunter UI).
signal sound_heard(world_pos: Vector2, heard_near: bool)
# Fired on every peer when a Hunter reports the Runner and a zone locks.
signal zone_reported(zone_name: String)

const MATCH_TIME := 300.0         # seconds; Hunters win when it hits 0 (GDD 3)
# Mashing is noisy, but a ping per tap would be a siren. Fire one every few
# accepted hits instead: ~4 tells per device. Counted in hits, not in fractions
# of progress, so there is no float boundary to land wrong side of.
const SOUND_EVERY_HITS := 3

var sound_near_radius := 540.0   # Hunters within this of a noise see clearly;
								 # farther ones only get a minimap ping

var winner := ""                 # "", Roles.WIN_RUNNER, Roles.WIN_HUNTERS
var time_left := MATCH_TIME

@onready var devices: DeviceSystem = $DeviceSystem
@onready var knock: KnockSystem = $KnockSystem
@onready var zones: ZoneSystem = $ZoneSystem
@onready var elevators: ElevatorSystem = $ElevatorSystem
# The Runner's horizontal fast-travel. Built in code (no scene node) so levels
# only need the "Tunnel" TileMapLayer, nothing wired per-instance.
var tunnels := TunnelSystem.new()
@onready var _players: Node = get_node("../Players")
@onready var _devices_root: Node = get_node("../Devices")
@onready var _escape_root: Node = get_node("../Escape")
@onready var _elevators_root: Node = get_node("../Elevators")
@onready var _terrain: TileMapLayer = get_node("../Terrain")

# Lag compensation: how far back hunter_press may rewind the Runner. Bounds the
# cheat surface (a doctored timestamp can never claim more than this) while
# still covering interp delay + a bad ping.
const LAGCOMP_MAX_REWIND_MS := 300

# Host-only recent-position history, fed each physics tick (see pos_history.gd).
var pos_history := PosHistory.new()

var _sync_accum := 0.0           # cadence for periodic (clock) fast syncs
var _last_sound_slice := {}      # device index -> last progress slice that made noise
# Server's copy of the Runner's kill cooldown. Ticked off physics delta rather
# than wall clock so it obeys the same clock as everything else here, and held on
# the server so a client cannot shorten it. There is only ever one Runner.
var _attack_cd_left := 0.0

func _ready() -> void:
	add_to_group("game_manager")
	elevators.setup(_elevators_root, _players)
	add_child(tunnels)
	tunnels.setup(get_node_or_null("../Tunnel") as TileMapLayer, _terrain)
	set_physics_process(multiplayer.is_server())

# ---- read facade (HUD / players / devices / escape) ------------------------

func players() -> Node:
	return _players

func devices_root() -> Node:
	return _devices_root

func escape_root() -> Node:
	return _escape_root

func device_total() -> int:
	return DeviceSystem.DEVICE_COUNT

func device_ratio(idx: int) -> float:
	return devices.ratio(idx)

func device_done(idx: int) -> bool:
	return devices.done(idx)

func devices_destroyed() -> int:
	return devices.destroyed_count()

func escape_open() -> bool:
	return devices.all_destroyed()

## Progress of the device the Runner is working on right now, or -1 when it is
## not mashing anything (the HUD hides the bar rather than showing a stale one).
func active_device_ratio() -> float:
	return devices.ratio(devices.active_index) if devices.active_index >= 0 else -1.0

func time_ratio() -> float:
	return time_left / MATCH_TIME

func time_seconds() -> int:
	return int(ceil(time_left))

func knock_count() -> int:
	return knock.knocks

func knock_ratio() -> float:
	return knock.knock_ratio()

func runner_stunned() -> bool:
	return knock.stunned()

func runner_iframe() -> bool:
	return knock.invulnerable()

# ---- report / lockdown (GDD 4.3) ------------------------------------------

## A Hunter reports the Runner. Server validates that the Hunter can actually see
## the Runner (fog-clear radius, not just proximity), then locks the zone the
## Runner occupies and broadcasts a minimap ping to all Hunters.
@rpc("any_peer", "call_local", "reliable")
func report_press() -> void:
	if not multiplayer.is_server() or winner != "":
		return
	var id := _sender_id()
	var h: Node2D = _players.get_node_or_null(str(id))
	if h == null or h.dead or h.get("role") != Roles.HUNTER:
		return
	var runner := _find_runner()
	if runner == null:
		return
	# Visibility check: the Runner must be inside this Hunter's fog-clear radius.
	# Reuses the same distance the fog shader uses for the spotting mechanic.
	if not _hunter_can_see_runner(h, runner):
		return
	var z := zones.try_lockdown(runner.global_position)
	if z == "":
		return
	_report_broadcast.rpc(z)
	_broadcast(true)

## True when the Runner is inside the Hunter's effective vision radius. On the
## server we use the base radius (not the widened "wild" radius the client sees),
## so a Hunter cannot report from further away just because their fog is swelling.
func _hunter_can_see_runner(h: Node2D, runner: Node2D) -> bool:
	return h.global_position.distance_to(runner.global_position) <= Fog.BASE_RADIUS

@rpc("authority", "call_local", "reliable")
func _report_broadcast(zone_name: String) -> void:
	zone_reported.emit(zone_name)

## Read facade: is the zone at `pos` currently locked?
func zone_locked_at(pos: Vector2) -> bool:
	return zones.is_locked(pos)

## Read facade: lockdown seconds remaining for the zone containing `pos`.
func zone_lockdown_left(pos: Vector2) -> float:
	var z := zones.zone_at(pos)
	if z == "":
		return 0.0
	return zones.lockdown.get(z, 0.0)

## Read facade: full zone data for minimap/HUD.
func zone_data() -> ZoneSystem:
	return zones

# ---- elevators (GDD 4.5) --------------------------------------------------

## A Hunter requests an elevator ride. Server validates, starts the ride, and
## tells the requesting peer to animate locally.
@rpc("any_peer", "call_local", "reliable")
func elevator_press() -> void:
	if not multiplayer.is_server() or winner != "":
		return
	var id := _sender_id()
	var h: Node2D = _players.get_node_or_null(str(id))
	if h == null or h.dead or h.get("role") != Roles.HUNTER:
		return
	if h.stunned or h.get("riding"):
		return
	if not elevators.try_ride(h):
		return
	var ride: Dictionary = elevators._riding[id]
	h.ride_start.rpc_id(id, ride["start_pos"], ride["end_pos"])
	emit_sound(h.global_position)

## Read facade: is this peer currently riding an elevator?
func is_riding(peer_id: int) -> bool:
	return elevators.is_riding(peer_id)

# ---- tunnels (Runner horizontal fast-travel) ------------------------------

## If a Runner at `pos` is standing at a tunnel mouth, the entry/far mouths to
## hold them between; else null. The Runner is the host, so the body queries this
## directly (no rpc) — see player._physics_process.
func tunnel_enter_at(pos: Vector2):
	return tunnels.enter_at(pos)

# ---- sabotage (GDD 4.1) ---------------------------------------------------

## The Runner mashed at a device. Which device is the SERVER's call: we ask the
## device nodes who the Runner is actually standing in, rather than trusting an
## index off the wire, so a hacked client cannot break a device from across the
## map. The client's own range check is only there to skip pointless rpcs.
##
## "call_local" is REQUIRED, not decoration: the Runner is the host, so this
## rpc_id(1) targets the caller itself, and Godot refuses a self-call unless the
## rpc is declared call_local ("RPC on yourself is not allowed by selected mode").
## Without it the Runner could not sabotage or kill at all. It costs nothing when
## a client calls it — the local run just fails the is_server() check above.
@rpc("any_peer", "call_local", "reliable")
func sabotage_press() -> void:
	if not multiplayer.is_server() or winner != "":
		return
	var id := _sender_id()
	var runner: Node2D = _players.get_node_or_null(str(id))
	if runner == null or runner.get("role") != Roles.RUNNER or runner.stunned:
		return
	var idx := _device_at_runner()
	if idx < 0:
		return
	# Zone lockdown blocks sabotage (GDD 4.3): the device is still there, but
	# the Runner cannot progress on it while the zone is locked.
	var device_node: Node2D = _devices_root.get_node_or_null("Device%d" % idx)
	if device_node != null and zones.is_locked(device_node.global_position):
		return
	var finished := devices.hit(idx)
	_emit_sabotage_sound(idx, runner)
	if finished:
		_on_device_done()
	else:
		_broadcast(true)

## Index of an unbroken device the Runner is standing in, or -1.
func _device_at_runner() -> int:
	for d in _devices_root.get_children():
		if d.runner_in_range():
			return d.index
	return -1

## One noise every SOUND_EVERY_HITS mashes, not one per tap.
func _emit_sabotage_sound(idx: int, runner: Node2D) -> void:
	var slice := devices.hits(idx) / SOUND_EVERY_HITS
	if slice == int(_last_sound_slice.get(idx, -1)):
		return
	_last_sound_slice[idx] = slice
	emit_sound(runner.global_position)

## A device just broke. If that was the last one the way out opens — and it can
## open while the Runner is ALREADY standing in it (it broke the device next to
## the exit), which body_entered will never report, so check the overlap here.
func _on_device_done() -> void:
	_broadcast(true)
	if not devices.all_destroyed():
		return
	for e in _escape_root.get_children():
		if e.runner_inside():
			_set_winner(Roles.WIN_RUNNER)
			return

## The Runner reached the escape point (called by EscapePoint on the server).
func try_escape() -> void:
	if not multiplayer.is_server() or winner != "":
		return
	if not devices.all_destroyed():
		return          # still work to do; the way out is shut
	_set_winner(Roles.WIN_RUNNER)

# ---- sound exposure (GDD 4.3) --------------------------------------------

## Called on the server when the Runner does something noisy (slides a tunnel,
## mashes a device, kills someone, ...). Splits Hunters into "near" (get a
## vision-clarity boost) and "far" (get a minimap ping), then relays to every peer.
func emit_sound(world_pos: Vector2) -> void:
	if not multiplayer.is_server() or winner != "":
		return
	var near_ids: Array = []
	for c in _players.get_children():
		if c.get("role") != Roles.HUNTER or c.dead:
			continue
		if c.global_position.distance_to(world_pos) <= sound_near_radius:
			near_ids.append(c.name.to_int())
	_sound.rpc(world_pos, near_ids)

@rpc("authority", "call_local", "reliable")
func _sound(world_pos: Vector2, near_ids: Array) -> void:
	sound_heard.emit(world_pos, near_ids.has(multiplayer.get_unique_id()))

# ---- knock input (Hunters tap "attack") -----------------------------------

## One Hunter swung at the Runner. Every gate here is the server's call — the
## client's own range test (player_combat) is only prediction.
## call_local so this still works if a Hunter ever hosts — see sabotage_press.
##
## `render_host_time` is the host-clock timestamp of the Runner state the Hunter
## was RENDERING when it pressed (see player_combat._render_host_time). The range
## test rewinds the Runner to that moment (lag compensation): the Hunter aims at
## what it sees, and what it sees is interp_delay + transit in the past — judging
## against the Runner's *current* position makes every knock on a moving Runner
## whiff for remote players. 0 (or an out-of-window value) degrades to the plain
## current-position test. Only position rewinds; iframe/stun pacing stays on the
## server's current state so compensation can never squeeze extra knocks in.
@rpc("any_peer", "call_local", "reliable")
func hunter_press(render_host_time: int = 0) -> void:
	if not multiplayer.is_server() or winner != "":
		return
	var id := _sender_id()
	var h: Node2D = _players.get_node_or_null(str(id))
	var runner := _find_runner()
	if h == null or h.dead or runner == null:
		return
	if h.get("role") != Roles.HUNTER:
		return
	var runner_pos: Vector2 = runner.global_position
	if render_host_time > 0:
		var now := Time.get_ticks_msec()
		var rewind_to := clampi(render_host_time, now - LAGCOMP_MAX_REWIND_MS, now)
		var past := pos_history.sample(runner.name.to_int(), float(rewind_to))
		if not past.is_empty():
			runner_pos = past["pos"]
	if not _in_range(h, runner_pos):
		return
	if not knock.can_knock():
		return          # inside an iframe, or already stunned
	_knock_back(h, runner)
	if knock.add_knock():
		_on_stun()
	else:
		# Every knock moves the count, which both roles can see — always reliable.
		_broadcast(true)

# ---- kill input (the Runner taps "attack") --------------------------------

## The Runner swung at a Hunter. A kill buys the Runner time and a lane, not a
## removed opponent — Hunters respawn forever (GDD 4.6).
## call_local is required — see sabotage_press.
##
## No lag compensation here, deliberately: the Runner IS the host, so there is no
## network delay on its press, and the Hunters' global_position on the host is
## the interpolated value the Runner was rendering — _kill_target already tests
## exactly what the Runner saw. (If a Hunter ever hosts, the symmetric case is
## covered by hunter_press's rewind.)
@rpc("any_peer", "call_local", "reliable")
func attack_press() -> void:
	if not multiplayer.is_server() or winner != "":
		return
	var id := _sender_id()
	var runner: Node2D = _players.get_node_or_null(str(id))
	if runner == null or runner.get("role") != Roles.RUNNER:
		return
	if runner.stunned or _attack_cd_left > 0.0:
		return
	var victim := _kill_target(runner)
	if victim == null:
		return          # swung at nothing: no kill, and no cooldown burned
	_attack_cd_left = PlayerCombat.ATTACK_CD
	victim.kill.rpc_id(victim.get_multiplayer_authority())
	# Tell the Runner's own peer to start its cooldown mirror. Only a landed kill
	# does this, so a whiff never costs the Runner its anti-pincer tool.
	runner.attack_confirmed.rpc_id(id)
	emit_sound(runner.global_position)
	_broadcast(true)

## Nearest living Hunter inside the Runner's reach and on the side it faces.
## `net_flip` is replicated, so the server can read the Runner's facing directly
## rather than trusting the client to report it.
func _kill_target(runner: Node2D) -> Node2D:
	var facing := -1.0 if runner.net_flip else 1.0
	var best: Node2D = null
	var best_d := INF
	for c in _players.get_children():
		if c.get("role") != Roles.HUNTER or c.dead:
			continue
		var to: Vector2 = c.global_position - runner.global_position
		if signf(to.x) != facing and absf(to.x) > 4.0:
			continue
		var d := to.length()
		if d <= PlayerCombat.KILL_RANGE and d < best_d:
			best_d = d
			best = c
	return best

## Shove the Runner along the direction the KNOCKER IS FACING. GDD 4.3 wants a
## knock to physically kick the Runner off what it was breaking, and taking the
## direction from the Hunter's facing (rather than from who is left of whom) makes
## that a thing the Hunter aims: line up the side you want it driven towards. It
## also stays stable when the two are practically on top of each other, where the
## relative-position sign flips back and forth frame to frame.
##
## `net_flip` is replicated, so the server reads the Hunter's real facing instead
## of trusting the client to report it.
func _knock_back(h: Node2D, runner: Node2D) -> void:
	var dir := -1.0 if h.net_flip else 1.0
	runner.knockback.rpc_id(
		runner.get_multiplayer_authority(), dir * KnockSystem.KNOCKBACK_VX)

## Third knock landed: stun the Runner and knock back whatever it was breaking.
## The rollback is the real cost — the stun alone is just seconds.
func _on_stun() -> void:
	var runner := _find_runner()
	devices.on_runner_stunned()
	if runner != null:
		# Run the stun on the Runner's OWN peer. The old code wrote the Runner's
		# stun timer directly on the host because "host == Runner" — which silently
		# stopped working the moment a Hunter hosted.
		runner.stun.rpc_id(runner.get_multiplayer_authority(), KnockSystem.STUN_TIME)
	_broadcast(true)

# ---- per-frame upkeep -----------------------------------------------------

func _physics_process(delta: float) -> void:
	if winner != "":
		return
	# Feed the lag-comp history (server only — physics is off elsewhere). Note
	# that remote players' global_position here is the interpolated (rendered)
	# value, which is exactly the timeline hunter_press rewinds within.
	var now_ms := float(Time.get_ticks_msec())
	for c in _players.get_children():
		pos_history.record(c.name.to_int(), now_ms, c.global_position,
			bool(c.get("dead")), bool(c.get("stunned")))
	# Match clock: Hunters win if it runs out (GDD 3).
	time_left = maxf(0.0, time_left - delta)
	if time_left <= 0.0:
		_set_winner(Roles.WIN_HUNTERS)
		return
	if _attack_cd_left > 0.0:
		_attack_cd_left -= delta
	if devices.active_index >= 0 and _device_at_runner() < 0:
		devices.active_index = -1
		_broadcast(false)
	if knock.tick(delta):
		_broadcast(false)
	if zones.tick(delta):
		_broadcast(false)
	var arrived := elevators.tick(delta)
	for ride in arrived:
		var h: Node2D = _players.get_node_or_null(str(ride["pid"]))
		if h != null:
			h.ride_end.rpc_id(ride["pid"], ride["end_pos"])
	# Keep the clock (and any drift) in sync a couple times a second.
	_sync_accum += delta
	if _sync_accum >= 0.5:
		_sync_accum = 0.0
		_broadcast(false)

# ---- helpers --------------------------------------------------------------

## Peer id of whoever called the rpc we are inside. A remote caller reports its
## own id; a LOCAL call (the host calling rpc_id(1) on itself) reports 0, so map
## that back to our own id. Player nodes are named after peer ids, and looking up
## "0" finds nothing — which would silently drop every action the host takes.
func _sender_id() -> int:
	var id := multiplayer.get_remote_sender_id()
	return multiplayer.get_unique_id() if id == 0 else id

func _in_range(h: Node2D, runner_pos: Vector2) -> bool:
	return h.global_position.distance_to(runner_pos) <= KnockSystem.KNOCK_RANGE

func _find_runner() -> Node2D:
	for c in _players.get_children():
		if c.get("role") == Roles.RUNNER:
			return c
	return null

# ---- replication ----------------------------------------------------------

func _set_winner(w: String) -> void:
	winner = w
	knock.force_end()
	devices.force_end()
	zones.force_end()
	elevators.force_end()
	_broadcast(true)
	# The round is over — drop any dev snapshot so the next launch starts fresh.
	if DevSnapshot.enabled():
		DevSnapshot.clear()

# ---- dev resume (server-only match state; see DevSnapshot) -----------------

## Bumped whenever the shape below changes. restore_state refuses anything else:
## a snapshot from the old grapple/key build has `installs` and no device
## progress, so restoring it would silently produce a nonsense round (every device
## intact, but the state it was saved with long gone) rather than fail loudly.
const SNAPSHOT_VERSION := 4

func snapshot_state() -> Dictionary:
	return {
		"v": SNAPSHOT_VERSION,
		"prog": devices.progress.duplicate(),
		"active": devices.active_index,
		"time": time_left,
		"winner": winner,
		"knocks": knock.knocks,
		"decay": knock.decay_left,
		"iframe": knock.iframe_left,
		"stun": knock.stun_left,
		"zones": zones.snapshot(),
		"elev": elevators.snapshot(),
	}

func restore_state(d: Dictionary) -> void:
	if int(d.get("v", 1)) != SNAPSHOT_VERSION:
		return         # stale schema: start fresh rather than restore garbage
	devices.progress = (d.get("prog", {}) as Dictionary).duplicate()
	devices.active_index = int(d.get("active", -1))
	time_left = float(d.get("time", MATCH_TIME))
	winner = str(d.get("winner", ""))
	knock.knocks = int(d.get("knocks", 0))
	knock.decay_left = float(d.get("decay", 0.0))
	knock.iframe_left = float(d.get("iframe", 0.0))
	knock.stun_left = float(d.get("stun", 0.0))
	zones.restore(d.get("zones", {}))
	elevators.restore(d.get("elev", {}))
	_broadcast(true)   # push the restored state to every peer's HUD

func _state_dict() -> Dictionary:
	return {
		# Host clock, so clients can maintain a host-time offset for lag comp
		# (see NetStats.note_host_time). Rides the existing ≥2 Hz sync for free.
		"ht": Time.get_ticks_msec(),
		"prog": devices.progress,
		"active": devices.active_index,
		"time": time_left,
		"knocks": knock.knocks,
		"iframe": knock.iframe_left,
		"stun": knock.stun_left,
		"winner": winner,
		"zlock": zones.lockdown,
		"zcool": zones.cooldown,
	}

func _apply_state(d: Dictionary) -> void:
	if not multiplayer.is_server():
		Net.stats.note_host_time(int(d.get("ht", 0)))
	# duplicate(), not the dict itself: _sync_state is call_local, so on the host
	# the incoming dict IS the live one and aliasing it would tie the two together.
	devices.progress = (d.get("prog", {}) as Dictionary).duplicate()
	devices.active_index = int(d.get("active", -1))
	time_left = float(d.get("time", MATCH_TIME))
	knock.knocks = int(d.get("knocks", 0))
	knock.iframe_left = float(d.get("iframe", 0.0))
	knock.stun_left = float(d.get("stun", 0.0))
	winner = str(d.get("winner", ""))
	zones.lockdown = (d.get("zlock", {}) as Dictionary).duplicate()
	zones.cooldown = (d.get("zcool", {}) as Dictionary).duplicate()
	state_changed.emit()

func _broadcast(reliable: bool) -> void:
	if reliable:
		_sync_state.rpc(_state_dict())
	else:
		_sync_state_fast.rpc(_state_dict())

@rpc("authority", "call_local", "reliable")
func _sync_state(d: Dictionary) -> void:
	_apply_state(d)

@rpc("authority", "call_local", "unreliable")
func _sync_state_fast(d: Dictionary) -> void:
	if winner != "":
		return
	_apply_state(d)
