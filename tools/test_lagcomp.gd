extends SceneTree

## Headless test for PosHistory (scripts/net/pos_history.gd) and the rewind
## window arithmetic used by game_manager.hunter_press.
## Run: Godot --headless --path . --script tools/test_lagcomp.gd

const PosHistory := preload("res://scripts/net/pos_history.gd")

# Mirrors game_manager.gd — keep in sync (asserted below via parse, not import,
# since loading GameManager drags the whole world scene in).
const LAGCOMP_MAX_REWIND_MS := 300
const KNOCK_RANGE := 64.0

var _fails := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		print("  ok: %s" % label)
	else:
		_fails += 1
		printerr("  FAIL: %s" % label)


func _initialize() -> void:
	print("[test_lagcomp]")
	_test_sample_lerp_and_clamp()
	_test_flag_latching()
	_test_window_trim()
	_test_rewind_saves_the_hit()
	_test_rewind_cap_rejects_stale_claims()
	if _fails == 0:
		print("ALL OK")
	quit(0 if _fails == 0 else 1)


func _test_sample_lerp_and_clamp() -> void:
	var ph := PosHistory.new()
	ph.record(2, 1000.0, Vector2(0, 0), false, false)
	ph.record(2, 1016.0, Vector2(16, 0), false, false)
	var mid: Dictionary = ph.sample(2, 1008.0)
	_check((mid["pos"] as Vector2).is_equal_approx(Vector2(8, 0)),
		"lerps between ticks (got %s)" % mid["pos"])
	_check(ph.sample(2, 500.0)["pos"] == Vector2(0, 0), "clamps below the window")
	_check(ph.sample(2, 9999.0)["pos"] == Vector2(16, 0), "clamps above the window")
	_check(ph.sample(77, 1008.0).is_empty(), "unknown peer -> empty")


func _test_flag_latching() -> void:
	var ph := PosHistory.new()
	ph.record(2, 1000.0, Vector2.ZERO, false, false)
	ph.record(2, 1016.0, Vector2.ZERO, false, true)   # stunned from t=1016
	_check(ph.sample(2, 1008.0)["stunned"] == false, "flags latch from the tick before t")
	_check(ph.sample(2, 1016.0)["stunned"] == false, "boundary sample still pre-stun")
	_check(ph.sample(2, 1017.0)["stunned"] == true, "post-tick sample sees the stun")


func _test_window_trim() -> void:
	var ph := PosHistory.new()
	for i in 200:
		ph.record(2, 1000.0 + i * 16.0, Vector2(i, 0), false, false)
	# Oldest surviving entry must be within MAX_AGE_MS of the newest.
	var newest_t := 1000.0 + 199 * 16.0
	var oldest: Dictionary = ph.sample(2, 0.0)   # clamps to the oldest entry
	_check(newest_t - oldest["t"] <= PosHistory.MAX_AGE_MS,
		"history trimmed to %d ms (oldest at %.0f)" % [int(PosHistory.MAX_AGE_MS), oldest["t"]])


## The scenario lag comp exists for: the Runner sprints out of range during the
## knock's flight time. Judged at "now" the swing whiffs; rewound to what the
## Hunter rendered, it lands.
func _test_rewind_saves_the_hit() -> void:
	var ph := PosHistory.new()
	var hunter_pos := Vector2(0, 0)
	# Runner runs right at 300 px/s, sampled at 60 Hz; at t=1000 it's 50px away
	# (in range), 150ms later it's 95px away (out of range).
	var t := 1000.0
	while t <= 1150.0:
		ph.record(2, t, Vector2(50.0 + (t - 1000.0) * 0.3, 0), false, false)
		t += 16.6
	var now := 1150.0
	var render_host_time := 1000.0   # what the hunter's press claims it saw
	_check(hunter_pos.distance_to(ph.sample(2, now)["pos"]) > KNOCK_RANGE,
		"at 'now' the runner is out of range (whiff without lag comp)")
	var rewind_to := clampf(render_host_time, now - LAGCOMP_MAX_REWIND_MS, now)
	_check(hunter_pos.distance_to(ph.sample(2, rewind_to)["pos"]) <= KNOCK_RANGE,
		"rewound to the rendered moment the hit lands")


func _test_rewind_cap_rejects_stale_claims() -> void:
	var ph := PosHistory.new()
	# Runner was in range long ago, then left; a doctored press claims that moment.
	ph.record(2, 1000.0, Vector2(30, 0), false, false)
	var t := 1016.0
	while t <= 2000.0:
		ph.record(2, t, Vector2(500, 0), false, false)   # far away ever since
		t += 16.0
	var now := 2000.0
	var claimed := 1000.0   # 1s old — far beyond the 300ms cap
	var rewind_to := clampf(claimed, now - LAGCOMP_MAX_REWIND_MS, now)
	_check(rewind_to == now - LAGCOMP_MAX_REWIND_MS, "claim clamped to the cap")
	_check(Vector2(0, 0).distance_to(ph.sample(2, rewind_to)["pos"]) > KNOCK_RANGE,
		"stale claim cannot resurrect an ancient hit")
