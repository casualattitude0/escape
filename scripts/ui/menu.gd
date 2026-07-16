extends Control

## Dev-build main menu — a hand-drawn "coloring-book / SCP-file" front-end for
## playtesting. Three sections (Host / Find / Local-LAN) sit on a left nav; the
## right panel swaps to match. Once you host or join, the panel becomes the
## lobby (roster + Start). Every section drives the real Net autoload.
##
## Design source: templates/dev-menu/DevMenu.dc.html (Escape Design System),
## imported via the claude_design MCP. The whole UI is built in code so the
## "sticker" look (bold ink outlines + hard offset shadows) and the dynamic
## lobby list live in one place — and so the scene file can stay a bare root
## (the editor owns menu.tscn; _build wipes whatever it holds and rebuilds).

# ---- Palette (tokens/colors.css) ------------------------------------------
const INK := Color("#17151a")
const INK_SOFT := Color("#3b3841")
const INK_FAINT := Color("#6b6772")
const PAPER := Color("#ffffff")
const PAPER_WARM := Color("#fbf6ec")
const PAPER_LINE := Color("#efe9dc")
const GRAY_100 := Color("#f0eeeb")
const GRAY_200 := Color("#ddd9d3")
const GRAY_400 := Color("#948f86")
const CANDY_ORANGE := Color("#ff7a1f")
const CANDY_GREEN := Color("#4fd16b")
const CANDY_PURPLE := Color("#9b5de5")
const CANDY_YELLOW := Color("#ffc53d")
const DANGER := Color("#ff3b30")
const DANGER_DK := Color("#cc2a20")

const LEVELS := ["SECTOR-04B", "COLD-STORAGE", "ATRIUM-9", "INCINERATOR", "SEALED-AIR", "SHAFT-12"]
const ROLES := ["AUTO", "RUNNER", "HUNTER"]

# ---- Fonts (four voices; system substitutes for the design's webfonts) -----
var _f_hand: SystemFont
var _f_body: SystemFont
var _f_mono: SystemFont
var _f_stencil: SystemFont

# ---- State ----------------------------------------------------------------
var _section := "host"
var _connected := false
var _auto_start := false
var _role := "AUTO"
# Source of truth for the join address, so the CLI / dev-loop paths work no
# matter which section panel (and thus which live LineEdit) is currently built.
var _addr := "127.0.0.1"

# ---- Node refs (built in _build) ------------------------------------------
var _name_edit: LineEdit
var _role_btn: Button
var _nav_btns: Dictionary = {}       # section name -> Button
var _quit_btn: Button
var _stage: Control                  # fixed 1280x720 stage, scaled to fit
var _panel_content: MarginContainer  # swappable body of the right panel
var _level_opt: OptionButton
var _room_rows: VBoxContainer
var _lobby_count: Label
var _addr_edit: LineEdit
var _port_edit: LineEdit
var _players_edit: LineEdit
var _log_lbl: Label
var _refresh_timer: Timer

# Lobby (connected) view refs
var _roster_lbl: Label
var _start_btn: Button
var _share_lbl: Label
var _lobby_title: Label

func _ready() -> void:
	_build_fonts()
	_build()
	Net.players_changed.connect(_refresh_roster)
	Net.connection_ok.connect(func(): _say("connected · waiting for host to start"))
	Net.connection_failed_.connect(func(): _reset("connection failed — check the address"))
	Net.server_left.connect(func(): _reset("the host has left"))
	Net.hosted_online.connect(_on_hosted_online)
	var last := Net.last_address()
	if last != "":
		_addr = last
	if OS.has_feature("web"):
		# A browser tab can't bind a listening socket — web can only Join.
		_nav_btns["host"].disabled = true
		_nav_btns["local"].disabled = true
		_select_section("browse")
	_refresh_roster()
	_handle_cli()

# ===========================================================================
# BUILD
# ===========================================================================

func _build_fonts() -> void:
	_f_hand = SystemFont.new()
	_f_hand.font_names = PackedStringArray(["Chalkboard SE", "Bradley Hand", "Marker Felt", "Comic Sans MS", "Nunito"])
	_f_body = SystemFont.new()
	_f_body.font_names = PackedStringArray(["Nunito", "Hiragino Sans GB", "Heiti TC", "Helvetica Neue", "Arial"])
	_f_mono = SystemFont.new()
	_f_mono.font_names = PackedStringArray(["Space Mono", "Menlo", "Courier New"])
	_f_stencil = SystemFont.new()
	_f_stencil.font_names = PackedStringArray(["Saira Stencil One", "Stencil", "Impact", "Arial Black", "Nunito"])

func _build() -> void:
	# The editor owns menu.tscn and may keep legacy nodes in it; start from a
	# clean slate so the scene's contents never matter.
	for c in get_children():
		c.queue_free()

	var desk := ColorRect.new()
	desk.color = GRAY_400
	desk.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	desk.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(desk)

	# Everything is laid out on a fixed 1280x720 stage, then scaled to fit the
	# window (like the design's transform:scale) so no content is ever cropped,
	# whatever the window's size or aspect.
	_stage = Control.new()
	_stage.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_stage.size = Vector2(1280, 720)
	_stage.pivot_offset = Vector2.ZERO
	add_child(_stage)
	get_viewport().size_changed.connect(_fit_stage)
	_fit_stage.call_deferred()

	var screen_margin := MarginContainer.new()
	screen_margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for m in ["left", "right", "top", "bottom"]:
		screen_margin.add_theme_constant_override("margin_" + m, 16)
	_stage.add_child(screen_margin)

	# The "screen" card: paper, thick ink border, rounded, soft paper drop.
	var screen := PanelContainer.new()
	var screen_sb := _box(PAPER, INK, 12, 4)
	screen_sb.shadow_color = Color(INK, 0.20)
	screen_sb.shadow_size = 10
	screen_sb.shadow_offset = Vector2(4, 8)
	screen.add_theme_stylebox_override("panel", screen_sb)
	screen_margin.add_child(screen)

	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 30)
	pad.add_theme_constant_override("margin_right", 30)
	pad.add_theme_constant_override("margin_top", 24)
	pad.add_theme_constant_override("margin_bottom", 24)
	screen.add_child(pad)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	pad.add_child(root)

	root.add_child(_build_top())
	root.add_child(_build_middle())
	root.add_child(_build_bottom())

	_select_section(_section)

## Scale the 1280x720 stage to fit the window, preserving aspect, centered on
## the gray desk (letterboxed on whichever axis has spare room).
func _fit_stage() -> void:
	if _stage == null or not is_instance_valid(_stage):
		return
	var vp := get_viewport_rect().size
	_stage.size = Vector2(1280, 720)
	var s: float = min(vp.x / 1280.0, vp.y / 720.0)
	_stage.scale = Vector2(s, s)
	_stage.position = (vp - Vector2(1280, 720) * s) * 0.5

## --- TOP: title + build tag + identity chip -------------------------------
func _build_top() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)

	var title_box := VBoxContainer.new()
	title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_box.add_theme_constant_override("separation", 4)

	var title_line := HBoxContainer.new()
	title_line.add_theme_constant_override("separation", 14)
	var title := Label.new()
	title.text = "Escape"
	title.add_theme_font_override("font", _f_hand)
	title.add_theme_font_size_override("font_size", 68)
	title.add_theme_color_override("font_color", INK)
	title.add_theme_color_override("font_shadow_color", CANDY_ORANGE)
	title.add_theme_constant_override("shadow_offset_x", 3)
	title.add_theme_constant_override("shadow_offset_y", 3)
	title_line.add_child(title)
	title_line.add_child(_stamp("Dev Build", CANDY_PURPLE, -6.0))
	title_box.add_child(title_line)

	var subtitle := Label.new()
	subtitle.text = "network test menu · develop@a1f4c9"
	subtitle.add_theme_font_override("font", _f_mono)
	subtitle.add_theme_font_size_override("font_size", 13)
	subtitle.add_theme_color_override("font_color", INK_SOFT)
	title_box.add_child(subtitle)

	row.add_child(title_box)
	row.add_child(_build_identity_chip())
	return row

func _build_identity_chip() -> Control:
	var chip := PanelContainer.new()
	chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sb := _box(PAPER, INK, 999, 3)
	sb.shadow_color = INK
	sb.shadow_size = 0
	sb.shadow_offset = Vector2(3, 3)
	sb.content_margin_left = 14
	sb.content_margin_right = 8
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	chip.add_theme_stylebox_override("panel", sb)

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 10)
	hb.add_child(_stencil_label("PLAYER", 9, INK_FAINT))

	_name_edit = LineEdit.new()
	_name_edit.text = "dev_tester"
	_name_edit.placeholder_text = "dev_tester"
	_name_edit.custom_minimum_size = Vector2(110, 0)
	_name_edit.flat = true
	_name_edit.add_theme_font_override("font", _f_mono)
	_name_edit.add_theme_font_size_override("font_size", 14)
	_name_edit.add_theme_color_override("font_color", INK)
	hb.add_child(_name_edit)

	_role_btn = _button(_role, INK, PAPER, _f_stencil, 11, 12, 5, 999)
	_role_btn.pressed.connect(_cycle_role)
	hb.add_child(_role_btn)

	chip.add_child(hb)
	return chip

## --- MIDDLE: left nav + spacer + right panel ------------------------------
func _build_middle() -> Control:
	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 24)

	var nav := VBoxContainer.new()
	nav.custom_minimum_size = Vector2(338, 0)
	nav.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	nav.add_theme_constant_override("separation", 11)
	_nav_btns["host"] = _nav_button("Host Game")
	_nav_btns["browse"] = _nav_button("Find Game")
	_nav_btns["local"] = _nav_button("Local / LAN")
	nav.add_child(_nav_btns["host"])
	nav.add_child(_nav_btns["browse"])
	nav.add_child(_nav_btns["local"])
	_nav_btns["host"].pressed.connect(func(): _select_section("host"))
	_nav_btns["browse"].pressed.connect(func(): _select_section("browse"))
	_nav_btns["local"].pressed.connect(func(): _select_section("local"))

	var sep := Panel.new()
	sep.custom_minimum_size = Vector2(0, 2)
	var sep_sb := StyleBoxFlat.new()
	sep_sb.bg_color = Color(INK, 0.15)
	sep_sb.set_corner_radius_all(2)
	sep.add_theme_stylebox_override("panel", sep_sb)
	var sep_wrap := MarginContainer.new()
	sep_wrap.add_theme_constant_override("margin_top", 5)
	sep_wrap.add_theme_constant_override("margin_bottom", 5)
	sep_wrap.add_child(sep)
	nav.add_child(sep_wrap)

	_quit_btn = _nav_button("Quit to Desktop")
	_quit_btn.add_theme_color_override("font_color", DANGER_DK)
	_quit_btn.pressed.connect(_on_quit)
	nav.add_child(_quit_btn)
	row.add_child(nav)

	# Spacer (a mascot would show through here in the full design).
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(496, 0)
	panel.size_flags_vertical = Control.SIZE_FILL
	var panel_sb := _box(PAPER_WARM, INK, 14, 3)
	panel_sb.shadow_color = Color(INK, 0.20)
	panel_sb.shadow_size = 8
	panel_sb.shadow_offset = Vector2(4, 8)
	panel_sb.content_margin_left = 24
	panel_sb.content_margin_right = 24
	panel_sb.content_margin_top = 22
	panel_sb.content_margin_bottom = 20
	panel.add_theme_stylebox_override("panel", panel_sb)

	_panel_content = MarginContainer.new()
	panel.add_child(_panel_content)
	row.add_child(panel)
	return row

## --- BOTTOM: kbd hints + net status + stdout ------------------------------
func _build_bottom() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)

	var hints := HBoxContainer.new()
	hints.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hints.add_theme_constant_override("separation", 14)
	hints.add_child(_hint("↑↓", "navigate"))
	hints.add_child(_hint("Enter", "select"))
	hints.add_child(_hint("Esc", "back"))
	row.add_child(hints)

	var ready_box := HBoxContainer.new()
	ready_box.add_theme_constant_override("separation", 7)
	var dot := Panel.new()
	dot.custom_minimum_size = Vector2(11, 11)
	dot.add_theme_stylebox_override("panel", _box(CANDY_GREEN, INK, 999, 2))
	var dot_wrap := CenterContainer.new()
	dot_wrap.add_child(dot)
	ready_box.add_child(dot_wrap)
	ready_box.add_child(_stencil_label("Net Ready", 10, INK))
	row.add_child(ready_box)

	var pill := PanelContainer.new()
	var pill_sb := _box(INK, INK, 999, 0)
	pill_sb.content_margin_left = 14
	pill_sb.content_margin_right = 14
	pill_sb.content_margin_top = 6
	pill_sb.content_margin_bottom = 6
	pill.add_theme_stylebox_override("panel", pill_sb)
	var pill_hb := HBoxContainer.new()
	pill_hb.add_theme_constant_override("separation", 10)
	pill_hb.add_child(_stencil_label("stdout", 9, GRAY_400))
	_log_lbl = Label.new()
	_log_lbl.text = "> ready · net idle"
	_log_lbl.add_theme_font_override("font", _f_mono)
	_log_lbl.add_theme_font_size_override("font_size", 12)
	_log_lbl.add_theme_color_override("font_color", CANDY_GREEN)
	_log_lbl.clip_text = true
	_log_lbl.custom_minimum_size = Vector2(280, 0)
	pill_hb.add_child(_log_lbl)
	pill.add_child(pill_hb)
	row.add_child(pill)
	return row

# ===========================================================================
# SECTION PANELS
# ===========================================================================

func _select_section(section: String) -> void:
	if _connected:
		return
	_section = section
	for key in _nav_btns:
		_style_nav_button(_nav_btns[key], key == section)
	match section:
		"host":
			_show_panel(_build_host_panel())
		"browse":
			_show_panel(_build_browse_panel())
			_start_room_refresh()
		"local":
			_show_panel(_build_local_panel())
	if section != "browse":
		_stop_room_refresh()

func _show_panel(node: Control) -> void:
	for c in _panel_content.get_children():
		c.queue_free()
	_panel_content.add_child(node)

func _build_host_panel() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	box.add_child(_section_heading("Host Session"))

	box.add_child(_field_label("Level"))
	_level_opt = OptionButton.new()
	for lvl in LEVELS:
		_level_opt.add_item(lvl)
	_level_opt.add_theme_font_override("font", _f_mono)
	_level_opt.add_theme_font_size_override("font_size", 14)
	_level_opt.add_theme_color_override("font_color", INK)
	var opt_sb := _box(PAPER, INK, 3, 2)
	opt_sb.content_margin_left = 12
	opt_sb.content_margin_right = 12
	opt_sb.content_margin_top = 8
	opt_sb.content_margin_bottom = 8
	_level_opt.add_theme_stylebox_override("normal", opt_sb)
	_level_opt.add_theme_stylebox_override("hover", opt_sb)
	_level_opt.add_theme_stylebox_override("pressed", opt_sb)
	_level_opt.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	box.add_child(_level_opt)

	var host_btn := _button("Host Game  →", CANDY_GREEN, PAPER, _f_hand, 24, 20, 14, 9)
	host_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host_btn.pressed.connect(_on_host_online)
	box.add_child(host_btn)
	return box

func _build_browse_panel() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)

	var head := HBoxContainer.new()
	var head_lbl := _section_heading("Lobby Browser")
	head_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(head_lbl)
	_lobby_count = Label.new()
	_lobby_count.text = "· scanning…"
	_lobby_count.add_theme_font_override("font", _f_mono)
	_lobby_count.add_theme_font_size_override("font_size", 12)
	_lobby_count.add_theme_color_override("font_color", INK_FAINT)
	_lobby_count.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_lobby_count)
	var refresh_btn := _button("↻", PAPER, INK, _f_hand, 16, 12, 5, 9)
	refresh_btn.pressed.connect(_refresh_rooms)
	head.add_child(refresh_btn)
	box.add_child(head)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 262)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_room_rows = VBoxContainer.new()
	_room_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_room_rows)
	box.add_child(scroll)
	return box

func _build_local_panel() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	box.add_child(_section_heading("Local / LAN"))

	var grid := HBoxContainer.new()
	grid.add_theme_constant_override("separation", 12)
	var port_col := VBoxContainer.new()
	port_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	port_col.add_theme_constant_override("separation", 6)
	port_col.add_child(_field_label("Host · Port"))
	_port_edit = _text_input(str(Net.PORT))
	port_col.add_child(_port_edit)
	grid.add_child(port_col)
	var players_col := VBoxContainer.new()
	players_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	players_col.add_theme_constant_override("separation", 6)
	players_col.add_child(_field_label("Players"))
	_players_edit = _text_input("2")
	players_col.add_child(_players_edit)
	grid.add_child(players_col)
	box.add_child(grid)

	var spawn_btn := _button("Host", CANDY_GREEN, PAPER, _f_hand, 20, 20, 12, 9)
	spawn_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spawn_btn.pressed.connect(_on_quick_host_join)
	box.add_child(spawn_btn)

	box.add_child(_divider())

	box.add_child(_field_label("Join · Address"))
	var join_row := HBoxContainer.new()
	join_row.add_theme_constant_override("separation", 10)
	_addr_edit = _text_input(_addr)
	_addr_edit.placeholder_text = "127.0.0.1"
	_addr_edit.text_changed.connect(func(t): _addr = t)
	_addr_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	join_row.add_child(_addr_edit)
	var connect_btn := _button("Connect", CANDY_PURPLE, PAPER, _f_hand, 20, 18, 11, 9)
	connect_btn.pressed.connect(_on_join)
	join_row.add_child(connect_btn)
	box.add_child(join_row)

	var presets := HBoxContainer.new()
	presets.add_theme_constant_override("separation", 8)
	var loop_btn := _button("127.0.0.1", GRAY_100, INK, _f_mono, 12, 12, 5, 999)
	loop_btn.pressed.connect(func(): _set_addr("127.0.0.1"))
	presets.add_child(loop_btn)
	var lan_btn := _button("192.168.1.x", GRAY_100, INK, _f_mono, 12, 12, 5, 999)
	lan_btn.pressed.connect(func(): _set_addr("192.168.1."))
	presets.add_child(lan_btn)
	box.add_child(presets)

	box.add_child(_divider())

	box.add_child(_field_label("Quick Dev"))
	var quick := HBoxContainer.new()
	quick.add_theme_constant_override("separation", 10)
	var rc := _button("Reconnect", PAPER, INK, _f_hand, 15, 14, 8, 9)
	rc.pressed.connect(_on_quick_reconnect)
	quick.add_child(rc)
	var kill := _button("Kill", DANGER, PAPER, _f_hand, 15, 14, 8, 9)
	kill.pressed.connect(_on_kill)
	quick.add_child(kill)
	box.add_child(quick)
	return box

## The lobby view replaces the section body once we host/join, so the roster
## and the host's Start button live where the section panel was.
func _build_lobby_panel(is_host: bool) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	_lobby_title = _section_heading("Room Open" if is_host else "Connecting…")
	box.add_child(_lobby_title)

	_share_lbl = Label.new()
	_share_lbl.add_theme_font_override("font", _f_mono)
	_share_lbl.add_theme_font_size_override("font_size", 13)
	_share_lbl.add_theme_color_override("font_color", INK_SOFT)
	_share_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_share_lbl.visible = false
	box.add_child(_share_lbl)

	box.add_child(_field_label("Roster"))
	_roster_lbl = Label.new()
	_roster_lbl.text = "Not connected"
	_roster_lbl.add_theme_font_override("font", _f_mono)
	_roster_lbl.add_theme_font_size_override("font_size", 14)
	_roster_lbl.add_theme_color_override("font_color", CANDY_GREEN.darkened(0.15))
	box.add_child(_roster_lbl)

	box.add_child(_divider())

	_start_btn = _button("Start Game  →", CANDY_ORANGE, PAPER, _f_hand, 22, 20, 13, 9)
	_start_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_start_btn.visible = is_host
	_start_btn.disabled = true
	_start_btn.pressed.connect(func(): Net.start_game())
	box.add_child(_start_btn)

	var leave_btn := _button("Leave Lobby", PAPER, DANGER_DK, _f_hand, 18, 18, 10, 9)
	leave_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	leave_btn.pressed.connect(func(): _reset("left the lobby"))
	box.add_child(leave_btn)
	return box

# ===========================================================================
# WIDGET HELPERS
# ===========================================================================

func _box(bg: Color, border: Color, radius: int, border_w: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	if border_w > 0:
		sb.set_border_width_all(border_w)
		sb.border_color = border
	return sb

## A "sticker" button: bold ink outline + hard offset shadow, styled for every
## interaction state (press nudges content toward the shadow, like a real press).
func _button(text: String, fill: Color, fg: Color, font: Font, font_size: int, pad_h: int, pad_v: int, radius: int) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_override("font", font)
	b.add_theme_font_size_override("font_size", font_size)
	b.add_theme_color_override("font_color", fg)
	b.add_theme_color_override("font_hover_color", fg)
	b.add_theme_color_override("font_pressed_color", fg)
	b.add_theme_color_override("font_focus_color", fg)
	b.add_theme_color_override("font_disabled_color", Color(fg, 0.5))

	var normal := _box(fill, INK, radius, 3)
	normal.shadow_color = INK
	normal.shadow_size = 0
	normal.shadow_offset = Vector2(3, 3)
	_pad(normal, pad_h, pad_v, Vector2(0, 0))

	var hover := normal.duplicate()
	hover.bg_color = fill.lightened(0.06)

	var pressed := _box(fill, INK, radius, 3)
	pressed.shadow_color = INK
	pressed.shadow_size = 0
	pressed.shadow_offset = Vector2(1, 1)
	_pad(pressed, pad_h, pad_v, Vector2(2, 2))

	var disabled := _box(GRAY_200, INK, radius, 3)
	_pad(disabled, pad_h, pad_v, Vector2(0, 0))

	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("disabled", disabled)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return b

func _pad(sb: StyleBoxFlat, pad_h: int, pad_v: int, shift: Vector2) -> void:
	sb.content_margin_left = pad_h + shift.x
	sb.content_margin_right = pad_h - shift.x
	sb.content_margin_top = pad_v + shift.y
	sb.content_margin_bottom = pad_v - shift.y

func _nav_button(text: String) -> Button:
	var b := _button("·  " + text, PAPER, INK, _f_hand, 30, 18, 13, 8)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return b

## Active nav item pops: candy fill, white ink, a bigger sticker shadow.
func _style_nav_button(b: Button, active: bool) -> void:
	var space := b.text.find(" ")
	var label := b.text.substr(space).strip_edges() if space >= 0 else b.text
	b.text = ("»  " if active else "·  ") + label
	var fill := CANDY_ORANGE if active else PAPER
	var fg := PAPER if active else INK
	if b == _quit_btn:
		fg = DANGER_DK
	var normal := _box(fill, INK, 8, 3)
	normal.shadow_color = INK
	normal.shadow_size = 0
	normal.shadow_offset = Vector2(5, 5) if active else Vector2(3, 3)
	_pad(normal, 18, 13, Vector2(0, 0))
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", normal)
	b.add_theme_color_override("font_color", fg)
	b.add_theme_color_override("font_hover_color", fg)

func _stamp(text: String, color: Color, rot: float) -> Control:
	var wrap := Control.new()
	wrap.custom_minimum_size = Vector2(122, 40)
	wrap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var badge := PanelContainer.new()
	var sb := _box(color, INK, 6, 3)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 5
	sb.content_margin_bottom = 5
	badge.add_theme_stylebox_override("panel", sb)
	badge.add_child(_stencil_label(text, 13, PAPER))
	wrap.add_child(badge)
	badge.pivot_offset = Vector2(60, 20)
	badge.rotation_degrees = rot
	badge.position = Vector2(0, 4)
	return wrap

func _stencil_label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text.to_upper()
	l.add_theme_font_override("font", _f_stencil)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l

func _section_heading(text: String) -> Label:
	return _stencil_label(text, 20, INK)

func _field_label(text: String) -> Label:
	return _stencil_label(text, 12, INK_SOFT)

func _text_input(value: String) -> LineEdit:
	var e := LineEdit.new()
	e.text = value
	e.add_theme_font_override("font", _f_mono)
	e.add_theme_font_size_override("font_size", 15)
	e.add_theme_color_override("font_color", INK)
	var sb := _box(PAPER, INK, 3, 2)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	e.add_theme_stylebox_override("normal", sb)
	e.add_theme_stylebox_override("focus", _box(PAPER, CANDY_ORANGE, 3, 2))
	return e

func _divider() -> Control:
	var d := Panel.new()
	d.custom_minimum_size = Vector2(0, 2)
	var sb := StyleBoxFlat.new()
	sb.bg_color = INK
	d.add_theme_stylebox_override("panel", sb)
	var wrap := MarginContainer.new()
	wrap.add_theme_constant_override("margin_top", 6)
	wrap.add_theme_constant_override("margin_bottom", 6)
	wrap.add_child(d)
	return wrap

func _hint(key: String, action: String) -> Control:
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)
	var cap := PanelContainer.new()
	var sb := _box(PAPER, INK, 5, 2)
	sb.shadow_color = INK
	sb.shadow_size = 0
	sb.shadow_offset = Vector2(1, 1)
	sb.content_margin_left = 7
	sb.content_margin_right = 7
	sb.content_margin_top = 3
	sb.content_margin_bottom = 3
	cap.add_theme_stylebox_override("panel", sb)
	var kl := Label.new()
	kl.text = key
	kl.add_theme_font_override("font", _f_mono)
	kl.add_theme_font_size_override("font_size", 11)
	kl.add_theme_color_override("font_color", INK)
	cap.add_child(kl)
	hb.add_child(cap)
	var al := Label.new()
	al.text = action
	al.add_theme_font_override("font", _f_mono)
	al.add_theme_font_size_override("font_size", 11)
	al.add_theme_color_override("font_color", INK_SOFT)
	al.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hb.add_child(al)
	return hb

# ===========================================================================
# LOBBY BROWSER
# ===========================================================================

func _start_room_refresh() -> void:
	if _refresh_timer == null:
		_refresh_timer = Timer.new()
		_refresh_timer.wait_time = 5.0
		_refresh_timer.timeout.connect(_refresh_rooms)
		add_child(_refresh_timer)
	_refresh_timer.start()
	_refresh_rooms()

func _stop_room_refresh() -> void:
	if _refresh_timer != null:
		_refresh_timer.stop()

func _refresh_rooms() -> void:
	if _room_rows == null or not is_instance_valid(_room_rows):
		return
	var rooms: Array = await Net.list_rooms()
	if _room_rows == null or not is_instance_valid(_room_rows):
		return
	for c in _room_rows.get_children():
		c.queue_free()
	for room in rooms:
		if not (room is Dictionary):
			continue
		_room_rows.add_child(_room_row(room))
	if rooms.is_empty():
		var empty := Label.new()
		empty.text = "No open rooms found."
		empty.add_theme_font_override("font", _f_body)
		empty.add_theme_font_size_override("font_size", 14)
		empty.add_theme_color_override("font_color", INK_FAINT)
		_room_rows.add_child(empty)
	if _lobby_count != null and is_instance_valid(_lobby_count):
		_lobby_count.text = "· %d sessions" % rooms.size()

func _room_row(room: Dictionary) -> Control:
	var count := int(room.get("player_count", 0))
	var maxp := int(room.get("max_players", 0))
	var is_full := maxp > 0 and count >= maxp
	var room_id: String = str(room.get("room_id", ""))

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_color = PAPER_LINE
	sb.border_width_bottom = 2
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	sb.content_margin_left = 4
	sb.content_margin_right = 4
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", sb)
	pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var inner := HBoxContainer.new()
	inner.add_theme_constant_override("separation", 12)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 2)
	var name_lbl := Label.new()
	name_lbl.text = str(room.get("name", "?"))
	name_lbl.add_theme_font_override("font", _f_body)
	name_lbl.add_theme_font_size_override("font_size", 14)
	name_lbl.add_theme_color_override("font_color", INK)
	name_lbl.clip_text = true
	info.add_child(name_lbl)
	var meta := Label.new()
	meta.text = "%d / %d players" % [count, maxp]
	meta.add_theme_font_override("font", _f_mono)
	meta.add_theme_font_size_override("font_size", 11)
	meta.add_theme_color_override("font_color", INK_FAINT)
	info.add_child(meta)
	inner.add_child(info)

	var pill := PanelContainer.new()
	var pill_sb := _box(CANDY_GREEN if not is_full else INK_FAINT, INK, 999, 2)
	pill_sb.content_margin_left = 10
	pill_sb.content_margin_right = 10
	pill_sb.content_margin_top = 3
	pill_sb.content_margin_bottom = 3
	pill.add_theme_stylebox_override("panel", pill_sb)
	pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pill.add_child(_stencil_label("Open" if not is_full else "Full", 9, PAPER))
	inner.add_child(pill)

	var join_btn := _button("Join", CANDY_ORANGE if not is_full else GRAY_200, PAPER if not is_full else INK_FAINT, _f_hand, 16, 14, 6, 8)
	join_btn.custom_minimum_size = Vector2(70, 0)
	join_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	join_btn.disabled = is_full or room_id == ""
	if not join_btn.disabled:
		join_btn.pressed.connect(func(): _join_room(room_id))
	inner.add_child(join_btn)

	pc.add_child(inner)
	return pc

# ===========================================================================
# NET WIRING
# ===========================================================================

func _on_host_lan() -> void:
	_apply_port_override()
	var err := Net.host()
	if err != OK:
		_say("failed to host (%d) — port may be in use" % err)
		return
	_say("HOST local · 0.0.0.0:%d · %s" % [Net.port(), _current_level()])
	_enter_connected(true)

func _on_host_online() -> void:
	var err := Net.host_online(_room_name())
	if err != OK:
		_say("failed to reach the relay (%d)" % err)
		return
	_say("HOST · %s · as %s [%s]" % [_current_level(), _player_name(), _role])
	_enter_connected(true)

func _on_join() -> void:
	var ip := _addr.strip_edges()
	if ip == "":
		ip = "127.0.0.1"
	_apply_port_override()
	var err := Net.join(ip)
	if err != OK:
		_say("could not connect (%d)" % err)
		return
	_say("CONNECT %s:%d · as %s" % [ip, Net.port(), _player_name()])
	_enter_connected(false)

func _join_room(room_id: String) -> void:
	var err := Net.join_relay(room_id)
	if err != OK:
		_say("could not reach the relay (%d)" % err)
		return
	_say("join relay room %s · as %s" % [room_id, _player_name()])
	_enter_connected(false)

func _on_hosted_online(room_id: String) -> void:
	if _lobby_title != null and is_instance_valid(_lobby_title):
		_lobby_title.text = "Room Open — Online"
	if _share_lbl != null and is_instance_valid(_share_lbl):
		_share_lbl.text = "Room code: %s" % room_id
		_share_lbl.visible = true
	_say("online room open · code %s" % room_id)

func _on_quick_host_join() -> void:
	# One-process convenience: open a room and auto-start as soon as a second
	# window (a manually-launched client) connects.
	_auto_start = true
	_on_host_lan()
	_say("QUICK · host + auto-start when a client joins @ 127.0.0.1:%d" % Net.port())

func _on_quick_reconnect() -> void:
	var last := Net.last_address()
	if last == "":
		last = "127.0.0.1"
	_set_addr(last)
	_on_join()

func _on_kill() -> void:
	Net.leave()
	_reset("KILL · session terminated · net idle")

func _on_quit() -> void:
	_say("QUIT · shutting down dev client…")
	get_tree().quit()

func _apply_port_override() -> void:
	if _port_edit != null and is_instance_valid(_port_edit):
		var p := int(_port_edit.text.strip_edges())
		if p > 0:
			Net.set_port_override(p)

func _enter_connected(is_host: bool) -> void:
	# A deliberate (re)connect — clear the "left to menu" latch so the dev loop
	# resumes auto-connecting on future launches.
	Net.clear_left_to_menu()
	_connected = true
	_stop_room_refresh()
	for key in _nav_btns:
		_nav_btns[key].disabled = true
	_quit_btn.disabled = true
	_show_panel(_build_lobby_panel(is_host))
	if is_host and not OS.has_feature("web"):
		var addrs := PackedStringArray()
		for ip in IP.get_local_addresses():
			if ip.find(":") == -1 and not ip.begins_with("127."):
				addrs.append(ip)
		if not addrs.is_empty() and _share_lbl != null:
			_share_lbl.text = "Share with testers: %s (port %d)" % [", ".join(addrs), Net.port()]
			_share_lbl.visible = true
	_refresh_roster()

func _reset(msg: String) -> void:
	Net.leave()
	_connected = false
	_auto_start = false
	for key in _nav_btns:
		_nav_btns[key].disabled = false
	_quit_btn.disabled = false
	_say(msg)
	_select_section(_section)
	_refresh_roster()

func _refresh_roster() -> void:
	if _roster_lbl == null or not is_instance_valid(_roster_lbl):
		return
	if Net.players.is_empty():
		_roster_lbl.text = "Not connected"
		if _start_btn != null and is_instance_valid(_start_btn):
			_start_btn.disabled = true
		return
	var lines := PackedStringArray()
	var ids := Net.players.keys()
	ids.sort()
	for id in ids:
		var tag := "  (you)" if id == multiplayer.get_unique_id() else ""
		lines.append("· %s  [%s]%s" % [id, Net.players[id], tag])
	_roster_lbl.text = "\n".join(lines)
	if _start_btn != null and is_instance_valid(_start_btn):
		_start_btn.disabled = Net.players.size() < 2
	# Need the Runner + at least one Hunter to start.
	if _auto_start and Net.is_host() and Net.players.size() >= 2:
		_auto_start = false
		Net.start_game()

# ===========================================================================
# SMALL HELPERS
# ===========================================================================

func _say(msg: String) -> void:
	if _log_lbl != null and is_instance_valid(_log_lbl):
		_log_lbl.text = "> " + msg

func _set_addr(v: String) -> void:
	_addr = v
	if _addr_edit != null and is_instance_valid(_addr_edit):
		_addr_edit.text = v

func _player_name() -> String:
	if _name_edit != null and _name_edit.text.strip_edges() != "":
		return _name_edit.text.strip_edges()
	return "dev_tester"

func _current_level() -> String:
	if _level_opt != null and is_instance_valid(_level_opt) and _level_opt.selected >= 0:
		return LEVELS[_level_opt.selected]
	return LEVELS[0]

func _room_name() -> String:
	return "%s · %s" % [_player_name(), _current_level()]

func _cycle_role() -> void:
	var i := ROLES.find(_role)
	_role = ROLES[(i + 1) % ROLES.size()]
	_role_btn.text = _role
	_say("role → %s" % _role)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and _connected:
		_reset("left the lobby")
		get_viewport().set_input_as_handled()

# ===========================================================================
# DEV LAUNCH  (behaviour preserved from the original menu.gd)
# ===========================================================================

## Dev convenience so a script edit + restart drops you straight back into a
## match with no clicks. Launch tokens (used by the headless smoke test):
##   host              open a room and auto-start once a Hunter joins
##   join[=<ip>]       auto-join (default 127.0.0.1)
##   resume            also restore the in-progress match (DevSnapshot)
##   hostonline[=<name>]   host via the relay (see Net.RELAY_WS_URL)
##   joinrelay=<room_id>   join a relay room directly, skipping the browse list
##   relay=<url>       point host_online/join_relay at a local relay-server
##   port=<n> / token=<t> / auto
##
## With no tokens, running from the editor (Net.DEV_AUTOCONNECT) the two windows
## self-negotiate: each tries to host, whoever binds the port first is the
## Runner and the other auto-joins. Never fires in an exported build.
func _handle_cli() -> void:
	var mode := ""
	var resume := false
	var auto := false
	var room_id := ""
	for arg in OS.get_cmdline_user_args():
		if arg == "host":
			mode = "host"
		elif arg.begins_with("joinrelay="):
			mode = "joinrelay"
			room_id = arg.split("=")[1]
		elif arg == "hostonline" or arg.begins_with("hostonline="):
			mode = "hostonline"
			var parts := arg.split("=")
			if parts.size() > 1 and _name_edit != null:
				_name_edit.text = parts[1]
		elif arg == "join" or arg.begins_with("join="):
			mode = "join"
			var parts := arg.split("=")
			if parts.size() > 1:
				_set_addr(parts[1])
		elif arg.begins_with("map="):
			Net.world_scene = "res://scenes/levels/section1.tscn"
		elif arg == "resume":
			resume = true
		elif arg == "auto":
			auto = true
		elif arg.begins_with("port="):
			Net.set_port_override(int(arg.split("=")[1]))
		elif arg.begins_with("token="):
			Net.set_token(arg.split("=")[1])
		elif arg.begins_with("relay="):
			Net.set_relay_url_override(arg.split("=", true, 1)[1])
	# If we deliberately left to the menu, stay at the lobby on launch instead of
	# auto-reconnecting. Persists across every launch (and both editor instances)
	# until the player deliberately reconnects — see _clear_left_to_menu callers.
	if Net.left_to_menu():
		Net.suppress_autoconnect = true
	# Self-negotiate: explicit "auto" token, or the editor two-window loop.
	if mode == "" and not Net.suppress_autoconnect and (auto or (Net.DEV_AUTOCONNECT and OS.has_feature("editor"))):
		if not auto:
			resume = true          # the editor loop always resumes
		Net.dev_resume = resume
		if Net.host() == OK:
			_auto_start = true
			_say("dev · hosting, waiting for a client")
			_enter_connected(true)
		else:
			_set_addr("127.0.0.1")
			_on_join()
		return
	Net.dev_resume = resume
	if mode == "host":
		_auto_start = true
		_on_host_lan()
	elif mode == "join":
		_on_join()
	elif mode == "hostonline":
		_auto_start = true
		_on_host_online()
	elif mode == "joinrelay":
		_join_room(room_id)
