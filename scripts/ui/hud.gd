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
	role_label.modulate = Color(0.55, 0.85, 0.65) if _my_role == Roles.RUNNER else Color(0.9, 0.5, 0.5)
	hint_label.text = "Move A/D   Jump Space   Slide Shift/S into tunnels   Attack F (kills Hunters)\nGrab a key, follow the arrow to a door — 3 keys in one door escapes. Beat the clock!" if _my_role == Roles.RUNNER \
		else "Move A/D   Jump Space   Get close to a key-carrying Runner and MASH F to knock the key loose\nJust run out the clock. Vision is limited — noises clear your sight nearby, or ping the minimap"
	_refresh()

func _process(_delta: float) -> void:
	if _gm == null:
		return
	var s: int = _gm.time_seconds()
	timer_label.text = "%d:%02d" % [s / 60, s % 60]
	timer_label.modulate = Color(0.95, 0.4, 0.4) if s <= 15 else Color(1, 1, 1)

func _refresh() -> void:
	if _gm == null:
		return
	var per: int = _gm.per_door()
	var best: int = _gm.best_progress()
	if _my_role == Roles.RUNNER:
		if _gm.carrying():
			items_label.text = "Key in hand — deliver it to a door  (best %d/%d)" % [best, per]
			items_label.modulate = Color(1.0, 0.85, 0.4)
		else:
			items_label.text = "Grab a key  (best door %d/%d)" % [best, per]
			items_label.modulate = Color(1, 1, 1)
	else:
		items_label.text = "Runner's best door: %d/%d" % [best, per]
		items_label.modulate = Color(1, 1, 1)

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
			mash_prompt.modulate = Color(1, 0.85, 0.3)
		else:
			mash_prompt.text = "Mash F to knock the key loose!"
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
		banner.text = "Time's up — the monster is contained!"
	banner.text += "\n" + ("You win!" if won else "You lose")
	banner.modulate = Color(0.6, 0.9, 0.6) if won else Color(0.9, 0.55, 0.55)
