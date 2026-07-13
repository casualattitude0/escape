class_name RelayMultiplayerPeer
extends MultiplayerPeerExtension

## A MultiplayerPeer that routes traffic through Escape's relay server
## (see relay-server/) instead of connecting host<->client directly. Neither
## side needs a reachable inbound address: both open one outbound WebSocket
## to the relay, which demuxes/muxes so this class only ever sees "peer 1"
## (the host) in client mode, or a set of client peer ids in host mode.
##
## This is a drop-in replacement for WebSocketMultiplayerPeer in
## multiplayer.multiplayer_peer — every RPC/signal-based script elsewhere
## (world.gd, player_combat.gd, net.gd's own _register/_sync_players flow)
## keeps working unchanged, since they only touch the high-level
## `multiplayer` API, never the peer directly.
##
## Wire format matches relay-server/main.go exactly: a 1-byte frame-type tag
## (0 = control JSON, 1 = data), with data frames host<->relay carrying a
## 4-byte little-endian peer-id header (sender inbound, target outbound —
## 0 meaning broadcast) that relay<->client frames omit, since a client only
## ever hears from / talks to "the host".

signal relay_connected(room_id: String)
signal relay_failed(reason: String)

const FRAME_CONTROL := 0
const FRAME_DATA := 1

enum Mode { HOST, CLIENT }

var _mode: Mode
var _ws := WebSocketPeer.new()
var _handshake_sent := false
var _status: int = MultiplayerPeer.CONNECTION_DISCONNECTED
var _unique_id: int = 0
var _target_peer: int = 0
var _transfer_channel: int = 0
var _transfer_mode: int = MultiplayerPeer.TRANSFER_MODE_RELIABLE
var _refuse_new_connections := false
var _room_id: String = ""
var _last_packet_peer: int = 0
var _incoming: Array = []   # Array of {peer: int, data: PackedByteArray}

# host-only
var _room_name: String
var _max_players: int
# client-only
var _join_room_id: String


static func create_host(url: String, room_name: String, max_players: int) -> RelayMultiplayerPeer:
	var p := RelayMultiplayerPeer.new()
	p._mode = Mode.HOST
	p._unique_id = 1
	p._room_name = room_name
	p._max_players = max_players
	p._start(url)
	return p


static func create_client(url: String, room_id: String) -> RelayMultiplayerPeer:
	var p := RelayMultiplayerPeer.new()
	p._mode = Mode.CLIENT
	p._join_room_id = room_id
	p._start(url)
	return p


func room_id() -> String:
	return _room_id


func _start(url: String) -> void:
	var err := _ws.connect_to_url(url)
	if err != OK:
		# Deferred: the caller hasn't had a chance to connect to our signals
		# yet, since _start() runs synchronously inside create_host/create_client.
		call_deferred("emit_signal", "relay_failed", "connect_error_%d" % err)
		return
	_status = MultiplayerPeer.CONNECTION_CONNECTING


func _send_control(msg: Dictionary) -> void:
	var buf := PackedByteArray([FRAME_CONTROL])
	buf.append_array(JSON.stringify(msg).to_utf8_buffer())
	_ws.send(buf, WebSocketPeer.WRITE_MODE_BINARY)


# ---- MultiplayerPeerExtension overrides ------------------------------------

func _poll() -> void:
	_ws.poll()
	var state := _ws.get_ready_state()

	if state == WebSocketPeer.STATE_OPEN and not _handshake_sent:
		_handshake_sent = true
		if _mode == Mode.HOST:
			_send_control({"op": "host", "name": _room_name, "max_players": _max_players})
		else:
			_send_control({"op": "join", "room_id": _join_room_id})

	# Only one raw message per engine poll tick — a control frame's handling
	# (peer_connected/peer_disconnected) reenters SceneMultiplayer synchronously,
	# and batching it with an already-queued data frame in the same _poll() call
	# can hand SceneMultiplayer a packet whose sender it hasn't registered yet.
	# One-per-frame guarantees SceneMultiplayer fully settles between the two.
	if _ws.get_available_packet_count() > 0:
		_handle_packet(_ws.get_packet())

	if state == WebSocketPeer.STATE_CLOSED and _status != MultiplayerPeer.CONNECTION_DISCONNECTED:
		var was_connecting := _status == MultiplayerPeer.CONNECTION_CONNECTING
		_status = MultiplayerPeer.CONNECTION_DISCONNECTED
		if was_connecting:
			relay_failed.emit("ws_closed")


func _handle_packet(pkt: PackedByteArray) -> void:
	if pkt.is_empty():
		return
	match pkt[0]:
		FRAME_CONTROL:
			var parsed = JSON.parse_string(pkt.slice(1).get_string_from_utf8())
			if parsed is Dictionary:
				_handle_control(parsed)
		FRAME_DATA:
			if _mode == Mode.HOST:
				if pkt.size() < 5:
					return
				_incoming.push_back({"peer": pkt.decode_u32(1), "data": pkt.slice(5)})
			else:
				_incoming.push_back({"peer": 1, "data": pkt.slice(1)})


func _handle_control(msg: Dictionary) -> void:
	match msg.get("op", ""):
		"hosted":
			_room_id = msg.get("room_id", "")
			_status = MultiplayerPeer.CONNECTION_CONNECTED
			relay_connected.emit(_room_id)
		"joined":
			_unique_id = int(msg.get("peer_id", 0))
			_room_id = _join_room_id
			_status = MultiplayerPeer.CONNECTION_CONNECTED
			relay_connected.emit(_room_id)
			# SceneMultiplayer's connected_to_server isn't driven by connection
			# status at all — it watches for peer_connected(1) specifically
			# (1 = the reserved server id). Real peers (ENet, WebSocket) emit
			# this themselves on connect; we must too.
			peer_connected.emit(1)
		"join_failed":
			_status = MultiplayerPeer.CONNECTION_DISCONNECTED
			relay_failed.emit(String(msg.get("reason", "unknown")))
			_ws.close()
		"peer_joined":
			peer_connected.emit(int(msg.get("peer_id", 0)))
		"peer_left":
			peer_disconnected.emit(int(msg.get("peer_id", 0)))
		"host_left":
			_status = MultiplayerPeer.CONNECTION_DISCONNECTED
			_ws.close()


func _get_available_packet_count() -> int:
	return _incoming.size()


func _get_packet_script() -> PackedByteArray:
	if _incoming.is_empty():
		return PackedByteArray()
	var entry: Dictionary = _incoming.pop_front()
	_last_packet_peer = entry["peer"]
	return entry["data"]


func _put_packet_script(buffer: PackedByteArray) -> Error:
	if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return ERR_UNCONFIGURED
	var buf := PackedByteArray([FRAME_DATA])
	if _mode == Mode.HOST:
		var header := PackedByteArray()
		header.resize(4)
		header.encode_u32(0, _target_peer)
		buf.append_array(header)
	buf.append_array(buffer)
	return _ws.send(buf, WebSocketPeer.WRITE_MODE_BINARY) as Error


## SceneMultiplayer queries the sender via _get_packet_peer() BEFORE it calls
## _get_packet_script() to dequeue — so this must report the id of the packet
## still at the front of the queue, not the previously-consumed one.
func _get_packet_peer() -> int:
	if _incoming.is_empty():
		return _last_packet_peer
	return _incoming[0]["peer"]


func _get_packet_channel() -> int:
	return 0


func _get_packet_mode() -> int:
	return MultiplayerPeer.TRANSFER_MODE_RELIABLE


func _get_transfer_channel() -> int:
	return _transfer_channel


func _set_transfer_channel(channel: int) -> void:
	_transfer_channel = channel


func _get_transfer_mode() -> int:
	return _transfer_mode


func _set_transfer_mode(mode: int) -> void:
	_transfer_mode = mode


func _set_target_peer(peer: int) -> void:
	_target_peer = peer


func _get_unique_id() -> int:
	return _unique_id


func _get_connection_status() -> int:
	return _status


func _is_server() -> bool:
	return _mode == Mode.HOST


func _is_server_relay_supported() -> bool:
	return false   # clients only ever talk to the host, never to each other


func _get_max_packet_size() -> int:
	return 1 << 20


func _set_refuse_new_connections(enable: bool) -> void:
	_refuse_new_connections = enable


func _is_refusing_new_connections() -> bool:
	return _refuse_new_connections


func _disconnect_peer(_peer: int, _force: bool) -> void:
	pass   # not used anywhere in this project today


func _close() -> void:
	_ws.close()
	_status = MultiplayerPeer.CONNECTION_DISCONNECTED
