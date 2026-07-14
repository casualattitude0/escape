extends Node

## Autoload "Net" — high-level multiplayer plumbing for Escape.
## Host is the Runner (peer 1); everyone who joins is a Hunter. The host is
## also the authority for game state (see GameManager).

const PORT := 24565
const MAX_CLIENTS := 4          # up to 4 Hunters + 1 Runner
const PREFS_PATH := "user://net.cfg"   # remembers the last address you joined

## Deployed relay server's WebSocket endpoint (see relay-server/, deployed to
## GCP project escape-502321 / Cloud Run service "escape-relay", asia-east1 —
## Taiwan, since the playerbase is in Asia; a us-central1 relay added ~150ms).
## Lets any player host or join over the internet with no port-forwarding, by
## routing traffic through this always-on relay instead of connecting
## host<->client directly — see RelayMultiplayerPeer and relay-server/main.go
## for the wire protocol. Override for local testing with the "relay=<url>"
## CLI token (see menu.gd _handle_cli) or by calling set_relay_url_override().
const RELAY_WS_URL := "wss://escape-relay-562296751796.asia-east1.run.app/connect"

## WebSocketMultiplayerPeer (not ENet) so a web-exported client can Join a
## game — browsers can't open raw UDP sockets, only WebSocket ones. A browser
## tab still can't bind a listening socket, so Host stays native-only; Join
## works from both native and web builds. See host()/join()/_make_url().

# Editor-only dev loop: when running from the editor with no launch tokens, the
# lobby self-negotiates host/join across the two windows and resumes the match,
# so a script edit + restart lands you back in-game with no clicks. Set false to
# always get the normal lobby. Never active in an exported build (gated on the
# "editor" feature in menu.gd).
const DEV_AUTOCONNECT := true

signal players_changed          # the roster (id -> role) changed
signal connection_ok            # this client finished connecting
signal connection_failed_       # this client could not connect
signal server_left              # the host went away
signal hosted_online(room_id: String)   # host_online() finished registering with the relay

# peer_id -> role ("runner" / "hunter"). Mirrored on every peer.
var players: Dictionary = {}

# Dev-launch flag: true when this instance was started with the "resume" launch
# token (or the dev_resume feature). Set once by the lobby, read by DevSnapshot.
# Persists across the menu->world scene change because Net is an autoload.
var dev_resume := false

# Set by the pause menu while it is open, so the local player ignores input
# without freezing the (networked) simulation for everyone else.
var local_input_locked := false

# Set when the player deliberately returns to the lobby, so the editor dev loop
# doesn't immediately re-connect them. Cleared on a fresh process launch.
var suppress_autoconnect := false

# True once the world scene has loaded (set on every peer via _load_world). The
# host uses it to route a late/reconnecting client straight into the match.
var match_active := false

# Which map to play. Host picks it (default map 1); the choice rides along in the
# _load_world RPC so every peer loads the same scene. See scenes/world2.tscn.
var world_scene := "res://scenes/levels/world.tscn"

# Live match snapshot handed across a rejoin reload (host-only). When a client
# (re)joins mid-match the host fills this, everyone reloads the world, and the
# fresh world restores from it. See world.gd rejoin_new_peer / _ready.
var rejoin_snapshot: Dictionary = {}

# Dev override for the ENet port (set from the "port=<n>" launch token), so you
# can run a second, independent session without colliding with the default one.
var _port_override := 0
var _my_token := ""             # this client's stable identity (lazy, see my_token)

# Dev override for RELAY_WS_URL (set from the "relay=<url>" launch token), so
# host_online()/join_relay() can point at a locally-run relay-server instead
# of the deployed one.
var _relay_url_override := ""
var _rooms_request: HTTPRequest
var _rooms_busy := false

# --- host-only reconnection bookkeeping ------------------------------------
# token -> {"role": String, "connected": bool}. Survives a disconnect so the
# same client (same token) reclaims its role instead of getting a fresh slot.
var _slots: Dictionary = {}
var _peer_token: Dictionary = {}   # live peer_id -> token

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func is_host() -> bool:
	return multiplayer.multiplayer_peer != null and multiplayer.is_server()

func port() -> int:
	return _port_override if _port_override > 0 else PORT

func set_port_override(p: int) -> void:
	_port_override = p

func set_token(token: String) -> void:
	_my_token = token

## This client's stable identity. Generated once and stored in user://, so a
## reconnect after a drop or restart presents the same id and reclaims the slot.
func my_token() -> String:
	if _my_token != "":
		return _my_token
	var cfg := ConfigFile.new()
	cfg.load(PREFS_PATH)
	_my_token = cfg.get_value("net", "token", "")
	if _my_token == "":
		_my_token = "%d-%08x%08x" % [Time.get_ticks_usec(), randi(), randi()]
		cfg.set_value("net", "token", _my_token)
		cfg.save(PREFS_PATH)
	return _my_token

func host() -> Error:
	if OS.has_feature("web"):
		return ERR_UNAVAILABLE   # a browser tab can't bind a listening socket
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(port())
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	players = {1: Roles.RUNNER}
	_slots.clear()
	_peer_token.clear()
	players_changed.emit()
	return OK

func join(address: String) -> Error:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(_make_url(address))
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	_save_last_address(address)
	return OK

## Turns a bare host, "host:port", or full "ws://..." address into a URL
## WebSocketMultiplayerPeer.create_client() accepts. Lets the join field keep
## taking a plain IP (LAN/Tailscale) as well as a playit.gg-style host:port.
func _make_url(address: String) -> String:
	var addr := address.strip_edges()
	if addr.begins_with("ws://") or addr.begins_with("wss://"):
		return addr
	if addr.find(":") == -1:
		return "ws://%s:%d" % [addr, port()]
	return "ws://%s" % addr

func last_address() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(PREFS_PATH) != OK:
		return ""
	return cfg.get_value("net", "address", "")

func _save_last_address(address: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(PREFS_PATH)   # keep any other prefs; ignore "missing file"
	cfg.set_value("net", "address", address)
	cfg.save(PREFS_PATH)

## Persisted twin of suppress_autoconnect: set when the player deliberately
## leaves to the menu, so the editor dev loop stays at the lobby on every launch
## afterwards (the in-memory flag resets per process). It stays set — even across
## the editor's multi-instance runs, where each window reads it independently —
## until the player deliberately reconnects, which calls clear_left_to_menu().
func set_left_to_menu(v: bool) -> void:
	var cfg := ConfigFile.new()
	cfg.load(PREFS_PATH)   # keep any other prefs; ignore "missing file"
	cfg.set_value("net", "left_to_menu", v)
	cfg.save(PREFS_PATH)

func left_to_menu() -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(PREFS_PATH) != OK:
		return false
	return bool(cfg.get_value("net", "left_to_menu", false))

func clear_left_to_menu() -> void:
	set_left_to_menu(false)

# ---- relay-based hosting/joining (internet-wide lobby list) ---------------

func relay_ws_url() -> String:
	return _relay_url_override if _relay_url_override != "" else RELAY_WS_URL

func set_relay_url_override(url: String) -> void:
	_relay_url_override = url

## The relay's plain HTTP base (for the GET /rooms directory query), derived
## from its WebSocket URL: wss://host/connect -> https://host, ws:// -> http://.
func _relay_http_base() -> String:
	var url := relay_ws_url().replace("wss://", "https://").replace("ws://", "http://")
	if url.ends_with("/connect"):
		url = url.substr(0, url.length() - "/connect".length())
	return url

func host_online(room_name: String, max_players: int = MAX_CLIENTS) -> Error:
	var peer := RelayMultiplayerPeer.create_host(relay_ws_url(), room_name, max_players)
	peer.relay_connected.connect(_on_relay_hosted, CONNECT_ONE_SHOT)
	peer.relay_failed.connect(_on_relay_host_failed, CONNECT_ONE_SHOT)
	multiplayer.multiplayer_peer = peer
	players = {1: Roles.RUNNER}
	_slots.clear()
	_peer_token.clear()
	players_changed.emit()
	_save_last_room_name(room_name)
	return OK

func _on_relay_hosted(room_id: String) -> void:
	hosted_online.emit(room_id)

func _on_relay_host_failed(_reason: String) -> void:
	multiplayer.multiplayer_peer = null
	players.clear()
	players_changed.emit()
	connection_failed_.emit()

## Join a room from the browse list by id (see list_rooms()). Outcome arrives
## via the same connection_ok/connection_failed_ signals join() uses — both
## paths end up driven by the peer's _get_connection_status() transitions.
func join_relay(room_id: String) -> Error:
	var peer := RelayMultiplayerPeer.create_client(relay_ws_url(), room_id)
	multiplayer.multiplayer_peer = peer
	return OK

## Queries the relay's open-room directory. Coroutine — callers must `await`.
func list_rooms() -> Array:
	if _rooms_busy:
		return []
	if _rooms_request == null:
		_rooms_request = HTTPRequest.new()
		add_child(_rooms_request)
	if _rooms_request.request(_relay_http_base() + "/rooms") != OK:
		return []
	_rooms_busy = true
	var result: Array = await _rooms_request.request_completed
	_rooms_busy = false
	var response_code: int = result[1]
	var body: PackedByteArray = result[3]
	if response_code != 200:
		return []
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	return parsed if parsed is Array else []

func last_room_name() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(PREFS_PATH) != OK:
		return ""
	return cfg.get_value("net", "room_name", "")

func _save_last_room_name(name: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(PREFS_PATH)
	cfg.set_value("net", "room_name", name)
	cfg.save(PREFS_PATH)

func leave() -> void:
	multiplayer.multiplayer_peer = null
	players.clear()
	_slots.clear()
	_peer_token.clear()
	match_active = false
	players_changed.emit()

func start_game() -> void:
	# Host only. Everyone loads the world together.
	if is_host():
		_load_world.rpc(world_scene)

# ---- reconnection handshake -----------------------------------------------
# A client, once its ENet link is up, tells the host who it is (its token). The
# host assigns a role: a known token reclaims its reserved slot, a new one gets a
# fresh Hunter slot. If a match is already running, the host routes the client
# straight into it (see world.gd, which spawns + resyncs on the late arrival).

@rpc("any_peer", "reliable")
func _register(token: String) -> void:
	if not is_host():
		return
	var peer := multiplayer.get_remote_sender_id()
	var reclaim: bool = _slots.has(token)
	var role: String = _slots[token]["role"] if reclaim else Roles.HUNTER
	_slots[token] = {"role": role, "connected": true}
	_peer_token[peer] = token
	players[peer] = role
	_sync_players.rpc(players)
	players_changed.emit()
	if match_active:
		# A match is already running. Snapshot it and reload everyone together so
		# the newcomer is spawned cleanly alongside the rest (see world.rejoin).
		var world := get_tree().get_first_node_in_group("world_host")
		if world != null:
			world.rejoin_new_peer()
		else:
			_load_world.rpc_id(peer, world_scene)   # host not in world yet; just send them in

func reload_all() -> void:
	if is_host():
		_load_world.rpc(world_scene)

func _on_peer_connected(_id: int) -> void:
	pass   # role is assigned when the peer registers (see _register)

func _on_peer_disconnected(id: int) -> void:
	if not is_host():
		return
	# Reserve the slot (keep the role) so this token can reclaim it on reconnect.
	if _peer_token.has(id):
		var token: String = _peer_token[id]
		if _slots.has(token):
			_slots[token]["connected"] = false
		_peer_token.erase(id)
	players.erase(id)
	_sync_players.rpc(players)
	players_changed.emit()

@rpc("authority", "call_remote", "reliable")
func _sync_players(roster: Dictionary) -> void:
	players = roster
	players_changed.emit()

@rpc("authority", "call_local", "reliable")
func _load_world(scene: String = "") -> void:
	match_active = true
	if scene != "":
		world_scene = scene
	get_tree().change_scene_to_file(world_scene)

# ---- client-side connection callbacks -------------------------------------

func _on_connected_to_server() -> void:
	_register.rpc_id(1, my_token())   # announce our identity to the host
	connection_ok.emit()

func _on_connection_failed() -> void:
	multiplayer.multiplayer_peer = null
	connection_failed_.emit()

func _on_server_disconnected() -> void:
	multiplayer.multiplayer_peer = null
	players.clear()
	match_active = false
	server_left.emit()
