class_name NetInterp
extends RefCounted

## Interpolation buffer for a REMOTE player's replicated position. The owner
## replicates `net_pos` at 22–33 Hz; rendering those raw samples directly makes
## remote players step/stutter, and any dropped packet becomes a visible hitch.
## Instead every sample is timestamped on arrival and the body is drawn at
## `now - interp_delay` — always between two known samples, so motion stays
## smooth through jitter and (once the transport goes unreliable) packet loss.
##
## The price is that remote players render ~interp_delay in the past. That is
## deliberate and lag compensation (game_manager.gd, Phase 2) accounts for it.

const MAX_SAMPLES := 16
const MAX_EXTRAPOLATION_MS := 100.0   # coast at most this far past the newest sample
const SNAP_DIST := 128.0              # a jump this big is a teleport, not movement

## How far in the past we render. ~2.2 send-intervals + jitter margin: enough
## that one late/lost packet still leaves a bracketing pair.
var interp_delay_ms := 100.0

var _samples: Array = []   # of {t: float ms, pos: Vector2}, time-ascending


func set_send_interval(seconds: float) -> void:
	interp_delay_ms = clampf(2.2 * seconds * 1000.0 + 20.0, 70.0, 160.0)


func clear() -> void:
	_samples.clear()


func push(pos: Vector2) -> void:
	push_at(float(Time.get_ticks_msec()), pos)


func push_at(t_ms: float, pos: Vector2) -> void:
	# A teleport (respawn, elevator arrival) must not be interpolated as a dash
	# across the map: drop history so sample() holds/starts at the new spot.
	if not _samples.is_empty() and _samples[-1]["pos"].distance_to(pos) > SNAP_DIST:
		_samples.clear()
	_samples.push_back({"t": t_ms, "pos": pos})
	while _samples.size() > MAX_SAMPLES:
		_samples.pop_front()


## Position to render at wall-clock `now_ms`, or null when no data yet.
func sample(now_ms: float) -> Variant:
	if _samples.is_empty():
		return null
	var t := now_ms - interp_delay_ms
	if t <= _samples[0]["t"]:
		return _samples[0]["pos"]
	for i in range(_samples.size() - 1):
		var a: Dictionary = _samples[i]
		var b: Dictionary = _samples[i + 1]
		if t <= b["t"]:
			var span: float = b["t"] - a["t"]
			if span <= 0.0:
				return b["pos"]
			return (a["pos"] as Vector2).lerp(b["pos"], (t - a["t"]) / span)
	# Past the newest sample (sender stalled or packets late): extrapolate along
	# the last known velocity, but only briefly — beyond the cap, hold still
	# rather than run off into a wall.
	var last: Dictionary = _samples[-1]
	if _samples.size() < 2:
		return last["pos"]
	var prev: Dictionary = _samples[-2]
	var span2: float = last["t"] - prev["t"]
	if span2 <= 0.0:
		return last["pos"]
	var overshoot: float = minf(t - last["t"], MAX_EXTRAPOLATION_MS)
	var vel: Vector2 = (last["pos"] - prev["pos"]) / span2
	return (last["pos"] as Vector2) + vel * overshoot
