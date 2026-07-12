extends CanvasLayer

## Reads the replicated game state and shows role, item progress, the capture
## read-bar and the end-of-game banner.

@onready var role_label: Label = %RoleLabel
@onready var items_label: Label = %ItemsLabel
@onready var hint_label: Label = %HintLabel
@onready var capture_bar: ProgressBar = %CaptureBar
@onready var banner: Label = %Banner

var _gm: Node
var _my_role := "hunter"

func _ready() -> void:
	_my_role = Net.players.get(multiplayer.get_unique_id(), "hunter")
	_gm = get_tree().get_first_node_in_group("game_manager")
	if _gm != null:
		_gm.state_changed.connect(_refresh)
	role_label.text = "你是：Runner（逃脫）" if _my_role == "runner" else "你是：Hunter（追捕）"
	role_label.modulate = Color(0.55, 0.85, 0.65) if _my_role == "runner" else Color(0.9, 0.5, 0.5)
	hint_label.text = "移動 A/D　跳 Space　滑行 Shift／S　攻擊 F" if _my_role == "runner" \
		else "移動 A/D　跳 Space　貼近怪物按住 E 讀條壓制"
	_refresh()

func _refresh() -> void:
	if _gm == null:
		return
	items_label.text = "物件 %d / %d" % [_gm.items_collected, _gm.items_total]
	capture_bar.value = _gm.capture_ratio() * 100.0
	if _gm.winner == "":
		banner.visible = false
		return
	banner.visible = true
	var won: bool = (_gm.winner == _my_role) or (_gm.winner == "hunters" and _my_role == "hunter")
	if _gm.winner == "runner":
		banner.text = "Runner 逃脫成功！"
	else:
		banner.text = "怪物已被重新收容！"
	banner.text += "\n" + ("你贏了 🏆" if won else "你輸了")
	banner.modulate = Color(0.6, 0.9, 0.6) if won else Color(0.9, 0.55, 0.55)
