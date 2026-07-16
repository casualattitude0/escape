extends SceneTree
func _init() -> void:
	var ps := load("res://scenes/levels/section1.tscn")
	if ps == null:
		push_error("WORLD_LOAD_FAILED")
	else:
		print("WORLD_OK ", ps.get_class())
	var ts := load("res://scenes/resources/terrain_tileset.tres")
	print("TILESET_OK " if ts != null else "TILESET_FAIL")
	quit()
