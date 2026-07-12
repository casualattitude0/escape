extends Control

## Hunter-only minimap (GDD 4.3). Shows the facility outline with the Hunters'
## own positions so a split-up team can coordinate. It deliberately does NOT
## reveal the Runner — until the Runner makes noise in another room, which drops
## a fading amber "sound ping" where the noise came from.

# World bounds of the level: 100x60 tiles @ 32px (see tools/generate_level.py).
const TILE := 32
const GRID := Vector2i(100, 60)
const MAP_MIN := Vector2(0, 0)
const MAP_MAX := Vector2(GRID.x * TILE, GRID.y * TILE)
const PING_TIME := 4.0

const COL_WALL := Color(0.30, 0.34, 0.44)
const COL_SELF := Color(0.45, 0.9, 0.55)
const COL_TEAM := Color(0.55, 0.75, 1.0)
const COL_PING := Color(1.0, 0.78, 0.25)

var _gm: Node
var _players: Node
var _me := ""
var _ping_pos := Vector2.ZERO
var _ping_left := 0.0
var _map_tex: ImageTexture     # baked silhouette of the level geometry

func _ready() -> void:
	_me = str(multiplayer.get_unique_id())
	if Net.players.get(multiplayer.get_unique_id(), Roles.HUNTER) != Roles.HUNTER:
		visible = false          # the Runner has no minimap
		set_process(false)
		return
	_gm = get_tree().get_first_node_in_group("game_manager")
	if _gm != null:
		_players = _gm.players()
		_gm.sound_heard.connect(_on_sound_heard)
	_bake_map()

## Render the Terrain's solid cells into a small texture once, so the minimap
## shows the actual facility layout rather than a blank box.
func _bake_map() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var tilemap := scene.get_node_or_null("Terrain") as TileMapLayer
	if tilemap == null:
		return
	var img := Image.create(GRID.x, GRID.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for cell in tilemap.get_used_cells():
		if cell.x >= 0 and cell.x < GRID.x and cell.y >= 0 and cell.y < GRID.y:
			img.set_pixel(cell.x, cell.y, COL_WALL)
	_map_tex = ImageTexture.create_from_image(img)

func _process(delta: float) -> void:
	if _ping_left > 0.0:
		_ping_left -= delta
	queue_redraw()

func _on_sound_heard(pos: Vector2, heard_near: bool) -> void:
	# A near noise clears the Hunter's own vision (handled by the fog); only a
	# far one — the Runner acting in another room — pings the map.
	if not heard_near:
		_ping_pos = pos
		_ping_left = PING_TIME

func _world_to_map(p: Vector2) -> Vector2:
	var t := (p - MAP_MIN) / (MAP_MAX - MAP_MIN)
	return Vector2(t.x * size.x, t.y * size.y)

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.07, 0.08, 0.12, 0.72))
	if _map_tex != null:
		draw_texture_rect(_map_tex, Rect2(Vector2.ZERO, size), false)
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.4, 0.45, 0.55, 0.6), false, 2.0)
	if _players == null:
		return
	for c in _players.get_children():
		if c.get("role") != Roles.HUNTER:
			continue
		var col := COL_SELF if c.name == _me else COL_TEAM
		draw_circle(_world_to_map(c.global_position), 4.0, col)
	if _ping_left > 0.0:
		var a := _ping_left / PING_TIME
		var pulse := 0.5 + 0.5 * sin((PING_TIME - _ping_left) * 8.0)
		var r: float = lerp(6.0, 12.0, pulse)
		var at := _world_to_map(_ping_pos)
		draw_circle(at, r, Color(COL_PING.r, COL_PING.g, COL_PING.b, a))
		draw_arc(at, r + 4.0, 0.0, TAU, 24, Color(COL_PING.r, COL_PING.g, COL_PING.b, a * 0.6), 2.0)
