extends Area2D

## One elevator shaft with two stops (GDD 4.5). Hunter-exclusive vertical
## fast-travel. The Runner uses tunnels (horizontal); Hunters use elevators
## (vertical). The two networks are independent.
##
## A Hunter walks into the elevator area and presses E to ride to the other
## stop. The ride takes RIDE_TIME seconds. During the ride the Hunter is
## locked in place (no input) and visually moves along the shaft. The
## elevator emits sound on departure so the Runner's minimap picks it up.

@export var stop_top: Vector2 = Vector2.ZERO
@export var stop_bottom: Vector2 = Vector2.ZERO

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

var _hunters_inside: Dictionary = {}

func _on_body_entered(body: Node) -> void:
	if body.get("role") == Roles.HUNTER:
		_hunters_inside[body] = true

func _on_body_exited(body: Node) -> void:
	_hunters_inside.erase(body)

func hunter_in_range(body: Node2D) -> bool:
	return _hunters_inside.has(body)

## Which stop is closer to the given position.
func near_stop(pos: Vector2) -> Vector2:
	if pos.distance_to(stop_top) < pos.distance_to(stop_bottom):
		return stop_top
	return stop_bottom

## The other stop from the one nearest to pos.
func far_stop(pos: Vector2) -> Vector2:
	if pos.distance_to(stop_top) < pos.distance_to(stop_bottom):
		return stop_bottom
	return stop_top
