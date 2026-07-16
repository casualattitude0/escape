extends Control

## Per-role minimap (GDD 4.3 / 4.4).
##
## Hunter: facility outline, own position, sound pings (amber), and report zone
## pings (red flash). Does NOT show teammates or the Runner.
##
## Runner: facility outline, own position, unbroken devices, escape point, and
## directional arrows pointing toward each Hunter (bearing only, not position).

const TILE := 64
const GRID := Vector2i(50, 30)
const MAP_MIN := Vector2(0, 0)
const MAP_MAX := Vector2(GRID.x * TILE, GRID.y * TILE)
const PING_TIME := 4.0
const REPORT_PING_TIME := 6.0

const COL_WALL := Color(0.30, 0.34, 0.44)
const COL_SELF := Color(0.45, 0.9, 0.55)
const COL_PING := Color(1.0, 0.78, 0.25)
const COL_REPORT := Color(0.95, 0.3, 0.3)
const COL_DOOR_LOCKED := Color(0.85, 0.35, 0.35)
const COL_DOOR_PARTIAL := Color(0.9, 0.75, 0.3)
const COL_DOOR_OPEN := Color(0.35, 0.9, 0.45)
const COL_KEY := Color(0.96, 0.83, 0.32)
const COL_ARROW := Color(0.55, 0.75, 1.0)

var _gm: Node
var _players: Node
var _me := ""
var _is_runner := false
var _ping_pos := Vector2.ZERO
var _ping_left := 0.0
var _time := 0.0
var _map_tex: ImageTexture
var _devices_root: Node
var _escape_root: Node

# Report zone pings: zone_name -> seconds remaining
var _report_pings := {}

func _ready() -> void:
	_me = str(multiplayer.get_unique_id())
	_is_runner = Net.players.get(multiplayer.get_unique_id(), Roles.HUNTER) == Roles.RUNNER
	_gm = get_tree().get_first_node_in_group("game_manager")
	if _gm != null:
		_players = _gm.players()
		if not _is_runner:
			_gm.sound_heard.connect(_on_sound_heard)
			_gm.zone_reported.connect(_on_zone_reported)
	var scene := get_tree().current_scene
	if scene != null and _is_runner:
		_devices_root = scene.get_node_or_null("Devices")
		_escape_root = scene.get_node_or_null("Escape")
	_bake_map()

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
	_time += delta
	if _ping_left > 0.0:
		_ping_left -= delta
	var expired: Array = []
	for z in _report_pings:
		_report_pings[z] -= delta
		if _report_pings[z] <= 0.0:
			expired.append(z)
	for z in expired:
		_report_pings.erase(z)
	queue_redraw()

func _on_sound_heard(pos: Vector2, heard_near: bool) -> void:
	if not heard_near:
		_ping_pos = pos
		_ping_left = PING_TIME

func _on_zone_reported(zone_name: String) -> void:
	_report_pings[zone_name] = REPORT_PING_TIME

func _world_to_map(p: Vector2) -> Vector2:
	var t := (p - MAP_MIN) / (MAP_MAX - MAP_MIN)
	return Vector2(t.x * size.x, t.y * size.y)

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.07, 0.08, 0.12, 0.72))
	if _map_tex != null:
		draw_texture_rect(_map_tex, Rect2(Vector2.ZERO, size), false)
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.4, 0.45, 0.55, 0.6), false, 2.0)
	if _is_runner:
		_draw_runner()
	else:
		_draw_hunter()

## Runner view: own position, devices, escape, directional arrows toward Hunters.
func _draw_runner() -> void:
	var pulse := 0.5 + 0.5 * sin(_time * 5.0)
	if _escape_root != null and _gm != null:
		var open: bool = _gm.escape_open()
		for d in _escape_root.get_children():
			if d is Node2D:
				var col := COL_DOOR_OPEN if open else COL_DOOR_LOCKED
				var at := _world_to_map(d.global_position)
				var s := 5.0
				draw_rect(Rect2(at - Vector2(s, s), Vector2(s, s) * 2.0), col)
				if open:
					draw_rect(Rect2(at - Vector2(s, s), Vector2(s, s) * 2.0), col.lightened(0.4), false, 1.5)
	if _devices_root != null and _gm != null:
		for it in _devices_root.get_children():
			if not (it is Node2D):
				continue
			if _gm.device_done(it.index):
				continue
			var col := COL_KEY.lerp(COL_DOOR_PARTIAL, _gm.device_ratio(it.index))
			var at := _world_to_map(it.global_position)
			draw_circle(at, lerp(2.5, 4.5, pulse), col)
			draw_arc(at, 6.0, 0.0, TAU, 20, Color(col.r, col.g, col.b, 0.5 * (1.0 - pulse)), 1.5)

	var my_node: Node2D = null
	if _players != null:
		my_node = _players.get_node_or_null(_me)
	if my_node != null:
		var my_pos := _world_to_map(my_node.global_position)
		draw_circle(my_pos, 4.0, COL_SELF)
		# Directional arrows toward each Hunter (bearing only)
		for c in _players.get_children():
			if c.get("role") != Roles.HUNTER or c.get("dead"):
				continue
			var dir: Vector2 = (c.global_position - my_node.global_position).normalized()
			var arrow_dist := 14.0
			var arrow_pos := my_pos + dir * arrow_dist
			_draw_arrow(arrow_pos, dir, COL_ARROW)

## Hunter view: own position, sound pings, report zone pings. No teammates.
func _draw_hunter() -> void:
	if _players != null:
		var c: Node2D = _players.get_node_or_null(_me)
		if c != null:
			draw_circle(_world_to_map(c.global_position), 4.0, COL_SELF)

	# Sound pings (passive Runner noise)
	if _ping_left > 0.0:
		var a := _ping_left / PING_TIME
		var p := 0.5 + 0.5 * sin((PING_TIME - _ping_left) * 8.0)
		var r: float = lerp(6.0, 12.0, p)
		var at := _world_to_map(_ping_pos)
		draw_circle(at, r, Color(COL_PING.r, COL_PING.g, COL_PING.b, a))
		draw_arc(at, r + 4.0, 0.0, TAU, 24, Color(COL_PING.r, COL_PING.g, COL_PING.b, a * 0.6), 2.0)

	# Report zone pings (player-triggered)
	if _gm != null:
		var zs: ZoneSystem = _gm.zone_data()
		for z in _report_pings:
			if not zs.zones.has(z):
				continue
			var rect: Rect2 = zs.zones[z]
			var tl := _world_to_map(rect.position)
			var br := _world_to_map(rect.position + rect.size)
			var map_rect := Rect2(tl, br - tl)
			var a: float = _report_pings[z] / REPORT_PING_TIME
			var flash := 0.6 + 0.4 * sin(_report_pings[z] * 6.0)
			draw_rect(map_rect, Color(COL_REPORT.r, COL_REPORT.g, COL_REPORT.b, a * 0.3 * flash))
			draw_rect(map_rect, Color(COL_REPORT.r, COL_REPORT.g, COL_REPORT.b, a * 0.7), false, 1.5)

	# Active lockdown zones (solid overlay while locked)
	if _gm != null:
		var zs2: ZoneSystem = _gm.zone_data()
		for z in zs2.lockdown:
			if zs2.lockdown[z] <= 0.0:
				continue
			if _report_pings.has(z):
				continue
			var rect: Rect2 = zs2.zones[z]
			var tl := _world_to_map(rect.position)
			var br := _world_to_map(rect.position + rect.size)
			draw_rect(Rect2(tl, br - tl), Color(COL_REPORT.r, COL_REPORT.g, COL_REPORT.b, 0.15))

func _draw_arrow(pos: Vector2, dir: Vector2, col: Color) -> void:
	var perp := Vector2(-dir.y, dir.x)
	var tip := pos + dir * 5.0
	var left := pos - dir * 3.0 + perp * 3.0
	var right := pos - dir * 3.0 - perp * 3.0
	draw_polygon(PackedVector2Array([tip, left, right]), PackedColorArray([col, col, col]))
