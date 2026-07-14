extends Node
class_name GrappleSystem

## The capture mash-off state (server-authoritative; owned by the GameManager).
## Two racing bars:
##   * CAPTURE (`cap`) — Hunters fill it. 3 checkpoints; never drops below the
##     highest reached (a persistent "save point"). Full = captured.
##   * ESCAPE (`esc`) — the Runner fills it; each Runner tap is worth 2x
##     (ESC_STEP = 2 * CAP_STEP). Full = broke free.
## The GameManager drives this: start() / add_capture() / add_escape() on taps,
## and reads `cap`/`esc`/`active` for replication. Neither bar decays over time —
## progress is only ever gained by taps (and the ratchet floor).

const CAP_STEP := 0.045          # capture bar gained per Hunter tap
const ESC_STEP := 0.090          # escape bar gained per Runner tap (2x)
const GRAB_COOLDOWN := 1.5       # after an escape, no re-grab for a moment
const CHECKPOINTS := [0.3333, 0.6667]

var cap := 0.0                   # capture bar 0..1 (persists across grapples)
var esc := 0.0                   # escape bar 0..1 (per grapple)
var cap_floor := 0.0             # highest checkpoint reached (ratchet)
var active := false

var _cd := 0.0

func on_cooldown() -> bool:
	return _cd > 0.0

func tick_cooldown(delta: float) -> void:
	if _cd > 0.0:
		_cd -= delta

func start() -> void:
	active = true
	esc = 0.0
	cap = maxf(cap, cap_floor)   # resume from the saved checkpoint

## Add one Hunter tap. Returns true when the capture bar fills (a capture).
func add_capture() -> bool:
	cap = minf(1.0, cap + CAP_STEP)
	for cp in CHECKPOINTS:
		if cap >= cp and cp > cap_floor:
			cap_floor = cp
	return cap >= 1.0

## Add one Runner tap. Returns true when the escape bar fills (grapple ended).
func add_escape() -> bool:
	esc = minf(1.0, esc + ESC_STEP)
	if esc >= 1.0:
		end(true)
		return true
	return false

func decay(delta: float) -> void:
	cap = maxf(cap_floor, cap - CAP_DECAY * delta)
	esc = maxf(0.0, esc - ESC_DECAY * delta)

func end(escaped: bool) -> void:
	active = false
	esc = 0.0
	cap = cap_floor              # keep checkpoint progress, drop the rest
	if escaped:
		_cd = GRAB_COOLDOWN

func force_end() -> void:
	active = false

## Wipe the whole mash-off (both bars + the ratchet). Called after a capture
## scatters the key, so the next carry-run is a fresh contest (GDD 4.5).
func reset() -> void:
	active = false
	cap = 0.0
	esc = 0.0
	cap_floor = 0.0
	_cd = GRAB_COOLDOWN
