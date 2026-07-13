extends Control

## Lobby: host or join a game, then the host starts it.

@onready var host_btn: Button = %HostButton
@onready var join_btn: Button = %JoinButton
@onready var start_btn: Button = %StartButton
@onready var address: LineEdit = %Address
@onready var status: Label = %Status
@onready var share_label: Label = %ShareLabel
@onready var roster: Label = %Roster
@onready var host_online_btn: Button = %HostOnlineButton
@onready var room_name_edit: LineEdit = %RoomNameEdit
@onready var browse_btn: Button = %BrowseButton
@onready var room_list: ItemList = %RoomList
@onready var refresh_timer: Timer = %RefreshTimer

var _auto_start := false

func _ready() -> void:
	host_btn.pressed.connect(_on_host)
	join_btn.pressed.connect(_on_join)
	start_btn.pressed.connect(func(): Net.start_game())
	host_online_btn.pressed.connect(_on_host_online)
	browse_btn.pressed.connect(_on_browse_toggle)
	room_list.item_selected.connect(_on_room_selected)
	refresh_timer.timeout.connect(_refresh_rooms)
	Net.players_changed.connect(_refresh)
	Net.connection_ok.connect(func(): status.text = "Connected. Waiting for host to start...")
	Net.connection_failed_.connect(func(): _reset("Connection failed. Check the IP."))
	Net.server_left.connect(func(): _reset("The host has left."))
	Net.hosted_online.connect(_on_hosted_online)
	var last := Net.last_address()
	if last != "" and address.text.strip_edges() == "":
		address.text = last
	var last_room := Net.last_room_name()
	if last_room != "" and room_name_edit.text.strip_edges() == "":
		room_name_edit.text = last_room
	if OS.has_feature("web"):
		# A browser tab can't bind a listening socket — web builds can only Join.
		host_btn.visible = false
		host_online_btn.visible = false
	_refresh()
	_handle_cli()

## Dev convenience so a script edit + restart drops you straight back into a
## match with no clicks.
##
## Explicit launch tokens (used by the headless smoke test):
##   host              open a room and auto-start once a Hunter joins
##   join[=<ip>]       auto-join (default 127.0.0.1)
##   resume            also restore the in-progress match (DevSnapshot)
##   hostonline[=<name>]   host via the relay (see Net.RELAY_WS_URL)
##   joinrelay=<room_id>   join a relay room directly, skipping the browse list
##   relay=<url>       point host_online/join_relay at a local relay-server
##                     instead of the deployed one, e.g. relay=ws://127.0.0.1:8080/connect
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
			if parts.size() > 1:
				room_name_edit.text = parts[1]
		elif arg == "join" or arg.begins_with("join="):
			mode = "join"
			var parts := arg.split("=")
			if parts.size() > 1:
				address.text = parts[1]
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
	elif mode == "hostonline":
		_auto_start = true
		_on_host_online()
	elif mode == "joinrelay":
		_join_room(room_id)

func _on_host() -> void:
	var err := Net.host()
	if err != OK:
		status.text = "Failed to host (%d). The port may be in use." % err
		return
	_host_succeeded()

func _host_succeeded() -> void:
	status.text = "Room open (you are the Runner). Waiting for Hunters..."
	share_label.text = _share_text()
	share_label.visible = share_label.text != ""
	_enter_connected(true)

## Local (non-loopback) addresses this machine is reachable at, so the host
## can read one off screen and hand it to a tester — a LAN IP for someone on
## the same network, or a Tailscale/ZeroTier virtual IP (shows up here too,
## since those are just another network interface) for someone off it. Kept
## in its own label (not appended to Status) so it survives Status changing
## to "Connecting..." / error text for other reasons.
func _share_text() -> String:
	var addrs := PackedStringArray()
	for ip in IP.get_local_addresses():
		if ip.find(":") == -1 and not ip.begins_with("127."):
			addrs.append(ip)
	if addrs.is_empty():
		return ""
	return "Share an address with testers: %s (port %d)" % [", ".join(addrs), Net.port()]

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

## Host a room via the relay, so anyone on the internet can find and join it
## through Browse Games — no port-forwarding or shared address required.
func _on_host_online() -> void:
	var room_name := room_name_edit.text.strip_edges()
	if room_name == "":
		room_name = "Untitled Room"
	var err := Net.host_online(room_name)
	if err != OK:
		status.text = "Failed to reach the relay (%d)." % err
		return
	status.text = "Connecting to relay..."
	_enter_connected(true)

func _on_hosted_online(room_id: String) -> void:
	status.text = "Room open online (you are the Runner). Waiting for Hunters..."
	share_label.text = "Room code: %s" % room_id
	share_label.visible = true

func _on_browse_toggle() -> void:
	room_list.visible = not room_list.visible
	if room_list.visible:
		_refresh_rooms()
		refresh_timer.start()
	else:
		refresh_timer.stop()

func _refresh_rooms() -> void:
	var rooms: Array = await Net.list_rooms()
	room_list.clear()
	for room in rooms:
		if not (room is Dictionary):
			continue
		var idx := room_list.add_item("%s  (%d/%d)" % [room.get("name", "?"), room.get("player_count", 0), room.get("max_players", 0)])
		room_list.set_item_metadata(idx, room.get("room_id", ""))
	if rooms.is_empty():
		room_list.add_item("No open rooms found.")
		room_list.set_item_disabled(0, true)

func _on_room_selected(index: int) -> void:
	var meta = room_list.get_item_metadata(index)
	if not (meta is String) or meta == "":
		return
	refresh_timer.stop()
	_join_room(meta)

func _join_room(room_id: String) -> void:
	var err := Net.join_relay(room_id)
	if err != OK:
		status.text = "Could not reach the relay (%d)." % err
		return
	status.text = "Connecting..."
	_enter_connected(false)

func _enter_connected(is_host: bool) -> void:
	host_btn.disabled = true
	join_btn.disabled = true
	address.editable = false
	host_online_btn.disabled = true
	browse_btn.disabled = true
	room_name_edit.editable = false
	room_list.visible = false
	refresh_timer.stop()
	start_btn.visible = is_host

func _reset(msg: String) -> void:
	Net.leave()
	host_btn.disabled = false
	join_btn.disabled = false
	address.editable = true
	host_online_btn.disabled = false
	browse_btn.disabled = false
	room_name_edit.editable = true
	start_btn.visible = false
	status.text = msg
	share_label.visible = false
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
