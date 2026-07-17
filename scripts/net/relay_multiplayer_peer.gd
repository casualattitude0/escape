class_name RelayMultiplayerPeer
extends MultiplayerPeerExtension

## Hybrid relay/P2P MultiplayerPeer for Escape's online rooms.
##
## Every session keeps ONE outbound WebSocket to the relay server (see
## relay-server/main.go) — it carries room control, WebRTC signaling, and data
## for peers whose direct link isn't up. On top of that, each remote peer gets
## a WebRTCPeerConnection with two pre-negotiated data channels; once a pair
## connects, that peer's game traffic moves off the relay onto the direct UDP
## path (movement on the unreliable channel), and falls back to the relay
## seamlessly if the link dies. Per-peer, not per-session: in the same room one
## client can be P2P while another (symmetric NAT) stays relayed.
##
## This class is a drop-in for multiplayer.multiplayer_peer — all RPC/signal
## scripts elsewhere only touch the high-level `multiplayer` API. Peer ids stay
## relay-assigned (host = 1, clients from 2), so authority logic is untouched.
##
## Relay wire format matches relay-server/main.go: 1-byte frame tag (0 control
## JSON / 1 data); host<->relay data frames carry a 4-byte LE peer-id header
## (sender inbound, target outbound) that relay<->client frames omit. WebRTC
## signaling rides control frames as {"op":"rtc","peer_id":N,"payload":{...}}
## with payload kinds offer/answer/ice/switch, relay-routed without parsing.
##
## The reliable-path cutover ("switch") barrier: reliable packets must not be
## reordered across paths, so each side keeps sending reliable data over the WS
## until its DC pair opens, then sends a "switch" marker over the WS and moves
## to the DC. The receiver holds early DC packets until the marker arrives —
## the WS is ordered, so everything sent before the switch has been delivered.

signal relay_connected(room_id: String)
signal relay_failed(reason: String)
## A peer's traffic path changed (P2P came up, or fell back to relay).
signal transport_changed(peer_id: int, p2p: bool)

const FRAME_CONTROL := 0
const FRAME_DATA := 1

enum Mode { HOST, CLIENT }

## Per-remote-peer WebRTC link state. RELAY (no link / gave up) is represented
## by link == null or state == FALLBACK; NEGOTIATING covers offer/answer/ICE
## up to "both channels open".
enum LinkState { NEGOTIATING, P2P, FALLBACK }

const ICE_CONFIG := {"iceServers": [{"urls": ["stun:stun.l.google.com:19302"]}]}
const RTC_CONNECT_TIMEOUT_MS := 10_000
## SCTP message-size safety line: anything bigger (rejoin snapshots) takes the
## relay's WS path, which has no practical frame limit.
const DC_MAX_PACKET := 16 * 1024

class RtcLink:
	var pc: WebRTCPeerConnection
	var reliable: WebRTCDataChannel
	var fast: WebRTCDataChannel
	var state: int = LinkState.NEGOTIATING
	var started_ms: int = 0
	var switch_sent := false        # we moved our reliable sends to the DC
	var switch_received := false    # their marker arrived; DC packets may flow
	var held: Array = []            # DC reliable packets held until the marker

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
var _last_packet_mode: int = MultiplayerPeer.TRANSFER_MODE_RELIABLE
var _incoming: Array = []   # Array of {peer: int, data: PackedByteArray, mode: int}

## peer_id -> RtcLink (host: one per client; client: only key 1). A peer with
## no entry (or a FALLBACK one) talks over the relay.
var _links: Dictionary = {}
## Set from Net before the first poll; "p2p=off" launch token forces relay-only.
var p2p_enabled := true

# Data-frame totals for the F3 overlay (see net_stats.gd). Control frames and
# pings don't count — only actual game traffic.
var packets_in: int = 0
var packets_out: int = 0

# keepalive: Cloud Run and intermediate proxies drop idle WebSockets;
# a periodic ping keeps the connection alive.
const PING_INTERVAL_MS := 15_000
var _last_ping_ms: int = 0

# connection timeout: give up if the relay doesn't respond to the
# handshake within this window.
const CONNECT_TIMEOUT_MS := 10_000
var _connect_started_ms: int = 0

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


## Whether this build can do WebRTC at all: the webrtc-native GDExtension ships
## real libs only for macOS/Windows here, and a fresh clone / headless CI may
## have none — then initialize() fails and everything stays relay-only, which
## is exactly the pre-P2P behaviour.
static func rtc_available() -> bool:
	var pc := WebRTCPeerConnection.new()
	return pc.initialize(ICE_CONFIG) == OK


func room_id() -> String:
	return _room_id


## True while `peer` (or, for a client, the host) is on the direct P2P path.
func link_is_p2p(peer: int) -> bool:
	var link: RtcLink = _links.get(peer)
	return link != null and link.state == LinkState.P2P


## True when every current remote peer is P2P (and there is at least one).
## The host's adaptive send rate keys off this — mixed rooms pace for the
## slowest path.
func all_links_p2p() -> bool:
	if _links.is_empty():
		return false
	for peer in _links:
		if not link_is_p2p(peer):
			return false
	return true


func _start(url: String) -> void:
	var err := _ws.connect_to_url(url)
	if err != OK:
		call_deferred("emit_signal", "relay_failed", "connect_error_%d" % err)
		return
	_status = MultiplayerPeer.CONNECTION_CONNECTING
	_connect_started_ms = Time.get_ticks_msec()
	_last_ping_ms = _connect_started_ms


func _send_control(msg: Dictionary) -> void:
	var buf := PackedByteArray([FRAME_CONTROL])
	buf.append_array(JSON.stringify(msg).to_utf8_buffer())
	_ws.send(buf, WebSocketPeer.WRITE_MODE_BINARY)


## Sends a WebRTC signaling payload to `peer` via the relay. On a client the
## peer argument is ignored (a client only ever signals with the host, and the
## relay stamps our id on the way through).
func _send_rtc(peer: int, payload: Dictionary) -> void:
	if _mode == Mode.HOST:
		_send_control({"op": "rtc", "peer_id": peer, "payload": payload})
	else:
		_send_control({"op": "rtc", "payload": payload})


# ---- WebRTC link lifecycle --------------------------------------------------

## Host side: start negotiating with a fresh client (called on peer_joined).
## Client side: called with peer==1 when the host's offer arrives.
func _create_link(peer: int) -> RtcLink:
	var link := RtcLink.new()
	link.pc = WebRTCPeerConnection.new()
	if link.pc.initialize(ICE_CONFIG) != OK:
		return null
	# Both sides create matching negotiated channels — no in-band negotiation,
	# no glare. id 1 carries RPCs (ordered+reliable); id 2 carries replication
	# (ordered but maxRetransmits 0: late packets are DROPPED by SCTP, never
	# delivered stale, which is what makes unreliable position sync safe
	# without hand-rolled sequence numbers).
	link.reliable = link.pc.create_data_channel("reliable", {"negotiated": true, "id": 1})
	link.fast = link.pc.create_data_channel("fast",
		{"negotiated": true, "id": 2, "ordered": true, "maxRetransmits": 0})
	if link.reliable == null or link.fast == null:
		link.pc.close()
		return null
	link.pc.session_description_created.connect(_on_session_created.bind(peer))
	link.pc.ice_candidate_created.connect(_on_ice_created.bind(peer))
	link.started_ms = Time.get_ticks_msec()
	_links[peer] = link
	return link


func _on_session_created(type: String, sdp: String, peer: int) -> void:
	var link: RtcLink = _links.get(peer)
	if link == null:
		return
	link.pc.set_local_description(type, sdp)
	_send_rtc(peer, {"kind": type, "sdp": sdp})


func _on_ice_created(media: String, index: int, name: String, peer: int) -> void:
	_send_rtc(peer, {"kind": "ice", "media": media, "index": index, "name": name})


func _drop_to_relay(peer: int, reason: String) -> void:
	var link: RtcLink = _links.get(peer)
	if link == null:
		return
	var was_p2p := link.state == LinkState.P2P
	# Anything the DC delivered stays valid — release it before the path dies.
	_release_held(link)
	link.state = LinkState.FALLBACK
	link.pc.close()
	print("[Relay] peer %d: p2p %s (%s), using relay" %
		[peer, "lost" if was_p2p else "unavailable", reason])
	transport_changed.emit(peer, false)


func _release_held(link: RtcLink) -> void:
	link.switch_received = true
	for data in link.held:
		_incoming.push_back({"peer": _link_peer(link), "data": data,
			"mode": MultiplayerPeer.TRANSFER_MODE_RELIABLE})
	link.held.clear()


func _link_peer(link: RtcLink) -> int:
	for peer in _links:
		if _links[peer] == link:
			return peer
	return 0


func _poll_links() -> void:
	var now := Time.get_ticks_msec()
	for peer in _links:
		var link: RtcLink = _links[peer]
		if link.state == LinkState.FALLBACK:
			continue
		link.pc.poll()
		var rel_state := link.reliable.get_ready_state()
		var fast_state := link.fast.get_ready_state()
		if link.state == LinkState.NEGOTIATING:
			if rel_state == WebRTCDataChannel.STATE_OPEN \
					and fast_state == WebRTCDataChannel.STATE_OPEN:
				# Cutover: marker over the (ordered) WS, then reliable sends
				# move to the DC. See the barrier note in the header.
				_send_rtc(peer, {"kind": "switch"})
				link.switch_sent = true
				link.state = LinkState.P2P
				print("[Relay] peer %d: p2p up" % peer)
				transport_changed.emit(peer, true)
			elif now - link.started_ms > RTC_CONNECT_TIMEOUT_MS:
				_drop_to_relay(peer, "timeout")
				continue
			elif link.pc.get_connection_state() in [
					WebRTCPeerConnection.STATE_FAILED, WebRTCPeerConnection.STATE_CLOSED]:
				_drop_to_relay(peer, "ice_failed")
				continue
		elif link.state == LinkState.P2P:
			if rel_state != WebRTCDataChannel.STATE_OPEN \
					or fast_state != WebRTCDataChannel.STATE_OPEN \
					or link.pc.get_connection_state() in [
						WebRTCPeerConnection.STATE_FAILED,
						WebRTCPeerConnection.STATE_CLOSED,
						WebRTCPeerConnection.STATE_DISCONNECTED]:
				_drop_to_relay(peer, "link_lost")
				continue
		# Drain both channels regardless of state transitions this frame.
		while link.reliable.get_available_packet_count() > 0:
			var data := link.reliable.get_packet()
			packets_in += 1
			if link.switch_received:
				_incoming.push_back({"peer": peer, "data": data,
					"mode": MultiplayerPeer.TRANSFER_MODE_RELIABLE})
			else:
				link.held.push_back(data)
		while link.fast.get_available_packet_count() > 0:
			packets_in += 1
			_incoming.push_back({"peer": peer, "data": link.fast.get_packet(),
				"mode": MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED})


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

	# Connection timeout — if the relay hasn't promoted us past CONNECTING
	# within the deadline, give up instead of hanging forever.
	if _status == MultiplayerPeer.CONNECTION_CONNECTING:
		if Time.get_ticks_msec() - _connect_started_ms > CONNECT_TIMEOUT_MS:
			_ws.close()
			_status = MultiplayerPeer.CONNECTION_DISCONNECTED
			relay_failed.emit("connect_timeout")
			return

	# Keepalive ping — prevents Cloud Run / intermediate proxies from
	# dropping the WebSocket during idle periods (e.g. lobby waiting).
	if state == WebSocketPeer.STATE_OPEN:
		var now := Time.get_ticks_msec()
		if now - _last_ping_ms >= PING_INTERVAL_MS:
			_last_ping_ms = now
			_send_control({"op": "ping"})

	while _ws.get_available_packet_count() > 0:
		_handle_packet(_ws.get_packet())

	_poll_links()

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
			packets_in += 1
			if _mode == Mode.HOST:
				if pkt.size() < 5:
					return
				_incoming.push_back({"peer": pkt.decode_u32(1), "data": pkt.slice(5),
					"mode": MultiplayerPeer.TRANSFER_MODE_RELIABLE})
			else:
				_incoming.push_back({"peer": 1, "data": pkt.slice(1),
					"mode": MultiplayerPeer.TRANSFER_MODE_RELIABLE})


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
			var peer := int(msg.get("peer_id", 0))
			peer_connected.emit(peer)
			# Offer the direct path. If we can't (no extension / p2p=off) the
			# client never hears an offer and simply stays relayed — no
			# capability handshake needed.
			if p2p_enabled and rtc_available():
				var link := _create_link(peer)
				if link != null:
					link.pc.create_offer()
		"peer_left":
			var peer := int(msg.get("peer_id", 0))
			var link: RtcLink = _links.get(peer)
			if link != null:
				link.pc.close()
				_links.erase(peer)
			peer_disconnected.emit(peer)
		"host_left":
			_status = MultiplayerPeer.CONNECTION_DISCONNECTED
			_ws.close()
		"rtc":
			var payload = msg.get("payload")
			if payload is Dictionary:
				_handle_rtc(int(msg.get("peer_id", 1)), payload)


## `peer` is the signaling counterpart: the stamped sender id on the host, 1 on
## a client (the relay strips routing info — a client only talks to the host).
func _handle_rtc(peer: int, payload: Dictionary) -> void:
	var link: RtcLink = _links.get(peer)
	match payload.get("kind", ""):
		"offer":
			# Client side: the host wants a direct link. Mirror its channels
			# and answer (set_remote_description on an offer auto-creates one).
			if _mode != Mode.CLIENT or not p2p_enabled or not rtc_available():
				return
			if link == null:
				link = _create_link(peer)
			if link != null:
				link.pc.set_remote_description("offer", str(payload.get("sdp", "")))
		"answer":
			if link != null and _mode == Mode.HOST:
				link.pc.set_remote_description("answer", str(payload.get("sdp", "")))
		"ice":
			if link != null:
				link.pc.add_ice_candidate(str(payload.get("media", "")),
					int(payload.get("index", 0)), str(payload.get("name", "")))
		"switch":
			if link != null:
				_release_held(link)


func _get_available_packet_count() -> int:
	return _incoming.size()


func _get_packet_script() -> PackedByteArray:
	if _incoming.is_empty():
		return PackedByteArray()
	var entry: Dictionary = _incoming.pop_front()
	_last_packet_peer = entry["peer"]
	_last_packet_mode = entry["mode"]
	return entry["data"]


## Route one packet to one peer: open P2P link -> the data channel matching the
## transfer mode (with the reliable-side switch barrier and the SCTP size
## guard); anything else -> a relay data frame.
func _send_to_peer(peer: int, buffer: PackedByteArray, mode: int) -> Error:
	var link: RtcLink = _links.get(peer)
	if link != null and link.state == LinkState.P2P and buffer.size() <= DC_MAX_PACKET:
		if mode != MultiplayerPeer.TRANSFER_MODE_RELIABLE:
			packets_out += 1
			return link.fast.put_packet(buffer)
		if link.switch_sent:
			packets_out += 1
			return link.reliable.put_packet(buffer)
		# Reliable but pre-switch: keep using the relay so ordering holds.
	if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return ERR_UNCONFIGURED
	var buf := PackedByteArray([FRAME_DATA])
	if _mode == Mode.HOST:
		var header := PackedByteArray()
		header.resize(4)
		header.encode_u32(0, peer)
		buf.append_array(header)
	buf.append_array(buffer)
	packets_out += 1
	return _ws.send(buf, WebSocketPeer.WRITE_MODE_BINARY) as Error


func _put_packet_script(buffer: PackedByteArray) -> Error:
	if _mode == Mode.CLIENT:
		return _send_to_peer(1, buffer, _transfer_mode)
	# Host: expand broadcast/exclusion into per-peer unicasts. The relay's
	# native broadcast (target 0) can't be used once links diverge — a P2P
	# peer would receive the relay copy too and see every packet twice.
	if _target_peer > 0:
		return _send_to_peer(_target_peer, buffer, _transfer_mode)
	var exclude := -_target_peer
	var err := OK
	for peer in _links:
		if peer == exclude:
			continue
		var e := _send_to_peer(peer, buffer, _transfer_mode)
		if e != OK:
			err = e
	return err


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
	if _incoming.is_empty():
		return _last_packet_mode
	return _incoming[0]["mode"]


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
	for peer in _links:
		_links[peer].pc.close()
	_links.clear()
	_ws.close()
	_status = MultiplayerPeer.CONNECTION_DISCONNECTED
