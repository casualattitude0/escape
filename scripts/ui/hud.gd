extends CanvasLayer

## Reads the replicated game state and shows role, item progress, the grapple
## mash-off (capture bar with checkpoints + escape bar), a mash prompt, and the
## end-of-game banner.

@onready var role_label: Label = %RoleLabel
@onready var items_label: Label = %ItemsLabel
@onready var hint_label: Label = %HintLabel
@onready var capture_label: Label = %CaptureLabel
@onready var capture_bar: ProgressBar = %CaptureBar
@onready var escape_label: Label = %EscapeLabel
@onready var escape_bar: ProgressBar = %EscapeBar
@onready var mash_prompt: Label = %BreakFree
@onready var banner: Label = %Banner

var _gm: Node
var _my_role := Roles.HUNTER

func _ready() -> void:
	_my_role = Net.players.get(multiplayer.get_unique_id(), Roles.HUNTER)
	_gm = get_tree().get_first_node_in_group("game_manager")
	if _gm != null:
		_gm.state_changed.connect(_refresh)
	role_label.text = "You are: Runner (escape)" if _my_role == Roles.RUNNER else "You are: Hunter (capture)"
	role_label.modulate = Color(0.55, 0.85, 0.65) if _my_role == Roles.RUNNER else Color(0.9, 0.5, 0.5)
	hint_label.text = "Move A/D   Jump Space   Slide Shift/S into tunnels   Attack F (kills Hunters)\nMinimap marks the key objects to grab and the escape doors" if _my_role == Roles.RUNNER \
		else "Move A/D   Jump Space   Get close to a slowed Runner and MASH F to capture\nVision is limited — noises clear your sight nearby, or ping the minimap from afar"
	_refresh()

func _refresh() -> void:
	if _gm == null:
		return
	items_label.text = "Objects %d / %d" % [_gm.items_collected(), _gm.items_total()]

	var active: bool = _gm.grappling() and _gm.winner == ""
	capture_bar.value = _gm.capture_ratio() * 100.0
	escape_bar.value = _gm.escape_ratio() * 100.0
	# Only the Runner has an escape bar to fill.
	escape_label.visible = active and _my_role == Roles.RUNNER
	escape_bar.visible = active and _my_role == Roles.RUNNER

	if active:
		mash_prompt.visible = true
		if _my_role == Roles.RUNNER:
			mash_prompt.text = "GRABBED!  Mash F to escape!"
			mash_prompt.modulate = Color(1, 0.85, 0.3)
		else:
			mash_prompt.text = "Mash F to capture!"
			mash_prompt.modulate = Color(0.6, 0.9, 1.0)
	else:
		mash_prompt.visible = false

	if _gm.winner == "":
		banner.visible = false
		return
	banner.visible = true
	var won: bool = (_gm.winner == _my_role) or (_gm.winner == Roles.WIN_HUNTERS and _my_role == Roles.HUNTER)
	if _gm.winner == Roles.WIN_RUNNER:
		banner.text = "The Runner escaped!"
	else:
		banner.text = "The monster was recaptured!"
	banner.text += "\n" + ("You win!" if won else "You lose")
	banner.modulate = Color(0.6, 0.9, 0.6) if won else Color(0.9, 0.55, 0.55)
