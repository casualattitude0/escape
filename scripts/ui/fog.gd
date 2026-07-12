extends ColorRect

## Hunter-only restricted vision (GDD 4.2). A full-screen dark overlay with a
## soft "clear" circle centred on the local Hunter, so no one can read the whole
## map at a glance. The Runner has full sight and never sees this.
##
## Sound exposure (GDD 4.3): when a nearby Runner makes noise, the clear radius
## briefly swells so the Hunter can actually spot the Runner, then eases back.

const BASE_RADIUS := 175.0       # normal clear circle (px)
const CLARITY_RADIUS := 400.0    # expanded circle right after a near noise
const SOFTNESS := 110.0          # feathering of the fog edge (px)
const DARKNESS := 0.92           # opacity of the fog outside the circle
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
	COLOR = vec4(0.0, 0.0, 0.0, a);
}
"""

var _radius := BASE_RADIUS
var _clarity_left := 0.0
var _gm: Node
var _local: Node2D
var _mat: ShaderMaterial

func _ready() -> void:
	if Net.players.get(multiplayer.get_unique_id(), Roles.HUNTER) != Roles.HUNTER:
		visible = false          # Runner keeps full vision
		set_process(false)
		return
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	color = Color(0, 0, 0, 0)    # darkness comes entirely from the shader
	var shader := Shader.new()
	shader.code = SHADER_CODE
	_mat = ShaderMaterial.new()
	_mat.shader = shader
	material = _mat
	_gm = get_tree().get_first_node_in_group("game_manager")
	if _gm != null:
		_gm.sound_heard.connect(_on_sound_heard)

func _process(delta: float) -> void:
	if _local == null or not is_instance_valid(_local):
		_local = _find_local()
		if _local == null:
			return
	if _clarity_left > 0.0:
		_clarity_left -= delta
	var target := CLARITY_RADIUS if _clarity_left > 0.0 else BASE_RADIUS
	_radius = move_toward(_radius, target, EASE_SPEED * delta)
	var center: Vector2 = get_viewport().get_canvas_transform() * _local.global_position
	_mat.set_shader_parameter("center_px", center)
	_mat.set_shader_parameter("resolution", get_viewport_rect().size)
	_mat.set_shader_parameter("radius_px", _radius)
	_mat.set_shader_parameter("soft_px", SOFTNESS)
	_mat.set_shader_parameter("darkness", DARKNESS)

func _on_sound_heard(_pos: Vector2, heard_near: bool) -> void:
	if heard_near:
		_clarity_left = CLARITY_TIME

func _find_local() -> Node2D:
	if _gm == null:
		return null
	return _gm.players().get_node_or_null(str(multiplayer.get_unique_id()))
