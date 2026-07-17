class_name PosHistory
extends RefCounted

## Host-side ring buffer of every player's recent position (+ the flags a hit
## test cares about), recorded once per physics tick. Lag compensation rewinds
## into this: a Hunter's knock is judged against where the Runner was when the
## HUNTER saw it swing, not where the Runner is now — see game_manager.gd
## hunter_press. ~1.5s of history comfortably covers the 300ms rewind cap.

const MAX_AGE_MS := 1500.0

var _hist: Dictionary = {}   # peer_id -> Array of {t, pos, dead, stunned}, time-ascending


func clear() -> void:
	_hist.clear()


func record(peer_id: int, t_ms: float, pos: Vector2, dead: bool, stunned: bool) -> void:
	if not _hist.has(peer_id):
		_hist[peer_id] = []
	var arr: Array = _hist[peer_id]
	arr.push_back({"t": t_ms, "pos": pos, "dead": dead, "stunned": stunned})
	while not arr.is_empty() and t_ms - arr[0]["t"] > MAX_AGE_MS:
		arr.pop_front()


## Player state at host-clock `t_ms`: position lerped between the bracketing
## ticks, flags latched from the tick at-or-before t. Clamps to the oldest /
## newest entry outside the window. Empty Dictionary when the peer is unknown.
func sample(peer_id: int, t_ms: float) -> Dictionary:
	var arr: Array = _hist.get(peer_id, [])
	if arr.is_empty():
		return {}
	if t_ms <= arr[0]["t"]:
		return arr[0]
	for i in range(arr.size() - 1):
		var a: Dictionary = arr[i]
		var b: Dictionary = arr[i + 1]
		if t_ms <= b["t"]:
			var span: float = b["t"] - a["t"]
			var pos: Vector2 = b["pos"] if span <= 0.0 \
				else (a["pos"] as Vector2).lerp(b["pos"], (t_ms - a["t"]) / span)
			return {"t": t_ms, "pos": pos, "dead": a["dead"], "stunned": a["stunned"]}
	return arr[-1]
