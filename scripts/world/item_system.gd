extends Node
class_name ItemSystem

## The Runner's escape progress (server-authoritative; owned by the GameManager).
##
## New model (GDD 4.1): the Runner ferries interchangeable keys one at a time to
## a door. Each door needs PER_DOOR keys installed; completing ANY one door wins.
##   * `carrying` — is the Runner currently holding a key (its main capturable /
##     exposed window). Getting captured while carrying scatters that key.
##   * `installs` — door index -> keys installed so far. Installed keys are safe.

const KEYS_TOTAL := 3      # keys present in the world
const PER_DOOR := 3        # keys a single door needs to open

var carrying := false
var installs := {}         # int door index -> int installed count

func door_installs(idx: int) -> int:
	return int(installs.get(idx, 0))

## Install one key into a door. Returns the door's new count.
func install(idx: int) -> int:
	var n := door_installs(idx) + 1
	installs[idx] = n
	return n

func door_open(idx: int) -> bool:
	return door_installs(idx) >= PER_DOOR

func any_open() -> bool:
	for k in installs:
		if int(installs[k]) >= PER_DOOR:
			return true
	return false

## Highest install count across all doors (for HUD "best door 2/3").
func best_progress() -> int:
	var m := 0
	for k in installs:
		m = maxi(m, int(installs[k]))
	return m
