extends SceneTree

## Headless check of the sabotage rules (GDD 4.1) and of where the layout puts the
## escape point now that there is only one. Run:
##   Godot --headless --script tools/test_device_system.gd

const LEVEL := preload("res://scenes/levels/level.tscn")
const RUNNER_SPAWN := Vector2(208, 1690)   # mirrors world.gd

var _failed := 0

func _assert(cond: bool, what: String) -> void:
	if cond:
		print("  ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL %s" % what)

func _init() -> void:
	_test_rules()
	_test_layout()
	print("%s (%d failed)" % ["PASS" if _failed == 0 else "FAIL", _failed])
	quit(1 if _failed > 0 else 0)

func _test_rules() -> void:
	print("DeviceSystem rules")
	var d := DeviceSystem.new()

	# --- a device takes exactly HITS_PER_DEVICE mashes, no drift -------------
	var n := 0
	while not d.done(0) and n < 100:
		d.hit(0)
		n += 1
	_assert(n == DeviceSystem.HITS_PER_DEVICE,
		"a device takes exactly %d mashes" % DeviceSystem.HITS_PER_DEVICE)
	_assert(d.ratio(0) == 1.0, "a finished device reads as exactly 1.0")
	_assert(d.hit(0) == false, "mashing a broken device does nothing")
	_assert(d.active_index == -1, "finishing a device clears the active slot")

	# --- all four, then the way out -----------------------------------------
	d = DeviceSystem.new()
	_assert(not d.all_destroyed(), "the exit starts shut")
	for i in DeviceSystem.DEVICE_COUNT:
		for _h in DeviceSystem.HITS_PER_DEVICE:
			d.hit(i)
	_assert(d.destroyed_count() == DeviceSystem.DEVICE_COUNT, "all devices break")
	_assert(d.all_destroyed(), "the exit opens once they are all down")

	# --- a stun costs the Runner ground, but never all of it -----------------
	d = DeviceSystem.new()
	for _h in 5:
		d.hit(0)
	d.on_runner_stunned()
	_assert(d.hits(0) == 5 - DeviceSystem.ROLLBACK_HITS,
		"a stun rolls the device back by ROLLBACK_HITS")
	_assert(d.active_index == -1, "a stun clears the active slot")

	d = DeviceSystem.new()
	d.hit(0)                              # 1 hit, less than the rollback
	d.on_runner_stunned()
	_assert(d.hits(0) == 0, "rollback floors at zero, never goes negative")

	d = DeviceSystem.new()
	d.on_runner_stunned()                 # stunned while mashing nothing
	_assert(d.active_index == -1, "a stun with no active device is harmless")

	# --- a finished device cannot be rolled back ----------------------------
	d = DeviceSystem.new()
	for _h in DeviceSystem.HITS_PER_DEVICE:
		d.hit(0)
	d.on_runner_stunned()
	_assert(d.done(0), "a stun cannot un-break a finished device")

	# --- the Runner has to keep coming back ---------------------------------
	# A device is only worth interrupting if a stun costs more than the Runner can
	# re-mash for free. This is the balance relationship, stated as a check.
	_assert(DeviceSystem.ROLLBACK_HITS < DeviceSystem.HITS_PER_DEVICE,
		"a single stun never wipes a whole device")

## The plan flagged this: with only ONE escape point, does LevelLayout still put it
## somewhere sensible? GDD 4.7 wants it far from the Runner's spawn and clear of
## the devices.
func _test_layout() -> void:
	print("Escape point placement (door_count = 1)")
	var level := LEVEL.instantiate()
	root.add_child(level)
	var terrain := level.get_node_or_null("Terrain") as TileMapLayer
	if terrain == null:
		terrain = level as TileMapLayer
	if terrain == null:
		_assert(false, "found the Terrain layer")
		return

	var worst_exit_to_spawn := INF
	var worst_exit_to_device := INF
	for s in 12:                          # a spread of seeds, not one lucky roll
		var rng := RandomNumberGenerator.new()
		rng.seed = s * 7919
		var layout := LevelLayout.new(terrain)
		var plan: Dictionary = layout.generate(
			DeviceSystem.DEVICE_COUNT, 1, rng, RUNNER_SPAWN)
		var devices: Array = plan["items"]
		var exits: Array = plan["doors"]
		if devices.size() != DeviceSystem.DEVICE_COUNT or exits.size() != 1:
			_assert(false, "seed %d produced %d devices + %d exits"
				% [s, devices.size(), exits.size()])
			continue
		var exit_at: Vector2 = exits[0]
		worst_exit_to_spawn = minf(worst_exit_to_spawn, exit_at.distance_to(RUNNER_SPAWN))
		for dev in devices:
			worst_exit_to_device = minf(worst_exit_to_device, exit_at.distance_to(dev))

	_assert(worst_exit_to_spawn != INF, "every seed produced a full layout")
	print("  note: closest exit->spawn over 12 seeds  = %.0f px (%.1f tiles)"
		% [worst_exit_to_spawn, worst_exit_to_spawn / 32.0])
	print("  note: closest exit->device over 12 seeds = %.0f px (%.1f tiles)"
		% [worst_exit_to_device, worst_exit_to_device / 32.0])
	# 8 tiles is the separation LevelLayout._scatter asks for; it relaxes the
	# requirement when a map is crowded, so assert a floor rather than the ideal.
	_assert(worst_exit_to_device >= 5.0 * 32.0, "the exit never lands on top of a device")
	_assert(worst_exit_to_spawn >= 10.0 * 32.0, "the exit is never next to the Runner's spawn")
	level.queue_free()
