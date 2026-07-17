class_name NetStats
extends Node

## Net's measurement child ("/root/Net/Stats" on every peer — the fixed path is
## what makes the RPCs below resolvable). Two jobs:
##   1. RTT probe: ~1 Hz ping/pong per link, EMA-smoothed into rtt_ms.
##      Clients probe the host; the host probes every client.
##   2. F3 debug overlay: RTT, transport kind, packet rates, fakelag.
## The pong echoes the sender's own timestamp, so only the sender's clock is
## ever read — no cross-machine clock assumptions.

const PING_INTERVAL := 1.0
const EMA_ALPHA := 0.3

# peer_id -> smoothed RTT in ms. On a client this only ever holds key 1.
var rtt_ms: Dictionary = {}

# host_ticks_msec ≈ Time.get_ticks_msec() + host_time_offset, maintained from
# the "ht" stamps GameManager piggybacks on its state syncs. Lag compensation
# (player_combat._render_host_time) is the consumer. 0 on the host itself.
var host_time_offset := 0.0
var _offset_init := false

var _ping_accum := 0.0
var _overlay: CanvasLayer
var _label: Label
var _overlay_accum := 0.0

# in/out packets counted since the last overlay refresh (fed by RelayMultiplayerPeer).
var _last_counts := Vector2i.ZERO


func rtt(peer_id: int = 1) -> float:
	return rtt_ms.get(peer_id, 0.0)

## Fold in a host-clock stamp (client side only). The stamp left the host one
## way-trip ago, so adding rtt/2 lines its timeline up with our arrival clock.
## First stamp seeds the offset; later ones EMA in, riding out ping wobble.
func note_host_time(ht: int) -> void:
	if ht <= 0 or multiplayer.is_server():
		return
	var est := float(ht) + rtt(1) * 0.5 - float(Time.get_ticks_msec())
	if _offset_init:
		host_time_offset = lerpf(host_time_offset, est, 0.1)
	else:
		host_time_offset = est
		_offset_init = true


func _process(delta: float) -> void:
	_ping_accum += delta
	if _ping_accum >= PING_INTERVAL:
		_ping_accum = 0.0
		_send_pings()
	if _overlay != null and _overlay.visible:
		_overlay_accum += delta
		if _overlay_accum >= 0.25:
			_overlay_accum = 0.0
			_refresh_overlay()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_F3:
		_toggle_overlay()


func _connected() -> bool:
	var p := multiplayer.multiplayer_peer
	return p != null and not (p is OfflineMultiplayerPeer) \
		and p.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func _send_pings() -> void:
	if not _connected():
		return
	if multiplayer.is_server():
		for id in multiplayer.get_peers():
			_ping.rpc_id(id, Time.get_ticks_msec())
	else:
		_ping.rpc_id(1, Time.get_ticks_msec())


@rpc("any_peer", "unreliable")
func _ping(t: int) -> void:
	_pong.rpc_id(multiplayer.get_remote_sender_id(), t)


@rpc("any_peer", "unreliable")
func _pong(t: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	var sample := float(Time.get_ticks_msec() - t)
	if rtt_ms.has(sender):
		rtt_ms[sender] = lerpf(rtt_ms[sender], sample, EMA_ALPHA)
	else:
		rtt_ms[sender] = sample
	# Under fakelag print samples, so headless runs can verify rtt ≈ 2×fakelag.
	if Net.fakelag_ms > 0:
		print("[NetStats] rtt -> %d: %.0f ms" % [sender, rtt_ms[sender]])


# ---- overlay ----------------------------------------------------------------

func _toggle_overlay() -> void:
	if _overlay == null:
		_overlay = CanvasLayer.new()
		_overlay.layer = 100
		_label = Label.new()
		_label.position = Vector2(8, 8)
		_label.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
		_label.add_theme_color_override("font_outline_color", Color.BLACK)
		_label.add_theme_constant_override("outline_size", 3)
		_overlay.add_child(_label)
		add_child(_overlay)
		_refresh_overlay()
		return
	_overlay.visible = not _overlay.visible
	_overlay_accum = 0.0


func _refresh_overlay() -> void:
	var lines: PackedStringArray = []
	lines.append("net %s  id=%d" % [Net.transport_kind(), multiplayer.get_unique_id()])
	if Net.fakelag_ms > 0:
		lines.append("fakelag %d ms (one-way, this side)" % Net.fakelag_ms)
	for id in rtt_ms:
		lines.append("rtt -> %d: %.0f ms" % [id, rtt_ms[id]])
	if Net.transport_kind() != "LAN" and _connected():
		for id in multiplayer.get_peers():
			lines.append("link %d: %s" % [id, "P2P" if Net.link_is_p2p(id) else "RELAY"])
	var counts := _relay_counts()
	if counts != Vector2i(-1, -1):
		var dt := 0.25
		lines.append("relay pkts  in %.0f/s  out %.0f/s"
			% [(counts.x - _last_counts.x) / dt, (counts.y - _last_counts.y) / dt])
		_last_counts = counts
	_label.text = "\n".join(lines)


## (in, out) packet totals from the relay peer, or (-1,-1) when not on the relay.
func _relay_counts() -> Vector2i:
	var p := multiplayer.multiplayer_peer
	if p is LagPeer:
		p = p.inner
	if p is RelayMultiplayerPeer:
		return Vector2i(p.packets_in, p.packets_out)
	return Vector2i(-1, -1)
