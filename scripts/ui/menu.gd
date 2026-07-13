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
	Net.connection_ok.connect(func(): status.text = "Connected. Waiting for host to start...")
	Net.connection_failed_.connect(func(): _reset("Connection failed. Check the IP."))
	Net.server_left.connect(func(): _reset("The host has left."))
	var last := Net.last_address()
	if last != "" and address.text.strip_edges() == "":
		address.text = last
	_refresh()
	_handle_cli()

## Dev convenience so a script edit + restart drops you straight back into a
## match with no clicks.
##
## Explicit launch tokens (used by the headless smoke test):
##   host              open a room and auto-start once a Hunter joins
##   join[=<ip>]       auto-join (default 127.0.0.1)
##   resume            also restore the in-progress match (DevSnapshot)
##
## With no tokens, when running from the editor (Net.DEV_AUTOCONNECT), the two
## windows self-negotiate: each tries to host, whoever binds the port first is
## the Runner and the other auto-joins as a Hunter. This needs no per-instance
## editor config (which the running editor owns and overwrites) — just "Run
## Multiple Instances" with a count of 2. Never fires in an exported build.
func _handle_cli() -> void:
	var mode := ""
	var resume := false
	var auto := false
	for arg in OS.get_cmdline_user_args():
		if arg == "host":
			mode = "host"
		elif arg.begins_with("join"):
			mode = "join"
			var parts := arg.split("=")
			if parts.size() > 1:
				address.text = parts[1]
		elif arg == "resume":
			resume = true
		elif arg == "auto":
			auto = true
	# Self-negotiate: explicit "auto" token, or the editor two-window loop.
	if mode == "" and not Net.suppress_autoconnect and (auto or (Net.DEV_AUTOCONNECT and OS.has_feature("editor"))):
		if not auto:
			resume = true          # the editor loop always resumes
		Net.dev_resume = resume
		if Net.host() == OK:
			# Won the race — we are the Runner. Auto-start when a Hunter joins.
			_auto_start = true
			_host_succeeded()
		else:
			# Someone already hosts — join them.
			address.text = "127.0.0.1"
			_on_join()
		return
	Net.dev_resume = resume
	if mode == "host":
		_auto_start = true
		_on_host()
	elif mode == "join":
		_on_join()

func _on_host() -> void:
	var err := Net.host()
	if err != OK:
		status.text = "Failed to host (%d). The port may be in use." % err
		return
	_host_succeeded()

func _host_succeeded() -> void:
	status.text = "Room open (you are the Runner). Waiting for Hunters..."
	_enter_connected(true)

func _on_join() -> void:
	var ip := address.text.strip_edges()
	if ip == "":
		ip = "127.0.0.1"
	var err := Net.join(ip)
	if err != OK:
		status.text = "Could not connect (%d)." % err
		return
	status.text = "Connecting..."
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
		roster.text = "Not connected"
		start_btn.disabled = true
		return
	var lines := PackedStringArray()
	var ids := Net.players.keys()
	ids.sort()
	for id in ids:
		var tag := " (you)" if id == multiplayer.get_unique_id() else ""
		lines.append("· %s  [%s]%s" % [id, Net.players[id], tag])
	roster.text = "\n".join(lines)
	# Need at least the Runner + 1 Hunter to start.
	start_btn.disabled = Net.players.size() < 2
	if _auto_start and Net.is_host() and Net.players.size() >= 2:
		_auto_start = false
		Net.start_game()
