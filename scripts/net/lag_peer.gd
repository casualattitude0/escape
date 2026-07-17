class_name LagPeer
extends MultiplayerPeerExtension

## Dev-only wrapper that delays every INCOMING packet by a fixed amount, so the
## 127.0.0.1 editor dev loop can reproduce real-network latency deterministically
## (launch token "fakelag=<ms>", see menu.gd). Wraps any MultiplayerPeer — the
## LAN WebSocketMultiplayerPeer and RelayMultiplayerPeer alike — and forwards
## everything else straight through. With both editor windows launched with the
## same token, each side delays its inbound path, so observed RTT ≈ 2 × fakelag.

var inner: MultiplayerPeer
var delay_ms: int = 0

# FIFO of {release: int, peer: int, data: PackedByteArray, mode: int, channel: int}.
# Constant delay keeps it ordered by release time, so ready packets are a prefix.
var _queue: Array = []
var _last_packet_peer: int = 0
var _last_packet_mode: int = MultiplayerPeer.TRANSFER_MODE_RELIABLE
var _last_packet_channel: int = 0


static func create(wrapped: MultiplayerPeer, ms: int) -> LagPeer:
	var p := LagPeer.new()
	p.inner = wrapped
	p.delay_ms = ms
	# Re-emit connection lifecycle signals; SceneMultiplayer watches the ACTIVE
	# peer object (us), not the wrapped one, for peer_connected(1) etc.
	wrapped.peer_connected.connect(func(id: int) -> void: p.peer_connected.emit(id))
	wrapped.peer_disconnected.connect(func(id: int) -> void: p.peer_disconnected.emit(id))
	return p


func _poll() -> void:
	inner.poll()
	var release := Time.get_ticks_msec() + delay_ms
	while inner.get_available_packet_count() > 0:
		# Sender/mode/channel describe the NEXT packet — read them before get_packet().
		var entry := {
			"release": release,
			"peer": inner.get_packet_peer(),
			"mode": inner.get_packet_mode(),
			"channel": inner.get_packet_channel(),
		}
		entry["data"] = inner.get_packet()
		_queue.push_back(entry)


func _ready_count() -> int:
	var now := Time.get_ticks_msec()
	var n := 0
	while n < _queue.size() and _queue[n]["release"] <= now:
		n += 1
	return n


func _get_available_packet_count() -> int:
	return _ready_count()


func _get_packet_script() -> PackedByteArray:
	if _queue.is_empty():
		return PackedByteArray()
	var entry: Dictionary = _queue.pop_front()
	_last_packet_peer = entry["peer"]
	_last_packet_mode = entry["mode"]
	_last_packet_channel = entry["channel"]
	return entry["data"]


func _get_packet_peer() -> int:
	if _queue.is_empty():
		return _last_packet_peer
	return _queue[0]["peer"]


func _get_packet_mode() -> int:
	if _queue.is_empty():
		return _last_packet_mode
	return _queue[0]["mode"]


func _get_packet_channel() -> int:
	if _queue.is_empty():
		return _last_packet_channel
	return _queue[0]["channel"]


func _put_packet_script(buffer: PackedByteArray) -> Error:
	return inner.put_packet(buffer)


func _set_target_peer(peer: int) -> void:
	inner.set_target_peer(peer)


func _set_transfer_mode(mode: int) -> void:
	inner.transfer_mode = mode as MultiplayerPeer.TransferMode


func _get_transfer_mode() -> int:
	return inner.transfer_mode


func _set_transfer_channel(channel: int) -> void:
	inner.transfer_channel = channel


func _get_transfer_channel() -> int:
	return inner.transfer_channel


func _get_unique_id() -> int:
	return inner.get_unique_id()


func _get_connection_status() -> int:
	return inner.get_connection_status()


func _is_server() -> bool:
	return inner.get_unique_id() == 1


func _is_server_relay_supported() -> bool:
	return inner.is_server_relay_supported()


func _get_max_packet_size() -> int:
	return 1 << 20


func _set_refuse_new_connections(enable: bool) -> void:
	inner.refuse_new_connections = enable


func _is_refusing_new_connections() -> bool:
	return inner.refuse_new_connections


func _disconnect_peer(peer: int, force: bool) -> void:
	inner.disconnect_peer(peer, force)


func _close() -> void:
	inner.close()
