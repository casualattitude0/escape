extends Node
class_name DeviceSystem

## Sabotage progress (server-authoritative; owned by the GameManager).
##
## The Runner's only way forward (GDD 4.1): stand next to one of DEVICE_COUNT
## devices and mash the attack key until it breaks. Break them all and the escape
## point opens.
##
## The point of making this a mash you have to stand still for is that advancing
## and being exposed are the same act — a Runner just running around is nearly
## uncatchable, so the Hunters' job is to guard devices, not to give chase.
##
## Getting stunned mid-mash costs ROLLBACK_HITS of that device's progress: that is
## the entire payoff for the Hunters' three knocks, and the reason a stun is worth
## anything at all when they cannot kill the Runner.

const DEVICE_COUNT := 4          # devices that must be broken to open the escape
const HITS_PER_DEVICE := 10      # accepted mashes to break one device
const ROLLBACK_HITS := 3         # mashes lost when a stun interrupts the work
const DEVICE_RANGE := 48.0       # how close the Runner must be to mash a device

# Progress is counted in whole mashes, not as a 0..1 float. Adding 0.1 ten times
# lands on 0.9999999999999999, so a float device would silently need an eleventh
# hit and never compare equal to full. Counting hits is exact, and the ratio the
# UI wants is a division away.
var progress := {}               # int device index -> int hits landed
var active_index := -1           # device being mashed right now (-1 = none)

func hits(idx: int) -> int:
	return int(progress.get(idx, 0))

func ratio(idx: int) -> float:
	return float(hits(idx)) / float(HITS_PER_DEVICE)

func done(idx: int) -> bool:
	return hits(idx) >= HITS_PER_DEVICE

func destroyed_count() -> int:
	var n := 0
	for i in DEVICE_COUNT:
		if done(i):
			n += 1
	return n

func all_destroyed() -> bool:
	return destroyed_count() >= DEVICE_COUNT

## Land one mash on device `idx`. Returns true when this hit finishes it.
func hit(idx: int) -> bool:
	if done(idx):
		return false
	active_index = idx
	progress[idx] = mini(HITS_PER_DEVICE, hits(idx) + 1)
	if done(idx):
		active_index = -1
		return true
	return false

## The Runner was stunned: knock the device it was working on back a chunk. This
## is what a stun actually costs the Runner (GDD 4.6) — the stun itself is only
## time, this is the lost ground.
func on_runner_stunned() -> void:
	if active_index < 0:
		return
	progress[active_index] = maxi(0, hits(active_index) - ROLLBACK_HITS)
	active_index = -1

func force_end() -> void:
	active_index = -1
