extends Node

## Pins the Godot semantics that the Runner's attack depends on:
## a peer calling rpc_id(1) on ITSELF (the host is the Runner) only executes the
## method when the rpc is declared "call_local". Without it the call is silently
## dropped — no error, nothing happens.
##
## Run: Godot --headless --path . tools/test_rpc_call_local.tscn

var _with_local := 0
var _without_local := 0
var _sender_seen := -1

@rpc("any_peer", "call_local", "reliable")
func with_call_local() -> void:
	_with_local += 1
	_sender_seen = multiplayer.get_remote_sender_id()

@rpc("any_peer", "reliable")
func without_call_local() -> void:
	_without_local += 1

func _ready() -> void:
	var failed := 0
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(47999, 4)
	if err != OK:
		print("FAIL (could not open a test server: %d)" % err)
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer
	print("Godot rpc self-call semantics (host id = %d)" % multiplayer.get_unique_id())

	with_call_local.rpc_id(1)
	without_call_local.rpc_id(1)
	await get_tree().process_frame
	await get_tree().process_frame

	if _with_local == 1:
		print("  ok   rpc_id(1) on self RUNS when declared call_local")
	else:
		failed += 1
		print("  FAIL call_local self-call ran %d times (expected 1)" % _with_local)

	if _without_local == 0:
		print("  ok   rpc_id(1) on self is SILENTLY DROPPED without call_local")
		print("       ^ this is why the Runner (== the host) could not attack")
	else:
		failed += 1
		print("  FAIL no-call_local self-call ran %d times (expected 0)" % _without_local)

	# A call_local self-call reports OUR OWN id, not 0 — so game_manager's
	# _sender_id() finds the host's own player node correctly. Its 0 fallback only
	# covers a direct (non-rpc) invocation.
	if _sender_seen == multiplayer.get_unique_id():
		print("  ok   a local call reports sender id %d (our own id), not 0" % _sender_seen)
	else:
		failed += 1
		print("  FAIL local call reported sender %d (expected %d)"
			% [_sender_seen, multiplayer.get_unique_id()])

	multiplayer.multiplayer_peer = null
	peer.close()

	failed += _check_game_rpcs()
	print("%s (%d failed)" % ["PASS" if failed == 0 else "FAIL", failed])
	get_tree().quit(1 if failed > 0 else 0)

# Every rpc below can have the HOST as its target, because the host is the Runner:
# the Runner rpc_id(1)s the GameManager (itself), and the server rpc_id()s the
# Runner's own peer (itself) right back. Each one therefore has to be call_local
# or it is dropped on the floor. This is the guard for the bug where the Runner
# could not attack, sabotage, or be stunned at all.
const MUST_BE_CALL_LOCAL := {
	"res://scripts/world/game_manager.gd": ["hunter_press", "sabotage_press", "attack_press"],
	"res://scripts/player/player.gd": ["kill", "stun", "knockback", "attack_confirmed"],
}

func _check_game_rpcs() -> int:
	print("Game rpcs that can target the host must be call_local")
	var bad := 0
	for path in MUST_BE_CALL_LOCAL:
		var script: Script = load(path)
		var cfg: Dictionary = script.get_rpc_config()
		for method in MUST_BE_CALL_LOCAL[path]:
			var entry = cfg.get(method)
			if entry == null:
				bad += 1
				print("  FAIL %s.%s has no rpc config at all" % [path.get_file(), method])
			elif not bool(entry.get("call_local", false)):
				bad += 1
				print("  FAIL %s.%s is NOT call_local -> the host's own call is dropped"
					% [path.get_file(), method])
			else:
				print("  ok   %s.%s is call_local" % [path.get_file(), method])
	return bad
