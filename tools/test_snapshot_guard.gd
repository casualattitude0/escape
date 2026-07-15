extends Node

## Verifies that a dev-resume snapshot from the OLD keys-and-grapple build is
## rejected instead of restored (the version guard in GameManager.restore_state
## and world.gd). Run:
##   Godot --headless --path . tools/test_snapshot_guard.tscn
##
## Run as a SCENE, not with --script: GameManager reaches the Net and DevSnapshot
## autoloads, and autoloads only exist when the project's main loop is running.
##
## This is the failure the guard exists for: a v1 snapshot has `installs`, `cap`,
## `esc` and NO device progress, and its `active` field is a bool where v2 keeps
## the index of the device being mashed — so restoring one would quietly produce a
## round with a wrong clock and device 0 half-broken, rather than fail loudly.

const GM_SCRIPT := preload("res://scripts/world/game_manager.gd")

# A real v1 snapshot, copied from disk (user://dev_snapshot.cfg) before this
# change landed.
const V1_GM := {
	"active": false,
	"cap": 0.0,
	"cap_floor": 0.0,
	"carried_index": -1,
	"carrying": false,
	"esc": 0.0,
	"installs": {},
	"time": 69.0000000000012,
	"winner": "",
}

var _failed := 0

func _assert(cond: bool, what: String) -> void:
	if cond:
		print("  ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL %s" % what)

## GameManager reaches for ../Players, ../Devices, ../Escape and ../Terrain, so
## give it the tree shape it expects.
func _make_gm() -> Node:
	var world := Node2D.new()
	world.name = "World"
	for n in ["Players", "Devices", "Escape"]:
		var child := Node2D.new()
		child.name = n
		world.add_child(child)
	var terrain := TileMapLayer.new()
	terrain.name = "Terrain"
	world.add_child(terrain)

	var gm := Node.new()
	gm.name = "GameManager"
	gm.set_script(GM_SCRIPT)
	var ds := Node.new()
	ds.name = "DeviceSystem"
	ds.set_script(preload("res://scripts/world/device_system.gd"))
	gm.add_child(ds)
	var ks := Node.new()
	ks.name = "KnockSystem"
	ks.set_script(preload("res://scripts/world/knock_system.gd"))
	gm.add_child(ks)
	world.add_child(gm)

	add_child(world)
	return gm

func _ready() -> void:
	print("Dev-resume snapshot version guard")
	var gm := _make_gm()

	# --- a v1 snapshot must be refused ---------------------------------------
	var before_time: float = gm.time_left
	gm.restore_state(V1_GM.duplicate())
	_assert(gm.time_left == before_time,
		"a v1 snapshot does NOT overwrite the clock (69s stays out)")
	_assert(gm.devices.destroyed_count() == 0, "a v1 snapshot leaves devices untouched")
	_assert(gm.devices.active_index == -1,
		"v1's `active: false` does not become device 0 (int(false) == 0)")
	_assert(not gm.escape_open(), "a v1 snapshot cannot open the exit")

	# --- a v2 snapshot round-trips -------------------------------------------
	gm.devices.progress = {0: 10, 1: 4}
	gm.devices.active_index = 1
	gm.time_left = 42.0
	gm.knock.knocks = 2
	var snap: Dictionary = gm.snapshot_state()
	_assert(int(snap.get("v", -1)) == GM_SCRIPT.SNAPSHOT_VERSION,
		"a fresh snapshot is stamped v%d" % GM_SCRIPT.SNAPSHOT_VERSION)

	var gm2 := _make_gm()
	gm2.restore_state(snap)
	_assert(gm2.time_left == 42.0, "a v2 snapshot restores the clock")
	_assert(gm2.devices.hits(0) == 10 and gm2.devices.hits(1) == 4,
		"a v2 snapshot restores device damage")
	_assert(gm2.devices.active_index == 1, "a v2 snapshot restores the active device")
	_assert(gm2.knock.knocks == 2, "a v2 snapshot restores the knock count")

	# The snapshot must not alias the live dict, or a later mash would mutate it.
	gm.devices.progress[0] = 3
	_assert(int(snap["prog"][0]) == 10, "a taken snapshot does not alias live state")

	print("%s (%d failed)" % ["PASS" if _failed == 0 else "FAIL", _failed])
	get_tree().quit(1 if _failed > 0 else 0)
