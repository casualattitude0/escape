extends Control

## Lobby: host or join a game, then the host starts it.

@onready var host_btn: Button = %HostButton
@onready var join_btn: Button = %JoinButton
@onready var start_btn: Button = %StartButton
@onready var address: LineEdit = %Address
@onready var status: Label = %Status
@onready var roster: Label = %Roster

var _auto_start := false

func _ready() -> void:
	host_btn.pressed.connect(_on_host)
	join_btn.pressed.connect(_on_join)
	start_btn.pressed.connect(func(): Net.start_game())
	Net.players_changed.connect(_refresh)
	Net.connection_ok.connect(func(): status.text = "已連線，等待房主開始…")
	Net.connection_failed_.connect(func(): _reset("連線失敗，請確認 IP。"))
	Net.server_left.connect(func(): _reset("房主已離開。"))
	_refresh()
	_handle_cli()

## Dev convenience for testing with two windows, e.g.
##   Godot --path . -- host          (opens a room, auto-starts on 1st join)
##   Godot --path . -- join=127.0.0.1
func _handle_cli() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "host":
			_auto_start = true
			_on_host()
		elif arg.begins_with("join"):
			var parts := arg.split("=")
			if parts.size() > 1:
				address.text = parts[1]
			_on_join()

func _on_host() -> void:
	var err := Net.host()
	if err != OK:
		status.text = "開房失敗 (%d)。連接埠可能被占用。" % err
		return
	status.text = "已開房 (Runner)。等待 Hunter 加入…"
	_enter_connected(true)

func _on_join() -> void:
	var ip := address.text.strip_edges()
	if ip == "":
		ip = "127.0.0.1"
	var err := Net.join(ip)
	if err != OK:
		status.text = "無法連線 (%d)。" % err
		return
	status.text = "連線中…"
	_enter_connected(false)

func _enter_connected(is_host: bool) -> void:
	host_btn.disabled = true
	join_btn.disabled = true
	address.editable = false
	start_btn.visible = is_host

func _reset(msg: String) -> void:
	Net.leave()
	host_btn.disabled = false
	join_btn.disabled = false
	address.editable = true
	start_btn.visible = false
	status.text = msg
	_refresh()

func _refresh() -> void:
	if Net.players.is_empty():
		roster.text = "尚未連線"
		start_btn.disabled = true
		return
	var lines := PackedStringArray()
	var ids := Net.players.keys()
	ids.sort()
	for id in ids:
		var tag := "（你）" if id == multiplayer.get_unique_id() else ""
		lines.append("· %s  [%s]%s" % [id, Net.players[id], tag])
	roster.text = "\n".join(lines)
	# Need at least the Runner + 1 Hunter to start.
	start_btn.disabled = Net.players.size() < 2
	if _auto_start and Net.is_host() and Net.players.size() >= 2:
		_auto_start = false
		Net.start_game()
