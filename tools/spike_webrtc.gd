extends SceneTree

## Spike: verify the webrtc-native GDExtension behaves as HybridMultiplayerPeer
## (Phase 4) assumes — two in-process WebRTCPeerConnections, loopback ICE, and
## pre-negotiated data channels (id 1 reliable / id 2 ordered+maxRetransmits:0).
## Run: Godot --headless --path . --script tools/spike_webrtc.gd

var _a := WebRTCPeerConnection.new()
var _b := WebRTCPeerConnection.new()
var _a_reliable: WebRTCDataChannel
var _a_fast: WebRTCDataChannel
var _b_reliable: WebRTCDataChannel
var _b_fast: WebRTCDataChannel


func _initialize() -> void:
	print("[spike_webrtc]")
	print("  class exists: %s" % ClassDB.class_exists("WebRTCPeerConnectionExtension"))
	var init_a := _a.initialize({})
	var init_b := _b.initialize({})
	print("  initialize(): a=%d b=%d (0 is OK)" % [init_a, init_b])
	if init_a != OK or init_b != OK:
		printerr("  FAIL: initialize failed — extension not loaded?")
		quit(1)
		return

	_a_reliable = _a.create_data_channel("reliable", {"negotiated": true, "id": 1})
	_a_fast = _a.create_data_channel("fast", {"negotiated": true, "id": 2, "ordered": true, "maxRetransmits": 0})
	_b_reliable = _b.create_data_channel("reliable", {"negotiated": true, "id": 1})
	_b_fast = _b.create_data_channel("fast", {"negotiated": true, "id": 2, "ordered": true, "maxRetransmits": 0})
	print("  channels created: %s" % [[_a_reliable, _a_fast, _b_reliable, _b_fast].all(func(c): return c != null)])

	# Wire signaling directly (loopback "relay").
	_a.session_description_created.connect(func(type: String, sdp: String) -> void:
		_a.set_local_description(type, sdp)
		_b.set_remote_description(type, sdp))
	_b.session_description_created.connect(func(type: String, sdp: String) -> void:
		_b.set_local_description(type, sdp)
		_a.set_remote_description(type, sdp))
	_a.ice_candidate_created.connect(func(media: String, index: int, name: String) -> void:
		_b.add_ice_candidate(media, index, name))
	_b.ice_candidate_created.connect(func(media: String, index: int, name: String) -> void:
		_a.add_ice_candidate(media, index, name))

	var err := _a.create_offer()
	print("  create_offer: %d" % err)


var _frames := 0
var _sent := false


func _process(_delta: float) -> bool:
	_a.poll()
	_b.poll()
	_frames += 1

	var open := _a_reliable.get_ready_state() == WebRTCDataChannel.STATE_OPEN \
		and _a_fast.get_ready_state() == WebRTCDataChannel.STATE_OPEN \
		and _b_reliable.get_ready_state() == WebRTCDataChannel.STATE_OPEN \
		and _b_fast.get_ready_state() == WebRTCDataChannel.STATE_OPEN

	if open and not _sent:
		_sent = true
		print("  all 4 channels OPEN after %d frames" % _frames)
		_a_reliable.put_packet("hi-reliable".to_utf8_buffer())
		_a_fast.put_packet("hi-fast".to_utf8_buffer())
		_b_reliable.put_packet("yo-reliable".to_utf8_buffer())

	if _sent:
		var got_rel := _b_reliable.get_available_packet_count() > 0
		var got_fast := _b_fast.get_available_packet_count() > 0
		var got_back := _a_reliable.get_available_packet_count() > 0
		if got_rel and got_fast and got_back:
			print("  b<-reliable: %s" % _b_reliable.get_packet().get_string_from_utf8())
			print("  b<-fast:     %s" % _b_fast.get_packet().get_string_from_utf8())
			print("  a<-reliable: %s" % _a_reliable.get_packet().get_string_from_utf8())
			print("ALL OK")
			quit(0)
			return true

	if _frames > 1800:   # ~30s: something is stuck
		printerr("  FAIL: timed out; states rel_a=%d fast_a=%d rel_b=%d fast_b=%d conn_a=%d conn_b=%d"
			% [_a_reliable.get_ready_state(), _a_fast.get_ready_state(),
			_b_reliable.get_ready_state(), _b_fast.get_ready_state(),
			_a.get_connection_state(), _b.get_connection_state()])
		quit(1)
		return true
	return false
