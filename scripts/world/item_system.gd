extends Node
class_name ItemSystem

## Tracks the Runner's key-object collection (x/y/z). Server-authoritative;
## owned by the GameManager.

var total := 3
var collected := 0

func collect() -> void:
	collected += 1

func all_collected() -> bool:
	return collected >= total
