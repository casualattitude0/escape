extends Node
class_name ShieldSystem

## The Runner's break-time force field (GDD 4.1). While the Runner is parked at a
## device with a medium, a shield is up: a Hunter's knock hits the SHIELD, not the
## Runner, so it can mash in safety. The shield has HP but NO time limit — it only
## falls when Hunters knock it down. So an unguarded device is broken freely, and
## "more Hunters -> faster break" is how "單人拖不住、多人才行" plays out at a device.
##
## When it breaks it goes on COOLDOWN: for that window the Runner is exposed and
## knocks land normally (toward the 3-hit stun, KnockSystem). Survive the window and
## the shield re-raises; get stunned and the medium goes home (game_manager._on_stun).
##
## Server-authoritative; up/hp are replicated through the GameManager sync so every
## peer draws the same bubble. The per-Hunter hit rate limit lives on the GameManager
## (it owns peer ids); this node is just the state.
##
## Tuning is load-bearing for "單人拖不住" (with KnockSystem IFRAME_TIME=1.20,
## KNOCK_DECAY=4.0, KNOCKS_TO_STUN=3):
##   * SHIELD_HP * (per-Hunter hit CD) > KNOCK_DECAY  → a lone Hunter's shield-up
##     phase outlasts the decay, so its 1-2 knocks per window never accumulate to 3.
##   * COOLDOWN < 2 * IFRAME_TIME  → at most 2 knocks land in one exposure window,
##     so no single window can deliver a 3-stun on its own.
## Several Hunters break the shield in parallel (short shield-up phases), so the
## count survives between windows and a stun lands — exactly the intended asymmetry.

const SHIELD_HP := 3          # Hunter hits to break the shield
const SHIELD_HIT_CD := 0.3    # per-Hunter seconds between shield hits (see GameManager)
const COOLDOWN := 2.0         # seconds the shield is down after breaking (exposure window)

var up := false               # shield currently raised
var hp := 0                   # current shield health (0 when down)
var cooldown := 0.0           # recharge time left after a break

func is_up() -> bool:
	return up

func ratio() -> float:
	return float(hp) / float(SHIELD_HP)

## Per-frame upkeep (server). `breaking` is true when the Runner is parked at a
## device with a medium (server truth). Raises the shield when engaged and off
## cooldown, ticks the cooldown, and lowers it when the Runner disengages. Returns
## true on a discrete change so the caller can broadcast.
func tick(breaking: bool, delta: float) -> bool:
	var changed := false
	if cooldown > 0.0:
		cooldown -= delta
		if cooldown <= 0.0:
			cooldown = 0.0
			changed = true
	if breaking:
		if not up and cooldown <= 0.0:
			up = true
			hp = SHIELD_HP
			changed = true
	elif up:
		# Left the device (or lost the medium): the shield simply drops — no
		# cooldown, it wasn't broken. A cooldown from a real break keeps ticking
		# regardless of engagement, so leaving and returning can't refresh it.
		up = false
		changed = true
	return changed

## A Hunter knock landed on the raised shield. Returns true if it broke.
func hit() -> bool:
	if not up:
		return false
	hp -= 1
	if hp <= 0:
		hp = 0
		up = false
		cooldown = COOLDOWN
		return true
	return false

func force_end() -> void:
	up = false
	hp = 0
	cooldown = 0.0
