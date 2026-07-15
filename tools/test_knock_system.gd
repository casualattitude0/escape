extends SceneTree

## Headless check of the KnockSystem rules (GDD 4.6). Run:
##   Godot --headless --script tools/test_knock_system.gd
##
## These assert the three knobs that decide whether the core loop holds up:
## a lone Hunter cannot mash through an iframe, knocks are not banked forever,
## and three of them stun.

var _failed := 0

func _assert(cond: bool, what: String) -> void:
	if cond:
		print("  ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL %s" % what)

## Burn `secs` of KnockSystem time in physics-sized steps.
func _advance(k: KnockSystem, secs: float) -> void:
	var step := 1.0 / 60.0
	var t := 0.0
	while t < secs:
		k.tick(step)
		t += step

func _init() -> void:
	print("KnockSystem rules")

	# --- three knocks stun, and the count resets behind them ------------------
	var k := KnockSystem.new()
	_assert(not k.add_knock(), "1st knock does not stun")
	_advance(k, KnockSystem.IFRAME_TIME)
	_assert(not k.add_knock(), "2nd knock does not stun")
	_advance(k, KnockSystem.IFRAME_TIME)
	_assert(k.add_knock(), "3rd knock stuns")
	_assert(k.stunned(), "Runner is stunned")
	_assert(k.knocks == 0, "count resets after the stun")

	# --- the iframe is the whole valve, and the only rate limit ---------------
	k = KnockSystem.new()
	k.add_knock()
	_assert(not k.can_knock(), "blocked inside the iframe (so mashing gains nothing)")
	_advance(k, KnockSystem.IFRAME_TIME + 0.02)
	_assert(k.can_knock(), "iframe expires and knocks land again")

	# --- knocks are not banked ------------------------------------------------
	k = KnockSystem.new()
	k.add_knock()
	k.knocks = 2                      # pretend two landed, then the Hunters lose it
	_advance(k, KnockSystem.KNOCK_DECAY + 0.05)
	_assert(k.knocks == 0, "count decays to zero when nobody follows up")

	# --- a stunned Runner cannot be knocked again ----------------------------
	k = KnockSystem.new()
	k.add_knock()
	_advance(k, KnockSystem.IFRAME_TIME)
	k.add_knock()
	_advance(k, KnockSystem.IFRAME_TIME)
	k.add_knock()                     # stunned now
	_advance(k, KnockSystem.IFRAME_TIME + 0.02)
	_assert(not k.can_knock(), "no knocking a Runner that is already stunned")
	_advance(k, KnockSystem.STUN_TIME)
	_assert(not k.stunned(), "stun expires")
	_assert(k.can_knock(), "knocks land again once the stun ends")

	# --- how long does a solo Hunter need? (the balance question, GDD 8) -----
	var solo := (KnockSystem.KNOCKS_TO_STUN - 1) * KnockSystem.IFRAME_TIME
	print("  note: %d knocks take a lone Hunter >= %.1fs of contact" \
		% [KnockSystem.KNOCKS_TO_STUN, solo])
	_assert(solo < KnockSystem.KNOCK_DECAY,
		"a solo Hunter CAN stun a Runner that stands still (iframe gap < decay)")

	print("%s (%d failed)" % ["PASS" if _failed == 0 else "FAIL", _failed])
	quit(1 if _failed > 0 else 0)
