extends Node
class_name ZoneSystem

## Zones and lockdown state (server-authoritative; owned by the GameManager).
##
## Zones are the named rooms from LevelLayout.ROOMS, converted to world-space
## Rect2. A Hunter reports the Runner -> the zone the Runner occupies locks ->
## sabotage is blocked in that zone for LOCKDOWN_TIME seconds -> then a cooldown
## prevents re-locking the same zone for LOCKDOWN_COOLDOWN seconds.
##
## Lockdown blocks sabotage only (GDD prototype recommendation), not movement.
## The Runner can still fight and flee; they just can't progress on devices in
## the locked zone.

const TILE := 32

const LOCKDOWN_TIME := 8.0
const LOCKDOWN_COOLDOWN := 15.0

# zone_name -> Rect2 in world space
var zones := {}
# zone_name -> float seconds of active lockdown remaining (0 = not locked)
var lockdown := {}
# zone_name -> float seconds of cooldown remaining (0 = can be locked)
var cooldown := {}

func _init() -> void:
	_load_rooms(LevelLayout.ROOMS)

func _load_rooms(rooms: Dictionary) -> void:
	zones.clear()
	lockdown.clear()
	cooldown.clear()
	for room_name in rooms:
		var r: Rect2i = rooms[room_name]
		zones[room_name] = Rect2(
			r.position.x * TILE,
			r.position.y * TILE,
			r.size.x * TILE,
			r.size.y * TILE)
		lockdown[room_name] = 0.0
		cooldown[room_name] = 0.0

func use_layout2() -> void:
	_load_rooms(LevelLayout2.ROOMS)

## Which zone a world position falls in, or "" if outside all zones.
func zone_at(pos: Vector2) -> String:
	for z in zones:
		if (zones[z] as Rect2).has_point(pos):
			return z
	return ""

## True when the device at `pos` is in a locked zone.
func is_locked(pos: Vector2) -> bool:
	var z := zone_at(pos)
	return z != "" and lockdown[z] > 0.0

## Try to lock the zone at `pos`. Returns the zone name on success, "" on fail.
func try_lockdown(pos: Vector2) -> String:
	var z := zone_at(pos)
	if z == "":
		return ""
	if lockdown[z] > 0.0 or cooldown[z] > 0.0:
		return ""
	lockdown[z] = LOCKDOWN_TIME
	return z

## Tick all timers. Returns true if any discrete state change happened.
func tick(delta: float) -> bool:
	var changed := false
	for z in lockdown:
		if lockdown[z] > 0.0:
			lockdown[z] = maxf(0.0, lockdown[z] - delta)
			if lockdown[z] <= 0.0:
				cooldown[z] = LOCKDOWN_COOLDOWN
				changed = true
		if cooldown[z] > 0.0:
			cooldown[z] = maxf(0.0, cooldown[z] - delta)
			if cooldown[z] <= 0.0:
				changed = true
	return changed

## Snapshot for dev resume / rejoin.
func snapshot() -> Dictionary:
	return {"lockdown": lockdown.duplicate(), "cooldown": cooldown.duplicate()}

func restore(d: Dictionary) -> void:
	lockdown = (d.get("lockdown", {}) as Dictionary).duplicate()
	cooldown = (d.get("cooldown", {}) as Dictionary).duplicate()

func force_end() -> void:
	for z in lockdown:
		lockdown[z] = 0.0
		cooldown[z] = 0.0
