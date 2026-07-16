extends Node2D

func _ready() -> void:
	# dark sky
	var cl := CanvasLayer.new(); cl.layer = -2; add_child(cl)
	var sky := ColorRect.new(); sky.color = Color(0.156, 0.164, 0.243)
	sky.anchor_right = 1.0; sky.anchor_bottom = 1.0; cl.add_child(sky)
	# parallax bg
	var bg := Sprite2D.new()
	bg.texture = load("res://sprites/Tilesets/bg_shaft.png")
	bg.centered = false; bg.scale = Vector2(2, 2)
	bg.modulate = Color(0.4, 0.43, 0.56)
	var bgl := CanvasLayer.new(); bgl.layer = -1; add_child(bgl); bgl.add_child(bg)
	# terrain
	var lvl: Node = (load("res://scenes/levels/section1.tscn") as PackedScene).instantiate()
	add_child(lvl)
	# camera over room A / B area (tiles ~ x30..68 y46..54 -> px)
	var cam := Camera2D.new(); cam.position = Vector2(1500, 1600); cam.zoom = Vector2(1.4, 1.4)
	add_child(cam); cam.make_current()
	await RenderingServer.frame_post_draw
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://_shot_out.png")
	get_tree().quit()
