extends SceneTree

## Headless test for NetInterp (scripts/player/net_interp.gd).
## Run: Godot --headless --path . --script tools/test_interp_buffer.gd
## Feeds synthetic samples (jitter, gaps, teleports) through push_at()/sample()
## and asserts: bracketed interpolation, hold-before-first, extrapolation cap,
## and teleport snap. Prints "ALL OK" and exits 0 on success.

# Preload rather than the global class name: --script runs don't build the
# global class cache, so NetInterp wouldn't resolve.
const NetInterp := preload("res://scripts/player/net_interp.gd")

var _fails := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		print("  ok: %s" % label)
	else:
		_fails += 1
		printerr("  FAIL: %s" % label)


func _initialize() -> void:
	print("[test_interp_buffer]")
	_test_basic_lerp()
	_test_hold_before_first()
	_test_extrapolation_cap()
	_test_teleport_snap()
	_test_smoothness_under_jitter()
	if _fails == 0:
		print("ALL OK")
	quit(0 if _fails == 0 else 1)


func _test_basic_lerp() -> void:
	var it := NetInterp.new()
	it.interp_delay_ms = 100.0
	it.push_at(1000.0, Vector2(0, 0))
	it.push_at(1045.0, Vector2(45, 0))   # 1 px/ms
	# now=1122.5 -> t=1022.5, halfway between samples
	var p: Vector2 = it.sample(1122.5)
	_check(p.is_equal_approx(Vector2(22.5, 0)), "lerps between bracketing samples (got %s)" % p)


func _test_hold_before_first() -> void:
	var it := NetInterp.new()
	it.interp_delay_ms = 100.0
	it.push_at(1000.0, Vector2(7, 7))
	_check(it.sample(1000.0) == Vector2(7, 7), "holds at first sample before history exists")
	_check(it.sample(0.0) == Vector2(7, 7), "clamps to first sample for very old t")
	var empty := NetInterp.new()
	_check(empty.sample(1000.0) == null, "returns null with no data")


func _test_extrapolation_cap() -> void:
	var it := NetInterp.new()
	it.interp_delay_ms = 100.0
	it.push_at(1000.0, Vector2(0, 0))
	it.push_at(1050.0, Vector2(50, 0))   # 1 px/ms rightwards
	# t = 1150 -> 100ms past newest -> extrapolate exactly the cap: +100 px
	var at_cap: Vector2 = it.sample(1250.0)
	_check(at_cap.is_equal_approx(Vector2(150, 0)), "extrapolates along velocity (got %s)" % at_cap)
	# far beyond the cap: held at the cap, not running away
	var beyond: Vector2 = it.sample(9999.0)
	_check(beyond.is_equal_approx(Vector2(150, 0)), "extrapolation capped at %d ms (got %s)"
		% [int(NetInterp.MAX_EXTRAPOLATION_MS), beyond])


func _test_teleport_snap() -> void:
	var it := NetInterp.new()
	it.interp_delay_ms = 100.0
	it.push_at(1000.0, Vector2(0, 0))
	it.push_at(1045.0, Vector2(2000, 0))   # way past SNAP_DIST: a teleport
	var p: Vector2 = it.sample(1100.0)
	_check(p == Vector2(2000, 0), "teleport clears history and holds at the new spot (got %s)" % p)


func _test_smoothness_under_jitter() -> void:
	# Constant-velocity sender, jittered arrival times + one dropped packet.
	# The rendered path must stay monotonic in x and never move faster than
	# ~2x the true velocity between frames.
	var it := NetInterp.new()
	it.interp_delay_ms = 100.0
	var jitter := [0.0, 12.0, -8.0, 15.0, -5.0, 9.0, -11.0, 4.0]
	var t := 1000.0
	for i in 16:
		if i == 9:
			continue   # dropped packet
		var send_t := 1000.0 + i * 45.0
		it.push_at(send_t + jitter[i % jitter.size()], Vector2(send_t - 1000.0, 0))
	var prev_x := -INF
	var max_step := 0.0
	var prev := Vector2.ZERO
	var first := true
	var backwards := 0
	var now := 1150.0
	while now < 1700.0:
		var p: Vector2 = it.sample(now)
		if p.x < prev_x - 0.001:
			backwards += 1
		prev_x = p.x
		if not first:
			max_step = maxf(max_step, p.distance_to(prev))
		prev = p
		first = false
		now += 16.6
	_check(backwards == 0, "path monotonic under jitter+loss (%d reversals)" % backwards)
	_check(max_step < 2.0 * 16.6, "frame step bounded under jitter (max %.1f px/frame)" % max_step)
