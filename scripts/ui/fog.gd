extends ColorRect

## Restricted vision (GDD 4.2). A full-screen pale (white) fog overlay with a
## soft "clear" circle centred on the local player, so no one can read the whole
## map at a glance. White, not black, keeps the restricted view bright per the
## scene art rule (受限視野往淡灰退，不變黑; docs/ART_SCENE.md §5).
##
## Both roles are fogged, but the Runner sees more than the Hunter: a lighter
## overlay (RUNNER_DARKNESS) and a wider clear circle (RUNNER_RADIUS).
##
## Spotting (Hunter only): while the Runner is inside the Hunter's clear circle,
## the Hunter's vision swells to a wide "wild" radius and holds there; once the
## Runner slips out of sight it lingers briefly, then eases back. Because the
## detection uses the current radius, the swell is sticky (the Runner enters at
## BASE_RADIUS but stays tracked out to WILD_RADIUS). Every radius change is
## smoothed with half-life easing so it never snaps.

const BASE_RADIUS := 175.0       # Hunter's normal clear circle (px)
const RUNNER_RADIUS := 260.0     # Runner's clear circle (wider: better sight)
const WILD_RADIUS := 400.0       # Hunter's expanded circle while the Runner is spotted
const SOFTNESS := 110.0          # feathering of the fog edge (px)
const DARKNESS := 0.92           # Hunter fog opacity outside the circle
const RUNNER_DARKNESS := 0.95    # Runner fog opacity (lighter: still semi-sees)
const SPOT_LINGER := 2.5         # how long the wild radius holds after losing sight (s)
const EASE_HALFLIFE := 0.18      # seconds to close half the gap to the target radius

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
var _spot_left := 0.0
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

func _process(delta: float) -> void:
	if _local == null or not is_instance_valid(_local):
		_local = _find_local()
		if _local == null:
			return
	# Only the Hunter's view reacts to the Runner; the Runner keeps a steady circle.
	if _is_hunter:
		if _runner_in_view():
			_spot_left = SPOT_LINGER       # spotted right now — refresh the hold
		elif _spot_left > 0.0:
			_spot_left -= delta            # lost sight — linger, then ease back
	var target := WILD_RADIUS if _spot_left > 0.0 else _base_radius
	# Half-life smoothing: frame-rate independent, eases in and never snaps.
	_radius = lerp(target, _radius, pow(0.5, delta / EASE_HALFLIFE))
	var center: Vector2 = get_viewport().get_canvas_transform() * _local.global_position
	_mat.set_shader_parameter("center_px", center)
	_mat.set_shader_parameter("resolution", get_viewport_rect().size)
	_mat.set_shader_parameter("radius_px", _radius)
	_mat.set_shader_parameter("soft_px", SOFTNESS)
	_mat.set_shader_parameter("darkness", _darkness)

## True when the Runner is inside the Hunter's current clear circle. Detecting
## against the live radius (not BASE_RADIUS) makes the swell sticky: the Runner
## enters at the narrow radius but stays tracked while within the widened one.
func _runner_in_view() -> bool:
	var runner := _find_runner()
	if runner == null or not is_instance_valid(runner):
		return false
	return _local.global_position.distance_to(runner.global_position) <= _radius

func _find_runner() -> Node2D:
	if _gm == null:
		return null
	for c in _gm.players().get_children():
		if c.get("role") == Roles.RUNNER:
			return c
	return null

func _find_local() -> Node2D:
	if _gm == null:
		return null
	return _gm.players().get_node_or_null(str(multiplayer.get_unique_id()))
