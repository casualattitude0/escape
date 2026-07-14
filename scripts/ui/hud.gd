extends CanvasLayer

## Reads the replicated game state and shows role, the match clock, escape
## progress (carrying a key / best door), the grapple mash-off, a mash prompt,
## and the end-of-game banner.

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

func _ready() -> void:
	_my_role = Net.players.get(multiplayer.get_unique_id(), Roles.HUNTER)
	_gm = get_tree().get_first_node_in_group("game_manager")
	if _gm != null:
		_gm.state_changed.connect(_refresh)
	role_label.text = "You are: Runner (escape)" if _my_role == Roles.RUNNER else "You are: Hunter (contain)"
	role_label.modulate = Color(1, 0, 0)
	hint_label.text = "A/D move · Space jump · Shift slide · F attack\nGrab keys → doors. 3 keys opens a door. Beat the clock!" if _my_role == Roles.RUNNER \
		else "A/D move · Space jump\nMASH F near a key-carrier to knock it loose. Run out the clock."
	_refresh()

func _process(_delta: float) -> void:
	if _gm == null:
		return
	var s: int = _gm.time_seconds()
	timer_label.text = "%d:%02d" % [s / 60, s % 60]
	timer_label.modulate = Color(1, 0, 0)

func _refresh() -> void:
	if _gm == null:
		return
	var per: int = _gm.per_door()
	var best: int = _gm.best_progress()
	if _my_role == Roles.RUNNER:
		if _gm.carrying():
			items_label.text = "Key in hand — deliver it to a door  (best %d/%d)" % [best, per]
			items_label.modulate = Color(1, 0, 0)
		else:
			items_label.text = "Grab a key  (best door %d/%d)" % [best, per]
			items_label.modulate = Color(1, 0, 0)
	else:
		items_label.text = "Runner's best door: %d/%d" % [best, per]
		items_label.modulate = Color(1, 0, 0)

	var active: bool = _gm.grappling() and _gm.winner == ""
	capture_bar.value = _gm.capture_ratio() * 100.0
	escape_bar.value = _gm.escape_ratio() * 100.0
	# Only the Runner has an escape bar to fill.
	escape_label.visible = active and _my_role == Roles.RUNNER
	escape_bar.visible = active and _my_role == Roles.RUNNER

	if active:
		mash_prompt.visible = true
		if _my_role == Roles.RUNNER:
			mash_prompt.text = "GRABBED!  Mash F before the key drops!"
			mash_prompt.modulate = Color(1, 0, 0)
		else:
			mash_prompt.text = "Mash F to knock the key loose!"
			mash_prompt.modulate = Color(1, 0, 0)
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
		banner.text = "Time's up — the monster is contained!"
	banner.text += "\n" + ("You win!" if won else "You lose")
	banner.modulate = Color(1, 0, 0)
