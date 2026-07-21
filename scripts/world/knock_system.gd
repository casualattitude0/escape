extends Node
class_name KnockSystem

## The knock-to-stun state (server-authoritative; owned by the GameManager).
##
## Hunters cannot kill the Runner — knocking it is their only verb, and it buys
## time rather than winning (GDD 4.6). Three knocks stun it; every knock opens an
## invulnerability window and kicks it away from whatever it was breaking.
##
## Knocks BANK: the count never bleeds off on its own. Once a knock lands it stays
## on the Runner until the third one stuns and resets the tally — time passing does
## nothing to it. So the two knobs that decide whether Hunters can hold the Runner
## (GDD 7) are:
##   * IFRAME_TIME  — the gap nobody can knock through. Note it is global to the
##     Runner, not per-Hunter: a second Hunter cannot knock inside it either, so
##     piling on more Hunters does not stun any faster. What extra Hunters buy is
##     coverage — more angles the Runner has to break away from.
##   * STUN_TIME    — how much of the Runner's clock a full stun burns.

const KNOCKS_TO_STUN := 3
const IFRAME_TIME := 1.20        # invulnerable after getting up from a stun
const STUN_TIME := 2.50          # how long a stunned Runner is frozen
const KNOCK_RANGE := 64.0        # how close a Hunter must be to knock (~2 tiles)
const KNOCKBACK_VX := 480.0      # horizontal kick, aimed along the knocker's facing

var knocks := 0                  # 0..KNOCKS_TO_STUN-1 (a full count stuns and resets)
var iframe_left := 0.0
var stun_left := 0.0

## Advance the timers. Returns true only when a DISCRETE change landed that the
## clients need told about promptly — a window closing or a stun ending.
##
## Deliberately not "true whenever a timer moved": the clients read these as
## booleans (stunned / invulnerable) and a count, so syncing a decrementing float
## every physics frame would push 60 packets a second down a relay that the rest
## of the game throttles to ~22Hz (see $Sync in player.gd). The half-second
## heartbeat in the GameManager covers any drift in between.
func tick(delta: float) -> bool:
	var changed := false
	if iframe_left > 0.0:
		iframe_left = maxf(0.0, iframe_left - delta)
		changed = changed or iframe_left <= 0.0     # window closed: knocks land again
	if stun_left > 0.0:
		stun_left = maxf(0.0, stun_left - delta)
		if stun_left <= 0.0:
			iframe_left = IFRAME_TIME
			changed = true
	return changed

func stunned() -> bool:
	return stun_left > 0.0

func invulnerable() -> bool:
	return iframe_left > 0.0

func knock_ratio() -> float:
	return float(knocks) / float(KNOCKS_TO_STUN)

## Server-side gate for one Hunter's tap: the Runner must be neither stunned nor
## inside an invulnerability window.
##
## This doubles as the rate limit, so there is no separate one. Every accepted
## knock opens an IFRAME_TIME window and this rejects everything inside it, so
## two knocks can never land closer together than that — a client mashing the key
## (or a hacked one spamming the rpc) gains exactly nothing.
func can_knock() -> bool:
	return stun_left <= 0.0 and iframe_left <= 0.0

## Land one knock. Returns true when this was the third (the Runner is stunned).
func add_knock() -> bool:
	knocks += 1
	if knocks >= KNOCKS_TO_STUN:
		knocks = 0
		stun_left = STUN_TIME
		return true
	return false

## Wipe everything (round over / restore).
func force_end() -> void:
	knocks = 0
	iframe_left = 0.0
	stun_left = 0.0
