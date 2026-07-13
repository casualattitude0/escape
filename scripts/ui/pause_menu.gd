extends CanvasLayer
class_name PauseMenu

## In-match overlay opened with Esc. It does NOT freeze the networked simulation
## (the other players keep going — you can't pause them), it just suspends this
## player's local input and offers to leave. Self-contained: builds its own UI in
## code and is instantiated by world.gd, so no scene wiring is required.

var _resume_btn: Button

func _ready() -> void:
	layer = 128                                   # above the HUD
	process_mode = Node.PROCESS_MODE_ALWAYS       # keep working even if the tree pauses
	_build()
	visible = false

func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP  # swallow clicks so the game doesn't get them
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	vbox.custom_minimum_size = Vector2(240, 0)
	center.add_child(vbox)

	var title := Label.new()
	title.text = "Paused"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	_resume_btn = _make_button(vbox, "Resume", close)
	_make_button(vbox, "Leave to Menu", _leave)
	_make_button(vbox, "Quit Game", func(): get_tree().quit())

func _make_button(parent: Node, text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 40)
	b.pressed.connect(on_press)
	parent.add_child(b)
	return b

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		toggle()
		get_viewport().set_input_as_handled()

func toggle() -> void:
	if visible:
		close()
	else:
		open()

func open() -> void:
	visible = true
	Net.local_input_locked = true
	_resume_btn.grab_focus()

func close() -> void:
	visible = false
	Net.local_input_locked = false

func _leave() -> void:
	Net.local_input_locked = false
	# Stay at the lobby instead of instantly re-connecting via the dev loop.
	Net.suppress_autoconnect = true
	Net.leave()
	get_tree().change_scene_to_file("res://scenes/menu.tscn")
