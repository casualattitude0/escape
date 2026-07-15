extends CanvasLayer

## Reads the replicated game state and shows role, the match clock, sabotage
## progress, the knock meter, a prompt, and the end-of-game banner.

@onready var role_label: Label = %RoleLabel
@onready var items_label: Label = %ItemsLabel
@onready var timer_label: Label = %TimerLabel
@onready var hint_label: Label = %HintLabel
@onready var capture_label: Label = %CaptureLabel
@onready var capture_bar: ProgressBar = %CaptureBar
@onready var escape_label: Label = %EscapeLabel
@onready var escape_bar: ProgressBar = %EscapeBar
@onready var mash_prompt: Label = %BreakFree
@onready var banner: Label = %Banner

var _gm: Node
var _my_role := Roles.HUNTER
var _my_combat: PlayerCombat

func _ready() -> void:
	_my_role = Net.players.get(multiplayer.get_unique_id(), Roles.HUNTER)
	_gm = get_tree().get_first_node_in_group("game_manager")
	if _gm != null:
		_gm.state_changed.connect(_refresh)
	role_label.text = "You are: Runner (escape)" if _my_role == Roles.RUNNER else "You are: Hunter (contain)"
	role_label.modulate = Color(1, 0, 0)
	if _my_role == Roles.RUNNER:
		hint_label.text = "A/D move · Space jump · Shift slide · F attack (near device: break)"
		for c in get_tree().get_first_node_in_group("game_manager").players().get_children():
			if c.is_multiplayer_authority():
				_my_combat = c.combat
				break
	else:
		hint_label.text = "A/D move · Space jump\nF to knock the Runner. 3 knocks stun it. Run out the clock."
	_refresh()

func _process(_delta: float) -> void:
	if _gm == null:
		return
	var s: int = _gm.time_seconds()
	timer_label.text = "%d:%02d" % [s / 60, s % 60]
	timer_label.modulate = Color(1, 0, 0)
	if _my_combat != null:
		var mode_name := "BREAK" if _my_combat.mode == PlayerCombat.Mode.BREAK else "ATTACK"
		role_label.text = "You are: Runner (escape)  [%s]" % mode_name

func _refresh() -> void:
	if _gm == null:
		return
	var down: int = _gm.devices_destroyed()
	var total: int = _gm.device_total()
	if _my_role == Roles.RUNNER:
		items_label.text = "Devices: %d/%d destroyed%s" % [down, total,
			"  —  GET OUT" if _gm.escape_open() else ""]
	else:
		items_label.text = "Devices down: %d/%d" % [down, total]
	items_label.modulate = Color(1, 0, 0)

	var live: bool = _gm.winner == ""
	capture_bar.value = _gm.knock_ratio() * 100.0
	# Dim the meter through the invulnerability window so both sides can read the
	# one mechanic that is otherwise invisible: right now, knocks do not land.
	capture_bar.modulate = Color(0.45, 0.45, 0.45) if _gm.runner_iframe() else Color(1, 1, 1)

	# Sabotage progress of whatever the Runner is breaking, shown to everyone: the
	# Hunters need it to judge whether they still have time to get there.
	var sab: float = _gm.active_device_ratio()
	escape_label.visible = live and sab >= 0.0
	escape_bar.visible = live and sab >= 0.0
	escape_bar.value = maxf(sab, 0.0) * 100.0

	if live and _my_role == Roles.RUNNER and _gm.runner_stunned():
		mash_prompt.visible = true
		mash_prompt.text = "STUNNED!"
		mash_prompt.modulate = Color(1, 0, 0)
	else:
		mash_prompt.visible = false

	if _gm.winner == "":
		banner.visible = false
		return
	banner.visible = true
	var won: bool = (_gm.winner == _my_role) or (_gm.winner == Roles.WIN_HUNTERS and _my_role == Roles.HUNTER)
	if _gm.winner == Roles.WIN_RUNNER:
		banner.text = "The facility is down — the Runner escaped!"
	else:
		banner.text = "Time's up — the monster is contained!"
	banner.text += "\n" + ("You win!" if won else "You lose")
	banner.modulate = Color(1, 0, 0)
