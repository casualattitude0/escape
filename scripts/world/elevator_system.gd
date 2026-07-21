extends Node
class_name ElevatorSystem

## Manages elevator rides (server-authoritative; owned by the GameManager).
##
## When a Hunter requests a ride, the server validates they're at an elevator,
## then locks them for the ride duration and teleports them to the other stop.
## The ride emits sound so the Runner knows someone moved.

const RIDE_TIME := 0.8

var _elevators_root: Node
var _players: Node
# peer_id -> {end_pos: Vector2, time_left: float}
var _riding := {}

func setup(elevators_root: Node, players: Node) -> void:
	_elevators_root = elevators_root
	_players = players

## A Hunter requested an elevator ride. Returns true if accepted.
func try_ride(hunter: Node2D) -> bool:
	if _riding.has(hunter.name.to_int()):
		return false
	if _elevators_root == null:
		return false
	for e in _elevators_root.get_children():
		if not e.has_method("hunter_in_range"):
			continue
		if e.hunter_in_range(hunter):
			var dest: Vector2 = e.far_stop(hunter.global_position)
			_riding[hunter.name.to_int()] = {
				"end_pos": dest,
				"time_left": RIDE_TIME,
				"start_pos": hunter.global_position,
			}
			return true
	return false

## Start a timed ride to an explicit destination, bypassing the elevator-area
## check. Used by other vertical travel that shares this ride lifecycle (the
## Hunter shaft): tick() ends it and issues ride_end exactly like an elevator.
func begin_ride(pid: int, start_pos: Vector2, dest: Vector2) -> void:
	_riding[pid] = {"end_pos": dest, "time_left": RIDE_TIME, "start_pos": start_pos}

## Tick all active rides. Returns an array of {pid, end_pos} for rides that finished.
func tick(delta: float) -> Array:
	var finished: Array = []
	var to_remove: Array = []
	for pid in _riding:
		_riding[pid]["time_left"] -= delta
		if _riding[pid]["time_left"] <= 0.0:
			to_remove.append(pid)
			finished.append({"pid": pid, "end_pos": _riding[pid]["end_pos"]})
	for pid in to_remove:
		_riding.erase(pid)
	return finished

func is_riding(peer_id: int) -> bool:
	return _riding.has(peer_id)

## Interpolated position for a riding Hunter (for visual smoothness).
func ride_position(peer_id: int) -> Vector2:
	if not _riding.has(peer_id):
		return Vector2.ZERO
	var ride: Dictionary = _riding[peer_id]
	var t: float = 1.0 - (ride["time_left"] / RIDE_TIME)
	t = clampf(t, 0.0, 1.0)
	# Ease in-out for smooth feel
	t = t * t * (3.0 - 2.0 * t)
	return (ride["start_pos"] as Vector2).lerp(ride["end_pos"] as Vector2, t)

func force_end() -> void:
	_riding.clear()

func snapshot() -> Dictionary:
	return {"riding": _riding.duplicate(true)}

func restore(d: Dictionary) -> void:
	_riding = (d.get("riding", {}) as Dictionary).duplicate(true)
