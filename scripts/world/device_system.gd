extends Node
class_name DeviceSystem

## Sabotage progress (server-authoritative; owned by the GameManager).
##
## The Runner's only way forward (GDD 4.1): stand next to one of DEVICE_COUNT
## devices and mash the attack key until it breaks. Break them all and the escape
## point opens.
##
## The point of making this a mash you have to stand still for is that advancing
## and being exposed are the same act — but the Runner also has to have carried a
##破壞媒材 here first (GameManager gates the mash on carrying), so the transport is
## a second, moving exposure window on top of this stationary one.
##
## Progress is a PERMANENT RATCHET (GDD 4.1): it never rolls back. A stun no longer
## claws back hits — it sends the carried medium home and burns the Runner's clock.
## So the Hunters cannot un-break what is broken; their only lever is time.

const DEVICE_COUNT := 4          # default device count (fallback when none authored)
const HITS_PER_DEVICE := 10      # accepted mashes to break one device
const DEVICE_RANGE := 48.0       # how close the Runner must be to mash a device

# Actual number of devices in play. Devices are authored (painted on Device_tiles
# and grouped into clusters, world.gd), so the count is data, set on every peer in
# _build_layout. Defaults to DEVICE_COUNT for the procedural fallback path.
var device_count := DEVICE_COUNT

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
	for i in device_count:
		if done(i):
			n += 1
	return n

func all_destroyed() -> bool:
	return device_count > 0 and destroyed_count() >= device_count

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

func force_end() -> void:
	active_index = -1
