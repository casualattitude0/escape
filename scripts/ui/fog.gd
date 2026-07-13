extends ColorRect

## Restricted vision (GDD 4.2). A full-screen pale (white) fog overlay with a
## soft "clear" circle centred on the local player, so no one can read the whole
## map at a glance. White, not black, keeps the restricted view bright per the
## scene art rule (受限視野往淡灰退，不變黑; docs/ART_SCENE.md §5).
##
## Both roles are fogged, but the Runner sees more than the Hunter: a lighter
## overlay (RUNNER_DARKNESS) and a wider clear circle (RUNNER_RADIUS).
##
## Sound exposure (GDD 4.3, Hunter only): when a nearby Runner makes noise, the
## Hunter's clear radius briefly swells to spot the Runner, then eases back.

const BASE_RADIUS := 175.0       # Hunter's normal clear circle (px)
const RUNNER_RADIUS := 260.0     # Runner's clear circle (wider: better sight)
const CLARITY_RADIUS := 400.0    # expanded circle right after a near noise (Hunter)
const SOFTNESS := 110.0          # feathering of the fog edge (px)
const DARKNESS := 0.92           # Hunter fog opacity outside the circle
const RUNNER_DARKNESS := 0.95    # Runner fog opacity (lighter: still semi-sees)
const CLARITY_TIME := 2.5        # how long the expanded radius holds (s)
const EASE_SPEED := 900.0        # radius px/s toward its target

const SHADER_CODE := """
shader_type canvas_item;
uniform vec2 center_px;
uniform vec2 resolution;
uniform float radius_px;
uniform float soft_px;
uniform float darkness;
void fragment() {
	float dist = distance(UV * resolution, center_px);
	float a = smoothstep(radius_px, radius_px + soft_px, dist) * darkness;
	COLOR = vec4(1.0, 1.0, 1.0, a);
}
"""

var _is_hunter := true
var _base_radius := BASE_RADIUS
var _darkness := DARKNESS
var _radius := BASE_RADIUS
var _clarity_left := 0.0
var _gm: Node
var _local: Node2D
var _mat: ShaderMaterial

func _ready() -> void:
	_is_hunter = Net.players.get(multiplayer.get_unique_id(), Roles.HUNTER) == Roles.HUNTER
	_base_radius = BASE_RADIUS if _is_hunter else RUNNER_RADIUS
	_darkness = DARKNESS if _is_hunter else RUNNER_DARKNESS
	_radius = _base_radius
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	color = Color(0, 0, 0, 0)    # the fog colour comes entirely from the shader
	var shader := Shader.new()
	shader.code = SHADER_CODE
	_mat = ShaderMaterial.new()
	_mat.shader = shader
	material = _mat
	_gm = get_tree().get_first_node_in_group("game_manager")
	# Only the Hunter's view swells on nearby Runner noise (GDD 4.3).
	if _is_hunter and _gm != null:
		_gm.sound_heard.connect(_on_sound_heard)

func _process(delta: float) -> void:
	if _local == null or not is_instance_valid(_local):
		_local = _find_local()
		if _local == null:
			return
	if _clarity_left > 0.0:
		_clarity_left -= delta
	var target := CLARITY_RADIUS if _clarity_left > 0.0 else _base_radius
	_radius = move_toward(_radius, target, EASE_SPEED * delta)
	var center: Vector2 = get_viewport().get_canvas_transform() * _local.global_position
	_mat.set_shader_parameter("center_px", center)
	_mat.set_shader_parameter("resolution", get_viewport_rect().size)
	_mat.set_shader_parameter("radius_px", _radius)
	_mat.set_shader_parameter("soft_px", SOFTNESS)
	_mat.set_shader_parameter("darkness", _darkness)

func _on_sound_heard(_pos: Vector2, heard_near: bool) -> void:
	if heard_near:
		_clarity_left = CLARITY_TIME

func _find_local() -> Node2D:
	if _gm == null:
		return null
	return _gm.players().get_node_or_null(str(multiplayer.get_unique_id()))
