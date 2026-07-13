extends Node

## Autoload "Net" — high-level multiplayer plumbing for Escape.
## Host is the Runner (peer 1); everyone who joins is a Hunter. The host is
## also the authority for game state (see GameManager).

const PORT := 24565
const MAX_CLIENTS := 4          # up to 4 Hunters + 1 Runner
const PREFS_PATH := "user://net.cfg"   # remembers the last address you joined

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

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func is_host() -> bool:
	return multiplayer.multiplayer_peer != null and multiplayer.is_server()

func host() -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_CLIENTS)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	players = {1: Roles.RUNNER}
	players_changed.emit()
	return OK

func join(address: String) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, PORT)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	_save_last_address(address)
	return OK

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

func leave() -> void:
	multiplayer.multiplayer_peer = null
	players.clear()
	players_changed.emit()

func start_game() -> void:
	# Host only. Everyone loads the world together.
	if is_host():
		_load_world.rpc()

# ---- server-side roster management ----------------------------------------

func _on_peer_connected(id: int) -> void:
	if not is_host():
		return
	players[id] = Roles.HUNTER
	# Tell the newcomer (and refresh everyone) with the full roster.
	_sync_players.rpc(players)
	players_changed.emit()

func _on_peer_disconnected(id: int) -> void:
	if not is_host():
		return
	players.erase(id)
	_sync_players.rpc(players)
	players_changed.emit()

@rpc("authority", "call_remote", "reliable")
func _sync_players(roster: Dictionary) -> void:
	players = roster
	players_changed.emit()

@rpc("authority", "call_local", "reliable")
func _load_world() -> void:
	get_tree().change_scene_to_file("res://scenes/world.tscn")

# ---- client-side connection callbacks -------------------------------------

func _on_connected_to_server() -> void:
	connection_ok.emit()

func _on_connection_failed() -> void:
	multiplayer.multiplayer_peer = null
	connection_failed_.emit()

func _on_server_disconnected() -> void:
	multiplayer.multiplayer_peer = null
	players.clear()
	server_left.emit()
